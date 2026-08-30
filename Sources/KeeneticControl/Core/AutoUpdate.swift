import Foundation
import SwiftUI
import UserNotifications

/// Фоновая сверка источников доменов с тем, что лежит на роутере.
///
/// Сама НИЧЕГО на роутер не отправляет и к нему не подключается: сравнивает
/// свежие источники с последней прочитанной конфигурацией. Так проверка не
/// может ни сломать настройки, ни потратить лимит неудачных входов, а
/// решение применять план остаётся за человеком.
@MainActor
final class AutoUpdater: ObservableObject {
    static let shared = AutoUpdater()

    struct Finding: Identifiable {
        let id = UUID()
        var plan: Plan
        var routerID: UUID
        var routerName: String
        var found: Date
    }

    @Published private(set) var finding: Finding?
    @Published private(set) var checking = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastMessage: String?

    private var timer: Timer?
    private weak var session: RouterSession?
    private var notificationsAsked = false

    private init() {}

    func attach(session: RouterSession) {
        self.session = session
        lastCheck = Store.shared.settings.lastAutoUpdate
        reschedule()
    }

    func dismissFinding() { finding = nil }

    /// Тикаем часто и коротко: длинный таймер не переживает сон компьютера,
    /// а так после пробуждения проверка просто случится на следующем тике.
    func reschedule() {
        timer?.invalidate()
        timer = nil
        guard Store.shared.settings.autoUpdateEnabled else { return }

        let created = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        RunLoop.main.add(created, forMode: .common)
        timer = created
        Task { await tick() }
    }

    private func tick() async {
        let settings = Store.shared.settings
        guard settings.autoUpdateEnabled, !checking else { return }
        let interval = TimeInterval(max(1, settings.autoUpdateHours) * 3600)
        if let last = lastCheck, Date().timeIntervalSince(last) < interval { return }
        await check(manual: false)
    }

    /// Один проход сверки. `manual` — запуск кнопкой, тогда говорим и о том,
    /// что расхождений нет.
    func check(manual: Bool) async {
        guard !checking, let session else { return }
        checking = true
        defer { checking = false }

        let store = Store.shared
        let chosen = store.settings.autoUpdateSources
        let sources = store.allSources.filter { chosen.isEmpty || chosen.contains($0.key) }
        let conflicts = CustomSource.conflictingSourceTitles(store.allSources)
        guard conflicts.isEmpty else {
            lastMessage = "Сверка остановлена: источники спорят за один список."
            log(.warn, lastMessage! + " " + conflicts.joined(separator: "; "))
            return
        }
        guard !sources.isEmpty else {
            lastMessage = "Не выбрано ни одного источника."
            return
        }

        // Сравниваем с последней прочитанной конфигурацией. Подключаться
        // самостоятельно проверка не должна: это её единственная гарантия
        // безопасности.
        guard let state = session.state else {
            lastMessage = "Роутер ещё не прочитан — сверять не с чем."
            if manual { log(.warn, "Сверка источников: \(lastMessage!)") }
            return
        }

        let operation = session.beginOperation()
        let routerID = operation.routerID
        let profile = session.router
        let routerName = profile.name
        var plans: [Plan] = []
        var reserved = Set(state.groups.keys)
        var failures: [String] = []

        for spec in sources {
            // Пока источник скачивался, человек мог выбрать другой роутер.
            // Не продолжаем строить и тем более показывать устаревший план.
            guard session.isCurrent(operation) else {
                lastMessage = "Сверка отменена: выбран другой роутер."
                return
            }
            do {
                let data = try await session.loadSource(spec, forceRefresh: true)
                guard session.isCurrent(operation) else {
                    lastMessage = "Сверка отменена: выбран другой роутер."
                    return
                }
                plans.append(Planner.planImport(
                    groups: state.groups,
                    data: data,
                    chunkSize: store.settings.chunkSize,
                    removeStale: store.settings.removeStaleByDefault,
                    reservedIDs: &reserved))
            } catch {
                failures.append("\(spec.title): \(session.describe(error))")
            }
        }

        guard session.isCurrent(operation) else {
            lastMessage = "Сверка отменена: выбран другой роутер."
            return
        }
        lastCheck = Date()
        store.settings.lastAutoUpdate = lastCheck

        let merged = Planner.merge(title: "Обновление списков от \(Format.humanDate(Date()))",
                                   plans: plans)
            .forRouter(profile)

        if !failures.isEmpty {
            log(.warn, "Сверка источников: не загрузились — " + failures.joined(separator: "; "))
        }

        guard !merged.isEmpty else {
            // Молчим в журнале, когда всё совпало: смысл фоновой проверки в
            // том, чтобы напоминать о себе только когда есть что сказать.
            lastMessage = "Расхождений нет · проверено \(Format.age(lastCheck!))"
            if manual { log(.ok, "Сверка источников: списки на роутере совпадают с источниками.") }
            return
        }

        let summary = merged.summary.joined(separator: ", ")
        lastMessage = summary
        finding = Finding(plan: merged, routerID: routerID, routerName: routerName, found: Date())
        log(.warn, "Источники разошлись с «\(routerName)»: \(summary). "
            + "План готов — открой «Списки FQDN».")
        notify(router: routerName, summary: summary)
    }

    /// Системное уведомление — по возможности. Если разрешения нет,
    /// молча обходимся журналом и полосой в окне.
    private func notify(router: String, summary: String) {
        guard Store.shared.settings.autoUpdateNotify else { return }
        let center = UNUserNotificationCenter.current()

        func post() {
            let content = UNMutableNotificationContent()
            content.title = "Списки разошлись с «\(router)»"
            content.body = summary
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }

        if notificationsAsked {
            post()
            return
        }
        notificationsAsked = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in post() }
        }
    }
}
