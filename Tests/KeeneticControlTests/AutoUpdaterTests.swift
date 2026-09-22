import XCTest
@testable import KeeneticControl

@MainActor
final class AutoUpdaterTests: XCTestCase {
    private func data(_ spec: SourceSpec) -> SourceData {
        SourceData(spec: spec, entries: ["example.org"], fromCache: false,
                   fetchedAt: Date(), skipped: [], duplicates: 0, subnetsV4: [], subnetsV6: [])
    }

    private func prepare() -> RouterSession {
        Store.shared.settings.autoUpdateEnabled = false
        Store.shared.settings.autoUpdateNotify = false
        Store.shared.settings.autoUpdateSources = [SourceCatalog.all[0].key]
        let session = SessionFixture().session()
        session.connections.store(state: RouterState(), owner: session.router.id)
        return session
    }

    func testFailedDownloadIsNotReportedAsNoDifferences() async {
        let saved = Store.shared.settings
        defer { Store.shared.settings = saved }
        let session = prepare()
        let updater = AutoUpdater { _, _ in throw TransportError("Offline") }
        updater.attach(session: session)
        await updater.check(manual: true)
        XCTAssertNil(updater.finding)
        XCTAssertTrue(updater.lastMessage?.contains("не завершена") == true)
        XCTAssertFalse(updater.checking)
    }

    func testNewSuccessfulCheckClearsOutdatedFinding() async {
        let saved = Store.shared.settings
        defer { Store.shared.settings = saved }
        let session = prepare()
        let updater = AutoUpdater { _, spec in self.data(spec) }
        updater.attach(session: session)
        await updater.check(manual: true)
        XCTAssertNotNil(updater.finding)
        let spec = SourceCatalog.all[0]
        let group = FqdnGroup(ident: "domain-list0", descriptionText: spec.descriptionPrefix,
                              includes: ["example.org"])
        session.connections.store(state: RouterState(groups: [group.ident: group]), owner: session.router.id)
        await updater.check(manual: true)
        XCTAssertNil(updater.finding)
        XCTAssertTrue(updater.lastMessage?.contains("Расхождений нет") == true)
    }

    func testSwitchingRouterDuringDownloadDiscardsPlan() async {
        let saved = Store.shared.settings
        defer { Store.shared.settings = saved }
        let session = prepare()
        let updater = AutoUpdater { session, spec in
            await session.switchTo(RouterProfile(name: "Other", host: "other.invalid"))
            return self.data(spec)
        }
        updater.attach(session: session)
        await updater.check(manual: true)
        XCTAssertNil(updater.finding)
        XCTAssertEqual(updater.lastMessage, "Сверка отменена: изменились роутер, списки или параметры проверки.")
    }

    func testUpdatedGroupsInvalidatePendingPlan() async {
        let saved = Store.shared.settings
        defer { Store.shared.settings = saved }
        let session = prepare()
        let updater = AutoUpdater { session, spec in
            session.connections.store(state: RouterState(groups: ["new": FqdnGroup(ident: "new")]),
                                      owner: session.router.id)
            return self.data(spec)
        }
        updater.attach(session: session)
        await updater.check(manual: true)
        XCTAssertNil(updater.finding)
        XCTAssertEqual(updater.lastMessage, "Сверка отменена: изменились роутер, списки или параметры проверки.")
    }

    func testCancellationDoesNotShowFailureOrCreatePlan() async {
        let saved = Store.shared.settings
        defer { Store.shared.settings = saved }
        let session = prepare()
        let updater = AutoUpdater { _, _ in throw CancellationError() }
        updater.attach(session: session)
        await updater.check(manual: true)
        XCTAssertNil(updater.finding)
        XCTAssertEqual(updater.lastMessage, "Сверка отменена.")
    }
    func testRemovedSelectionClearsOldFindingBeforeEarlyReturn() async {
        let saved = Store.shared.settings
        defer { Store.shared.settings = saved }
        let session = prepare(), updater = AutoUpdater { _, spec in self.data(spec) }
        updater.attach(session: session)
        await updater.check(manual: true)
        XCTAssertNotNil(updater.finding)
        Store.shared.settings.autoUpdateSources = ["removed-source"]
        await updater.check(manual: true)
        XCTAssertNil(updater.finding)
        XCTAssertEqual(updater.lastMessage, "Не выбрано ни одного источника.")
    }

    func testEditingSourceDuringDownloadInvalidatesPlan() async {
        let saved = Store.shared.settings, custom = Store.shared.customSources
        defer { Store.shared.settings = saved; Store.shared.customSources = custom }
        let session = prepare()
        let source = CustomSource(title: "Test", descriptionPrefix: "unique-test-prefix",
                                  urls: ["https://example.invalid/old.txt"])
        Store.shared.customSources = [source]
        Store.shared.settings.autoUpdateSources = [source.spec.key]
        let updater = AutoUpdater { _, spec in
            Store.shared.customSources[0].urls = ["https://example.invalid/new.txt"]
            return self.data(spec)
        }
        updater.attach(session: session)
        await updater.check(manual: true)
        XCTAssertNil(updater.finding)
        XCTAssertEqual(updater.lastMessage, "Сверка отменена: изменились роутер, списки или параметры проверки.")
    }

    func testTaskCancellationDiscardsSuccessfulLateDownload() async {
        let saved = Store.shared.settings
        defer { Store.shared.settings = saved }
        let session = prepare(), started = expectation(description: "Download started")
        var pending: CheckedContinuation<Void, Never>?
        let updater = AutoUpdater { _, spec in
            await withCheckedContinuation { pending = $0; started.fulfill() }
            return self.data(spec)
        }
        updater.attach(session: session)
        let task = Task { await updater.check(manual: true) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        pending?.resume()
        await task.value
        XCTAssertNil(updater.finding)
        XCTAssertNil(updater.lastCheck)
        XCTAssertEqual(updater.lastMessage, "Сверка отменена.")
        XCTAssertFalse(updater.checking)
    }

}
