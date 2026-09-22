import XCTest
@testable import KeeneticControl

@MainActor
final class DisabledRouteExecutionTests: XCTestCase {
    private let emptyConfig = "hostname fixture\n!\n"
    private let route = "ip route 203.0.113.10 Wireguard0 auto"
    private var disabledConfig: String { "hostname fixture\n\(route)\nip route disable\n!\n" }

    func testRestoreSendsDisabledRouteAsOneBatchEvenWithBatchSizeOne() async throws {
        let transport = FakeTransport(), fixture = SessionFixture(transport)
        fixture.settings.batchSize = 1
        var current = emptyConfig
        let wanted = disabledConfig, command = route
        transport.onRead = { current }
        transport.onBatch = { batch in
            XCTAssertEqual(batch, [command, "ip route disable"])
            current = wanted
            return ""
        }
        let session = fixture.session()
        defer { session.disconnectAll() }
        let diff = try Restore.validatedComparison(backup: wanted, current: current)
        let plan = try Restore.validatedPlan(diff, chunkSize: 300, title: "Restore disabled")
        let result = try await session.apply(plan: plan.forRouter(fixture.profile), dryRun: false, saveConfig: true)
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertEqual(transport.batchCommands, [[command, "ip route disable"]])
        XCTAssertEqual(transport.commands, ["show running-config", command, "ip route disable", "show running-config", "system configuration save"])
        XCTAssertEqual(fixture.backups.count, 1)
    }

    func testIgnoredDisablePreventsSaveAndIsReportedInHistory() async throws {
        let transport = FakeTransport(), fixture = SessionFixture(transport)
        var current = emptyConfig
        let command = route
        transport.onRead = { current }
        transport.onBatch = { _ in current = "hostname fixture\n\(command)\n!\n"; return "" }
        let session = fixture.session()
        defer { session.disconnectAll() }
        let diff = try Restore.validatedComparison(backup: disabledConfig, current: current)
        let result = try await session.apply(plan: Restore.plan(diff, chunkSize: 300, title: "Restore"),
                                             dryRun: false, saveConfig: true)
        XCTAssertFalse(result.problems.isEmpty)
        XCTAssertFalse(transport.commands.contains("system configuration save"))
        XCTAssertEqual(fixture.operationHistory.records.first?.status, .needsAttention)
    }

    func testImportVerificationDoesNotSaveIfDisableWasIgnored() async throws {
        let transport = FakeTransport(), fixture = SessionFixture(transport)
        let activeConfig = "hostname fixture\n\(route)\n!\n"
        transport.onRead = { activeConfig }
        let session = fixture.session()
        defer { session.disconnectAll() }
        var plan = Plan(title: "Import disabled route")
        plan.commands = [route, "ip route disable"]
        plan.verifyBeforeSave = true
        plan.expectedStaticRouteAdditions = Set(StaticRouteParser.parse(config: disabledConfig).map(\.configurationKey))
        let result = try await session.apply(plan: plan, dryRun: false, saveConfig: true)
        XCTAssertFalse(result.problems.isEmpty)
        XCTAssertFalse(transport.commands.contains("system configuration save"))
    }

    func testFailedContextualBatchIsNeverRetriedIndividuallyOrSaved() async throws {
        let transport = FakeTransport(), fixture = SessionFixture(transport)
        let initial = emptyConfig
        transport.onRead = { initial }
        transport.onBatch = { _ in "error: rejected" }
        let session = fixture.session()
        defer { session.disconnectAll() }
        let diff = try Restore.validatedComparison(backup: disabledConfig, current: initial)
        do {
            _ = try await session.apply(plan: Restore.plan(diff, chunkSize: 300, title: "Restore"), dryRun: false, saveConfig: true)
            XCTFail("Expected batch failure")
        } catch {}
        XCTAssertEqual(transport.batchCommands, [[route, "ip route disable"]])
        XCTAssertEqual(transport.commands, ["show running-config", route, "ip route disable"])
        XCTAssertEqual(fixture.operationHistory.records.first?.status, .failed)
    }

    func testOrphanAndWrongFamilyDisableAreRejectedBeforeConnection() async {
        for commands in [["ip route disable"], ["IP ROUTE DISABLE"], [route, "ipv6 route disable"], ["show version", "ip route disable"]] {
            let fixture = SessionFixture(), session = fixture.session()
            var plan = Plan(title: "Unsafe context")
            plan.commands = commands
            do {
                _ = try await session.apply(plan: plan, dryRun: false, saveConfig: true)
                XCTFail("Invalid context reached execution")
            } catch {}
            do {
                _ = try await session.runCommands(commands, title: "Unsafe commands", saveConfig: false)
                XCTFail("Invalid command context reached execution")
            } catch {}
            XCTAssertTrue(fixture.opened.isEmpty)
            XCTAssertTrue(fixture.backups.isEmpty)
        }
    }

    func testDirectCommandSequenceAlsoPreservesContextualBatch() async throws {
        let transport = FakeTransport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { session.disconnectAll() }
        _ = try await session.runCommands([route, "ip route disable", "show version"], title: "Paired commands", saveConfig: false)
        XCTAssertEqual(transport.batchCommands, [[route, "ip route disable"]])
        XCTAssertEqual(transport.commands, [route, "ip route disable", "show version"])
    }
}
