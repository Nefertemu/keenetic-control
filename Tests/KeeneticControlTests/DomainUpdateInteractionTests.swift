import AppKit
import SwiftUI
import XCTest
@testable import KeeneticControl

@MainActor
final class DomainUpdateInteractionTests: XCTestCase {
    private let source = SourceSpec(key: "interaction", title: "Interaction source", subtitle: "Fixture",
        descriptionPrefix: "interaction", icon: "globe", urls: ["https://example.invalid/list"],
        cacheName: "interaction-test.txt", minDomains: 1)

    private func config() -> String {
        "hostname ui-fixture\nobject-group fqdn domain-list0\n description interaction\n include old.example.org\n!\n"
    }

    private func present<V: View>(_ view: V) async throws -> (NSWindow, NSHostingView<V>) {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 788, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosting.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.setFrameSize(NSSize(width: 788, height: 500))
        try await settle(hosting)
        return (window, hosting)
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }


    func testClickUpdateShowsFailureAndReturningToSectionKeepsDetailsExpanded() async throws {
        let transport = FakeTransport()
        let configuration = config()
        transport.onRead = { configuration }
        let fixture = SessionFixture(transport), session = fixture.session()
        defer { session.disconnectAll() }
        var loadCalls = 0
        let updater = DomainListUpdateController(sourceLoader: { _, _ in
            loadCalls += 1
            throw TransportError("Проверочная ошибка источника: списки сохранены")
        })
        let section = DomainListUpdateSection(session: session, updater: updater,
            catalog: [source], settings: .default).padding(20)
        let (window, hosting) = try await present(section)
        defer { window.orderOut(nil); window.close() }
        try NativeUIInteractions.click("Обновить списки", in: hosting, window: window)
        for _ in 0..<100 where updater.report == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(loadCalls, 1)
        XCTAssertEqual(updater.report?.results.first?.status, .skipped)
        XCTAssertTrue(fixture.backups.isEmpty)
        XCTAssertEqual(transport.commands.filter { $0 != "show running-config" }, [])
        // Новый SwiftUI экран получает готовый отчёт, как после перехода назад.
        let (returnedWindow, returnedHosting) = try await present(DomainListUpdateSection(
            session: session, updater: updater, catalog: [source], settings: .default).padding(20))
        defer { returnedWindow.orderOut(nil); returnedWindow.close() }
        let descriptions = try NativeUIInteractions.labels(in: returnedHosting)
        XCTAssertTrue(descriptions.contains { $0.contains("Проверочная ошибка источника") },
                      "Error should already be expanded on returning: \(descriptions)")
    }

    func testClickCancelInterruptsSourceBeforeAnyRouterWrite() async throws {
        let transport = FakeTransport()
        let configuration = config()
        transport.onRead = { configuration }
        let fixture = SessionFixture(transport), session = fixture.session()
        defer { session.disconnectAll() }
        let started = expectation(description: "Source requested from button")
        let updater = DomainListUpdateController(sourceLoader: { _, spec in
            started.fulfill()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return SourceData(spec: spec, entries: ["new.example.org"], fromCache: false,
                fetchedAt: Date(), skipped: [], duplicates: 0, subnetsV4: [], subnetsV6: [])
        })
        let (window, hosting) = try await present(DomainListUpdateSection(session: session,
            updater: updater, catalog: [source], settings: .default).padding(20))
        defer { window.orderOut(nil); window.close() }
        try NativeUIInteractions.click("Обновить списки", in: hosting, window: window)
        await fulfillment(of: [started], timeout: 3)
        try await settle(hosting)
        try NativeUIInteractions.click("Отменить", in: hosting, window: window)
        for _ in 0..<100 where updater.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(updater.report?.cancelled, true)
        XCTAssertFalse(updater.isRunning)
        XCTAssertTrue(fixture.backups.isEmpty)
        XCTAssertEqual(transport.commands.filter { $0 != "show running-config" }, [])
    }

    func testTemporaryApplicationIsVisibleWithoutOpeningDetails() async throws {
        let report = DomainListUpdateReport(results: [DomainSourceUpdateResult(spec: source,
            status: .appliedTemporarily, added: 1, removed: 1)])
        let (window, hosting) = try await present(DomainListUpdateCard(report: report).padding(20))
        defer { window.orderOut(nil); window.close() }
        let labels = try NativeUIInteractions.labels(in: hosting)
        XCTAssertTrue(labels.contains { $0.contains("Применено временно") })
        XCTAssertTrue(labels.contains { $0.contains("после перезагрузки") })
    }
}
