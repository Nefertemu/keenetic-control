import AppKit
import SwiftUI
import Vision
import XCTest
@testable import KeeneticControl

@MainActor
final class RestoreUITests: XCTestCase {
    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/ui-snapshots", isDirectory: true)
    }

    func testSelectiveRestorePreviewKeepsChoicesAndActionsVisibleInBothThemes() async throws {
        let backup = RegressionFixtures.sampleConfig
        let current = backup.replacingOccurrences(of: "kinopub.tv", with: "new.example")

        let difference = try Restore.validatedComparison(backup: backup, current: current)
        for width in [520.0, 760.0] {
            for dark in [false, true] {
                let view = RestorePreview(difference: difference, snapshot: "router_2026-09-22_running-config.kcbackup", onBuild: { _ in }, onCancel: {})
                    .environment(\.colorScheme, dark ? .dark : .light)
                let text = try await render(view, size: NSSize(width: width, height: 620),
                                            dark: dark, name: "restore-selection-\(Int(width))")
                for label in ["Что восстановить", "Содержимое", "Цепочки", "Статические", "Выбрать списки", "Собрать план", "Отмена"] {
                    XCTAssertTrue(text.contains { $0.contains(label) }, "Missing \(label): \(text)")
                }
            }
        }
    }

    func testPortablePasswordSheetKeepsBothFieldsAndActionsVisibleInBothThemes() async throws {
        let request = PortableBackupRequest(mode: .exportFile(URL(fileURLWithPath: "/tmp/source.kcbackup"),
            URL(fileURLWithPath: "/tmp/export.kcportable")), host: "fixture")
        for dark in [false, true] {
            let text = try await render(PortableBackupSheet(request: request, onComplete: { _ in }, onCancel: {})
                .environment(\.colorScheme, dark ? .dark : .light),
                size: NSSize(width: 470, height: 250), dark: dark, name: "portable-password")
            for label in ["Экспорт с паролем", "Повтори пароль", "Зашифровать", "Отмена"] {
                XCTAssertTrue(text.contains { $0.contains(label) }, "Missing \(label): \(text)")
            }
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool, name: String) async throws -> [String] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting; window.appearance = hosting.appearance; window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        hosting.setFrameSize(size)
        for _ in 0..<3 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(hosting.bounds.width, size.width, accuracy: 1)
        XCTAssertEqual(hosting.bounds.height, size.height, accuracy: 1)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        let request = try NativeUIInteractions.recognitionRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        try VNImageRequestHandler(data: png, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
