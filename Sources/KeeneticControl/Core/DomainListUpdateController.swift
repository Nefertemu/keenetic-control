import Combine
import Foundation

struct DomainSourceUpdateResult: Identifiable {
    enum Status { case updated, appliedTemporarily, unchanged, skipped, needsAttention, needsConfirmation }
    var spec: SourceSpec
    var status: Status
    var added: Int = 0
    var removed: Int = 0
    var createdParts: Int = 0
    var message: String? = nil
    var fetchedAt: Date? = nil
    var sourceVersion: OperationSourceVersion? = nil
    var id: String { spec.key }
}

struct DomainListUpdateReport {
    var finishedAt: Date = Date()
    var results: [DomainSourceUpdateResult] = []
    var error: String? = nil
    var backupURL: URL? = nil
    var cancelled: Bool = false
}

struct DomainRemovalConfirmation: Identifiable {
    let id = UUID()
    let spec: SourceSpec
    let previousEntries: Set<String>
    let desiredEntries: Set<String>
    let fetchedAt: Date?
    var removed: Int { previousEntries.subtracting(desiredEntries).count }

    static func isUnusual(previous: Set<String>, desired: Set<String>) -> Bool {
        let removed = previous.subtracting(desired).count
        return removed >= 20 && Double(removed) / Double(max(1, previous.count)) > 0.5
    }
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
    @Published private(set) var canCancel = false
    @Published private(set) var pendingConfirmations: [DomainRemovalConfirmation] = []

    private var cancelRequested = false
    private var downloadTask: Task<[String: SourceData], Error>?
    private var updateTask: Task<Void, Never>?
    private var lastRequest: (catalog: [SourceSpec], chunkSize: Int, saveConfig: Bool)?

    func cancel() {
        guard isRunning, canCancel else { return }
        cancelRequested = true
        phase = "Отменяю обновление…"
        updateTask?.cancel()
        downloadTask?.cancel()
    }

    func confirmRemoval(_ id: UUID, session: RouterSession) async {
        guard !isRunning, owner == RouterPresentationContext(session.router),
              let confirmation = pendingConfirmations.first(where: { $0.id == id }),
              let request = lastRequest else { return }
        await update(session: session, catalog: request.catalog, chunkSize: request.chunkSize,
                     saveConfig: request.saveConfig, confirmedRemovals: [confirmation])
    }

    private let sourceLoader: @MainActor (RouterSession, SourceSpec) async throws -> SourceData
    private let catalogProvider: (() -> [SourceSpec])?

    init(sourceLoader: @escaping @MainActor (RouterSession, SourceSpec) async throws -> SourceData = {
        try await $0.loadSource($1, forceRefresh: true, requireFreshComplete: true)
    }, catalogProvider: (() -> [SourceSpec])? = nil) {
        self.sourceLoader = sourceLoader
        self.catalogProvider = catalogProvider
    }

    func update(session: RouterSession, catalog: [SourceSpec], chunkSize: Int,
                saveConfig: Bool, confirmedRemovals: [DomainRemovalConfirmation] = []) async {
        guard !isRunning else { return }
        let profile = session.router
        let operation = session.beginOperation()
        let verificationLimit = session.connections.dependencies.settings().maxDomainsPerList
        let effectiveChunkSize = FqdnLimits.effective(chunkSize: chunkSize, verificationLimit: verificationLimit)
        isRunning = true
        canCancel = true
        cancelRequested = false
        pendingConfirmations = []
        lastRequest = (catalog, chunkSize, saveConfig)
        owner = RouterPresentationContext(profile)
        routerName = profile.name
        report = nil
        phase = "Читаю списки на роутере…"
        completed = 0
        total = 0
        var historyID: UUID?
        defer {
            isRunning = false; canCancel = false; downloadTask = nil; updateTask = nil; phase = ""
            if let report {
                session.operationHistory.recordDomainReport(profile: profile, report: report, historyID: historyID)
            }
        }

        var results: [String: DomainSourceUpdateResult] = [:]
        var planned: [String: Plan] = [:]
        var writeStarted = false
        var backupURL: URL?

        func orderedResults() -> [DomainSourceUpdateResult] {
            catalog.compactMap { results[$0.key] }
        }
        func requireRelevant() throws {
            try Task.checkCancellation()
            if cancelRequested { throw CancellationError() }
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

        let task = Task { @MainActor in
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
                phase = "Загружаю свежие источники…"
                let task = Task { @MainActor in
                    var downloaded: [String: SourceData] = [:]
                    try await SourceDownloadBatch.load(installed, loader: { spec in
                        let data = try await self.sourceLoader(session, spec)
                        guard data.spec == spec else { throw TransportError("Ответ относится к другому источнику.") }
                        guard !data.fromCache else {
                            throw TransportError("Свежая версия недоступна. Копия из кэша не используется для удаления доменов.")
                        }
                        return data
                    }, onComplete: { outcome in
                        try requireRelevant()
                        switch outcome.result {
                        case .success(let data): downloaded[outcome.spec.key] = data
                        case .failure(let error):
                            results[outcome.spec.key] = DomainSourceUpdateResult(spec: outcome.spec, status: .skipped,
                                                                                message: session.describe(error))
                        }
                        self.completed += 1
                    })
                    return downloaded
                }
                downloadTask = task
                let downloaded = try await withTaskCancellationHandler(operation: {
                    try await task.value
                }, onCancel: { task.cancel() })
                downloadTask = nil

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
                                message: "Списки этого источника удалены во время загрузки. Обновление пропущено.",
                                fetchedAt: data.fetchedAt, sourceVersion: OperationSourceVersion(spec: spec, data: data))
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
                                createdParts: plan.createdGroups.count, fetchedAt: data.fetchedAt,
                                sourceVersion: OperationSourceVersion(spec: spec, data: data))
                            if DomainRemovalConfirmation.isUnusual(previous: oldEntries, desired: wanted),
                               !confirmedRemovals.contains(where: {
                                   $0.spec == spec && $0.previousEntries == oldEntries && $0.desiredEntries == wanted
                               }) {
                                pendingConfirmations.append(DomainRemovalConfirmation(spec: spec,
                                    previousEntries: oldEntries, desiredEntries: wanted, fetchedAt: data.fetchedAt))
                                results[spec.key]?.status = .needsConfirmation
                                results[spec.key]?.message = "Источник резко сократился: удаляется \(oldEntries.subtracting(wanted).count) из \(oldEntries.count) записей. Его списки оставлены без изменений до подтверждения."
                            } else if !plan.isEmpty { planned[spec.key] = plan }

                        } catch {
                            results[spec.key] = DomainSourceUpdateResult(spec: spec, status: .skipped,
                                message: session.describe(error), fetchedAt: data.fetchedAt,
                                sourceVersion: OperationSourceVersion(spec: spec, data: data))
                        }
                    }

                    let plans = installed.compactMap { planned[$0.key] }
                    let merged = Planner.merge(title: "Обновление списков доменов", plans: plans).forRouter(profile)
                    guard !merged.isEmpty else { return }
                    try requireRelevant()
                    phase = "Применяю изменения и проверяю списки…"
                    writeStarted = true
                    let outcome = try await session.apply(plan: merged, dryRun: false, saveConfig: saveConfig,
                                                           preWriteCheck: {
                        try requireRelevant()
                        // Последняя точка отмены, непосредственно перед записью.
                        self.canCancel = false
                    })
                    backupURL = outcome.backupURL
                    historyID = outcome.historyID
                    // После начала записи переключение вкладки/выбора роутера
                    // не перенаправляет команды: executor удерживает владельца.
                    for spec in installed where planned[spec.key] != nil {
                        results[spec.key]?.status = outcome.problems.isEmpty ? (saveConfig ? .updated : .appliedTemporarily) : .needsAttention
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
                if report?.error == nil, !results.values.contains(where: { $0.status == .skipped || $0.status == .needsAttention || $0.status == .needsConfirmation }),
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
                historyID = applicationError?.historyID ?? historyID
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
        updateTask = task
        await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: { task.cancel() })
    }
}
