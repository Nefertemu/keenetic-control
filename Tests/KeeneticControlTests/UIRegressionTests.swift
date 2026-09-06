import AppKit
import SwiftUI
import XCTest
import Vision
@testable import KeeneticControl

private enum UIScenario: String, CaseIterable {
    case overview, routes, pingCheck, domains
}

private struct LayoutFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func measured(_ key: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: LayoutFrames.self,
                                   value: [key: proxy.frame(in: .named("fixture"))])
        })
    }
}

private struct UIScenarioView: View {
    var scenario: UIScenario
    var session: RouterSession
    var onLayout: ([String: CGRect]) -> Void
    @State private var alert: AlertPayload?
    @State private var section: AppSection = .overview
    @State private var tab: DomainsTab = .routes

    var body: some View {
        RouterDetailLayout {
            RouterUpdateBanners(
                release: AvailableUpdate(version: "99.1.0", title: "Fixture release",
                                         pageURL: URL(string: "https://example.invalid")!, notes: ""),
                finding: AutoUpdater.Finding(plan: Plan(title: "Fixture plan"),
                                             routerID: session.router.id,
                                             routerName: session.router.name, found: Date()),
                activeRouterID: session.router.id,
                onDismissRelease: {}, onDismissFinding: {}, onViewPlan: { _ in })
                .measured("banners")
        } content: {
            Group {
                switch scenario {
                case .overview: OverviewView(alert: $alert, section: $section)
                case .routes: StaticRoutesView(alert: $alert)
                case .pingCheck: PingCheckView(alert: $alert)
                case .domains: DomainsView(alert: $alert, tab: $tab)
                }
            }
            .measured("content")
        }
        .environmentObject(session)
        .coordinateSpace(name: "fixture")
        .onPreferenceChange(LayoutFrames.self, perform: onLayout)
    }
}

@MainActor
final class UIRegressionTests: XCTestCase {
    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ui-snapshots", isDirectory: true)
    }

    private func session() -> RouterSession {
        let fixture = SessionFixture()
        let session = fixture.session()
        var profile = session.router
        profile.name = "Главный роутер — офис разработки и резервный канал с очень длинным названием"
        session.profileDidChange(profile)
        var state = RouterState(configText: RegressionFixtures.sampleConfig,
                                readAt: Date(timeIntervalSince1970: 1_700_000_000))
        for index in 0..<12 {
            var interface = KeeneticInterface(ident: "Wireguard\(index)")
            interface.descriptionText = "Туннель \(index) — резервный канал офиса с очень длинным названием"
            interface.type = "Wireguard"
            interface.link = "up"
            interface.state = "up"
            state.interfaces[interface.ident] = interface
            state.candidates.append(interface)
            state.wireguardInterfaces.append(interface.ident)
            state.pingCheckBindings[interface.ident] = PingCheckBinding(profile: "Проверка-длинного-названия-\(index)", restart: false)
            state.pingCheckProfiles.append(PingCheckProfile(name: "Проверка-длинного-названия-\(index)", host: "connectivity-check-\(index).example.org"))
        }
        for index in 0..<80 {
            let ident = "Список-\(index)-с-очень-длинным-названием-для-проверки-вёрстки"
            state.groups[ident] = FqdnGroup(ident: ident,
                descriptionText: "Рабочие сервисы и резервные домены подразделения \(index)",
                includes: Set((0..<20).map { "service-\($0).department-\(index).example.org" }),
                routeLines: ["dns-proxy route object-group \(ident) Wireguard0"])
        }
        state.staticRoutes = (0..<500).map { index in
            StaticRoute(destination: "10.\(index / 256).\(index % 256).0/24", via: "Wireguard\(index % 12)",
                        comment: "Маршрут \(index) — длинный комментарий для проверки прокрутки и границ таблицы")
        }
        session.connections.store(state: state, owner: profile.id)
        session.connections.store(status: .online(.ssh), owner: profile.id)
        return session
    }

    func testOverviewThemesAndWidths() async throws { try await check(.overview) }
    func testFiveHundredRoutesThemesAndWidths() async throws { try await check(.routes) }
    func testLongPingCheckNamesThemesAndWidths() async throws { try await check(.pingCheck) }
    func testEightyDomainGroupsThemesAndWidths() async throws { try await check(.domains) }

    private func check(_ scenario: UIScenario) async throws {
        XCTAssertTrue(AppPaths.support.lastPathComponent.hasPrefix("KeeneticControl-tests-"))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let session = session()
        let themes: [(String, NSAppearance.Name, ColorScheme)] = [
            ("light", .aqua, .light), ("dark", .darkAqua, .dark)]
        var imageData: [Data] = []
        for (theme, appearance, scheme) in themes {
            for width in [788.0, 1220.0] {
                var frames: [String: CGRect] = [:]
                let root = UIScenarioView(scenario: scenario, session: session) { frames = $0 }
                    .environment(\.colorScheme, scheme)
                let hosting = NSHostingView(rootView: root)
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
                // SwiftUI preference/layout and LazyVStack need a committed AppKit pass.
                for _ in 0..<3 {
                    hosting.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                let banners = try XCTUnwrap(frames["banners"])
                let content = try XCTUnwrap(frames["content"])
                XCTAssertGreaterThanOrEqual(banners.minY, -1)
                XCTAssertLessThanOrEqual(content.maxY, 761)
                XCTAssertGreaterThan(banners.height, 100, "Both banners must be visible")
                XCTAssertLessThanOrEqual(banners.maxY, content.minY + 1, "Banners overlap content")
                XCTAssertLessThanOrEqual(banners.width, width + 1)
                XCTAssertLessThanOrEqual(content.width, width + 1)
                XCTAssertGreaterThan(content.height, 400, "Content was squeezed out")
                XCTAssertEqual(hosting.bounds.width, width, accuracy: 1)

                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 20_000, "Blank or missing render")
                let name = "\(scenario.rawValue)-\(theme)-\(Int(width)).png"
                try png.write(to: outputDirectory.appendingPathComponent(name))
                imageData.append(png)

                // XCTest не включает дерево SwiftUI Accessibility. Проверяем
                // видимость действий по самим пикселям через локальный Vision OCR.
                let labels = try recognize(XCTUnwrap(NSBitmapImageRep(data: png)), topHeight: banners.height)
                for title in ["Открыть релиз", "Посмотреть план"] {
                    let label = try XCTUnwrap(labels.first { $0.text.contains(title) },
                                             "Banner action missing from render: \(title)")
                    XCTAssertGreaterThan(label.frame.minX, 0)
                    XCTAssertLessThan(label.frame.maxX, 1)
                }
                if scenario == .routes || scenario == .pingCheck {
                    XCTAssertEqual(session.state?.staticRoutes.count, 500)
                    let scrolls = subviews(hosting).compactMap { $0 as? NSScrollView }
                    let vertical = try XCTUnwrap(scrolls.max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
                    let document = try XCTUnwrap(vertical.documentView)
                    XCTAssertGreaterThan(document.bounds.height, vertical.contentSize.height * 2)
                    for _ in 0..<3 {
                        document.scroll(NSPoint(x: 0, y: document.bounds.maxY))
                        hosting.layoutSubtreeIfNeeded()
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    XCTAssertGreaterThan(vertical.contentView.bounds.minY, 0, "Last rows cannot be reached")
                    let bottom = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bottom)
                    let bottomPNG = try XCTUnwrap(bottom.representation(using: .png, properties: [:]))
                    try bottomPNG.write(to: outputDirectory.appendingPathComponent("\(scenario.rawValue)-\(theme)-\(Int(width))-bottom.png"))
                    let bottomLabels = try recognize(XCTUnwrap(NSBitmapImageRep(data: bottomPNG)))
                    let expected = scenario == .routes ? "10.1.243.0/24" : "Туннель 11"
                    XCTAssertTrue(bottomLabels.contains { $0.text.contains(expected) },
                                  "Last row missing from render: \(expected). Recognized: \(bottomLabels.map(\.text))")
                }
            }
        }
        XCTAssertNotEqual(imageData[0], imageData[2], "Theme did not affect rendering")
    }

    private func subviews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(subviews)
    }

    private func recognize(_ bitmap: NSBitmapImageRep, topHeight: CGFloat? = nil) throws
        -> [(text: String, frame: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        if let topHeight {
            request.regionOfInterest = CGRect(x: 0, y: 1 - topHeight / 760,
                                               width: 1, height: topHeight / 760)
        }
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
        }
    }
}
