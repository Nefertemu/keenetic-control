import Foundation
import SwiftUI

enum ConnectionStatus: Equatable {
    case offline
    case connecting
    case online(TransportKind)
    case failed(String)

    var isOnline: Bool { if case .online = self { return true }; return false }
    var isBusy: Bool { self == .connecting }

    var title: String {
        switch self {
        case .offline:            return "Не подключено"
        case .connecting:         return "Подключаюсь…"
        case .online(let kind):   return "На связи · \(kind.shortTitle)"
        case .failed:             return "Ошибка связи"
        }
    }

    var tint: Color {
        switch self {
        case .offline:    return .secondary
        case .connecting: return .orange
        case .online:     return .green
        case .failed:     return .red
        }
    }
}

struct RouterState {
    var configText: String = ""
    var groups: [String: FqdnGroup] = [:]
    var interfaces: [String: KeeneticInterface] = [:]
    var candidates: [KeeneticInterface] = []
    var staticRoutes: [StaticRoute] = []
    var wireguardInterfaces: [String] = []
    var pingCheckProfiles: [PingCheckProfile] = []
    var pingCheckBindings: [String: PingCheckBinding] = [:]
    var readAt: Date = Date()

    var sortedGroups: [FqdnGroup] { RouterConfigParser.sortedGroups(groups) }

    /// Примечание интерфейса из конфигурации роутера — то же, что видно
    /// в веб-панели рядом с именем.
    func note(for ident: String) -> String? {
        let note = interfaces[ident]?.descriptionText ?? ""
        return note.isEmpty ? nil : note
    }

    /// «Wireguard0 · Dataforest» — имя вместе с примечанием.
    func label(for ident: String) -> String {
        guard let note = note(for: ident) else { return ident }
        return "\(ident) · \(note)"
    }
    var totalDomains: Int { groups.values.reduce(0) { $0 + $1.includes.count } }
    var routedGroups: Int { groups.values.filter { !$0.routeLines.isEmpty }.count }
}

struct ProgressInfo: Equatable {
    var label: String
    var done: Int
    var total: Int
    var started: Date = Date()

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    var eta: String? {
        let elapsed = Date().timeIntervalSince(started)
        guard done > 0, elapsed > 1, done < total else { return nil }
        let rate = Double(done) / elapsed
        guard rate > 0 else { return nil }
        return Format.duration(Double(total - done) / rate)
    }
}

struct ApplyOutcome {
    var applied: Bool
    var problems: [String] = []
    var backupURL: URL?
    var elapsed: TimeInterval = 0
}

/// Живое соединение с одним роутером. Переключение между роутерами их не
/// рвёт: у каждого своё состояние, своя очередь операций и своя попытка
/// подключения, так что долгое чтение одного не блокирует другой.
@MainActor
final class RouterSlot {
    var transport: KeeneticTransport?
    var state: RouterState?
    var status: ConnectionStatus = .offline
    var connectTask: Task<KeeneticTransport, Error>?
    /// По чему судим, что профиль поменялся и соединение пора выбросить.
    var connectionKey: String
    let queue: DispatchQueue

    init(profile: RouterProfile) {
        connectionKey = profile.connectionKey
        queue = DispatchQueue(
            label: "pro.netcraze.KeeneticControl.session.\(profile.id.uuidString)",
            qos: .userInitiated)
    }
}

@MainActor
final class RouterSession: ObservableObject {
    // Свойства описывают АКТИВНЫЙ роутер и зеркалятся в его слот,
    // чтобы состояние пережило переключение.
    @Published private(set) var status: ConnectionStatus = .offline {
        didSet { slots[router.id]?.status = status }
    }
    @Published private(set) var state: RouterState? {
        didSet { slots[router.id]?.state = state }
    }
    @Published private(set) var progress: ProgressInfo?
    @Published private(set) var activity: String?
    @Published var router: RouterProfile

    private var transport: KeeneticTransport? {
        didSet { slots[router.id]?.transport = transport }
    }
    private var slots: [UUID: RouterSlot] = [:]

    private var activeSlot: RouterSlot { slot(for: router) }
    private var queue: DispatchQueue { activeSlot.queue }

    init(router: RouterProfile) {
        self.router = router
        slots[router.id] = RouterSlot(profile: router)
    }

    private func slot(for profile: RouterProfile) -> RouterSlot {
        if let existing = slots[profile.id] { return existing }
        let created = RouterSlot(profile: profile)
        slots[profile.id] = created
        return created
    }

    /// Какие роутеры сейчас на связи — для отметок в списке выбора.
    func isConnected(_ id: UUID) -> Bool {
        slots[id]?.status.isOnline ?? false
    }

    /// Прочитанное состояние любого роутера из пула — для сравнения между собой.
    func readState(for id: UUID) -> RouterState? {
        id == router.id ? state : slots[id]?.state
    }

    /// Роутеры, конфигурацию которых уже прочитали.
    func routersWithState() -> Set<UUID> {
        var result = Set(slots.filter { $0.value.state != nil }.map(\.key))
        if state != nil { result.insert(router.id) }
        return result
    }

    // MARK: - Подключение

    /// Переключение НЕ разрывает связь: соединение остаётся в своём слоте,
    /// и возврат к роутеру происходит мгновенно, без повторного чтения.
    func switchTo(_ profile: RouterProfile) async {
        if profile.id == router.id {
            router = profile
            dropIfProfileChanged(profile)
            return
        }

        // Текущее состояние уже лежит в своём слоте благодаря didSet.
        router = profile
        let target = slot(for: profile)
        dropIfProfileChanged(profile)

        transport = target.transport
        state = target.state
        status = target.status
        progress = nil
        activity = nil
    }

    /// Сменили адрес, порт или транспорт — старое соединение уже не про этот роутер.
    private func dropIfProfileChanged(_ profile: RouterProfile) {
        let target = slot(for: profile)
        guard target.connectionKey != profile.connectionKey else { return }
        target.connectionKey = profile.connectionKey

        let stale = target.transport
        target.transport = nil
        target.state = nil
        target.status = .offline
        target.connectTask?.cancel()
        target.connectTask = nil

        if profile.id == router.id {
            transport = nil
            state = nil
            status = .offline
        }
        // abort() безопасен из любого потока и не блокирует: закрывает
        // дескриптор и добивает процесс, ждать его на очереди слота незачем.
        stale?.abort()
    }

    /// Закрыть все живые соединения — при выходе из приложения.
    func disconnectAll() {
        for slot in slots.values {
            slot.connectTask?.cancel()
            slot.transport?.abort()
            slot.transport = nil
            slot.status = .offline
        }
        transport = nil
        status = .offline
    }

    /// Результат операции мог прийти уже после переключения роутера —
    /// тогда он принадлежит слоту владельца, а не активным свойствам.
    private func store(transport newValue: KeeneticTransport?,
                       status newStatus: ConnectionStatus, owner: UUID) {
        if owner == router.id {
            transport = newValue
            status = newStatus
        } else if let slot = slots[owner] {
            slot.transport = newValue
            slot.status = newStatus
        }
    }

    private func store(state newValue: RouterState, owner: UUID) {
        if owner == router.id { state = newValue } else { slots[owner]?.state = newValue }
    }

    private func clearActivity(owner: UUID) {
        if owner == router.id { activity = nil }
    }

    func connect() async throws {
        if status.isOnline, transport != nil { return }

        let slot = activeSlot

        // Попытка уже идёт — дожидаемся её, а не поднимаем вторую сессию.
        if let running = slot.connectTask {
            _ = try await running.value
            return
        }

        status = .connecting
        let profile = router
        let owner = profile.id

        let task = Task { try await self.openTransport(profile: profile) }
        slot.connectTask = task
        defer { slot.connectTask = nil; clearActivity(owner: owner) }

        do {
            let opened = try await task.value
            store(transport: opened, status: .online(profile.transport), owner: owner)
        } catch {
            store(transport: nil, status: .failed(describe(error)), owner: owner)
            log(.error, "Подключение к \(profile.name): \(describe(error))")
            throw error
        }
    }

    /// Связь с роутером бывает капризной — одна осечка не повод сдаваться.
    private func openTransport(profile: RouterProfile) async throws -> KeeneticTransport {
        // Связка ключей может показать системный запрос доступа и держать
        // вызов сколько угодно — на главном потоке это заморозило бы окно.
        let password = await Task.detached { profile.resolvedPassword }.value
        let attempts = 3
        var lastError: Error = TransportError("Не удалось подключиться.")

        for attempt in 1...attempts {
            activity = attempt == 1
                ? "Подключаюсь к \(profile.endpoint)…"
                : "Попытка \(attempt) из \(attempts): \(profile.endpoint)…"

            let created: KeeneticTransport = profile.transport == .ssh
                ? SSHTransport(profile: profile, password: password)
                : try RCITransport(profile: profile, password: password)

            let started = Date()
            do {
                try await watch(created, budget: 70) { try created.connect() }
                let elapsed = Date().timeIntervalSince(started)
                log(.ok, "Подключение к \(profile.name) за \(String(format: "%.1f", elapsed)) с"
                    + (attempt > 1 ? " (попытка \(attempt))" : ""))
                return created
            } catch {
                created.abort()
                lastError = error
                let elapsed = Date().timeIntervalSince(started)
                log(.warn, "Попытка \(attempt)/\(attempts) не удалась за "
                    + "\(String(format: "%.1f", elapsed)) с: \(describe(error))")

                // Пароль не подошёл — повторять бессмысленно и вредно.
                if (error as? TransportError)?.isAuthFailure == true { throw error }
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }

        throw lastError
    }

    /// Сторож: если операция залипла дольше отведённого, рвём транспорт.
    /// Иначе последовательная очередь встанет намертво и интерфейс замрёт
    /// на «Подключаюсь…» без единой записи в журнале.
    private func watch<T>(_ transport: KeeneticTransport, budget: TimeInterval,
                          _ body: @escaping () throws -> T) async throws -> T {
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            transport.abort()
            log(.warn, "Операция превысила \(Int(budget)) с — соединение оборвано.")
        }
        defer { watchdog.cancel() }
        return try await background(body)
    }

    /// То же самое для текущего транспорта.
    private func guarded<T>(budget: TimeInterval,
                            _ body: @escaping (KeeneticTransport) throws -> T) async throws -> T {
        let owner = router.id
        let active = try await session()
        do {
            return try await watch(active, budget: budget) { try body(active) }
        } catch {
            // Транспорт мёртв — следующая операция поднимет новый.
            let slot = slots[owner]
            if transport === active || slot?.transport === active {
                store(transport: nil, status: .failed(describe(error)), owner: owner)
            }
            throw error
        }
    }

    func disconnect() async {
        guard let transport else {
            status = .offline
            return
        }
        self.transport = nil
        state = nil
        status = .offline
        await background { transport.close() }
    }

    /// Все операции идут через это: гарантируем живое соединение.
    private func session() async throws -> KeeneticTransport {
        if transport == nil || !status.isOnline { try await connect() }
        guard let transport else { throw TransportError("Нет соединения с роутером.") }
        return transport
    }

    // MARK: - Чтение состояния

    @discardableResult
    func refresh() async throws -> RouterState {
        let owner = router.id
        activity = "Читаю конфигурацию роутера…"
        defer { clearActivity(owner: owner) }

        let fresh: RouterState = try await guarded(budget: 200) { transport in
            let configText = try transport.fetchText("show running-config", timeout: 180)

            var statusInterfaces: [String: KeeneticInterface] = [:]
            if let rci = transport as? RCITransport {
                statusInterfaces = RouterConfigParser.parseInterfaceStatus(
                    json: try? rci.json(method: "GET", path: "rci/show/interface"))
            } else {
                let text = try transport.run("show interface", timeout: 120)
                statusInterfaces = RouterConfigParser.parseInterfaceStatus(text)
            }

            let interfaces = RouterConfigParser.merge(
                config: RouterConfigParser.parseConfigInterfaces(configText),
                status: statusInterfaces)

            let pingCheck = PingCheckParser.parse(config: configText)
            return RouterState(
                configText: configText,
                groups: RouterConfigParser.parseFqdnGroups(configText),
                interfaces: interfaces,
                candidates: RouterConfigParser.likelyRouteInterfaces(interfaces),
                staticRoutes: StaticRouteParser.parse(config: configText),
                wireguardInterfaces: WireGuardState.interfaceNames(config: configText),
                pingCheckProfiles: pingCheck.profiles,
                pingCheckBindings: pingCheck.bindings,
                readAt: Date())
        }

        store(state: fresh, owner: owner)
        log(.ok, "Прочитано: \(Format.lists(fresh.groups.count)), "
            + "\(Format.domains(fresh.totalDomains)), "
            + "\(Format.routes(fresh.staticRoutes.count)).")
        return fresh
    }

    // MARK: - Применение плана

    func apply(plan: Plan, dryRun: Bool, saveConfig: Bool) async throws -> ApplyOutcome {
        guard !plan.isEmpty else { return ApplyOutcome(applied: true) }

        if dryRun {
            log(.info, "Предпросмотр «\(plan.title)»: \(Format.commands(plan.commands.count)), на роутер ничего не ушло.")
            return ApplyOutcome(applied: false)
        }

        let transport = try await session()
        // Бэкап должен отражать то, что на роутере сейчас, а не час назад.
        let configText: String
        if let current = state, !current.configText.isEmpty,
           Date().timeIntervalSince(current.readAt) < 300 {
            configText = current.configText
        } else {
            activity = "Читаю конфигурацию перед изменением…"
            configText = try await watch(transport, budget: 200) {
                try transport.fetchText("show running-config", timeout: 180)
            }
            activity = nil
        }

        let backupURL = Backups.saveRunningConfig(
            host: router.host, text: configText, keep: Store.shared.settings.keepBackups)
        log(.info, "Резервная копия конфигурации: \(backupURL?.lastPathComponent ?? "не сохранена")")

        let started = Date()
        let batchSize = max(1, Store.shared.settings.batchSize)
        let limit = Store.shared.settings.maxDomainsPerList

        progress = ProgressInfo(label: plan.title, done: 0, total: plan.commands.count)
        defer { progress = nil }

        log(.info, "\(plan.title): отправляю \(Format.commands(plan.commands.count)).")

        do {
            try await execute(plan.commands, transport: transport, batchSize: batchSize)
        } catch {
            log(.error, "Выполнение остановлено: \(describe(error))")
            log(.warn, "Конфигурация НЕ сохранена. Часть команд могла примениться — проверь бэкап.")
            throw error
        }

        if saveConfig {
            activity = "Сохраняю конфигурацию роутера…"
            let output = try await watch(transport, budget: 200) {
                try transport.run("system configuration save", timeout: 180)
            }
            activity = nil
            if CLI.failed(output) {
                log(.error, "Не удалось сохранить конфигурацию: \(output)")
                throw TransportError("Роутер не сохранил конфигурацию.", hint: output)
            }
            log(.ok, "Конфигурация сохранена.")
        }

        activity = "Перечитываю конфигурацию для проверки…"
        let problems = try await verify(plan: plan, transport: transport, limit: limit)
        activity = nil

        let elapsed = Date().timeIntervalSince(started)
        if problems.isEmpty {
            log(.ok, "Готово за \(Format.duration(elapsed)): " + plan.summary.joined(separator: ", "))
        } else {
            for problem in problems { log(.warn, "Проверка: \(problem)") }
        }

        return ApplyOutcome(applied: true, problems: problems, backupURL: backupURL, elapsed: elapsed)
    }

    /// Пакетная отправка: `include`-команды летят пачками, остальные по одной.
    private func execute(_ commands: [String], transport: KeeneticTransport, batchSize: Int) async throws {
        let bulk = try! NSRegularExpression(pattern: "^(?:no\\s+)?object-group\\s+fqdn\\s+\\S+\\s+include\\s+")
        func isBulk(_ command: String) -> Bool {
            bulk.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
        }

        var index = 0
        var done = 0

        while index < commands.count {
            var chunk: [String] = []
            if isBulk(commands[index]) {
                while index + chunk.count < commands.count,
                      isBulk(commands[index + chunk.count]),
                      chunk.count < batchSize {
                    chunk.append(commands[index + chunk.count])
                }
            } else {
                chunk = [commands[index]]
            }

            let batch = chunk
            let output = try await watch(transport, budget: 150) { () -> String in
                batch.count == 1
                    ? try transport.run(batch[0], timeout: 120)
                    : try transport.runBatch(batch, timeout: 120)
            }

            if CLI.failed(output) {
                if batch.count > 1 {
                    log(.warn, "Ошибка внутри пачки — повторяю команды по одной…")
                    for command in batch {
                        let single = try await watch(transport, budget: 150) {
                            try transport.run(command, timeout: 120)
                        }
                        if CLI.failed(single) {
                            throw TransportError("Роутер отверг команду: \(command)", hint: single)
                        }
                    }
                } else {
                    throw TransportError("Роутер отверг команду: \(batch[0])", hint: output)
                }
            }

            done += batch.count
            index += batch.count
            progress?.done = done
        }
    }

    private func verify(plan: Plan, transport: KeeneticTransport, limit: Int) async throws -> [String] {
        let owner = router.id
        let configText = try await watch(transport, budget: 200) {
            try transport.fetchText("show running-config", timeout: 180)
        }
        let groups = RouterConfigParser.parseFqdnGroups(configText)
        var problems: [String] = []

        for (ident, domains) in plan.adds {
            let current = groups[ident]?.includes ?? []
            let missing = domains.subtracting(current)
            if !missing.isEmpty {
                let example = missing.sorted().prefix(3).joined(separator: ", ")
                problems.append("\(ident): не добавлено \(missing.count) (\(example)…)")
            }
        }
        for (ident, domains) in plan.removes {
            let remained = domains.intersection(groups[ident]?.includes ?? [])
            if !remained.isEmpty { problems.append("\(ident): не удалено \(remained.count)") }
        }
        for target in plan.routeTargets {
            guard let group = groups[target.group], group.isRouted(to: target.interface) else {
                problems.append("\(target.group): маршрут на \(target.interface) не появился")
                continue
            }
        }
        for target in plan.unrouteTargets {
            if let group = groups[target.group], group.isRouted(to: target.interface) {
                problems.append("\(target.group): маршрут на \(target.interface) остался")
            }
        }
        for ident in Set(plan.adds.keys).union(plan.removes.keys) {
            if let group = groups[ident], group.includes.count > limit {
                problems.append("\(ident): превышен лимит \(group.includes.count)/\(limit)")
            }
        }

        // Обновляем состояние из уже прочитанной конфигурации — лишний раз не ходим.
        let previous = owner == router.id ? state : slots[owner]?.state
        let pingCheck = PingCheckParser.parse(config: configText)
        store(state: RouterState(
            configText: configText,
            groups: groups,
            interfaces: previous?.interfaces ?? [:],
            candidates: previous?.candidates ?? [],
            staticRoutes: StaticRouteParser.parse(config: configText),
            wireguardInterfaces: WireGuardState.interfaceNames(config: configText),
            pingCheckProfiles: pingCheck.profiles,
            pingCheckBindings: pingCheck.bindings,
            readAt: Date()), owner: owner)

        return problems
    }

    // MARK: - Произвольные команды (маршруты, WireGuard)

    @discardableResult
    func runCommands(_ commands: [String], title: String, saveConfig: Bool = true) async throws -> String {
        guard !commands.isEmpty else { return "" }
        let transport = try await session()

        progress = ProgressInfo(label: title, done: 0, total: commands.count + (saveConfig ? 1 : 0))
        defer { progress = nil }

        var outputs: [String] = []
        for (index, command) in commands.enumerated() {
            log(.cmd, command)
            let output = try await watch(transport, budget: 150) {
                try transport.run(command, timeout: 120)
            }
            if CLI.failed(output) {
                throw TransportError("Роутер отверг команду: \(command)", hint: output)
            }
            if !output.isEmpty { outputs.append(output) }
            progress?.done = index + 1
        }

        if saveConfig {
            let output = try await watch(transport, budget: 200) {
                try transport.run("system configuration save", timeout: 180)
            }
            if CLI.failed(output) {
                throw TransportError("Роутер не сохранил конфигурацию.", hint: output)
            }
            progress?.done = commands.count + 1
            log(.ok, "Конфигурация сохранена.")
        }

        return outputs.joined(separator: "\n")
    }

    func readConfigText() async throws -> String {
        let transport = try await session()
        return try await watch(transport, budget: 200) {
            try transport.fetchText("show running-config", timeout: 180)
        }
    }

    func readStartupConfig() async throws -> String {
        let transport = try await session()
        return try await watch(transport, budget: 200) {
            try transport.fetchText("show startup-config", timeout: 180)
        }
    }

    // MARK: - Загрузка списков доменов

    func loadSource(_ spec: SourceSpec, forceRefresh: Bool) async throws -> SourceData {
        let ttl = Store.shared.settings.cacheTTLMinutes
        activity = "Загружаю «\(spec.title)»…"
        defer { activity = nil }
        return try await background { try SourceLoader.load(spec, ttlMinutes: ttl, forceRefresh: forceRefresh) }
    }

    // MARK: - Инструменты

    func setActivity(_ text: String?) { activity = text }

    func setProgress(_ info: ProgressInfo?) { progress = info }

    func bumpProgress(_ done: Int) { progress?.done = done }

    /// Блокирующая работа уходит с главного потока, интерфейс остаётся живым.
    func background<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func background<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    nonisolated func describe(_ error: Error) -> String {
        if let transportError = error as? TransportError {
            if let hint = transportError.hint, !hint.isEmpty {
                return transportError.message + "\n" + hint
            }
            return transportError.message
        }
        return error.localizedDescription
    }
}

enum Backups {
    @discardableResult
    static func saveRunningConfig(host: String, text: String, keep: Int) -> URL? {
        let safeHost = host.replacingOccurrences(
            of: "[^A-Za-z0-9_.-]+", with: "_", options: .regularExpression)
        let url = AppPaths.backups
            .appendingPathComponent("\(safeHost)_\(Format.stamp())_running-config.txt")

        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch {
            log(.warn, "Не удалось сохранить резервную копию: \(error.localizedDescription)")
            return nil
        }

        if keep > 0 { prune(prefix: safeHost, keep: keep) }
        return url
    }

    static func list() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.backups, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "txt" }.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
    }

    private static func prune(prefix: String, keep: Int) {
        let matching = list().filter { $0.lastPathComponent.hasPrefix(prefix + "_") }
        guard matching.count > keep else { return }
        for url in matching.dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }
}
