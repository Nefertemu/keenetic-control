import AppKit
import SwiftUI
import Vision
import XCTest
@testable import KeeneticControl

@MainActor
final class OutcomeSheetTests: XCTestCase {
    private let size = NSSize(width: 640, height: 600)
    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ui-snapshots", isDirectory: true)
    }

    func testHundredLongProblemsKeepCloseVisibleAndLastProblemReachableInBothThemes() async throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let problems = (1...100).map { index in
            let start = index == 1 ? "FIRSTROW001\n" : ""
            let end = index == 100 ? "\nLASTROW100" : ""
            return start + "Список \(index): маршрут на резервный интерфейс удалённого офиса "
                + "не совпал с планом. Ожидалась цепочка Wireguard0, Wireguard1, Wireguard2; "
                + "получено Wireguard0. Проверь порядок резервирования, доступность туннелей "
                + "и последние изменения конфигурации на роутере." + end
        }
        let outcome = ApplyOutcome(applied: true, problems: problems,
                                   backupURL: URL(fileURLWithPath: "/tmp/office-router_running-config.kcb"),
                                   elapsed: 125)
        let light = try await render(outcome, theme: "light", appearance: .aqua, scheme: .light)
        let dark = try await render(outcome, theme: "dark", appearance: .darkAqua, scheme: .dark)
        XCTAssertNotEqual(light, dark, "Both appearance variants must actually be rendered")
    }

    private func render(_ outcome: ApplyOutcome, theme: String,
                        appearance: NSAppearance.Name, scheme: ColorScheme) async throws -> Data {
        let root = OutcomeSheet(
            title: "Проверка всех списков основного роутера и резервных каналов офиса с длинным названием",
            outcome: outcome, onClose: {})
            .frame(width: size.width, height: size.height)
            .background(Palette.canvas)
            .environment(\.colorScheme, scheme)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = hosting.appearance
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        hosting.setFrameSize(size)
        await settle(hosting)

        XCTAssertEqual(hosting.bounds.width, 640, accuracy: 1)
        XCTAssertEqual(hosting.bounds.height, 600, accuracy: 1)
        let initial = try capture(hosting, name: "outcome-\(theme)-640")
        let initialLabels = try labels(in: initial)
        let firstClose = try visibleClose(in: initialLabels)
        XCTAssertTrue(initialLabels.contains { normalized($0.text).contains("FIRSTROW001") },
                      "The first problem must be readable when the sheet opens")
        XCTAssertFalse(initialLabels.contains { normalized($0.text).contains("LASTROW100") },
                       "The large fixture must require scrolling")

        let scroll = try XCTUnwrap(subviews(hosting).compactMap { $0 as? NSScrollView }.max {
            ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
        }, "Problems must have a scrollable viewport")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentSize.height * 3)
        let viewport = hosting.convert(scroll.bounds, from: scroll)
        XCTAssertTrue(hosting.bounds.insetBy(dx: -1, dy: -1).contains(viewport),
                      "The problems viewport must stay inside the sheet")

        // LazyVStack can revise its estimated document size as rows appear.
        // Repeating the scroll after layout reaches the actual last row.
        for _ in 0..<4 {
            document.scroll(NSPoint(x: 0, y: document.bounds.maxY))
            await settle(hosting)
        }
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        let bottom = try capture(hosting, name: "outcome-\(theme)-640-bottom")
        let bottomLabels = try labels(in: bottom)
        XCTAssertTrue(bottomLabels.contains { normalized($0.text).contains("LASTROW100") },
                      "The end of the final problem is clipped or unreachable: \(bottomLabels.map(\.text))")
        let lastClose = try visibleClose(in: bottomLabels)
        XCTAssertEqual(firstClose.minY, lastClose.minY, accuracy: 2,
                       "The close button must stay outside the scrolling list")
        return initial
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func capture(_ view: NSView, name: String) throws -> Data {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 20_000, "The sheet render is blank")
        try png.write(to: outputDirectory.appendingPathComponent(name + ".png"))
        return png
    }

    private func labels(in png: Data) throws -> [(text: String, frame: CGRect)] {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        let request = try NativeUIInteractions.recognitionRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.customWords = ["FIRSTROW001", "LASTROW100", "Закрыть"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let bounds = observation.boundingBox
            return (text, CGRect(x: bounds.minX * size.width, y: bounds.minY * size.height,
                                 width: bounds.width * size.width, height: bounds.height * size.height))
        }
    }

    /// XCTest does not expose SwiftUI's accessibility tree here. OCR verifies
    /// the visible label and room for the button's actual style padding.
    private func visibleClose(in labels: [(text: String, frame: CGRect)]) throws -> CGRect {
        let close = try XCTUnwrap(labels.first {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Закрыть") == .orderedSame
        },
                                 "Close must remain visible with a hundred long problems")
        let buttonBounds = close.frame.insetBy(dx: -16, dy: -8)
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(buttonBounds),
                      "The close button is clipped by the sheet boundary")
        return close.frame
    }

    private func normalized(_ text: String) -> String {
        text.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private func subviews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(subviews)
    }
}
