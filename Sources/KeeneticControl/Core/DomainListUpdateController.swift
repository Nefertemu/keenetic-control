import Combine
import Foundation

struct DomainSourceUpdateResult: Identifiable {
    enum Status { case updated, unchanged, skipped, needsAttention }
    var spec: SourceSpec
    var status: Status
    var added: Int = 0
    var removed: Int = 0
    var createdParts: Int = 0
    var message: String? = nil
    var id: String { spec.key }
}

struct DomainListUpdateReport {
    var finishedAt: Date = Date()
    var results: [DomainSourceUpdateResult] = []
    var error: String? = nil
    var backupURL: URL? = nil
    var cancelled: Bool = false
}

/// Одна явная команда пользователя: свежие источники → свежий снимок →
/// общий план → копия → применение → проверка → сохранение.
/// При уходе с вкладки контроллер остаётся у сессии вместе с результатом.
@MainActor
final class DomainListUpdateController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var owner: RouterPresentationContext?
    @Published private(set) var routerName = ""
    @Published private(set) var phase = ""
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var report: DomainListUpdateReport?

    private let sourceLoader: (RouterSession, SourceSpec) async throws -> SourceData
    private let catalogProvider: (() -> [SourceSpec])?

    init(sourceLoader: @escaping (RouterSession, SourceSpec) async throws -> SourceData = {
        try await $0.loadSource($1, forceRefresh: true, requireFreshComplete: true)
    }, catalogProvider: (() -> [SourceSpec])? = nil) {
        self.sourceLoader = sourceLoader
        self.catalogProvider = catalogProvider
    }

    func update(session: RouterSession, catalog: [SourceSpec], chunkSize: Int,
                saveConfig: Bool) async {
        guard !isRunning else { return }
        let profile = session.router
        let operation = session.beginOperation()
        let verificationLimit = session.connections.dependencies.settings().maxDomainsPerList
        let effectiveChunkSize = min(300, max(1, min(chunkSize, verificationLimit)))
        isRunning = true
        owner = RouterPresentationContext(profile)
        routerName = profile.name
        report = nil
        phase = "Читаю списки на роутере…"
        completed = 0
        total = 0
        defer { isRunning = false; phase = "" }

        var results: [String: DomainSourceUpdateResult] = [:]
        var planned: [String: Plan] = [:]
        var writeStarted = false
        var backupURL: URL?

        func orderedResults() -> [DomainSourceUpdateResult] {
            catalog.compactMap { results[$0.key] }
        }
        func requireRelevant() throws {
            try Task.checkCancellation()
            guard session.activeRouterID == profile.id, session.isCurrent(operation),
                  RouterPresentationContext(session.router) == RouterPresentationContext(profile) else {
                throw CancellationError()
            }
            if let catalogProvider, catalogProvider() != catalog {
                throw TransportError("Источники изменились во время проверки.",
                                     hint: "Нажми «Обновить списки» ещё раз.")
            }
            guard session.connections.dependencies.settings().maxDomainsPerList == verificationLimit else {
                throw TransportError("Лимит проверки изменился во время обновления.",
                                     hint: "Нажми «Обновить списки» ещё раз.")
            }
        }
        func markUnfinished(_ message: String) {
            for spec in catalog where planned[spec.key] != nil {
                results[spec.key]?.status = writeStarted ? .needsAttention : .skipped
                results[spec.key]?.message = message
            }
        }

        do {
            try requireRelevant()
            let conflicts = CustomSource.conflictingSourceTitles(catalog)
            guard conflicts.isEmpty, Set(catalog.map(\.key)).count == catalog.count else {
                throw TransportError("Нельзя однозначно связать списки с источниками.",
                                     hint: "Проверь названия своих источников: " + conflicts.joined(separator: "; "))
            }
            let initialText = try await session.readConfigText(operation: operation)
            try requireRelevant()
            session.connections.storeConfigurationSnapshot(initialText, owner: operation.routerID)
            let initialGroups = RouterConfigParser.parseFqdnGroups(initialText)
            let installed = catalog.filter { !Planner.managedGroups(initialGroups, spec: $0).isEmpty }
            guard !installed.isEmpty else {
                report = DomainListUpdateReport(error: "На роутере пока нет списков из известных источников. Загрузи нужный источник на вкладке «Источники».")
                return
            }

            total = installed.count
            var downloaded: [String: SourceData] = [:]
            for spec in installed {
                try requireRelevant()
                phase = "Загружаю «\(spec.title)»…"
                do {
                    let data = try await sourceLoader(session, spec)
                    try requireRelevant()
                    guard data.spec == spec else { throw TransportError("Ответ относится к другому источнику.") }
                    // Даже внедрённый загрузчик должен явно подтвердить
                    // свежесть; проверку записей повторяет чистый планировщик.
                    guard !data.fromCache else {
                        throw TransportError("Свежая версия недоступна. Копия из кэша не используется для удаления доменов.")
                    }
                    downloaded[spec.key] = data
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try requireRelevant()
                    results[spec.key] = DomainSourceUpdateResult(spec: spec, status: .skipped,
                                                                 message: session.describe(error))
                }
                completed += 1
            }

            try requireRelevant()
            guard !downloaded.isEmpty else {
                report = DomainListUpdateReport(results: orderedResults(),
                                                error: "Свежие источники недоступны. Списки не изменены.")
                return
            }

            try await session.withExclusiveWriteOperation(operation: operation) {
                try requireRelevant()
                phase = "Сверяю изменения со свежей конфигурацией…"
                let text = try await session.readConfigText(operation: operation)
                try requireRelevant()
                session.connections.storeConfigurationSnapshot(text, owner: operation.routerID)
                let groups = RouterConfigParser.parseFqdnGroups(text)
                var reserved = Set(groups.keys)

                for spec in installed {
                    guard let data = downloaded[spec.key] else { continue }
                    guard !Planner.managedGroups(groups, spec: spec).isEmpty else {
                        results[spec.key] = DomainSourceUpdateResult(spec: spec, status: .skipped,
                            message: "Списки этого источника удалены во время загрузки. Обновление пропущено.")
                        continue
                    }
                    do {
                        let plan = try DomainListSyncPlanner.plan(groups: groups, data: data,
                            chunkSize: effectiveChunkSize, reservedIDs: &reserved)
                        let oldEntries = Set(Planner.managedGroups(groups, spec: spec).flatMap(\.includes))
                        let wanted = Set(data.entries.compactMap(Domains.normalize))
                        results[spec.key] = DomainSourceUpdateResult(spec: spec,
                            status: plan.isEmpty ? .unchanged : .needsAttention,
                            added: wanted.subtracting(oldEntries).count,
                            removed: oldEntries.subtracting(wanted).count,
                            createdParts: plan.createdGroups.count)
                        if !plan.isEmpty { planned[spec.key] = plan }
                    } catch {
                        results[spec.key] = DomainSourceUpdateResult(spec: spec, status: .skipped,
                                                                     message: session.describe(error))
                    }
                }

                let plans = installed.compactMap { planned[$0.key] }
                let merged = Planner.merge(title: "Обновление списков доменов", plans: plans).forRouter(profile)
                guard !merged.isEmpty else { return }
                try requireRelevant()
                phase = "Применяю изменения и проверяю списки…"
                writeStarted = true
                let outcome = try await session.apply(plan: merged, dryRun: false, saveConfig: saveConfig,
                                                       preWriteCheck: requireRelevant)
                backupURL = outcome.backupURL
                // После начала записи переключение вкладки/выбора роутера
                // не перенаправляет команды: executor удерживает владельца.
                for spec in installed where planned[spec.key] != nil {
                    results[spec.key]?.status = outcome.problems.isEmpty ? .updated : .needsAttention
                    if !outcome.problems.isEmpty {
                        results[spec.key]?.message = "Результат не прошёл проверку. Открой подробности ниже."
                    } else if !saveConfig {
                        results[spec.key]?.message = "Применено без сохранения после перезагрузки — так задано в настройках."
                    }
                }
                if !outcome.problems.isEmpty {
                    report = DomainListUpdateReport(results: orderedResults(),
                        error: "Проверка нашла расхождения. Конфигурация не сохранена.\n"
                            + outcome.problems.joined(separator: "\n"), backupURL: backupURL)
                }
            }
            if report == nil { report = DomainListUpdateReport(results: orderedResults(), backupURL: backupURL) }
            if report?.error == nil, !results.values.contains(where: { $0.status == .skipped || $0.status == .needsAttention }),
               session.activeRouterID == profile.id, session.isCurrent(operation),
               AutoUpdater.shared.finding?.routerID == profile.id {
                AutoUpdater.shared.dismissFinding()
            }
            log(.info, "Списки «\(profile.name)»: обновлено \(results.values.filter { $0.status == .updated }.count), "
                + "без изменений \(results.values.filter { $0.status == .unchanged }.count), "
                + "пропущено \(results.values.filter { $0.status == .skipped }.count).")
        } catch {
            let applicationError = error as? DomainListApplicationError
            writeStarted = applicationError != nil
            backupURL = applicationError?.backupURL ?? backupURL
            let cancelled = error is CancellationError || applicationError?.cause is CancellationError
            let message: String
            if writeStarted {
                message = "Обновление не завершено. Часть команд могла примениться; проверь списки и резервную копию.\n"
                    + session.describe(error)
            } else if cancelled {
                message = "Обновление отменено до записи: изменился выбранный роутер или запрос был отменён."
            } else { message = session.describe(error) }
            markUnfinished(message)
            report = DomainListUpdateReport(results: orderedResults(), error: message,
                                            backupURL: backupURL, cancelled: cancelled)
            log(.warn, "Обновление списков «\(profile.name)»: \(message)")
        }
    }
}
