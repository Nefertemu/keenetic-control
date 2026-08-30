import Foundation
import SwiftUI

enum LogLevel: String, Codable {
    case info, ok, warn, error, cmd

    var symbol: String {
        switch self {
        case .info:  return "info.circle"
        case .ok:    return "checkmark.circle.fill"
        case .warn:  return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .cmd:   return "chevron.right"
        }
    }

    var tint: Color {
        switch self {
        case .info:  return .secondary
        case .ok:    return .green
        case .warn:  return .orange
        case .error: return .red
        case .cmd:   return .accentColor
        }
    }
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let text: String

    var stamp: String { LogEntry.formatter.string(from: date) }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Журнал приложения: живёт в памяти для интерфейса и дублируется на диск.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var entries: [LogEntry] = []

    private let fileURL: URL
    private let fileFormatter: DateFormatter
    private let limit = 4000

    private init() {
        fileURL = AppPaths.logs.appendingPathComponent("keenetic-control.log")
        fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        try? FileManager.default.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
        redactExistingFile()
    }

    func append(_ level: LogLevel, _ text: String) {
        let entry = LogEntry(date: Date(), level: level, text: CLI.redactSecrets(text))
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        write(entry)
    }

    func clear() {
        entries.removeAll()
        // Кнопка «Очистить» должна убрать и полную копию на диске:
        // иначе старые команды снова останутся в журнале после перезапуска.
        try? Data().write(to: fileURL, options: .atomic)
    }

    var plainText: String {
        entries.map { "[\($0.stamp)] \($0.level.rawValue.uppercased())  \($0.text)" }
            .joined(separator: "\n")
    }

    private func write(_ entry: LogEntry) {
        let line = "\(fileFormatter.string(from: entry.date))\t\(entry.level.rawValue)\t\(entry.text)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.write(contentsOf: data)
            if size > Self.maxFileSize { rotate() }
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// В прошлых версиях WireGuard-команды записывались целиком. При первом
    /// запуске новой версии заменяем их значения секретов прямо в старом логе.
    private func redactExistingFile() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let redacted = CLI.redactSecrets(text)
        guard redacted != text else { return }
        try? redacted.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Без ротации файл журнала растёт бесконечно.
    private static let maxFileSize: UInt64 = 4 * 1024 * 1024

    private func rotate() {
        let archive = fileURL.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: archive)
        try? FileManager.default.moveItem(at: fileURL, to: archive)
    }
}

/// Логирование из любого потока.
func log(_ level: LogLevel, _ text: String) {
    Task { @MainActor in LogStore.shared.append(level, text) }
}

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("KeeneticControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let cache: URL = subdirectory("cache")
    static let logs: URL = subdirectory("logs")
    static let backups: URL = subdirectory("backups")
    static let wireguard: URL = subdirectory("wireguard")

    static var settingsFile: URL { support.appendingPathComponent("settings.json") }
    static var routersFile: URL { support.appendingPathComponent("routers.json") }
    static var sourcesFile: URL { support.appendingPathComponent("sources.json") }

    private static func subdirectory(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
