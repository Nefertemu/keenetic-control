import AppKit
import SwiftUI
import Vision
import XCTest
@testable import KeeneticControl

@MainActor
final class RouteExplanationUITests: XCTestCase {
    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ui-snapshots", isDirectory: true)
    }

    func testDomainFromPaletteRunsRealSearchAndExplainsBothLists() async throws {
        try await search(query: "https://api.example.org/service", name: "domain",
                         required: ["api.example.org", "Точный список сервисов", "Основной туннель", "auto", "reject"])
    }

    func testIPShowsStaticRulesAndScrollableExplanation() async throws {
        try await search(query: "10.1.2.3", name: "ip",
                         required: ["10.1.2.3", "10.1.0.0/16", "Основной туннель"])
    }

    func testDisabledRouteIsVisibleWithoutBestRouteBadgeInSmallWindow() async throws {
        let config = "ip route 203.0.113.10 Wireguard0 auto reject\nip route disable"
        let state = RouterState(configText: config, staticRoutes: StaticRouteParser.parse(config: config))
        let report = try RouteExplanation.explain("203.0.113.10", state: state)
        let view = RouteExplanationContent(query: .constant("203.0.113.10"), hasState: true,
                                          report: report)
        for (theme, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light),
                                            ("dark", NSAppearance.Name.darkAqua, ColorScheme.dark)] {
            let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
            let window = makeWindow(hosting, width: 540, appearance: appearance)
            defer { window.orderOut(nil); window.close() }
            try await settle(hosting)
            let text = try capture(hosting, name: "route-explanation-disabled-\(theme)-540", technical: true)
            XCTAssertTrue(text.contains { $0.contains("Отключён") || $0.contains("Отключен") }, "\(text)")
            let normalizedText = text.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            XCTAssertTrue(normalizedText.contains("ip route disable"), "\(text)")
            XCTAssertFalse(text.contains { $0.contains("Наиболее точное правило") }, "\(text)")
        }
    }

    func testMalformedDisableBlocksImportInActualWindow() async throws {
        let parsed = StaticRouteParser.parseImport("ip route 203.0.113.10 Wireguard0\nipv6 route disable")
        // Establish the button's actual geometry with an enabled control and
        // prove that clicking it invokes the callback. The disabled label's
        // low contrast must not determine whether the negative test can click.
        var validAccepted = false
        let validHosting = NSHostingView(rootView: ImportPreview(routes: parsed.routes, skipped: [],
            onAccept: { _ in validAccepted = true }, onCancel: {}).environment(\.colorScheme, .light))
        let validWindow = makeWindow(validHosting, width: 540, appearance: .aqua)
        defer { validWindow.orderOut(nil); validWindow.close() }
        try await settle(validHosting)
        let buttonCenter = try NativeUIInteractions.center(of: "Составить план", in: validHosting)
        try NativeUIInteractions.click(at: buttonCenter, in: validHosting, window: validWindow)
        try await settle(validHosting)
        XCTAssertTrue(validAccepted, "The control click must reach the enabled import button")
        validWindow.orderOut(nil)
        var accepted = false
        let hosting = NSHostingView(rootView: ImportPreview(routes: parsed.routes, skipped: parsed.skipped,
            onAccept: { _ in accepted = true }, onCancel: {}).environment(\.colorScheme, .light))
        let window = makeWindow(hosting, width: 540, appearance: .aqua)
        defer { window.orderOut(nil); window.close() }
        try await settle(hosting)
        let text = try capture(hosting, name: "static-route-invalid-disable-light-540")
        XCTAssertTrue(text.contains { $0.contains("импорт заблокирован") }, "\(text)")
        XCTAssertEqual(hosting.bounds.size, validHosting.bounds.size)
        try NativeUIInteractions.click(at: buttonCenter, in: hosting, window: window)
        try await settle(hosting)
        XCTAssertFalse(accepted, "A broken disable directive must never silently enable the preceding route")
    }

    func testEmptyErrorLoadingAndUnreadStatesFitSmallWindow() async throws {
        let variants: [(String, String, Bool, Bool, String?)] = [
            ("empty", "Почему выбран этот маршрут", true, false, nil),
            ("loading", "Ищу совпадения", true, true, nil),
            ("error", "один домен", true, false, "Введи один домен, URL или IP-адрес без пробелов."),
            ("unread", "Сначала прочитай роутер", false, false, nil)
        ]
        for (name, expected, hasState, running, error) in variants {
            let view = RouteExplanationContent(query: .constant("api.example.org"), hasState: hasState,
                                               snapshotLabel: "Роутер с очень длинным названием офиса и подразделения · прочитано только что",
                                               isRunning: running, error: error)
            let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
            let window = makeWindow(hosting, width: 540, appearance: .darkAqua)
            defer { window.orderOut(nil); window.close() }
            try await settle(hosting)
            XCTAssertEqual(hosting.bounds.height, 760, accuracy: 1)
            let text = try capture(hosting, name: "route-explanation-\(name)-dark-540")
            XCTAssertTrue(text.contains { $0.contains(expected) }, "Missing state \(name): \(text)")
        }
    }

    private func search(query: String, name: String, required: [String]) async throws {
        let fixture = SessionFixture()
        let session = fixture.session()
        session.connections.store(state: RouteExplanationFixtures.state, owner: session.router.id)
        let themes: [(String, NSAppearance.Name, ColorScheme)] = [
            ("light", .aqua, .light), ("dark", .darkAqua, .dark)]
        for (theme, appearance, scheme) in themes {
            for width in [540.0, 1120.0] {
                Navigator.shared.routeQuery = nil
                let hosting = NSHostingView(rootView: RouteExplanationView()
                    .environmentObject(session)
                    .environment(\.liveRouterReadsEnabled, false)
                    .environment(\.colorScheme, scheme))
                let window = makeWindow(hosting, width: width, appearance: appearance)
                defer { window.orderOut(nil); window.close(); Navigator.shared.routeQuery = nil }
                try await settle(hosting)
                // This is the same entry point as choosing a domain in ⌘K;
                // it exercises the actual handler, detached search and result UI.
                Navigator.shared.routeQuery = query
                for _ in 0..<5 { try await settle(hosting) }
                XCTAssertNil(Navigator.shared.routeQuery)
                XCTAssertEqual(hosting.bounds.width, width, accuracy: 1)
                XCTAssertEqual(hosting.bounds.height, 760, accuracy: 1)
                let stem = "route-explanation-\(name)-\(theme)-\(Int(width))"
                let text = try capture(hosting, name: stem, technical: true)
                for expected in ["Поиск маршрута", "Найти маршрут"] + required {
                    XCTAssertTrue(text.contains { $0.contains(expected) }, "Missing \(expected): \(text)")
                }
                let scroll = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSScrollView }.first)
                let document = try XCTUnwrap(scroll.documentView)
                for _ in 0..<4 {
                    let bottomY = max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height)
                    document.scroll(NSPoint(x: 0, y: bottomY))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await settle(hosting)
                }
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
                let bottom = try capture(hosting, name: stem + "-bottom")
                XCTAssertTrue(bottom.contains { $0.contains("Открыть диагностику") }, "Diagnostics link cannot be reached: \(bottom)")
                XCTAssertTrue(bottom.contains { $0.contains("влияет на трафик") }, "Missing limitations: \(bottom)")
                XCTAssertTrue(fixture.opened.isEmpty, "Route explanation must never connect to a router")
                XCTAssertTrue(fixture.backups.isEmpty)
            }
        }
    }

    private func makeWindow<V: View>(_ hosting: NSHostingView<V>, width: Double,
                                     appearance: NSAppearance.Name) -> NSWindow {
        let size = NSSize(width: width, height: 760)
        hosting.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = hosting.appearance
        window.orderFront(nil)
        hosting.setFrameSize(size)
        return window
    }

    private func settle(_ hosting: NSView) async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 70_000_000)
        hosting.layoutSubtreeIfNeeded()
    }

    private func capture(_ hosting: NSView, name: String, technical: Bool = false) throws -> [String] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let png = try NativeUIInteractions.renderedPNG(in: hosting)
        try png.write(to: outputDirectory.appendingPathComponent(name + ".png"))
        return try NativeUIInteractions.labels(in: png, includeTechnicalPass: technical)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
