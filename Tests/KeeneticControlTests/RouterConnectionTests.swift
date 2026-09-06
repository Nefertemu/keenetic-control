import XCTest
@testable import KeeneticControl

@MainActor
final class RouterConnectionTests: XCTestCase {
    func testConcurrentReadersSharePublishedConnection() async throws {
        let gate = TransportGate(), transport = FakeTransport()
        transport.onConnect = { try gate.wait() }
        let fixture = SessionFixture(transport), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        let first = Task { try await session.readConfigText() }
        await fulfillment(of: [gate.started], timeout: 2)
        let second = Task { try await session.readConfigText() }
        await Task.yield()
        gate.release()
        let results = try await [first.value, second.value]
        XCTAssertEqual(results, [RegressionFixtures.sampleConfig, RegressionFixtures.sampleConfig])
        XCTAssertEqual(fixture.opened.count, 1)
        XCTAssertTrue(session.status.isOnline)
    }

    func testCancellingOneWaiterKeepsOtherConnected() async throws {
        let gate = TransportGate(), transport = FakeTransport()
        transport.onConnect = { try gate.wait() }
        transport.onAbort = { gate.release() }
        let fixture = SessionFixture(transport), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        let first = Task { try await session.connect() }
        await fulfillment(of: [gate.started], timeout: 2)
        let secondStarted = expectation(description: "Second waiter")
        let second = Task { secondStarted.fulfill(); try await session.connect() }
        await fulfillment(of: [secondStarted], timeout: 2)
        first.cancel()
        do { try await first.value; XCTFail("Cancelled waiter succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(transport.abortCount, 0)
        gate.release()
        try await second.value
        XCTAssertTrue(session.status.isOnline)
    }

    func testCancellingLastWaiterAbortsAndAllowsReconnect() async throws {
        let gate = TransportGate(), transport = FakeTransport(), next = FakeTransport()
        transport.onConnect = { try gate.wait() }
        transport.onAbort = { gate.release() }
        let fixture = SessionFixture(transport, next), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        let task = Task { try await session.connect() }
        await fulfillment(of: [gate.started], timeout: 2)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled connection succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await session.connect()
        XCTAssertGreaterThan(transport.abortCount, 0)
        XCTAssertEqual(fixture.opened.count, 2)
        XCTAssertTrue(session.status.isOnline)
    }

    func testSwitchRouterDuringReadPreservesOwner() async throws {
        let gate = TransportGate(), a = FakeTransport(), b = FakeTransport()
        a.onRead = { try gate.wait(); return "configuration A" }
        b.onRead = { "configuration B" }
        let fixture = SessionFixture(a, b), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        let task = Task { try await session.readConfigText() }
        await fulfillment(of: [gate.started], timeout: 2)
        let other = RouterProfile(name: "Other", host: "other.invalid")
        await session.switchTo(other)
        let configB = try await session.readConfigText()
        gate.release()
        let configA = try await task.value
        XCTAssertEqual(configA, "configuration A")
        XCTAssertEqual(configB, "configuration B")
        XCTAssertEqual(session.router.id, other.id)
        XCTAssertTrue(session.isConnected(fixture.profile.id))
        XCTAssertTrue(session.status.isOnline)
    }

    func testEditedProfileRejectsLateFailureWithoutDroppingNewConnection() async throws {
        let gate = TransportGate(), stale = FakeTransport(), fresh = FakeTransport()
        stale.onRead = {
            try gate.wait()
            throw TransportError("Old session failed", isSessionFailure: true)
        }
        let fixture = SessionFixture(stale, fresh), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        let task = Task { try await session.readConfigText() }
        await fulfillment(of: [gate.started], timeout: 2)
        var edited = fixture.profile
        edited.host = "new.invalid"
        session.profileDidChange(edited)
        let newConnection = Task { try await session.connect() }
        gate.release()
        do { _ = try await task.value; XCTFail("Stale read succeeded") } catch {}
        try await newConnection.value
        XCTAssertEqual(session.router.host, "new.invalid")
        XCTAssertEqual(fixture.opened.map(\.host), ["fixture.invalid", "new.invalid"])
        XCTAssertTrue(session.status.isOnline)
        XCTAssertTrue(fresh.isAlive)
    }

    func testDisconnectAbortsBlockedRead() async throws {
        let gate = TransportGate(), transport = FakeTransport()
        transport.onRead = { try gate.wait(); return "stale" }
        transport.onAbort = { gate.release() }
        let fixture = SessionFixture(transport), session = fixture.session()
        let task = Task { try await session.readConfigText() }
        await fulfillment(of: [gate.started], timeout: 2)
        await session.disconnect()
        do { _ = try await task.value; XCTFail("Disconnected read succeeded") } catch {}
        XCTAssertEqual(session.status, .offline)
        XCTAssertGreaterThan(transport.abortCount, 0)
    }

    func testSessionFailureRetriesReadExactlyOnce() async throws {
        let stale = FakeTransport(), fresh = FakeTransport()
        stale.onRead = { throw TransportError("Expired", isSessionFailure: true) }
        fresh.onRead = { "fresh configuration" }
        let fixture = SessionFixture(stale, fresh), session = fixture.session()
        defer { session.disconnectAll() }
        let text = try await session.readConfigText()
        XCTAssertEqual(text, "fresh configuration")
        XCTAssertEqual(fixture.opened.count, 2)
        XCTAssertEqual(stale.commands, ["show running-config"])
        XCTAssertEqual(fresh.commands, ["show running-config"])
    }

    func testRepeatedSessionFailureStopsAfterOneRetry() async {
        let a = FakeTransport(), b = FakeTransport()
        a.onRead = { throw TransportError("Expired", isSessionFailure: true) }
        b.onRead = a.onRead
        let fixture = SessionFixture(a, b), session = fixture.session()
        defer { session.disconnectAll() }
        do { _ = try await session.readConfigText(); XCTFail("Read succeeded") } catch {}
        XCTAssertEqual(fixture.opened.count, 2)
        XCTAssertFalse(session.status.isOnline)
    }

    func testAuthFailureDoesNotRetryAndNewHostClearsBlock() async throws {
        let denied = FakeTransport(), fresh = FakeTransport()
        denied.onConnect = { throw TransportError("Denied", isAuthFailure: true) }
        let fixture = SessionFixture(denied, fresh), session = fixture.session()
        defer { session.disconnectAll() }
        for _ in 0..<2 {
            do { try await session.connect(); XCTFail("Auth succeeded") } catch {}
        }
        XCTAssertEqual(fixture.opened.count, 1)
        XCTAssertNotNil(session.authBlock(fixture.profile.id))
        var edited = fixture.profile
        edited.host = "new.invalid"
        session.profileDidChange(edited)
        try await session.connect()
        XCTAssertNil(session.authBlock(fixture.profile.id))
        XCTAssertTrue(session.status.isOnline)
    }

    func testFilesAreIsolatedFromUserSettings() {
        XCTAssertTrue(AppPaths.support.lastPathComponent.hasPrefix("KeeneticControl-tests-"))
    }
}
