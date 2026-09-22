import Combine
import Foundation

/// Одна атомарная запись на операцию: история не зависит от текстового журнала.
/// Ключ роутера — UUID профиля, поэтому одинаковые имена не смешивают события.
@MainActor
final class OperationHistoryStore: ObservableObject {
    static let shared = OperationHistoryStore(directory: AppPaths.support.appendingPathComponent("operations"))
    @Published private(set) var records: [OperationHistoryRecord] = []
    @Published private(set) var persistenceError: String?

    private let directory: URL
    private let limit: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL, limit: Int = 100) {
        self.directory = directory
        self.limit = max(1, limit)
        encoder.outputFormatting = [.sortedKeys]
        load()
    }

    func records(for routerID: UUID) -> [OperationHistoryRecord] {
        records.filter { $0.routerID == routerID }
    }

    @discardableResult
    func begin(profile: RouterProfile, plan: Plan, configText: String, backupURL: URL?) -> UUID {
        let record = OperationHistoryRecord(profile: profile, plan: plan,
                                            configText: configText, backupURL: backupURL).redacted()
        append(record)
        return record.id
    }

    func finish(_ id: UUID, status: OperationHistoryRecord.Status, problems: [String] = []) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = status
        records[index].finishedAt = Date()
        records[index].problems = problems.map(DiagnosticPrivacy.redact)
        persist(records[index])
        prune()
    }

    func append(_ record: OperationHistoryRecord) {
        let safe = record.redacted()
        records.removeAll { $0.id == safe.id }
        records.insert(safe, at: 0)
        records.sort { $0.startedAt > $1.startedAt }
        persist(safe)
        prune()
    }

    /// Привязываем общий отчёт источников к записи применения. Проверка без
    /// изменений тоже остаётся в истории, но не создаёт фиктивных команд.
    func recordDomainReport(profile: RouterProfile, report: DomainListUpdateReport, historyID: UUID?) {
        let versions = report.results.compactMap(\.sourceVersion)
        let messages = report.results.compactMap { result in
            result.message.map { result.spec.title + ": " + $0 }
        }
        var notes = report.error.map { [$0] } ?? []
        notes.append(contentsOf: messages)
        let attention = report.error != nil || report.results.contains {
            $0.status == .skipped || $0.status == .needsAttention || $0.status == .needsConfirmation
        }
        let status: OperationHistoryRecord.Status = report.cancelled ? .cancelled
            : attention ? .needsAttention
            : report.results.contains { $0.status == .appliedTemporarily } ? .temporary
            : report.results.contains { $0.status == .updated } ? .saved : .unchanged
        if let historyID, let index = records.firstIndex(where: { $0.id == historyID }) {
            var record = records[index]
            if record.status != .failed { record.status = status }
            record.finishedAt = report.finishedAt
            if !notes.isEmpty {
                var seen = Set<String>()
                record.problems = (record.problems + notes).filter { seen.insert($0).inserted }
            }
            record.sources = versions
            append(record)
        } else {
            var plan = Plan(title: "Проверка списков доменов")
            plan.sourceVersions = versions
            var record = OperationHistoryRecord(profile: profile, plan: plan,
                                                configText: "", backupURL: report.backupURL)
            record.status = status
            record.problems = notes
            record.finishedAt = report.finishedAt
            append(record)
        }
    }

    func clear(routerID: UUID) {
        let selected = records.filter { $0.routerID == routerID && $0.status != .running }
        do {
            for record in selected {
                let url = fileURL(record.id)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                records.removeAll { $0.id == record.id }
            }
            persistenceError = nil
        } catch { failed(error) }
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            var damaged = 0
            for file in files {
                guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
                do {
                    let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true, let size = values.fileSize,
                          size <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
                    let data = try Data(contentsOf: file)
                    guard data.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
                    let original = try decoder.decode(OperationHistoryRecord.self, from: data)
                    var record = original.redacted()
                    guard record.id.uuidString == file.deletingPathExtension().lastPathComponent else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    if record.status == .running {
                        record.status = .interrupted
                        record.finishedAt = Date()
                        record.problems.append("Приложение закрылось до получения результата. Перечитай конфигурацию роутера перед повторным действием.")
                    }
                    if record != original { persist(record) }
                    records.append(record)
                } catch { damaged += 1 }
            }
            records.sort { $0.startedAt > $1.startedAt }
            prune()
            if damaged > 0 { persistenceError = "Не удалось прочитать записей истории: \(damaged). Остальные доступны." }
        } catch { failed(error) }
    }

    private func persist(_ record: OperationHistoryRecord) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try encoder.encode(record.redacted()).write(to: fileURL(record.id), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL(record.id).path)
            persistenceError = nil
        } catch { failed(error) }
    }

    private func prune() {
        // Предел отдельно для каждого роутера: активный сосед не вытесняет
        // историю роутера, к которому подключаются редко.
        var counts: [UUID: Int] = [:]
        let expired = records.filter { record in
            counts[record.routerID, default: 0] += 1
            return counts[record.routerID, default: 0] > limit && record.status != .running
        }
        for record in expired {
            do {
                let file = fileURL(record.id)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                records.removeAll { $0.id == record.id }
            } catch { failed(error) }
        }
    }

    private func failed(_ error: Error) {
        persistenceError = "Не удалось сохранить историю операций: " + error.localizedDescription
        log(.warn, persistenceError!)
    }
}
