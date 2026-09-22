import Foundation
import XCTest
@testable import KeeneticControl

@MainActor
final class OperationHistoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func plan() -> Plan {
        var result = Plan(title: "Обновление сервисов")
        result.addDomain("domain-list0", "new.example.org", command: "object-group fqdn domain-list0 include new.example.org")
        result.removeDomain("domain-list0", "old.example.org", command: "no object-group fqdn domain-list0 include old.example.org")
        return result
    }

    private let config = """
    hostname fixture
    object-group fqdn domain-list0
     description Services
     include old.example.org
    !
    """

    func testCompletedHistorySurvivesRestartAndSeparatesIdenticalRouterNames() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let first = RouterProfile(name: "Дом", host: "first.invalid")
        let second = RouterProfile(name: "Дом", host: "second.invalid")
        let history = OperationHistoryStore(directory: path)
        let firstID = history.begin(profile: first, plan: plan(), configText: config, backupURL: nil)
        history.finish(firstID, status: .saved)
        let secondID = history.begin(profile: second, plan: plan(), configText: config, backupURL: nil)
        history.finish(secondID, status: .temporary)
        let reloaded = OperationHistoryStore(directory: path)
        XCTAssertEqual(reloaded.records(for: first.id).map(\.id), [firstID])
        XCTAssertEqual(reloaded.records(for: second.id).map(\.status), [.temporary])
        let change = try XCTUnwrap(reloaded.records(for: first.id).first?.changes.first)
        XCTAssertEqual(change.added, ["new.example.org"])
        XCTAssertEqual(change.removed, ["old.example.org"])
        XCTAssertNil(reloaded.persistenceError)
    }

    func testInterruptedOperationIsMarkedAndNeverReportedAsSaved() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let first = OperationHistoryStore(directory: path)
        _ = first.begin(profile: RouterProfile(), plan: plan(), configText: config, backupURL: nil)
        let reloaded = OperationHistoryStore(directory: path)
        XCTAssertEqual(reloaded.records.first?.status, .interrupted)
        XCTAssertFalse(try XCTUnwrap(reloaded.records.first).problems.isEmpty)
        XCTAssertEqual(OperationHistoryStore(directory: path).records.first?.status, .interrupted)
    }

    func testSecretsAreRedactedOnDiskAndSourceVersionIgnoresOrder() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let source = SourceSpec(key: "fixture", title: "Source", subtitle: "", descriptionPrefix: "fixture",
                                icon: "globe", urls: ["https://name:secret@example.org/domains?token=hidden#private"], cacheName: "fixture")
        let first = SourceData(spec: source, entries: ["a.example", "b.example"], fromCache: false,
                               fetchedAt: Date(), skipped: [], duplicates: 0, subnetsV4: [], subnetsV6: [])
        let reversed = SourceData(spec: source, entries: Array(first.entries.reversed()), fromCache: false,
                                  fetchedAt: Date(), skipped: [], duplicates: 0, subnetsV4: [], subnetsV6: [])
        let version = OperationSourceVersion(spec: source, data: first)
        XCTAssertEqual(version.digest, OperationSourceVersion(spec: source, data: reversed).digest)
        XCTAssertEqual(version.locations, ["https://example.org/domains"])
        var commands = Plan(title: "WireGuard")
        commands.commands = ["interface Wireguard0 wireguard private-key super-private-key"]
        commands.sourceVersions = [version]
        let history = OperationHistoryStore(directory: path)
        let id = history.begin(profile: RouterProfile(), plan: commands, configText: "password secret-not-stored", backupURL: nil)
        history.finish(id, status: .failed, problems: ["wireguard private-key super-private-key"])
        let url = path.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        let saved = try String(contentsOf: url, encoding: .utf8)
        for secret in ["super-private-key", "secret-not-stored", "token=hidden", "name:secret"] {
            XCTAssertFalse(saved.contains(secret))
        }
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testFailedSourceReportAndJournalDoNotPersistURLCredentialsOrTokens() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let address = "https://history-user:history-password@example.org/list?token=history-token#history-fragment"
        let source = SourceSpec(key: "failed-private-source", title: "Private source", subtitle: "",
            descriptionPrefix: "private-source", icon: "globe", urls: [address], cacheName: "fixture")
        let message = "Не удалось загрузить источник: \(address): HTTP 503"
        let history = OperationHistoryStore(directory: path)
        history.recordDomainReport(profile: RouterProfile(), report: DomainListUpdateReport(results: [
            DomainSourceUpdateResult(spec: source, status: .skipped, message: message)
        ]), historyID: nil)
        let record = try XCTUnwrap(history.records.first)
        XCTAssertEqual(record.status, .needsAttention)
        XCTAssertTrue(record.problems.joined().contains("https://example.org/list"))
        let saved = try String(contentsOf: path.appendingPathComponent(record.id.uuidString).appendingPathExtension("json"), encoding: .utf8)
        LogStore.shared.append(.warn, message)
        let journal = try XCTUnwrap(LogStore.shared.entries.last).text
        let diskJournal = try String(contentsOf: AppPaths.logs.appendingPathComponent("keenetic-control.log"), encoding: .utf8)
        for secret in ["history-user", "history-password", "history-token", "history-fragment"] {
            XCTAssertFalse(saved.contains(secret), "History persisted \(secret)")
            XCTAssertFalse(journal.contains(secret), "Journal exposed \(secret)")
            XCTAssertFalse(diskJournal.contains(secret), "Journal persisted \(secret)")
        }
        XCTAssertEqual(source.domainURLs, [address], "Sanitizing diagnostics must not change the request URL")
    }

    func testDiagnosticRedactionPreservesOrdinaryErrorsAndSanitizesMultipleURLs() {
        let ordinary = "Не удалось прочитать файл. Повтори подключение: timeout (40 s), код 503."
        XCTAssertEqual(DiagnosticPrivacy.redact(ordinary), ordinary)
        let input = "HTTP 503: https://example.org/a?token=ONE\nЗеркало https://user:TWO@example.net/b#THREE"
        let safe = DiagnosticPrivacy.redact(input)
        XCTAssertEqual(safe, "HTTP 503: https://example.org/a\nЗеркало https://example.net/b")
        XCTAssertEqual(DiagnosticPrivacy.redact("Справка https://example.org/path."), "Справка https://example.org/path.")
        XCTAssertEqual(DiagnosticPrivacy.redact(safe), safe)
    }

    func testExistingCompletedHistoryIsSanitizedOnReload() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        var record = OperationHistoryRecord(profile: RouterProfile(), plan: plan(), configText: config, backupURL: nil)
        record.status = .failed
        record.problems = ["https://old-user:old-password@example.org/list?token=old-query#old-fragment"]
        let file = path.appendingPathComponent(record.id.uuidString).appendingPathExtension("json")
        try JSONEncoder().encode(record).write(to: file)
        let reloaded = OperationHistoryStore(directory: path)
        XCTAssertEqual(reloaded.records.first?.problems, ["https://example.org/list"])
        let disk = try String(contentsOf: file, encoding: .utf8)
        for secret in ["old-user", "old-password", "old-query", "old-fragment"] { XCTAssertFalse(disk.contains(secret)) }
    }

    func testRetentionAndClearDoNotDeleteAnotherRouterOrBackup() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let backup = path.appendingPathComponent("copy.kcbackup")
        try Data("fixture".utf8).write(to: backup)
        let first = RouterProfile(name: "First")
        let second = RouterProfile(name: "Second")
        let history = OperationHistoryStore(directory: path, limit: 2)
        for _ in 0..<4 {
            let id = history.begin(profile: first, plan: plan(), configText: config, backupURL: backup)
            history.finish(id, status: .saved)
        }
        let other = history.begin(profile: second, plan: plan(), configText: config, backupURL: backup)
        history.finish(other, status: .saved)
        XCTAssertEqual(history.records(for: first.id).count, 2)
        history.clear(routerID: first.id)
        XCTAssertEqual(history.records.map(\.id), [other])
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(OperationHistoryStore(directory: path).records.map(\.id), [other])
    }

    func testClearingHistoryKeepsAnOperationUntilItFinishes() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let history = OperationHistoryStore(directory: path)
        let profile = RouterProfile()
        let id = history.begin(profile: profile, plan: plan(), configText: config, backupURL: nil)
        history.clear(routerID: profile.id)
        XCTAssertEqual(history.records.first?.id, id)
        history.finish(id, status: .saved)
        XCTAssertEqual(OperationHistoryStore(directory: path).records.first?.status, .saved)
    }

    func testDamagedEntryAndWriteFailureAreVisibleWithoutLosingGoodHistory() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let history = OperationHistoryStore(directory: path)
        let id = history.begin(profile: RouterProfile(), plan: plan(), configText: config, backupURL: nil)
        history.finish(id, status: .saved)
        try Data("broken".utf8).write(to: path.appendingPathComponent(UUID().uuidString).appendingPathExtension("json"))
        let reloaded = OperationHistoryStore(directory: path)
        XCTAssertEqual(reloaded.records.map(\.id), [id])
        XCTAssertNotNil(reloaded.persistenceError)
        let invalidDirectory = path.appendingPathComponent("file-not-directory")
        try Data().write(to: invalidDirectory)
        let unwritable = OperationHistoryStore(directory: invalidDirectory)
        _ = unwritable.begin(profile: RouterProfile(), plan: plan(), configText: config, backupURL: nil)
        XCTAssertEqual(unwritable.records.count, 1)
        XCTAssertNotNil(unwritable.persistenceError)
    }

    func testReportAugmentsApplicationWithoutDuplicateAndNoOpIsRecorded() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let history = OperationHistoryStore(directory: path)
        let profile = RouterProfile()
        let id = history.begin(profile: profile, plan: plan(), configText: config, backupURL: nil)
        history.finish(id, status: .saved)
        let spec = SourceCatalog.all[0]
        let report = DomainListUpdateReport(results: [
            DomainSourceUpdateResult(spec: spec, status: .skipped, message: "Источник недоступен")])
        history.recordDomainReport(profile: profile, report: report, historyID: id)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.status, .needsAttention)
        XCTAssertEqual(history.records.first?.changes.first?.added, ["new.example.org"])
        history.recordDomainReport(profile: profile,
            report: DomainListUpdateReport(results: [DomainSourceUpdateResult(spec: spec, status: .unchanged)]), historyID: nil)
        XCTAssertEqual(history.records.count, 2)
        XCTAssertEqual(history.records.first?.status, .unchanged)
    }

    func testExecutorRecordsPartialFailureWithProtectedBackup() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let history = OperationHistoryStore(directory: path)
        let transport = FakeTransport()
        let originalConfig = config
        transport.onRead = { originalConfig }
        transport.onRun = { _ in throw TransportError("Обрыв соединения") }
        let profile = RouterProfile()
        let backup = path.appendingPathComponent("protected.kcbackup")
        let session = RouterSession(router: profile, dependencies: RouterSessionDependencies(
            makeTransport: { _, _ in transport }, password: { _ in nil }, retryDelay: {},
            settings: { .default }, backup: { _, _, _ in backup }, operationHistory: { history }))
        do {
            _ = try await session.apply(plan: plan().forRouter(profile), dryRun: false, saveConfig: true)
            XCTFail("Expected transport failure")
        } catch {}
        let record = try XCTUnwrap(history.records.first)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.backupURL, backup)
        XCTAssertFalse(transport.commands.contains("system configuration save"))
        XCTAssertFalse(record.problems.isEmpty)
    }
}
