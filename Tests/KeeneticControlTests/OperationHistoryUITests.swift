import AppKit
import SwiftUI
import Vision
import XCTest
@testable import KeeneticControl

@MainActor
final class OperationHistoryUITests: XCTestCase {
    func testHistoryFitsNarrowAndWideLayoutsInBothThemes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = OperationHistoryStore(directory: directory)
        let profile = RouterProfile(name: "Домашний роутер с длинным названием")
        let session = RouterSession(router: profile, dependencies: RouterSessionDependencies(
            makeTransport: { _, _ in FakeTransport() }, password: { _ in nil }, retryDelay: {},
            settings: { .default }, backup: { _, _, _ in nil }, operationHistory: { history }))
        let id = history.begin(profile: profile, plan: Plan(title: "Обновление списков доменов"),
                               configText: "", backupURL: nil)
        history.finish(id, status: .temporary)
        for width in [520.0, 860.0] {
            for dark in [false, true] {
                let text = try await render(OperationHistoryView(session: session),
                    size: NSSize(width: width, height: 550), dark: dark, name: "history-\(Int(width))")
                for label in ["История операций", "С замечаниями", "Очистить", "Применено временно"] {
                    XCTAssertTrue(text.contains { $0.localizedCaseInsensitiveContains(label)
                        || (label == "Очистить" && $0.localizedCaseInsensitiveContains("очстить")) }, "Missing \(label): \(text)")
                }
            }
        }
    }

    func testLongHistoryDetailKeepsCloseActionVisibleAndInvocable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-detail-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = OperationHistoryStore(directory: directory)
        var plan = Plan(title: "Обновление нескольких списков с длинными именами и сотнями записей для проверки размещения содержимого")
        for index in 0..<601 {
            plan.addDomain("domain-list0", "service-\(index).example.org", command: "object-group fqdn domain-list0 include service-\(index).example.org")
        }
        let id = history.begin(profile: RouterProfile(name: "Проверочный роутер"), plan: plan,
            configText: "", backupURL: URL(fileURLWithPath: "/missing-history-backup.kcbackup"))
        history.finish(id, status: .needsAttention, problems: Array(repeating:
            "Источник временно недоступен. Существующее содержимое сохранено; повторная проверка доступна после восстановления соединения.", count: 10))
        for dark in [false, true] {
            var closed = false
            let text = try await render(OperationHistoryDetail(recordID: id, history: history, onClose: { closed = true }),
                size: NSSize(width: 720, height: 620), dark: dark, name: "history-detail",
                pressClose: true)
            XCTAssertTrue(text.contains { $0.contains("Закрыть") })
            XCTAssertTrue(text.contains { $0.contains("перемещена или удалена") })
            XCTAssertTrue(closed, "Visible close button must invoke its real action")
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool, name: String,
                                 pressClose: Bool = false) async throws -> [String] {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
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
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/ui-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        let request = try NativeUIInteractions.recognitionRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        try VNImageRequestHandler(data: png, options: [:]).perform([request])
        if pressClose {
            try NativeUIInteractions.click("Закрыть", in: hosting, window: window)
        }

        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
