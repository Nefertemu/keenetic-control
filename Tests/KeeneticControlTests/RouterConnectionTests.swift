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

    func testWatchRejectsSuccessfulTransportResultAfterTimeout() async throws {
        let gate = TransportGate(), transport = FakeTransport()
        transport.onRun = { _ in try gate.wait(); return "partial response" }
        transport.onAbort = { gate.release() }
        let fixture = SessionFixture(transport), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        try await session.connect()
        do {
            _ = try await session.connections.watch(transport, budget: 0.02,
                                                     owner: fixture.profile.id) {
                try transport.run("show version")
            }
            XCTFail("A response received after the deadline was accepted")
        } catch { XCTAssertTrue(error is OperationTimeout, "\(error)") }
        XCTAssertEqual(transport.abortCount, 1)
    }

    func testCompletedOperationCannotAbortFollowingWork() throws {
        let cancellation = OperationCancellation()
        XCTAssertEqual(try cancellation.perform { "complete" }, "complete")
        var aborts = 0
        XCTAssertFalse(cancellation.cancel(abort: { aborts += 1 }))
        XCTAssertFalse(cancellation.cancel(OperationTimeout(), abort: { aborts += 1 }))
        XCTAssertEqual(aborts, 0)
    }

    func testCancellingQueuedReadPreservesHealthyConnection() async throws {
        let gate = TransportGate(), transport = FakeTransport()
        transport.onRead = { try gate.wait(); return "configuration" }
        transport.onAbort = { gate.release() }
        let fixture = SessionFixture(transport), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        let first = Task { try await session.readConfigText() }
        await fulfillment(of: [gate.started], timeout: 2)
        let queued = expectation(description: "Second read enqueued")
        let second = Task {
            queued.fulfill()
            return try await session.readConfigText()
        }
        await fulfillment(of: [queued], timeout: 2)
        second.cancel()
        gate.release()
        _ = try await first.value
        do { _ = try await second.value; XCTFail("Cancelled read succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(session.status.isOnline)
        XCTAssertTrue(transport.isAlive)
        XCTAssertEqual(transport.abortCount, 0)
        XCTAssertEqual(transport.commands, ["show running-config"])
    }

    func testConnectReplacesDeadTransport() async throws {
        let stale = FakeTransport(), fresh = FakeTransport()
        let fixture = SessionFixture(stale, fresh), session = fixture.session()
        defer { session.disconnectAll() }
        try await session.connect()
        stale.abort()
        try await session.connect()
        XCTAssertEqual(fixture.opened.count, 2)
        XCTAssertTrue(fresh.isAlive)
        XCTAssertTrue(session.status.isOnline)
    }

    func testLateLiveStatusPreservesLatestConfiguration() {
        let fixture = SessionFixture(), session = fixture.session()
        var state = RouterState(configText: "latest configuration", readAt: Date(timeIntervalSince1970: 2))
        state.interfaces["Wireguard0"] = KeeneticInterface(ident: "Wireguard0")
        state.wireguardInterfaces = ["Wireguard0", "Wireguard1"]
        session.connections.store(state: state, owner: fixture.profile.id)
        var incoming = KeeneticInterface(ident: "Wireguard0")
        incoming.pingCheckSuccessCount = 42

        _ = session.connections.mergeLiveInterface(incoming, ident: "Wireguard0", owner: fixture.profile.id)

        XCTAssertEqual(session.state?.configText, state.configText)
        XCTAssertEqual(session.state?.readAt, state.readAt)
        XCTAssertEqual(session.state?.wireguardInterfaces, state.wireguardInterfaces)
        XCTAssertEqual(session.state?.interfaces["Wireguard0"]?.pingCheckSuccessCount, 42)
    }

    func testCancellingConnectionMonitorKeepsHealthySession() async throws {
        let gate = TransportGate(), transport = FakeTransport()
        transport.onRun = { _ in try gate.wait(); return "version" }
        let fixture = SessionFixture(transport), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        try await session.connect()
        let monitor = Task { await session.monitorConnections() }
        await fulfillment(of: [gate.started], timeout: 2)
        monitor.cancel()
        gate.release()
        await monitor.value
        XCTAssertTrue(session.status.isOnline)
        XCTAssertTrue(transport.isAlive)
        XCTAssertEqual(transport.abortCount, 0)
    }

    func testConfigurationReadsRejectEmptyAndCLIErrorReplies() async throws {
        for reply in ["", " \r\n\t", "error: command failed", "unknown command",
                      "Command::Base error[7405600]: no such command"] {
            let transport = FakeTransport(), fixture = SessionFixture(transport)
            transport.onRead = { reply }
            let session = fixture.session()
            defer { session.disconnectAll() }
            do { _ = try await session.readConfigText(); XCTFail("Invalid running-config was accepted") }
            catch { XCTAssertTrue(error is TransportError) }
            do { _ = try await session.readStartupConfig(); XCTFail("Invalid startup-config was accepted") }
            catch { XCTAssertTrue(error is TransportError) }
            XCTAssertTrue(fixture.backups.isEmpty)
            XCTAssertEqual(transport.commands, ["show running-config", "show startup-config"])
        }
    }

    func testConfigurationReadsAcceptMinimalConfigAndErrorWordsInDescriptions() async throws {
        for config in ["hostname router", "hostname error:example\ninterface Wireguard0\n"
                       + " description error: резервный туннель\n"
                       + " description \"Command::Base error[7405600]: example\"\n"
                       + " description unknown command example\n"] {
            let transport = FakeTransport(), fixture = SessionFixture(transport)
            transport.onRead = { config }
            let session = fixture.session()
            defer { session.disconnectAll() }
            let running = try await session.readConfigText()
            let startup = try await session.readStartupConfig()
            XCTAssertEqual(running, config)
            XCTAssertEqual(startup, config)
        }
    }
}
