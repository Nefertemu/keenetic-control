import XCTest
@testable import KeeneticControl

@MainActor
final class RouterPlanTests: XCTestCase {
    func testDryRunHasNoExternalEffects() async throws {
        let fixture = SessionFixture(), session = fixture.session()
        var plan = Plan(title: "Preview")
        plan.commands = ["ip route 10.0.0.0 255.255.255.0 Wireguard0"]
        let result = try await session.apply(plan: plan, dryRun: true, saveConfig: true)
        XCTAssertFalse(result.applied)
        XCTAssertTrue(fixture.opened.isEmpty)
        XCTAssertTrue(fixture.backups.isEmpty)
    }

    func testBackupFailurePreventsCommands() async throws {
        let transport = FakeTransport(), fixture = SessionFixture(transport)
        fixture.backupSucceeds = false
        let session = fixture.session()
        defer { session.disconnectAll() }
        var plan = Plan(title: "Apply")
        plan.commands = ["ip route 10.0.0.0 255.255.255.0 Wireguard0"]
        do { _ = try await session.apply(plan: plan, dryRun: false, saveConfig: true); XCTFail("No backup") }
        catch {}
        XCTAssertEqual(transport.commands, ["show running-config"])
        XCTAssertEqual(fixture.backups, [RegressionFixtures.sampleConfig])
        XCTAssertNil(session.progress)
    }

    func testPlanBacksUpExecutesSavesAndVerifies() async throws {
        let transport = FakeTransport(), fixture = SessionFixture(transport)
        let session = fixture.session()
        defer { session.disconnectAll() }
        var plan = Plan(title: "Apply")
        plan.commands = ["object-group fqdn fixture", "object-group fqdn fixture include example.org",
                         "object-group fqdn fixture include example.net"]
        transport.onRun = { _ in
            XCTAssertEqual(fixture.backups.count, 1, "Backup must precede any write")
            return ""
        }
        let result = try await session.apply(plan: plan, dryRun: false, saveConfig: true)
        XCTAssertTrue(result.applied)
        XCTAssertEqual(transport.commands, ["show running-config"] + plan.commands
                       + ["system configuration save", "show running-config"])
        XCTAssertNotNil(session.state)
        XCTAssertNil(session.progress)
    }

    func testCancellationStopsRemainingCommandsAndSave() async throws {
        let gate = TransportGate(), transport = FakeTransport()
        transport.onRun = { _ in try gate.wait(); return "" }
        transport.onAbort = { gate.release() }
        let fixture = SessionFixture(transport), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        let task = Task { try await session.runCommands(["first", "second"], title: "Test") }
        await fulfillment(of: [gate.started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled write succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(transport.commands, ["first"])
        XCTAssertNil(session.progress)
    }

    func testSwitchDuringWriteKeepsCommandsOnOriginalRouter() async throws {
        let gate = TransportGate(), a = FakeTransport(), b = FakeTransport()
        a.onRun = { command in if command == "first" { try gate.wait() }; return "" }
        let fixture = SessionFixture(a, b), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        let task = Task { try await session.runCommands(["first", "second"], title: "Test") }
        await fulfillment(of: [gate.started], timeout: 2)
        let other = RouterProfile(name: "Other", host: "other.invalid")
        await session.switchTo(other)
        try await session.connect()
        gate.release()
        _ = try await task.value
        XCTAssertEqual(a.commands, ["first", "second", "system configuration save"])
        XCTAssertTrue(b.commands.isEmpty)
        XCTAssertEqual(session.router.id, other.id)
    }

    func testEditingProfileDuringWriteStopsFollowingCommands() async throws {
        let gate = TransportGate(), transport = FakeTransport()
        transport.onRun = { _ in try gate.wait(); return "" }
        transport.onAbort = { gate.release() }
        let fixture = SessionFixture(transport), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        let task = Task { try await session.runCommands(["first", "second"], title: "Test") }
        await fulfillment(of: [gate.started], timeout: 2)
        var edited = fixture.profile
        edited.host = "new.invalid"
        session.profileDidChange(edited)
        do { _ = try await task.value; XCTFail("Stale write succeeded") } catch {}
        XCTAssertEqual(transport.commands, ["first"])
        XCTAssertEqual(fixture.opened.count, 1)
    }

    func testFailedWriteIsNeverReplayedOrSaved() async throws {
        let transport = FakeTransport(), fixture = SessionFixture(transport)
        transport.onRun = { _ in throw TransportError("Lost after write", isSessionFailure: true) }
        let session = fixture.session()
        defer { session.disconnectAll() }
        do { _ = try await session.runCommands(["first", "second"], title: "Test"); XCTFail("Write succeeded") }
        catch {}
        XCTAssertEqual(fixture.opened.count, 1)
        XCTAssertEqual(transport.commands, ["first"])
        XCTAssertNil(session.progress)
    }

    func testPlanForOldAddressIsRejectedBeforeConnection() async throws {
        let fixture = SessionFixture(), session = fixture.session()
        var plan = Plan(title: "Old plan")
        plan.commands = ["first"]
        plan = plan.forRouter(fixture.profile)
        var edited = fixture.profile
        edited.host = "new.invalid"
        session.profileDidChange(edited)
        do { _ = try await session.apply(plan: plan, dryRun: false, saveConfig: true); XCTFail("Stale plan accepted") }
        catch {}
        XCTAssertTrue(fixture.opened.isEmpty)
        XCTAssertTrue(fixture.backups.isEmpty)
    }
    func testConcurrentPlansForSameRouterDoNotInterleave() async throws {
        let gate = TransportGate(), transport = FakeTransport()
        transport.onRun = { command in if command == "first" { try gate.wait() }; return "" }
        let fixture = SessionFixture(transport), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        let task = Task { try await session.runCommands(["first", "second"], title: "First") }
        await fulfillment(of: [gate.started], timeout: 2)
        do {
            _ = try await session.runCommands(["unrelated"], title: "Second")
            XCTFail("Concurrent writes accepted")
        } catch {}
        gate.release()
        _ = try await task.value
        XCTAssertEqual(transport.commands, ["first", "second", "system configuration save"])
        _ = try await session.runCommands(["next"], title: "Next", saveConfig: false)
        XCTAssertEqual(transport.commands.last, "next", "Write lease was not released")
    }

    func testCancelledQueuedWriteNeverCallsTransport() async throws {
        let gate = TransportGate(), transport = FakeTransport()
        transport.onRead = { try gate.wait(); return "configuration" }
        transport.onAbort = { gate.release() }
        let fixture = SessionFixture(transport), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        let read = Task { try await session.readConfigText() }
        await fulfillment(of: [gate.started], timeout: 2)
        let queued = expectation(description: "Write enqueued")
        let write = Task {
            queued.fulfill()
            return try await session.runCommands(["must not run"], title: "Cancelled")
        }
        await fulfillment(of: [queued], timeout: 2)
        write.cancel()
        XCTAssertEqual(transport.abortCount, 0, "Queued cancellation aborted another operation")
        gate.release()
        do { _ = try await write.value; XCTFail("Cancelled write succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await read.value
        XCTAssertEqual(transport.commands, ["show running-config"])
    }

}
