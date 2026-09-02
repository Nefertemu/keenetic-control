import Foundation
import SwiftUI

/// Сравнение версий вида «1.2.0».
///
/// Строкой их сравнивать нельзя: «1.10.0» лексикографически меньше «1.9.0»,
/// и приложение молча пропустило бы обновление.
enum AppVersion {
    /// Отрицательное — левая младше, ноль — равны, положительное — старше.
    static func compare(_ left: String, _ right: String) -> Int {
        let lhs = parts(left), rhs = parts(right)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    /// «v1.2.0», «1.2.0-beta.1» — берём только числовую часть.
    static func parts(_ value: String) -> [Int] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let withoutPrefix = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let core = withoutPrefix.split(separator: "-", maxSplits: 1).first.map(String.init)
            ?? withoutPrefix
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) > 0
    }
}

struct AvailableUpdate: Equatable {
    var version: String
    var title: String
    var pageURL: URL
    var notes: String
}

/// Проверка новых версий на GitHub.
///
/// Приложение НИЧЕГО не скачивает и не устанавливает само: оно только
/// сообщает, что версия вышла, и открывает страницу релиза. Молчаливая
/// подмена собственного бинарника — не та вещь, которую стоит делать без
/// ведома человека.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var available: AvailableUpdate?
    @Published private(set) var checking = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastError: String?

    /// Версию, о которой уже сказали, второй раз не навязываем.
    private var dismissedVersion: String?
    private let endpoint = URL(
        string: "https://api.github.com/repos/Nefertemu/keenetic-control/releases/latest")!

    private init() {}

    func dismiss() {
        dismissedVersion = available?.version
        available = nil
    }

    /// `manual` — запуск кнопкой: тогда сообщаем и об отсутствии обновлений.
    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        lastError = nil

        do {
            let release = try await fetchLatest()
            lastCheck = Date()
            Store.shared.settings.lastUpdateCheck = lastCheck

            guard AppVersion.isNewer(release.version, than: Bundle.appVersion) else {
                available = nil
                if manual { log(.ok, "Обновлений нет: у тебя \(Bundle.appVersion), последняя \(release.version).") }
                return
            }
            guard manual || release.version != dismissedVersion else { return }
            available = release
            log(.info, "Вышла версия \(release.version) — открой «Роутеры и настройки», чтобы перейти к релизу.")
        } catch {
            lastCheck = Date()
            lastError = error.localizedDescription
            if manual { log(.warn, "Не удалось проверить обновления: \(error.localizedDescription)") }
        }
    }

    private func fetchLatest() async throws -> AvailableUpdate {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KeeneticControl/\(Bundle.appVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TransportError("GitHub ответил HTTP \(http.statusCode).")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let page = object["html_url"] as? String,
              let url = URL(string: page)
        else { throw TransportError("Непонятный ответ GitHub.") }

        return AvailableUpdate(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            title: (object["name"] as? String) ?? tag,
            pageURL: url,
            notes: (object["body"] as? String) ?? "")
    }
}
