import Foundation
import XCTest
@testable import KeeneticControl

@MainActor
private final class MutableDomainCatalog {
    var sources: [SourceSpec]
    init(_ sources: [SourceSpec]) { self.sources = sources }
}

/// Транспорт хранит конфигурацию как роутер: команда меняет состояние сразу,
/// ограничение в 300 проверяется после каждой записи, а не только в конце.
private final class DomainUpdateRouter: @unchecked Sendable {
    struct Group {
        var description: String
        var entries: Set<String>
        var routes: [String] = []
    }

    private let lock = NSLock()
    private var groups: [String: Group]
    private var readCounter = 0
    private var largestCount = 0
    var beforeRead: ((Int) -> Void)?

    init(_ groups: [String: Group]) { self.groups = groups }

    var maximumCount: Int { lock.withLock { largestCount } }
    var reads: Int { lock.withLock { readCounter } }
    var snapshot: [String: Group] { lock.withLock { groups } }

    func change(_ ident: String, _ body: (inout Group) -> Void) {
        lock.withLock {
            guard var group = groups[ident] else { return }
            body(&group)
            groups[ident] = group
        }
    }

    func read() -> String {
        let count = lock.withLock { readCounter += 1; return readCounter }
        beforeRead?(count)
        return lock.withLock {
            var lines = ["hostname update-fixture"]
            for ident in groups.keys.sorted() {
                let group = groups[ident]!
                lines.append("object-group fqdn \(ident)")
                lines.append(" description \(CLI.quote(group.description))")
                lines += group.entries.sorted().map { " include \($0)" }
                lines.append("!")
            }
            for ident in groups.keys.sorted() {
                lines += groups[ident]!.routes.map { "dns-proxy route object-group \(ident) \($0)" }
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    func run(_ command: String) throws -> String {
        try lock.withLock {
            if command == "system configuration save" { return "" }
            var tokens = command.split(separator: " ").map(String.init)
            let removing = tokens.first == "no"
            if removing { tokens.removeFirst() }
            guard tokens.count >= 3 else { throw TransportError("Unexpected test command: \(command)") }
            if tokens[0...1] == ["object-group", "fqdn"] {
                let ident = tokens[2]
                if tokens.count == 3 {
                    if removing { groups.removeValue(forKey: ident) }
                    else if groups[ident] == nil { groups[ident] = Group(description: "", entries: []) }
                    return ""
                }
                guard groups[ident] != nil, tokens.count >= 5 else {
                    throw TransportError("Command addresses a missing group: \(command)")
                }
                switch tokens[3] {
                case "description":
                    groups[ident]!.description = CLI.unquote(tokens.dropFirst(4).joined(separator: " "))
                case "include":
                    if removing { groups[ident]!.entries.remove(tokens[4]) }
                    else { groups[ident]!.entries.insert(tokens[4]) }
                    largestCount = max(largestCount, groups[ident]!.entries.count)
                    guard groups[ident]!.entries.count <= 300 else {
                        throw TransportError("Router rejected entry 301")
                    }
                default: throw TransportError("Unsupported test command: \(command)")
                }
                return ""
            }
            if tokens.count >= 5, tokens[0...2] == ["dns-proxy", "route", "object-group"] {
                let ident = tokens[3], route = tokens.dropFirst(4).joined(separator: " ")
                guard groups[ident] != nil else { throw TransportError("Route before group creation") }
                if removing { groups[ident]!.routes.removeAll { $0 == route } }
                else if !groups[ident]!.routes.contains(route) { groups[ident]!.routes.append(route) }
                return ""
            }
            throw TransportError("Unsupported test command: \(command)")
        }
    }

    func transport() -> FakeTransport {
        let transport = FakeTransport()
        transport.onRead = { self.read() }
        transport.onRun = { try self.run($0) }
        return transport
    }
}

@MainActor
final class DomainListUpdateControllerTests: XCTestCase {
    private func source(_ key: String = "alpha") -> SourceSpec {
        SourceSpec(key: key, title: key.capitalized, subtitle: "Fixture", descriptionPrefix: key,
                   icon: "globe", urls: ["https://example.invalid/\(key).txt"],
                   cacheName: "domain-update-\(key).txt", minDomains: 1)
    }

    private func data(_ spec: SourceSpec, _ entries: [String], cached: Bool = false,
                      skipped: [String] = []) -> SourceData {
        SourceData(spec: spec, entries: entries, fromCache: cached, fetchedAt: Date(),
                   skipped: skipped, duplicates: 0, subnetsV4: [], subnetsV6: [])
    }

    private func writes(_ transport: FakeTransport) -> [String] {
        transport.commands.filter { $0 != "show running-config" }
    }

    func testOneClickRemovesStaleAdds301stEntryAndInheritsRouteChain() async throws {
        let spec = source()
        let retained = (0..<299).map { "retained-\($0).example.org" }
        let desired = retained + ["new-a.example.org", "new-b.example.org"]
        let chain = ["Wireguard0 auto", "Wireguard1 auto reject"]
        let backend = DomainUpdateRouter([
            "domain-list0": .init(description: spec.descriptionPrefix,
                                  entries: Set(retained + ["gone.example.org"]), routes: chain),
            "unmanaged": .init(description: "My own list", entries: ["personal.example.net"],
                               routes: ["ISP auto"]),
        ])
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { session.disconnectAll() }
        let initial = backend.read()
        let updater = DomainListUpdateController(sourceLoader: { _, spec in self.data(spec, desired) })

        await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: true)

        let report = try XCTUnwrap(updater.report)
        XCTAssertNil(report.error)
        XCTAssertFalse(report.cancelled)
        XCTAssertFalse(updater.isRunning)
        let result = try XCTUnwrap(report.results.first)
        XCTAssertEqual(result.status, .updated)
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.createdParts, 1)
        XCTAssertEqual(fixture.backups, [initial])
        XCTAssertNotNil(report.backupURL)
        let managed = Planner.managedGroups(try XCTUnwrap(session.state).groups, spec: spec)
        XCTAssertEqual(managed.count, 2)
        XCTAssertEqual(managed.reduce(into: Set<String>()) { $0.formUnion($1.includes) }, Set(desired))
        XCTAssertTrue(managed.allSatisfy { $0.includes.count <= 300 })
        XCTAssertLessThanOrEqual(backend.maximumCount, 300, "Temporary overflow is also a router failure")
        XCTAssertEqual(managed[0].routeAssignments, managed[1].routeAssignments)
        XCTAssertEqual(managed[1].routeAssignments.map(\.interface), ["Wireguard0", "Wireguard1"])
        XCTAssertTrue(managed[1].routeAssignments[1].reject)
        XCTAssertEqual(backend.snapshot["unmanaged"]?.entries, ["personal.example.net"])
        XCTAssertEqual(backend.snapshot["unmanaged"]?.routes, ["ISP auto"])
        XCTAssertEqual(writes(transport).filter { $0 == "system configuration save" }.count, 1)
    }

    func testRepeatedUpdateIsIdempotentAndCreatesNoSecondBackup() async throws {
        let spec = source()
        let backend = DomainUpdateRouter(["domain-list0": .init(description: "alpha", entries: ["old.example.org"])])
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { session.disconnectAll() }
        let updater = DomainListUpdateController(sourceLoader: { _, spec in self.data(spec, ["new.example.org"]) })
        await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: false)
        XCTAssertEqual(updater.report?.results.first?.status, .updated)
        let firstWrites = writes(transport)
        XCTAssertEqual(fixture.backups.count, 1)
        await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: false)
        XCTAssertEqual(updater.report?.results.first?.status, .unchanged)
        XCTAssertEqual(writes(transport), firstWrites)
        XCTAssertEqual(fixture.backups.count, 1)
        XCTAssertNil(updater.report?.backupURL)
        XCTAssertFalse(firstWrites.contains("system configuration save"))
    }

    func testLowerConfiguredLimitCreatesSmallerPartsAndPassesVerification() async throws {
        let spec = source()
        let existing = (0..<100).map { "entry-\($0).example.org" }
        let desired = (0..<201).map { "entry-\($0).example.org" }
        let backend = DomainUpdateRouter([
            "domain-list0": .init(description: "alpha", entries: Set(existing), routes: ["Wireguard0 auto"]),
        ])
        let transport = backend.transport(), fixture = SessionFixture(transport)
        fixture.settings.maxDomainsPerList = 100
        let session = fixture.session()
        defer { session.disconnectAll() }
        let updater = DomainListUpdateController(sourceLoader: { _, spec in self.data(spec, desired) })

        await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: true)

        XCTAssertNil(updater.report?.error)
        XCTAssertEqual(updater.report?.results.first?.status, .updated)
        XCTAssertEqual(updater.report?.results.first?.createdParts, 2)
        let managed = Planner.managedGroups(try XCTUnwrap(session.state).groups, spec: spec)
        XCTAssertEqual(managed.count, 3)
        XCTAssertEqual(managed.reduce(into: Set<String>()) { $0.formUnion($1.includes) }, Set(desired))
        XCTAssertTrue(managed.allSatisfy { $0.includes.count <= 100 })
        XCTAssertLessThanOrEqual(backend.maximumCount, 100)
        XCTAssertEqual(fixture.backups.count, 1)
        XCTAssertEqual(writes(transport).filter { $0 == "system configuration save" }.count, 1)
    }

    func testCachedFallbackCannotDeleteCurrentEntries() async throws {
        let spec = source()
        let backend = DomainUpdateRouter(["domain-list0": .init(description: "alpha", entries: ["keep.example.org", "newer.example.org"])])
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { session.disconnectAll() }
        let updater = DomainListUpdateController(sourceLoader: { _, spec in self.data(spec, ["keep.example.org"], cached: true) })
        await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: true)
        XCTAssertTrue(writes(transport).isEmpty)
        XCTAssertTrue(fixture.backups.isEmpty)
        XCTAssertEqual(backend.snapshot["domain-list0"]?.entries, ["keep.example.org", "newer.example.org"])
        XCTAssertEqual(updater.report?.results.first?.status, .skipped)
    }

    func testEmptyOrPartiallyParsedSourceCannotDeleteCurrentEntries() async {
        for malformed in [false, true] {
            let spec = source()
            let backend = DomainUpdateRouter(["domain-list0": .init(description: "alpha", entries: ["keep.example.org", "newer.example.org"])])
            let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
            defer { session.disconnectAll() }
            let updater = DomainListUpdateController(sourceLoader: { _, spec in
                self.data(spec, malformed ? ["keep.example.org"] : [],
                          skipped: malformed ? ["<unexpected-format>"] : [])
            })
            await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: true)
            XCTAssertTrue(writes(transport).isEmpty)
            XCTAssertTrue(fixture.backups.isEmpty)
            XCTAssertNotEqual(updater.report?.results.first?.status, .updated)
            XCTAssertNotEqual(updater.report?.results.first?.status, .unchanged)
        }
    }

    func testUnavailableSourceIsPreservedWhileHealthySourceUpdates() async throws {
        let alpha = source(), beta = source("beta")
        let backend = DomainUpdateRouter([
            "domain-list0": .init(description: "alpha", entries: ["alpha-old.example.org"]),
            "domain-list1": .init(description: "beta", entries: ["beta-old.example.org"]),
        ])
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { session.disconnectAll() }
        let updater = DomainListUpdateController(sourceLoader: { _, spec in
            if spec == alpha { throw TransportError("Source unavailable") }
            return self.data(spec, ["beta-new.example.org"])
        })
        await updater.update(session: session, catalog: [alpha, beta], chunkSize: 300, saveConfig: true)
        let results = try XCTUnwrap(updater.report).results
        XCTAssertEqual(results.first { $0.spec == alpha }?.status, .skipped)
        XCTAssertEqual(results.first { $0.spec == beta }?.status, .updated)
        XCTAssertEqual(backend.snapshot["domain-list0"]?.entries, ["alpha-old.example.org"])
        XCTAssertEqual(backend.snapshot["domain-list1"]?.entries, ["beta-new.example.org"])
        XCTAssertEqual(fixture.backups.count, 1)
    }

    func testSwitchingRouterDuringDownloadDiscardsLateResult() async {
        let spec = source()
        let backend = DomainUpdateRouter(["domain-list0": .init(description: "alpha", entries: ["old.example.org"])])
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { session.disconnectAll() }
        let updater = DomainListUpdateController(sourceLoader: { session, spec in
            await session.switchTo(RouterProfile(name: "Other", host: "other.invalid"))
            return self.data(spec, ["new.example.org"])
        })
        await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: true)
        XCTAssertTrue(writes(transport).isEmpty)
        XCTAssertTrue(fixture.backups.isEmpty)
        XCTAssertEqual(updater.report?.cancelled, true)
        XCTAssertEqual(fixture.opened.count, 1)
    }

    func testEditingSourceCatalogDuringDownloadPreventsWrite() async {
        let spec = source()
        let backend = DomainUpdateRouter(["domain-list0": .init(description: "alpha", entries: ["old.example.org"])])
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { session.disconnectAll() }
        let catalog = MutableDomainCatalog([spec])
        let updater = DomainListUpdateController(sourceLoader: { _, spec in
            catalog.sources = [self.source("changed")]
            return self.data(spec, ["new.example.org"])
        }, catalogProvider: { catalog.sources })
        await updater.update(session: session, catalog: catalog.sources, chunkSize: 300, saveConfig: true)
        XCTAssertTrue(writes(transport).isEmpty)
        XCTAssertTrue(fixture.backups.isEmpty)
        XCTAssertNotNil(updater.report?.error)
    }

    func testFinalReadUsesRoutingChangedDuringDownload() async throws {
        let spec = source(), desired = (0..<301).map { "new-\($0).example.org" }
        let backend = DomainUpdateRouter([
            "domain-list0": .init(description: "alpha", entries: ["old.example.org"], routes: ["Wireguard0 auto"]),
        ])
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { session.disconnectAll() }
        let updater = DomainListUpdateController(sourceLoader: { _, spec in
            backend.change("domain-list0") { $0.routes = ["Wireguard9 auto reject"] }
            return self.data(spec, desired)
        })
        await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: false)
        XCTAssertEqual(updater.report?.results.first?.status, .updated)
        XCTAssertTrue(fixture.backups.first?.contains("Wireguard9 auto reject") == true)
        let managed = Planner.managedGroups(try XCTUnwrap(session.state).groups, spec: spec)
        XCTAssertEqual(managed.count, 2)
        XCTAssertTrue(managed.allSatisfy { $0.routeAssignments.map(\.interface) == ["Wireguard9"] })
        XCTAssertFalse(writes(transport).contains { $0.contains("Wireguard0") })
    }

    func testConfigurationChangedAfterFinalPlanningPreventsWrite() async {
        let spec = source()
        let backend = DomainUpdateRouter(["domain-list0": .init(description: "alpha", entries: ["old.example.org"])])
        backend.beforeRead = { read in
            if read == 3 { backend.change("domain-list0") { $0.entries.insert("web-panel-change.example.org") } }
        }
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { session.disconnectAll() }
        let updater = DomainListUpdateController(sourceLoader: { _, spec in self.data(spec, ["new.example.org"]) })
        await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: true)
        XCTAssertGreaterThanOrEqual(backend.reads, 3)
        XCTAssertTrue(writes(transport).isEmpty)
        XCTAssertTrue(fixture.backups.isEmpty)
        XCTAssertNotNil(updater.report?.error)
        XCTAssertNotEqual(updater.report?.results.first?.status, .updated)
    }

    func testCatalogChangedDuringBackupReadStillPreventsWrite() async {
        let spec = source(), gate = TransportGate()
        let backend = DomainUpdateRouter(["domain-list0": .init(description: "alpha", entries: ["old.example.org"])])
        backend.beforeRead = { read in if read == 3 { try? gate.wait() } }
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        let catalog = MutableDomainCatalog([spec])
        let updater = DomainListUpdateController(sourceLoader: { _, spec in
            self.data(spec, ["new.example.org"])
        }, catalogProvider: { catalog.sources })
        let update = Task { await updater.update(session: session, catalog: catalog.sources, chunkSize: 300, saveConfig: true) }
        await fulfillment(of: [gate.started], timeout: 2)
        catalog.sources = [source("changed")]
        gate.release()
        await update.value
        XCTAssertTrue(writes(transport).isEmpty)
        XCTAssertTrue(fixture.backups.isEmpty)
        XCTAssertNotNil(updater.report?.error)
    }

    func testSelectedRouterChangedDuringBackupReadStillPreventsWrite() async {
        let spec = source(), gate = TransportGate()
        let backend = DomainUpdateRouter(["domain-list0": .init(description: "alpha", entries: ["old.example.org"])])
        backend.beforeRead = { read in if read == 3 { try? gate.wait() } }
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        let updater = DomainListUpdateController(sourceLoader: { _, spec in self.data(spec, ["new.example.org"]) })
        let update = Task { await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: true) }
        await fulfillment(of: [gate.started], timeout: 2)
        await session.switchTo(RouterProfile(name: "Other", host: "other.invalid"))
        gate.release()
        await update.value
        XCTAssertTrue(writes(transport).isEmpty)
        XCTAssertTrue(fixture.backups.isEmpty)
        XCTAssertEqual(updater.report?.cancelled, true)
    }

    func testConcurrentSecondClickDoesNotStartAnotherDownloadOrWrite() async {
        let spec = source(), gate = OperationGate()
        let backend = DomainUpdateRouter(["domain-list0": .init(description: "alpha", entries: ["old.example.org"])])
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        var downloads = 0
        let updater = DomainListUpdateController(sourceLoader: { _, spec in
            downloads += 1
            await gate.wait()
            return self.data(spec, ["new.example.org"])
        })
        let first = Task { await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: true) }
        await fulfillment(of: [gate.started], timeout: 2)
        await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: true)
        XCTAssertTrue(updater.isRunning)
        XCTAssertEqual(downloads, 1)
        gate.release()
        await first.value
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(fixture.backups.count, 1)
        XCTAssertEqual(updater.report?.results.first?.status, .updated)
    }

    func testCancellationDuringDownloadPreventsBackupAndWrite() async {
        let spec = source(), gate = OperationGate()
        let backend = DomainUpdateRouter(["domain-list0": .init(description: "alpha", entries: ["old.example.org"])])
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { gate.release(); session.disconnectAll() }
        let updater = DomainListUpdateController(sourceLoader: { _, spec in
            await gate.wait()
            return self.data(spec, ["new.example.org"])
        })
        let task = Task { await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: true) }
        await fulfillment(of: [gate.started], timeout: 2)
        task.cancel()
        gate.release()
        await task.value
        XCTAssertTrue(writes(transport).isEmpty)
        XCTAssertTrue(fixture.backups.isEmpty)
        XCTAssertEqual(updater.report?.cancelled, true)
        XCTAssertFalse(updater.isRunning)
    }

    func testNoInstalledSourcesDoesNotDownloadOrWrite() async {
        let spec = source()
        let backend = DomainUpdateRouter(["personal": .init(description: "My own list", entries: ["private.example.org"])])
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { session.disconnectAll() }
        var downloads = 0
        let updater = DomainListUpdateController(sourceLoader: { _, spec in downloads += 1; return self.data(spec, ["new.example.org"]) })
        await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: true)
        XCTAssertEqual(downloads, 0)
        XCTAssertTrue(writes(transport).isEmpty)
        XCTAssertTrue(fixture.backups.isEmpty)
        XCTAssertEqual(updater.report?.results.count, 0)
        XCTAssertFalse(updater.isRunning)
    }

    func testWriteFailureIsReportedWithBackupAndNeverSaved() async {
        let spec = source()
        let backend = DomainUpdateRouter(["domain-list0": .init(description: "alpha", entries: ["old.example.org"])])
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        transport.onRun = { _ in throw TransportError("Connection lost during write", isSessionFailure: true) }
        defer { session.disconnectAll() }
        let updater = DomainListUpdateController(sourceLoader: { _, spec in self.data(spec, ["new.example.org"]) })
        await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: true)
        XCTAssertEqual(fixture.backups.count, 1)
        XCTAssertNotNil(updater.report?.error)
        XCTAssertNotNil(updater.report?.backupURL)
        XCTAssertNotEqual(updater.report?.results.first?.status, .updated)
        XCTAssertFalse(writes(transport).contains("system configuration save"))
        XCTAssertFalse(updater.isRunning)
    }

    func testVerificationFailureIsNotReportedAsUpdated() async {
        let spec = source()
        let backend = DomainUpdateRouter(["domain-list0": .init(description: "alpha", entries: ["old.example.org"])])
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        transport.onRun = { _ in "" } // Прошивка приняла CLI, но конфигурация не изменилась.
        defer { session.disconnectAll() }
        let updater = DomainListUpdateController(sourceLoader: { _, spec in self.data(spec, ["new.example.org"]) })
        await updater.update(session: session, catalog: [spec], chunkSize: 300, saveConfig: true)
        XCTAssertEqual(fixture.backups.count, 1)
        XCTAssertEqual(updater.report?.results.first?.status, .needsAttention)
        XCTAssertNotNil(updater.report?.backupURL)
        XCTAssertFalse(writes(transport).contains("system configuration save"))
        XCTAssertFalse(updater.isRunning)
    }

    func testOverlappingSourcePrefixesPreventDownloadsAndRouterChanges() async {
        let base = source("alpha"), numbered = source("alpha 2")
        let backend = DomainUpdateRouter([
            "domain-list0": .init(description: "alpha", entries: ["first.example.org"]),
            "domain-list1": .init(description: "alpha 2", entries: ["second.example.org"])
        ])
        let transport = backend.transport(), fixture = SessionFixture(transport), session = fixture.session()
        defer { session.disconnectAll() }
        var downloads = 0
        let updater = DomainListUpdateController(sourceLoader: { _, spec in
            downloads += 1
            return self.data(spec, ["replacement.example.org"])
        })
        await updater.update(session: session, catalog: [base, numbered], chunkSize: 300, saveConfig: true)
        XCTAssertEqual(downloads, 0)
        XCTAssertTrue(transport.commands.isEmpty)
        XCTAssertTrue(fixture.backups.isEmpty)
        XCTAssertNotNil(updater.report?.error)
        XCTAssertEqual(backend.snapshot["domain-list1"]?.entries, ["second.example.org"])
    }
}
