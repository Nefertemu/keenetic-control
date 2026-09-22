import Foundation

enum Backups {
    /// Имя файла собирается из адреса роутера — приводим его к безопасному виду.
    static func safeHost(_ host: String) -> String {
        host.replacingOccurrences(of: "[^A-Za-z0-9_.-]+", with: "_", options: .regularExpression)
    }

    private static let namePattern = try! NSRegularExpression(
        pattern: "^(.+)_\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}(?:_[A-Fa-f0-9-]{36})?_running-config$")

    /// Чей это снимок. Снимки всех роутеров лежат в одной папке, и без
    /// разбора имени их не отфильтровать.
    static func host(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return RouterConfigParser.capture(namePattern, in: name, group: 1) ?? ""
    }

    /// Два плана могут создать снимки в одну секунду. Идентификатор не даёт
    /// второму снимку затереть первый, включая одновременные подключения.
    static func runningConfigFilename(host: String, date: Date = Date(),
                                      identifier: UUID = UUID()) -> String {
        "\(safeHost(host))_\(Format.stamp(date))_\(identifier.uuidString)_running-config.\(SecureBackup.pathExtension)"
    }

    @discardableResult
    static func saveRunningConfig(host: String, text: String, keep: Int) -> URL? {
        let safeHost = safeHost(host)
        let url = AppPaths.backups.appendingPathComponent(runningConfigFilename(host: host))

        do { try SecureBackup.write(text, to: url) }
        catch {
            log(.error, "Не удалось зашифровать резервную копию: \(error.localizedDescription)")
            return nil
        }

        if keep > 0 { prune(prefix: safeHost, keep: keep) }
        return url
    }

    static func list() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.backups, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter {
            $0.pathExtension == SecureBackup.pathExtension || $0.pathExtension == "txt"
        }.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
    }

    static func read(_ url: URL) throws -> String { try SecureBackup.read(url) }

    /// Пароль нужен только для открытия переносимого контейнера. Локальная
    /// копия сразу повторно шифруется ключом текущего Mac и проверяется чтением.
    static func importPortable(_ source: URL, password: String, host: String) throws -> URL {
        let text = try PortableBackup.read(source, password: password)
        let target = AppPaths.backups.appendingPathComponent(runningConfigFilename(host: host))
        do {
            try SecureBackup.write(text, to: target)
            guard try SecureBackup.read(target) == text else { throw SecureBackupError.invalidContainer }
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    /// Старые версии оставляли running-config открытым текстом. Миграция
    /// сначала пишет и перечитывает зашифрованный контейнер, и только после
    /// успешной сверки удаляет исходный `.txt`; при любой ошибке старый файл
    /// остаётся на месте.
    @discardableResult
    static func migrateLegacyBackups() -> (migrated: Int, failures: [String]) {
        let running = list().filter { $0.pathExtension == "txt" && !host(of: $0).isEmpty }
        let wireGuard = ((try? FileManager.default.contentsOfDirectory(
            at: AppPaths.wireguard, includingPropertiesForKeys: nil)) ?? []).filter {
                $0.pathExtension == "txt" && $0.deletingPathExtension().lastPathComponent
                    .hasSuffix("_startup-config")
            }
        let legacy = running + wireGuard
        var migrated = 0
        var failures: [String] = []

        for source in legacy {
            do {
                let text = try SecureBackup.read(source)
                let target = source.deletingPathExtension()
                    .appendingPathExtension(SecureBackup.pathExtension)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try SecureBackup.write(text, to: target)
                }
                guard try SecureBackup.read(target) == text else {
                    throw SecureBackupError.invalidContainer
                }
                try FileManager.default.removeItem(at: source)
                migrated += 1
            } catch {
                failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (migrated, failures)
    }

    private static func prune(prefix: String, keep: Int) {
        let matching = list().filter { host(of: $0) == prefix }
        guard matching.count > keep else { return }
        for url in matching.dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }
}
