import AppKit
import SwiftUI
import XCTest
import Vision
@testable import KeeneticControl

private struct DomainUpdateLayoutFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func updateMeasured(_ key: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: DomainUpdateLayoutFrames.self,
                                   value: [key: proxy.frame(in: .named("update-fixture"))])
        })
    }
}

private struct DomainUpdateUIFixture: View {
    var session: RouterSession
    var running: Bool
    var report: DomainListUpdateReport?
    var onLayout: ([String: CGRect]) -> Void
    @State private var alert: AlertPayload?
    @State private var tab = DomainsTab.routes

    var body: some View {
        RouterDetailLayout {
            RouterUpdateBanners(
                release: AvailableUpdate(version: "99.1.0", title: "Fixture release",
                                         pageURL: URL(string: "https://example.invalid")!, notes: ""),
                finding: AutoUpdater.Finding(plan: Plan(title: "Fixture plan"),
                                             routerID: session.router.id,
                                             routerName: "Основной роутер офиса с длинным названием", found: Date()),
                activeRouterID: session.router.id,
                onDismissRelease: {}, onDismissFinding: {}, onViewPlan: { _ in })
                .updateMeasured("banners")
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                DomainListUpdateCard(
                    isRunning: running,
                    phase: running ? "Загрузка источников: корпоративные сервисы с очень длинным названием и резервные домены" : "",
                    completed: running ? 4 : 0, total: running ? 8 : 0,
                    report: report, detailsExpanded: true)
                    .updateMeasured("card")
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                Picker("", selection: $tab) {
                    ForEach(DomainsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                Text(tab.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                DnsRoutesView(alert: $alert)
                    .updateMeasured("routes")
            }
        }
        .environmentObject(session)
        .environment(\.liveRouterReadsEnabled, false)
        .coordinateSpace(name: "update-fixture")
        .onPreferenceChange(DomainUpdateLayoutFrames.self, perform: onLayout)
    }
}

@MainActor
final class DomainListUpdateUITests: XCTestCase {
    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ui-snapshots", isDirectory: true)
    }

    func testOneClickActionWithBothBanners() async throws {
        try await check(name: "idle")
    }

    func testProgressKeepsDomainControlsVisible() async throws {
        try await check(name: "progress", running: true)
    }

    func testPartialFailureAndLongResultsCanBeScrolled() async throws {
        let report = DomainListUpdateReport(
            finishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            results: [
                DomainSourceUpdateResult(spec: spec("failed", title: "Корпоративные сервисы и резервные домены отдела разработки с очень длинным названием"),
                                         status: .skipped,
                                         message: "Источник недоступен. Список сохранён без изменений; повтори обновление после восстановления связи."),
                DomainSourceUpdateResult(spec: spec("updated", title: "Обновлённые сервисы"),
                                         status: .updated, added: 421, removed: 137, createdParts: 2)
            ] + (0..<18).map { index in
                DomainSourceUpdateResult(
                    spec: spec("source-\(index)", title: index == 17 ? "Последний источник" : "Рабочие сервисы подразделения \(index)"),
                    status: .unchanged)
            }, backupURL: URL(fileURLWithPath: "/tmp/domain-update-fixture.kcbackup"))
        try await check(name: "partial", report: report)
    }

    private func spec(_ key: String, title: String) -> SourceSpec {
        SourceSpec(key: key, title: title, subtitle: "Fixture", descriptionPrefix: key,
                   icon: "globe", urls: ["https://example.invalid/\(key).txt"], cacheName: key)
    }

    private func check(name: String, running: Bool = false,
                       report: DomainListUpdateReport? = nil) async throws {
        XCTAssertTrue(AppPaths.support.lastPathComponent.hasPrefix("KeeneticControl-tests-"))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let session = SessionFixture().session()
        var state = RouterState(configText: RegressionFixtures.sampleConfig)
        state.groups = RouterConfigParser.parseFqdnGroups(state.configText)
        state.interfaces = RouterConfigParser.parseConfigInterfaces(state.configText)
        state.candidates = state.interfaces.values.filter(\.isVPN).sorted { $0.ident < $1.ident }
        state.wireguardInterfaces = state.candidates.filter { $0.ident.hasPrefix("Wireguard") }.map(\.ident)
        session.connections.store(state: state, owner: session.router.id)
        XCTAssertEqual(state.groups.count, 2)
        XCTAssertEqual(state.candidates.first?.ident, "Wireguard0")
        let themes: [(String, NSAppearance.Name, ColorScheme)] = [
            ("light", .aqua, .light), ("dark", .darkAqua, .dark)]
        var rendered: [Data] = []
        for (theme, appearance, scheme) in themes {
            for width in [788.0, 1220.0] {
                var frames: [String: CGRect] = [:]
                let hosting = NSHostingView(rootView: DomainUpdateUIFixture(
                    session: session, running: running, report: report) { frames = $0 }
                    .environment(\.colorScheme, scheme))
                hosting.appearance = NSAppearance(named: appearance)
                let size = NSSize(width: width, height: 760)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                window.appearance = hosting.appearance
                window.orderFront(nil)
                defer { window.orderOut(nil); window.close() }
                hosting.setFrameSize(size)
                for _ in 0..<3 {
                    hosting.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                let banners = try XCTUnwrap(frames["banners"])
                let card = try XCTUnwrap(frames["card"])
                let routes = try XCTUnwrap(frames["routes"])
                XCTAssertGreaterThan(banners.height, 100)
                XCTAssertGreaterThanOrEqual(card.minY, banners.maxY)
                XCTAssertGreaterThanOrEqual(card.minX, 19)
                XCTAssertLessThanOrEqual(card.maxX, width - 19)
                XCTAssertLessThanOrEqual(card.maxY, routes.minY)
                XCTAssertGreaterThan(routes.height, 180, "Update results squeezed the route controls out of the window")
                XCTAssertLessThanOrEqual(routes.maxY, 761)
                XCTAssertEqual(hosting.bounds.width, width, accuracy: 1)
                XCTAssertEqual(hosting.bounds.height, 760, accuracy: 1)

                let png = try capture(hosting)
                rendered.append(png)
                try png.write(to: outputDirectory.appendingPathComponent("domain-update-\(name)-\(theme)-\(Int(width)).png"))
                let text = try recognize(png)
                for label in ["Открыть релиз", "Посмотреть план", running ? "Обновление" : "Обновить списки"] {
                    XCTAssertTrue(text.contains { $0.contains(label) }, "Missing action: \(label). Recognized: \(text)")
                }
                if running {
                    XCTAssertTrue(text.contains { $0.contains("Загрузка источников") }, "Recognized: \(text)")
                    XCTAssertTrue(text.contains { $0.filter { !$0.isWhitespace }.contains("4/8") },
                                  "Missing progress count. Recognized: \(text)")
                }
                if report != nil {
                    XCTAssertTrue(text.contains { $0.contains("Обновлено частично") })
                    XCTAssertTrue(text.contains { $0.contains("Источник недоступен") })
                    XCTAssertTrue(text.contains { $0.contains("Резервная копия сохранена") },
                                  "Backup action is missing. Recognized: \(text)")
                    // The bounded result area scrolls independently from the
                    // routing controls below it, including the final source.
                    let scrolls = descendants(hosting).compactMap { $0 as? NSScrollView }
                    let resultScroll = try XCTUnwrap(scrolls.filter {
                        $0.frame.height <= 145 && ($0.documentView?.bounds.height ?? 0) > 300
                    }.first)
                    let document = try XCTUnwrap(resultScroll.documentView)
                    for _ in 0..<3 {
                        document.scroll(NSPoint(x: 0, y: document.bounds.maxY))
                        hosting.layoutSubtreeIfNeeded()
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    XCTAssertGreaterThan(resultScroll.contentView.bounds.minY, 0)
                    let bottom = try capture(hosting)
                    try bottom.write(to: outputDirectory.appendingPathComponent("domain-update-\(name)-\(theme)-\(Int(width))-bottom.png"))
                    let bottomText = try recognize(bottom)
                    XCTAssertTrue(bottomText.contains { $0.contains("Последний источник") },
                                  "The final source cannot be reached. Recognized: \(bottomText)")
                    XCTAssertTrue(bottomText.contains { $0.contains("Обновить списки") })
                    XCTAssertTrue(bottomText.contains { $0.contains("Резервная копия сохранена") },
                                  "The backup action scrolled away with the source results")
                }
            }
        }
        XCTAssertNotEqual(rendered[0], rendered[2], "The appearance did not change")
    }

    private func capture(_ view: NSView) throws -> Data {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 20_000)
        return png
    }

    private func recognize(_ png: Data) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        try VNImageRequestHandler(data: png, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
