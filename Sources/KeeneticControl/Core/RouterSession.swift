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

    /// «Dataforest · Wireguard0» — сначала имя, которое дал человек.
    func label(for ident: String) -> String {
        guard let note = note(for: ident) else { return ident }
        return "\(note) · \(ident)"
    }

    /// Назначен ли интерфейсу профиль проверки связи.
    func hasPingCheck(_ ident: String) -> Bool {
        !(pingCheckBindings[ident]?.profile ?? "").isEmpty
    }

    /// Что роутер думает о проверке связи на этом интерфейсе сейчас.
    func pingCheck(for ident: String) -> PingCheckLiveState {
        interfaces[ident]?.pingCheck(configured: hasPingCheck(ident)) ?? .notConfigured
    }

    /// Как назвать интерфейс одним словом там, где места мало.
    func shortLabel(for ident: String) -> String { note(for: ident) ?? ident }

    /// Несколько интерфейсов одной строкой. Названные идут своими именами
    /// («Dataforest, Infomaniak»), безымянные из одного семейства
    /// сворачиваются в «Wireguard 0, 3» — иначе слово повторяется впустую.
    func targetSummary(_ idents: [String]) -> String {
        var named: [String] = []
        var families: [(family: String, numbers: [String])] = []

        for ident in idents {
            if let note = note(for: ident) { named.append(note); continue }
            let parts = InterfaceName.split(ident)
            guard let number = parts.number else { named.append(ident); continue }
            if let index = families.firstIndex(where: { $0.family == parts.family }) {
                if !families[index].numbers.contains(number) {
                    families[index].numbers.append(number)
                }
            } else {
                families.append((parts.family, [number]))
            }
        }

        let collapsed = families.map { item -> String in
            item.numbers.count == 1
                ? item.family + item.numbers[0]
                : item.family + " " + item.numbers.joined(separator: ", ")
        }
        return (named + collapsed).joined(separator: ", ")
    }

    /// Полная расшифровка для подсказки: по строке на интерфейс.
    func targetTooltip(_ idents: [String]) -> String {
        idents.map { label(for: $0) }.joined(separator: "\n")
    }
    var totalDomains: Int { groups.values.reduce(0) { $0 + $1.includes.count } }
    var routedGroups: Int { groups.values.filter { !$0.routeLines.isEmpty }.count }

    /// DNS-серверы из running-config. Они нужны только для диагностики:
    /// приложение не меняет их и не пытается угадывать настройки DNS.
    /// Адреса DNS-серверов роутера.
    ///
    /// В строке `ip name-server` за адресом идут ещё домен и привязка к
    /// интерфейсу — например `ip name-server 1.1.1.1 "" on Wireguard0`.
    /// Раньше в список попадали все слова подряд, и рядом с адресами
    /// оказывались `""`, `on` и имена интерфейсов, выданные за серверы.
    var nameServers: [String] {
        var result: [String] = []
        for raw in configText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("ip name-server ") else { continue }
            // Берём адреса с начала строки и останавливаемся на первом слове,
            // которое адресом не является.
            for value in line.dropFirst("ip name-server ".count)
                .split(whereSeparator: { $0.isWhitespace }) {
                let server = String(value)
                guard IPTools.isIP(server) else { break }
                if !result.contains(server) { result.append(server) }
            }
        }
        return result
    }
}

/// Последнее замеченное изменение конфигурации роутера.
///
/// Фоновое перечитывание умело сказать «конфигурация изменилась», но не
/// что именно. А правки приходят и из веб-панели роутера, так что вопрос
/// «что там поменялось, пока меня не было» — рабочий.
struct RouterChange {
    var at: Date
    var difference: Restore.Difference

    /// Пусто — поменялось что-то, чем приложение не управляет (Wi-Fi,
    /// NAT, межсетевой экран), и выдавать это за правку списков нельзя.
    var touchesManagedSettings: Bool { !difference.isEmpty }

    /// Сводка «что стало другим».
    ///
    /// `Restore.Difference` описывает разницу словами возврата к копии
    /// («вернуть», «убрать»), а здесь смысл обратный: слева прошлое
    /// состояние, справа текущее. Поэтому формулировки свои.
    var lines: [String] {
        var result: [String] = []
        if difference.extraDomainCount > 0 {
            result.append(Format.agree(difference.extraDomainCount, "добавлен", "добавлено")
                          + " \(Format.domains(difference.extraDomainCount))"
                          + namesSuffix(Array(difference.extraDomains.keys)))
        }
        if difference.missingDomainCount > 0 {
            result.append(Format.agree(difference.missingDomainCount, "убран", "убрано")
                          + " \(Format.domains(difference.missingDomainCount))"
                          + namesSuffix(Array(difference.missingDomains.keys)))
        }
        if !difference.extraGroups.isEmpty {
            result.append(Format.agree(difference.extraGroups.count, "появился", "появилось")
                          + " \(Format.lists(difference.extraGroups.count))"
                          + namesSuffix(difference.extraGroups.map(\.ident)))
        }
        if !difference.missingGroups.isEmpty {
            result.append(Format.agree(difference.missingGroups.count, "удалён", "удалено")
                          + " \(Format.lists(difference.missingGroups.count))"
                          + namesSuffix(difference.missingGroups.map(\.ident)))
        }
        if !difference.extraRouteLines.isEmpty {
            result.append("назначено маршрутов списков: \(difference.extraRouteLines.count)")
        }
        if !difference.missingRouteLines.isEmpty {
            result.append("снято маршрутов списков: \(difference.missingRouteLines.count)")
        }
        if !difference.extraRoutes.isEmpty {
            result.append(Format.agree(difference.extraRoutes.count, "добавлен", "добавлено")
                          + " \(Format.routes(difference.extraRoutes.count))")
        }
        if !difference.missingRoutes.isEmpty {
            result.append(Format.agree(difference.missingRoutes.count, "удалён", "удалено")
                          + " \(Format.routes(difference.missingRoutes.count))")
        }
        return result
    }

    /// «в itdog ru inside 2» или «в 3 списках» — чтобы не вываливать
    /// десяток идентификаторов в одну строку.
    private func namesSuffix(_ idents: [String]) -> String {
        let sorted = idents.sorted {
            RouterConfigParser.identOrder($0) < RouterConfigParser.identOrder($1)
        }
        guard !sorted.isEmpty else { return "" }
        if sorted.count == 1 { return " в \(sorted[0])" }
        if sorted.count == 2 { return " в \(sorted[0]) и \(sorted[1])" }
        return " в \(Format.lists(sorted.count))"
    }
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

struct ApplyOutcome: Identifiable {
    let id = UUID()
    var applied: Bool
    var problems: [String] = []
    var backupURL: URL?
    var elapsed: TimeInterval = 0
}

/// Снимок конкретного подключения, с которым началась длинная операция.
/// UUID сам по себе не достаточен: пользователь может отредактировать тот же
/// профиль и направить его на другой роутер, пока операция ждёт сеть.
struct RouterOperation: Equatable {
    let routerID: UUID
    let connectionKey: String
    let generation: Int
}

/// Живое соединение с одним роутером. Переключение между роутерами их не
/// рвёт: у каждого своё состояние, своя очередь операций и своя попытка
/// подключения, так что долгое чтение одного не блокирует другой.
@MainActor
final class RouterSlot {
    /// Последняя сохранённая версия профиля. Она нужна, чтобы продолжать
    /// подключение и чтение уже неактивного роутера после переключения UI.
    var profile: RouterProfile
    var transport: KeeneticTransport?
    var state: RouterState?
    /// Держится до следующего изменения, а не до следующего чтения:
    /// иначе после первой же тихой сверки сводка обнулялась бы.
    var lastChange: RouterChange?
    var status: ConnectionStatus = .offline
    /// Ход длинной операции принадлежит роутеру, а не окну: пока идёт
    /// заливка списков на один, второй должен оставаться рабочим.
    var progress: ProgressInfo?
    var activity: String?
    /// Роутер уже отверг эти учётные данные. Повторять нельзя: у веб-панели
    /// Keenetic есть защита от подбора (ip http lockout-policy), и лишние
    /// попытки отключают панель для этого компьютера на четверть часа.
    var authRejected: String?
    var connectTask: Task<KeeneticTransport, Error>?
    /// По чему судим, что профиль поменялся и соединение пора выбросить.
    var connectionKey: String
    /// Меняется при отмене или изменении профиля. Запоздавшая задача
    /// подключения не сможет положить старый транспорт обратно в слот.
    var connectionGeneration = 0
    let queue: DispatchQueue

    init(profile: RouterProfile) {
        self.profile = profile
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
    /// Зеркало lastChange активного роутера — чтобы экран обновлялся.
    @Published private(set) var lastChange: RouterChange? {
        didSet { slots[router.id]?.lastChange = lastChange }
    }
    @Published private(set) var state: RouterState? {
        didSet { slots[router.id]?.state = state }
    }
    @Published private(set) var progress: ProgressInfo? {
        didSet { slots[router.id]?.progress = progress }
    }
    @Published private(set) var activity: String? {
        didSet { slots[router.id]?.activity = activity }
    }
    @Published var router: RouterProfile

    private var transport: KeeneticTransport? {
        didSet { slots[router.id]?.transport = transport }
    }
    private var slots: [UUID: RouterSlot] = [:]

    /// Операция может завершаться уже после удаления её роутера из списка.
    /// В таком случае ей нельзя занимать очередь текущего, совсем другого
    /// роутера — у неё есть отдельная очередь для аккуратного завершения.
    private static let orphanedOperationQueue = DispatchQueue(
        label: "pro.netcraze.KeeneticControl.session.orphaned",
        qos: .utility)

    init(router: RouterProfile) {
        self.router = router
        slots[router.id] = RouterSlot(profile: router)
    }

    private func slot(for profile: RouterProfile) -> RouterSlot {
        if let existing = slots[profile.id] {
            existing.profile = profile
            return existing
        }
        let created = RouterSlot(profile: profile)
        slots[profile.id] = created
        return created
    }

    private func isCurrentConnection(_ profile: RouterProfile, generation: Int) -> Bool {
        guard let slot = slots[profile.id] else { return false }
        return slot.connectionGeneration == generation && slot.connectionKey == profile.connectionKey
    }

    /// Зафиксировать подключение активного роутера для составной операции.
    /// Все её следующие шаги должны использовать этот же адрес и поколение
    /// сессии — иначе после редактирования профиля старые команды могли бы
    /// уйти на новый адрес.
    func beginOperation() -> RouterOperation {
        let profile = router
        guard let slot = slots[profile.id] else {
            // Активный профиль уже удалили из Store, но UI ещё не успел
            // переключиться на следующий. Не создаём для удалённого роутера
            // новый слот, иначе случайное действие могло бы снова подключиться
            // к нему.
            return RouterOperation(routerID: profile.id, connectionKey: profile.connectionKey,
                                   generation: Int.min)
        }
        return RouterOperation(routerID: profile.id, connectionKey: slot.connectionKey,
                               generation: slot.connectionGeneration)
    }

    private func beginOperation(owner: UUID) throws -> RouterOperation {
        guard let slot = slots[owner] else {
            throw TransportError("Роутер был удалён во время операции.")
        }
        return RouterOperation(routerID: owner, connectionKey: slot.connectionKey,
                               generation: slot.connectionGeneration)
    }

    /// Можно ли ещё безопасно продолжать именно эту операцию.
    func isCurrent(_ operation: RouterOperation) -> Bool {
        guard let slot = slots[operation.routerID] else { return false }
        return slot.connectionGeneration == operation.generation
            && slot.connectionKey == operation.connectionKey
    }

    private func requireCurrent(_ operation: RouterOperation) throws {
        guard isCurrent(operation) else {
            throw TransportError(
                "Параметры подключения изменились во время операции.",
                hint: "Результат старой операции отброшен. Повтори действие для обновлённого профиля.")
        }
    }

    /// Какие роутеры сейчас на связи — для отметок в списке выбора.
    func isConnected(_ id: UUID) -> Bool {
        connectionStatus(for: id).isOnline
    }

    /// Состояние любого роутера, а не только выбранного в боковой панели.
    func connectionStatus(for id: UUID) -> ConnectionStatus {
        id == router.id ? status : (slots[id]?.status ?? .offline)
    }

    func activity(for id: UUID) -> String? {
        id == router.id ? activity : slots[id]?.activity
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
        progress = target.progress
        activity = target.activity
        lastChange = target.lastChange
    }

    /// Занят ли конкретный роутер длинной операцией — чтобы кнопки
    /// блокировались только у него.
    func isBusy(_ id: UUID) -> Bool {
        connectionStatus(for: id).isBusy
            || (id == router.id ? progress : slots[id]?.progress) != nil
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
        target.progress = nil
        target.activity = nil
        target.connectionGeneration &+= 1
        target.connectTask?.cancel()
        target.connectTask = nil

        if profile.id == router.id {
            transport = nil
            state = nil
            status = .offline
            progress = nil
            activity = nil
        }
        // abort() безопасен из любого потока и не блокирует: закрывает
        // дескриптор и добивает процесс, ждать его на очереди слота незачем.
        stale?.abort()
    }

    /// Профиль могли изменить в настройках, пока активен другой роутер.
    /// Обновление активного окна тогда не вызовет switchTo, поэтому отдельно
    /// инвалидируем слот неактивного роутера и его длинные операции.
    func profileDidChange(_ profile: RouterProfile) {
        guard slots[profile.id] != nil else { return }
        dropIfProfileChanged(profile)
    }

    /// Пароль поправили — снова можно пробовать.
    func clearAuthBlock(_ id: UUID) {
        guard slots[id]?.authRejected != nil else { return }
        slots[id]?.authRejected = nil
        if id == router.id, case .failed = status { status = .offline }
    }

    /// Учётные данные меняются отдельно от адреса профиля. Уже открытая
    /// сессия держит старый пароль, поэтому закрываем её сразу: следующая
    /// операция подключится именно с новым значением из связки ключей.
    func credentialsDidChange(_ id: UUID) {
        guard let slot = slots[id] else { return }
        slot.authRejected = nil
        slot.connectionGeneration &+= 1
        let stale = slot.transport
        slot.transport = nil
        slot.connectTask?.cancel()
        slot.connectTask = nil
        slot.status = .offline
        slot.activity = nil
        slot.progress = nil

        if id == router.id {
            transport = nil
            status = .offline
            activity = nil
            progress = nil
        }
        stale?.abort()
    }

    /// Почему подключение к роутеру заблокировано, если заблокировано.
    func authBlock(_ id: UUID) -> String? { slots[id]?.authRejected }

    /// Роутер удалили из списка — его соединение и состояние больше не нужны.
    func forget(_ id: UUID) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        slot.connectionGeneration &+= 1
        slot.connectTask?.cancel()
        slot.transport?.abort()
        slot.transport = nil
        slot.state = nil
        if id == router.id {
            transport = nil
            state = nil
            progress = nil
            activity = nil
            status = .offline
        }
    }

    /// Закрыть все живые соединения — при выходе из приложения.
    func disconnectAll() {
        for slot in slots.values {
            slot.connectionGeneration &+= 1
            slot.connectTask?.cancel()
            slot.connectTask = nil
            slot.transport?.abort()
            slot.transport = nil
            slot.state = nil
            slot.progress = nil
            slot.activity = nil
            slot.status = .offline
        }
        transport = nil
        state = nil
        progress = nil
        activity = nil
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
            objectWillChange.send()
            slot.transport = newValue
            slot.status = newStatus
        }
    }

    private func store(status newStatus: ConnectionStatus, owner: UUID) {
        if owner == router.id {
            status = newStatus
        } else if let slot = slots[owner] {
            objectWillChange.send()
            slot.status = newStatus
        }
    }

    private func store(state newValue: RouterState, owner: UUID) {
        let previous = readState(for: owner)?.configText
        if owner == router.id {
            state = newValue
        } else if let slot = slots[owner] {
            objectWillChange.send()
            slot.state = newValue
        }
        rememberChange(from: previous, to: newValue.configText, owner: owner)
    }

    /// Разница считается один раз в момент изменения: доменов тут тысячи,
    /// и пересчёт на каждую перерисовку экрана заметно тормозил бы.
    private func rememberChange(from previous: String?, to current: String, owner: UUID) {
        guard let previous, !previous.isEmpty, previous != current else { return }
        let change = RouterChange(at: Date(),
                                  difference: Restore.compare(backup: previous, current: current))
        if owner == router.id { lastChange = change } else { slots[owner]?.lastChange = change }
    }

    func forgetChange() {
        lastChange = nil
    }

    private func clearActivity(owner: UUID) { store(activity: nil, owner: owner) }

    private func store(activity newValue: String?, owner: UUID) {
        if owner == router.id {
            activity = newValue
        } else if let slot = slots[owner] {
            objectWillChange.send()
            slot.activity = newValue
        }
    }

    private func store(progress newValue: ProgressInfo?, owner: UUID) {
        if owner == router.id {
            progress = newValue
        } else if let slot = slots[owner] {
            objectWillChange.send()
            slot.progress = newValue
        }
    }

    private func bump(progress done: Int, owner: UUID) {
        if owner == router.id {
            progress?.done = done
        } else if let slot = slots[owner] {
            objectWillChange.send()
            slot.progress?.done = done
        }
    }

    func connect() async throws { try await connect(to: router) }

    /// Подключить конкретный роутер, не меняя выбранную вкладку. Раньше
    /// connect() читал только активные свойства и после переключения не мог
    /// продолжить составную операцию для прежнего роутера.
    func connect(to profile: RouterProfile) async throws {
        let slot = slot(for: profile)
        dropIfProfileChanged(profile)
        if slot.status.isOnline, slot.transport != nil { return }

        // Пароль уже отвергли. Каждая новая попытка — ещё одна отметка в
        // счётчике защиты роутера, а не шанс на успех.
        if let rejected = slot.authRejected {
            store(status: .failed(rejected), owner: profile.id)
            throw TransportError(rejected, isAuthFailure: true)
        }

        // Попытка уже идёт — дожидаемся её, а не поднимаем вторую сессию.
        if let running = slot.connectTask {
            _ = try await running.value
            return
        }

        store(status: .connecting, owner: profile.id)
        let owner = profile.id
        let generation = slot.connectionGeneration

        let task = Task { try await self.openTransport(profile: profile) }
        slot.connectTask = task
        defer {
            if isCurrentConnection(profile, generation: generation) {
                slot.connectTask = nil
                clearActivity(owner: owner)
            }
        }

        do {
            let opened = try await task.value
            guard !task.isCancelled, isCurrentConnection(profile, generation: generation) else {
                opened.abort()
                throw CancellationError()
            }
            store(transport: opened, status: .online(profile.transport), owner: owner)
        } catch {
            // Пока задача ждала пароль или сеть, профиль могли изменить,
            // удалить или отключить. Старый результат не должен портить
            // статус нового подключения.
            guard isCurrentConnection(profile, generation: generation) else { throw error }
            var message = describe(error)
            if (error as? TransportError)?.isAuthFailure == true {
                message += "\n\nДальнейшие попытки заблокированы: у веб-панели Keenetic "
                    + "есть защита от подбора пароля, и лишние заходы отключают её "
                    + "для этого компьютера примерно на 15 минут. Впиши верный пароль "
                    + "в «Роутеры и настройки» — запрет снимется сам."
                slots[owner]?.authRejected = message
            }
            store(transport: nil, status: .failed(message), owner: owner)
            log(.error, "Подключение к \(profile.name): \(message)")
            throw error
        }
    }

    /// Связь с роутером бывает капризной — одна осечка не повод сдаваться.
    private func openTransport(profile: RouterProfile) async throws -> KeeneticTransport {
        // Связка ключей может показать системный запрос доступа и держать
        // вызов сколько угодно — на главном потоке это заморозило бы окно.
        let password = await Task.detached { profile.resolvedPassword }.value
        try Task.checkCancellation()
        let attempts = 3
        var lastError: Error = TransportError("Не удалось подключиться.")

        for attempt in 1...attempts {
            try Task.checkCancellation()
            store(activity: attempt == 1
                    ? "Подключаюсь к \(profile.endpoint)…"
                    : "Попытка \(attempt) из \(attempts): \(profile.endpoint)…",
                  owner: profile.id)

            let created: KeeneticTransport = profile.transport == .ssh
                ? SSHTransport(profile: profile, password: password)
                : try RCITransport(profile: profile, password: password)

            let started = Date()
            do {
                try await watch(created, budget: 70, owner: profile.id) { try created.connect() }
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
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }

        throw lastError
    }

    /// Сторож: если операция залипла дольше отведённого, рвём транспорт.
    /// Иначе последовательная очередь встанет намертво и интерфейс замрёт
    /// на «Подключаюсь…» без единой записи в журнале.
    private func watch<T>(_ transport: KeeneticTransport, budget: TimeInterval, owner: UUID,
                          _ body: @escaping () throws -> T) async throws -> T {
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            transport.abort()
            log(.warn, "Операция превысила \(Int(budget)) с — соединение оборвано.")
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler(operation: {
            try await background(owner: owner, body)
        }, onCancel: {
            // `background` ждёт блокирующий SSH/HTTP-вызов. Отмена Swift-задачи
            // сама его не прерывает, а abort() разбудит ожидание немедленно.
            transport.abort()
        })
    }

    /// То же самое для транспорта конкретной операции.
    private func guarded<T>(operation: RouterOperation, budget: TimeInterval,
                            preserveConnectionOnFailure: Bool = false,
                            _ body: @escaping (KeeneticTransport) throws -> T) async throws -> T {
        try requireCurrent(operation)
        var active = try await session(operation: operation)
        do {
            // Диагностические RCI ping/traceroute имеют собственный deadline.
            // Их нельзя завершать abort() основного HTTP-транспорта: один
            // медленный туннель тогда закрывал сессию всему приложению.
            let result: T
            if preserveConnectionOnFailure {
                result = try await background(owner: operation.routerID) { try body(active) }
            } else {
                result = try await watch(active, budget: budget, owner: operation.routerID) {
                    try body(active)
                }
            }
            try requireCurrent(operation)
            return result
        } catch {
            if !Task.isCancelled,
               (error as? TransportError)?.isSessionFailure == true {
                // Роутер закрыл давно простаивавшую сессию между isAlive и
                // запросом. Для этих трёх вызовов body только читает данные
                // или выполняет диагностический ping, поэтому один повтор
                // безопасен и не дублирует пользовательские изменения.
                active.abort()
                store(transport: nil,
                      status: .failed("Сессия прервалась · переподключаюсь…"),
                      owner: operation.routerID)
                active = try await session(operation: operation)
                do {
                    let result: T
                    if preserveConnectionOnFailure {
                        result = try await background(owner: operation.routerID) { try body(active) }
                    } else {
                        result = try await watch(active, budget: budget,
                                                 owner: operation.routerID) { try body(active) }
                    }
                    try requireCurrent(operation)
                    return result
                } catch {
                    active.abort()
                    store(transport: nil, status: .failed(describe(error)),
                          owner: operation.routerID)
                    throw error
                }
            }
            // Для длинных операций транспорт мёртв — следующая операция
            // поднимет новый. Короткая живая проверка интерфейса не должна
            // ронять весь подключённый роутер из-за одного временного сбоя:
            // она покажет ошибку только в своей карточке и попробует снова.
            if !preserveConnectionOnFailure {
                let slot = slots[operation.routerID]
                if transport === active || slot?.transport === active {
                    store(transport: nil, status: .failed(describe(error)), owner: operation.routerID)
                }
            } else {
                // Живой монитор не должен молча оставлять старый статус. В
                // журнале сохраняем только безопасное описание ошибки — без
                // команд, адресов и содержимого конфигурации.
                log(.warn, "Живой Ping-Check не выполнен: \(describe(error))")
            }
            throw error
        }
    }

    /// Фоновая проверка обнаруживает закрытую роутером сессию до того, как
    /// пользователь нажмёт «Сохранить». Проверка ничего не меняет и идёт в
    /// той же последовательной очереди, что остальные команды.
    func monitorConnections() async {
        while !Task.isCancelled {
            let connected = slots.compactMap { owner, slot -> (UUID, KeeneticTransport)? in
                guard slot.status.isOnline, slot.progress == nil, let transport = slot.transport
                else { return nil }
                return (owner, transport)
            }
            for (owner, candidate) in connected {
                guard !Task.isCancelled, slots[owner]?.transport === candidate else { continue }
                do {
                    _ = try await background(owner: owner) {
                        try candidate.run("show version", timeout: 12)
                    }
                    guard candidate.isAlive else {
                        throw TransportError("Сессия закрыта роутером.", isSessionFailure: true)
                    }
                } catch {
                    guard slots[owner]?.transport === candidate else { continue }
                    candidate.abort()
                    store(transport: nil,
                          status: .failed("Сессия прервалась: \(describe(error))"),
                          owner: owner)
                    log(.warn, "Сторож соединения обнаружил обрыв: \(describe(error))")
                }
            }
            do { try await Task.sleep(nanoseconds: 6_000_000_000) }
            catch { return }
        }
    }

    func disconnect() async { await disconnect(router.id) }

    /// Отключить роутер из его строки, не переключая текущий экран.
    func disconnect(_ owner: UUID) async {
        guard let slot = slots[owner] else { return }
        slot.connectionGeneration &+= 1
        slot.connectTask?.cancel()
        slot.connectTask = nil
        let closing = slot.transport

        if owner == router.id {
            transport = nil
            state = nil
            status = .offline
            progress = nil
            activity = nil
        } else {
            objectWillChange.send()
            slot.transport = nil
            slot.state = nil
            slot.status = .offline
            slot.progress = nil
            slot.activity = nil
        }
        guard let closing else { return }
        await background(owner: owner) { closing.close() }
    }

    /// Все операции идут через это: гарантируем живое соединение ровно с тем
    /// профилем, с которым началась операция.
    private func session(operation: RouterOperation) async throws -> KeeneticTransport {
        try requireCurrent(operation)
        let owner = operation.routerID
        if let slot = slots[owner], slot.status.isOnline, let transport = slot.transport {
            if transport.isAlive { return transport }

            // После тайм-аута ссылка на SSH/HTTP-транспорт могла остаться в
            // слоте, хотя сам дескриптор уже закрыт. Сбрасываем её перед
            // повторным подключением — иначе каждая следующая проверка сразу
            // падает с «сессия не подключена».
            store(transport: nil, status: .offline, owner: owner)
            transport.abort()
        }
        guard let slot = slots[owner] else {
            throw TransportError("Роутер был удалён во время операции.")
        }
        try await connect(to: slot.profile)
        try requireCurrent(operation)
        guard let slot = slots[owner], slot.status.isOnline, let transport = slot.transport else {
            throw TransportError("Нет соединения с роутером.")
        }
        return transport
    }

    // MARK: - Чтение состояния

    @discardableResult
    func refresh() async throws -> RouterState {
        try await refresh(operation: beginOperation())
    }

    /// Фоновое перечитывание. `quiet` убирает подпись «Читаю конфигурацию…»
    /// и строку в журнале: раз в минуту они бы только мельтешили и засоряли
    /// журнал, а по-настоящему интересно лишь то, что конфигурация изменилась.
    @discardableResult
    func refresh(quiet: Bool) async throws -> RouterState {
        try await refresh(operation: beginOperation(), quiet: quiet)
    }

    /// Итог массового подключения.
    struct BulkConnectOutcome {
        var connected: [String] = []
        var alreadyOnline: [String] = []
        var failed: [(name: String, reason: String)] = []

        var isEmpty: Bool {
            connected.isEmpty && alreadyOnline.isEmpty && failed.isEmpty
        }
    }

    /// Подключиться и прочитать сразу все роутеры.
    ///
    /// У каждого своя очередь операций, поэтому чтения идут параллельно, а
    /// не одно за другим. Уже подключённые не трогаем, а тем, чей пароль
    /// роутер уже отверг, `connect(to:)` откажет сам — массовая кнопка не
    /// должна превращаться в перебор паролей по всем роутерам сразу.
    func connectAll(_ profiles: [RouterProfile]) async -> BulkConnectOutcome {
        var outcome = BulkConnectOutcome()
        var pending: [RouterProfile] = []

        for profile in profiles {
            let slot = slots[profile.id]
            if slot?.status.isOnline == true, slot?.state != nil {
                outcome.alreadyOnline.append(profile.name)
            } else {
                pending.append(profile)
            }
        }

        await withTaskGroup(of: (String, String?).self) { group in
            for profile in pending {
                group.addTask { @MainActor in
                    do {
                        _ = try await self.connectAndRefresh(profile)
                        return (profile.name, nil)
                    } catch {
                        return (profile.name, self.describe(error))
                    }
                }
            }
            for await (name, failure) in group {
                if let failure {
                    outcome.failed.append((name, failure))
                } else {
                    outcome.connected.append(name)
                }
            }
        }

        outcome.connected.sort()
        outcome.failed.sort { $0.name < $1.name }
        return outcome
    }

    /// Подключить и сразу прочитать конкретный роутер. Выбор в боковой
    /// панели на результат не влияет: состояние сохранится в его слоте.
    @discardableResult
    func connectAndRefresh(_ profile: RouterProfile) async throws -> RouterState {
        let target = slot(for: profile)
        dropIfProfileChanged(profile)
        let operation = RouterOperation(
            routerID: profile.id,
            connectionKey: target.connectionKey,
            generation: target.connectionGeneration)
        try await connect(to: profile)
        return try await refresh(operation: operation)
    }

    /// Перечитать состояние конкретного роутера. Длинные составные операции
    /// (например, безопасное обновление WireGuard) передают сюда владельца,
    /// чтобы переключение боковой панели не подменило цель следующего шага.
    @discardableResult
    func refresh(owner: UUID) async throws -> RouterState {
        try await refresh(operation: try beginOperation(owner: owner))
    }

    /// Вариант для составных операций: проверяет, что профиль не был
    /// отредактирован между несколькими чтениями и командами.
    @discardableResult
    func refresh(operation: RouterOperation, quiet: Bool = false) async throws -> RouterState {
        let owner = operation.routerID
        try requireCurrent(operation)
        if !quiet {
            store(activity: "Читаю конфигурацию роутера…", owner: owner)
        }
        defer { if !quiet { clearActivity(owner: owner) } }
        let readProfile = slots[owner]?.profile ?? router

        let fresh: RouterState = try await guarded(operation: operation, budget: 200) { transport in
            let configText = try transport.fetchText("show running-config", timeout: 180,
                                                     quiet: quiet)

            var statusInterfaces: [String: KeeneticInterface] = [:]
            if let rci = transport as? RCITransport {
                statusInterfaces = RouterConfigParser.parseInterfaceStatus(
                    json: RCITransport.interfaceStatusJSON(rci, logResult: !quiet))
            } else {
                let text = try transport.run("show interface", timeout: 120)
                statusInterfaces = RouterConfigParser.parseInterfaceStatus(text)
            }

            var interfaces = RouterConfigParser.merge(
                config: RouterConfigParser.parseConfigInterfaces(configText),
                status: statusInterfaces)

            // Ping-Check — отдельный operational endpoint/CLI-команда. Не
            // смешиваем её отсутствие с ошибкой чтения всего роутера: старые
            // прошивки могут не иметь компонента, но интерфейсы всё равно
            // должны отобразиться.
            let pingInfo: [String: PingCheckLiveInfo]
            if let rci = transport as? RCITransport {
                pingInfo = PingCheckStatusParser.parseJSON(
                    RCITransport.pingCheckStatusJSON(rci))
            } else {
                // `show ping-check` на части Keenetic завершает текущий pty
                // после ответа. Читаем его в коротком отдельном probe, чтобы
                // обычное SSH-соединение осталось пригодным для UI и
                // следующей операции.
                pingInfo = (try? SSHTransport.fetchPingCheck(profile: readProfile)) ?? [:]
            }
            if !quiet {
                log(.info, "Ping-Check при чтении: интерфейсов " + String(pingInfo.count))
            }
            RouterConfigParser.applyPingCheck(pingInfo, to: &interfaces)

            let pingCheck = PingCheckParser.parse(config: configText)
            let wireGuardClients = WireGuardState.interfaceNames(config: configText)
            return RouterState(
                configText: configText,
                groups: RouterConfigParser.parseFqdnGroups(configText),
                interfaces: interfaces,
                candidates: RouterConfigParser.likelyRouteInterfaces(
                    interfaces, wireGuardClients: Set(wireGuardClients)),
                staticRoutes: StaticRouteParser.parse(config: configText),
                wireguardInterfaces: wireGuardClients,
                pingCheckProfiles: pingCheck.profiles,
                pingCheckBindings: pingCheck.bindings,
                readAt: Date())
        }

        try requireCurrent(operation)
        let previous = readState(for: owner)?.configText
        store(state: fresh, owner: owner)
        if quiet {
            // В тихом режиме говорим только о том, ради чего он и нужен:
            // конфигурация на роутере стала другой.
            if let previous, previous != fresh.configText {
                log(.ok, "Конфигурация «\(slots[owner]?.profile.name ?? "роутера")» "
                    + "изменилась — перечитал сам.")
            }
        } else {
            log(.ok, "Прочитано: \(Format.lists(fresh.groups.count)), "
                + "\(Format.domains(fresh.totalDomains)), "
                + "\(Format.routes(fresh.staticRoutes.count)).")
        }
        return fresh
    }

    /// Обновить только живые данные одного интерфейса. Полный running-config
    /// здесь не нужен: RCI читает только operational-статус, а SSH — отдельный
    /// короткий блок `show ping-check`. Экран обновляется каждые несколько
    /// секунд без сброса черновиков и без ручного «Обновить».
    @discardableResult
    func refreshLiveInterface(_ ident: String) async throws -> KeeneticInterface? {
        let trimmed = ident.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/-]*$",
                           options: .regularExpression) != nil else {
            throw TransportError("Некорректное имя интерфейса для проверки.")
        }

        let operation = beginOperation()
        let owner = operation.routerID
        guard let snapshot = readState(for: owner) else {
            throw TransportError("Сначала прочитай конфигурацию роутера.")
        }
        // Для SSH берём ровно тот профиль, с которым началась операция. На
        // прошивках, закрывающих pty после `show ping-check`, ниже поднимется
        // отдельный одноразовый probe, не затрагивая основную сессию.
        let liveProfile = slots[owner]?.profile ?? router

        let fetched: (interfaces: [String: KeeneticInterface],
                      ping: [String: PingCheckLiveInfo]) = try await guarded(
            // На SSH не трогаем основной pty: часть прошивок закрывает его
            // после `show ping-check`, из-за чего следующий цикл раньше
            // уходил в бесконечные переподключения. Статистика интерфейса
            // остаётся из полного чтения, а статус и счётчики Ping-Check
            // обновляются из отдельного одноразового probe.
            operation: operation, budget: 45, preserveConnectionOnFailure: true) { transport in
            let statuses: [String: KeeneticInterface]
            if let rci = transport as? RCITransport {
                statuses = RouterConfigParser.parseInterfaceStatus(
                    json: RCITransport.interfaceStatusJSON(rci, logResult: false))
            } else {
                // SSH-вывод интерфейса уже прочитан при подключении. В
                // стороже нужен только operational-ответ Ping-Check.
                statuses = [:]
            }

            let pingInfo: [String: PingCheckLiveInfo]
            if let rci = transport as? RCITransport {
                pingInfo = PingCheckStatusParser.parseJSON(
                    RCITransport.pingCheckStatusJSON(rci))
            } else {
                // Новое соединение на каждый probe — намеренно: основной
                // интерактивный SSH остаётся доступен для действий и не
                // получает команду, после которой некоторые Keenetic
                // закрывают pty. Ошибка пробрасывается наружу и видна в
                // карточке, вместо ложного «роутер не сообщил».
                _ = transport
                pingInfo = try SSHTransport.fetchPingCheck(profile: liveProfile)
            }
            return (statuses, pingInfo)
        }

        // SSH-вариант содержит только записи Ping-Check; чужой интерфейс не
        // должен считаться успешным ответом для выбранного.
        if fetched.interfaces.isEmpty, fetched.ping[trimmed] == nil {
            return nil
        }

        var statuses = fetched.interfaces
        // SSH прислал только Ping-Check, поэтому подставляем последний
        // полный снимок интерфейса как основу и накладываем свежий статус.
        // Если operational-ответ пустой, `statuses` останется пустым и ниже
        // вернётся nil — старые данные не выдаются за новую проверку.
        if !fetched.ping.isEmpty, statuses[trimmed] == nil,
           let cached = snapshot.interfaces[trimmed] {
            statuses[trimmed] = cached
        }
        var pingInterfaces: [String: KeeneticInterface] = [:]
        RouterConfigParser.applyPingCheck(fetched.ping, to: &pingInterfaces)
        for (ident, item) in pingInterfaces {
            var existing = statuses[ident] ?? KeeneticInterface(ident: ident)
            if item.pingCheckStatus != nil { existing.pingCheckStatus = item.pingCheckStatus }
            if item.pingCheckProfile != nil { existing.pingCheckProfile = item.pingCheckProfile }
            if item.pingCheckFailureCount != nil {
                existing.pingCheckFailureCount = item.pingCheckFailureCount
            }
            if item.pingCheckSuccessCount != nil {
                existing.pingCheckSuccessCount = item.pingCheckSuccessCount
            }
            if !item.pingCheckResolvedAddresses.isEmpty {
                existing.pingCheckResolvedAddresses = item.pingCheckResolvedAddresses
            }
            statuses[ident] = existing
        }
        try requireCurrent(operation)

        guard let incoming = statuses[trimmed]
                ?? statuses.values.first(where: { $0.ident == trimmed }) else {
            return nil
        }

        var updated = snapshot
        var merged = updated.interfaces[trimmed] ?? KeeneticInterface(ident: trimmed)
        if !incoming.descriptionText.isEmpty { merged.descriptionText = incoming.descriptionText }
        if !incoming.type.isEmpty { merged.type = incoming.type }
        if !incoming.link.isEmpty { merged.link = incoming.link }
        if !incoming.connected.isEmpty { merged.connected = incoming.connected }
        if !incoming.state.isEmpty { merged.state = incoming.state }
        if !incoming.isGlobal.isEmpty { merged.isGlobal = incoming.isGlobal }
        if !incoming.defaultGW.isEmpty { merged.defaultGW = incoming.defaultGW }
        if !incoming.securityLevel.isEmpty { merged.securityLevel = incoming.securityLevel }
        if incoming.pingCheckStatus != nil { merged.pingCheckStatus = incoming.pingCheckStatus }
        if incoming.pingCheckProfile != nil { merged.pingCheckProfile = incoming.pingCheckProfile }
        if incoming.pingCheckFailureCount != nil {
            merged.pingCheckFailureCount = incoming.pingCheckFailureCount
        }
        if incoming.pingCheckSuccessCount != nil {
            merged.pingCheckSuccessCount = incoming.pingCheckSuccessCount
        }
        if !incoming.pingCheckResolvedAddresses.isEmpty {
            merged.pingCheckResolvedAddresses = incoming.pingCheckResolvedAddresses
        }
        // Пустой массив здесь значим: у интерфейса могли исчезнуть все пиры.
        merged.peers = incoming.peers
        merged.aliases.formUnion(incoming.aliases)
        updated.interfaces[trimmed] = merged
        store(state: updated, owner: owner)
        return merged
    }

    /// Измерить RTT до указанного ресурса через конкретный WireGuard-интерфейс.
    /// ICMP привязывается к имени интерфейса, TCP/UDP — к его IPv4-адресу
    /// (иначе KeeneticOS 5.01 не может определить MTU для traceroute socket).
    func ping(interface: String, target: String, count: Int = 3,
              method: InterfaceProbeMethod = .icmp,
              port: Int? = nil) async throws -> InterfacePingResult {
        let values = try InterfacePingProbe.validate(interface: interface, target: target)
        let operation = beginOperation()
        let owner = operation.routerID
        guard let snapshot = readState(for: owner),
              snapshot.wireguardInterfaces.contains(values.0) else {
            throw TransportError("Интерфейс \(values.0) не найден в текущей конфигурации.")
        }
        let sourceAddress = WireGuardState.parse(config: snapshot.configText, interface: values.0)
            .addresses
            .lazy
            .compactMap { $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) }
            .first { IPTools.parseIPv4($0) != nil }
        let profile = slots[owner]?.profile ?? router

        if profile.transport == .ssh {
            let result = try await background(owner: owner) {
                try SSHTransport.ping(profile: profile, interface: values.0,
                                      target: values.1, count: count,
                                      method: method, port: port,
                                      sourceAddress: sourceAddress)
            }
            try requireCurrent(operation)
            return result
        }

        let budget = method == .icmp ? TimeInterval(count + 25) : 35
        return try await guarded(operation: operation, budget: budget,
                                 preserveConnectionOnFailure: true) { transport in
            guard let rci = transport as? RCITransport else {
                throw TransportError("Активный RCI-транспорт недоступен.")
            }
            return try rci.ping(interface: values.0, target: values.1, count: count,
                                method: method, port: port,
                                sourceAddress: sourceAddress)
        }
    }

    // MARK: - Применение плана

    func apply(plan: Plan, dryRun: Bool, saveConfig: Bool) async throws -> ApplyOutcome {
        guard !plan.isEmpty else { return ApplyOutcome(applied: true) }
        let profile = router
        let operation = beginOperation()
        let owner = operation.routerID

        if let plannedFor = plan.routerID, plannedFor != owner {
            throw TransportError(
                "План составлен для другого роутера.",
                hint: "Вернись к роутеру, для которого был открыт план, и составь его заново.")
        }
        if let plannedConnection = plan.routerConnectionKey,
           plannedConnection != profile.connectionKey {
            throw TransportError(
                "Параметры роутера изменились после составления плана.",
                hint: "Составь план заново: старые команды не будут отправлены на новый адрес.")
        }
        if dryRun {
            log(.info, "Предпросмотр «\(plan.title)»: \(Format.commands(plan.commands.count)), на роутер ничего не ушло.")
            return ApplyOutcome(applied: false)
        }
        defer { clearActivity(owner: owner) }

        let transport = try await session(operation: operation)
        // Бэкап должен отражать то, что на роутере сейчас, а не час назад.
        let configText: String
        if let current = slots[owner]?.state, !current.configText.isEmpty,
           Date().timeIntervalSince(current.readAt) < 300 {
            configText = current.configText
        } else {
            store(activity: "Читаю конфигурацию перед изменением…", owner: owner)
            configText = try await watch(transport, budget: 200, owner: owner) {
                try transport.fetchText("show running-config", timeout: 180)
            }
        }
        try requireCurrent(operation)

        guard let backupURL = Backups.saveRunningConfig(
            host: profile.host, text: configText, keep: Store.shared.settings.keepBackups) else {
            throw TransportError(
                "Изменения отменены: не удалось создать защищённую резервную копию.",
                hint: "Проверь доступ приложения к связке ключей и свободное место на диске.")
        }
        log(.info, "Защищённая резервная копия: \(backupURL.lastPathComponent)")

        let started = Date()
        let batchSize = max(1, Store.shared.settings.batchSize)
        let limit = Store.shared.settings.maxDomainsPerList

        store(progress: ProgressInfo(label: plan.title, done: 0, total: plan.commands.count),
              owner: owner)
        defer { store(progress: nil, owner: owner) }

        log(.info, "\(plan.title): отправляю \(Format.commands(plan.commands.count)).")

        do {
            try await execute(plan.commands, transport: transport, batchSize: batchSize,
                              operation: operation)
        } catch {
            log(.error, "Выполнение остановлено: \(describe(error))")
            log(.warn, "Конфигурация НЕ сохранена. Часть команд могла примениться — проверь бэкап.")
            throw error
        }

        if saveConfig {
            store(activity: "Сохраняю конфигурацию роутера…", owner: owner)
            let output = try await watch(transport, budget: 200, owner: owner) {
                try transport.run("system configuration save", timeout: 180)
            }
            try requireCurrent(operation)
            if CLI.failed(output) {
                log(.error, "Не удалось сохранить конфигурацию: \(output)")
                throw TransportError("Роутер не сохранил конфигурацию.", hint: output)
            }
            log(.ok, "Конфигурация сохранена.")
        }

        store(activity: "Перечитываю конфигурацию для проверки…", owner: owner)
        let problems = try await verify(plan: plan, transport: transport, limit: limit,
                                        operation: operation)

        let elapsed = Date().timeIntervalSince(started)
        if problems.isEmpty {
            log(.ok, "Готово за \(Format.duration(elapsed)): " + plan.summary.joined(separator: ", "))
        } else {
            for problem in problems { log(.warn, "Проверка: \(problem)") }
        }

        return ApplyOutcome(applied: true, problems: problems, backupURL: backupURL, elapsed: elapsed)
    }

    /// Пакетная отправка: `include`-команды летят пачками, остальные по одной.
    private func execute(_ commands: [String], transport: KeeneticTransport,
                         batchSize: Int, operation: RouterOperation) async throws {
        let owner = operation.routerID
        let bulk = try! NSRegularExpression(pattern: "^(?:no\\s+)?object-group\\s+fqdn\\s+\\S+\\s+include\\s+")
        func isBulk(_ command: String) -> Bool {
            bulk.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
        }

        var index = 0
        var done = 0

        while index < commands.count {
            try requireCurrent(operation)
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
            let output = try await watch(transport, budget: 150, owner: owner) { () -> String in
                batch.count == 1
                    ? try transport.run(batch[0], timeout: 120)
                    : try transport.runBatch(batch, timeout: 120)
            }
            try requireCurrent(operation)

            if CLI.failed(output) {
                if batch.count > 1 {
                    log(.warn, "Ошибка внутри пачки — повторяю команды по одной…")
                    for command in batch {
                        try requireCurrent(operation)
                        let single = try await watch(transport, budget: 150, owner: owner) {
                            try transport.run(command, timeout: 120)
                        }
                        try requireCurrent(operation)
                        if CLI.failed(single) {
                            throw TransportError("Роутер отверг команду: \(CLI.redactSecrets(command))",
                                                 hint: CLI.redactSecrets(single))
                        }
                    }
                } else {
                    throw TransportError("Роутер отверг команду: \(CLI.redactSecrets(batch[0]))",
                                         hint: CLI.redactSecrets(output))
                }
            }

            done += batch.count
            index += batch.count
            bump(progress: done, owner: owner)
        }
    }

    private func verify(plan: Plan, transport: KeeneticTransport, limit: Int,
                        operation: RouterOperation) async throws -> [String] {
        let owner = operation.routerID
        try requireCurrent(operation)
        let configText = try await watch(transport, budget: 200, owner: owner) {
            try transport.fetchText("show running-config", timeout: 180)
        }
        try requireCurrent(operation)
        let groups = RouterConfigParser.parseFqdnGroups(configText)
        let problems = PlanVerifier.problems(plan: plan, groups: groups, limit: limit)

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
        try await runCommands(commands, title: title, saveConfig: saveConfig,
                              operation: beginOperation())
    }

    /// Выполнить команды на уже выбранном владельце операции. Если владелец
    /// больше не активен, но его соединение ещё живо, работа продолжается
    /// именно на нём; к новому роутеру команды не переедут.
    @discardableResult
    func runCommands(_ commands: [String], title: String, saveConfig: Bool,
                     owner: UUID) async throws -> String {
        try await runCommands(commands, title: title, saveConfig: saveConfig,
                              operation: try beginOperation(owner: owner))
    }

    /// Выполнить команды, не меняя цель при редактировании активного профиля.
    @discardableResult
    func runCommands(_ commands: [String], title: String, saveConfig: Bool,
                     operation: RouterOperation) async throws -> String {
        guard !commands.isEmpty else { return "" }
        try requireCurrent(operation)
        let owner = operation.routerID
        let transport = try await session(operation: operation)

        store(progress: ProgressInfo(label: title, done: 0,
                                     total: commands.count + (saveConfig ? 1 : 0)), owner: owner)
        defer { store(progress: nil, owner: owner) }

        var outputs: [String] = []
        for (index, command) in commands.enumerated() {
            try requireCurrent(operation)
            log(.cmd, CLI.redactSecrets(command))
            let output = try await watch(transport, budget: 150, owner: owner) {
                try transport.run(command, timeout: 120)
            }
            try requireCurrent(operation)
            if CLI.failed(output) {
                throw TransportError("Роутер отверг команду: \(CLI.redactSecrets(command))",
                                     hint: CLI.redactSecrets(output))
            }
            if !output.isEmpty { outputs.append(CLI.redactSecrets(output)) }
            bump(progress: index + 1, owner: owner)
        }

        if saveConfig {
            let output = try await watch(transport, budget: 200, owner: owner) {
                try transport.run("system configuration save", timeout: 180)
            }
            try requireCurrent(operation)
            if CLI.failed(output) {
                throw TransportError("Роутер не сохранил конфигурацию.", hint: output)
            }
            bump(progress: commands.count + 1, owner: owner)
            log(.ok, "Конфигурация сохранена.")
        }

        return outputs.joined(separator: "\n")
    }

    func readConfigText() async throws -> String {
        try await readConfigText(operation: beginOperation())
    }

    func readConfigText(owner: UUID) async throws -> String {
        try await readConfigText(operation: try beginOperation(owner: owner))
    }

    func readConfigText(operation: RouterOperation) async throws -> String {
        let transport = try await session(operation: operation)
        let text = try await watch(transport, budget: 200, owner: operation.routerID) {
            try transport.fetchText("show running-config", timeout: 180)
        }
        try requireCurrent(operation)
        return text
    }

    func readStartupConfig() async throws -> String {
        try await readStartupConfig(operation: beginOperation())
    }

    func readStartupConfig(owner: UUID) async throws -> String {
        try await readStartupConfig(operation: try beginOperation(owner: owner))
    }

    func readStartupConfig(operation: RouterOperation) async throws -> String {
        let transport = try await session(operation: operation)
        let text = try await watch(transport, budget: 200, owner: operation.routerID) {
            try transport.fetchText("show startup-config", timeout: 180)
        }
        try requireCurrent(operation)
        return text
    }

    // MARK: - Загрузка списков доменов

    func loadSource(_ spec: SourceSpec, forceRefresh: Bool) async throws -> SourceData {
        let ttl = Store.shared.settings.cacheTTLMinutes
        let owner = router.id
        store(activity: "Загружаю «\(spec.title)»…", owner: owner)
        defer { clearActivity(owner: owner) }
        return try await background(owner: owner) {
            try SourceLoader.load(spec, ttlMinutes: ttl, forceRefresh: forceRefresh)
        }
    }

    // MARK: - Инструменты

    /// Кому принадлежит то, что делается прямо сейчас.
    var activeRouterID: UUID { router.id }

    func setActivity(_ text: String?, owner: UUID? = nil) {
        store(activity: text, owner: owner ?? router.id)
    }

    func setProgress(_ info: ProgressInfo?, owner: UUID? = nil) {
        store(progress: info, owner: owner ?? router.id)
    }

    func bumpProgress(_ done: Int, owner: UUID? = nil) {
        bump(progress: done, owner: owner ?? router.id)
    }

    /// Блокирующая работа уходит с главного потока, интерфейс остаётся живым.
    private func background<T>(owner: UUID, _ body: @escaping () throws -> T) async throws -> T {
        let targetQueue = slots[owner]?.queue ?? Self.orphanedOperationQueue
        return try await withCheckedThrowingContinuation { continuation in
            targetQueue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func background<T>(owner: UUID, _ body: @escaping () -> T) async -> T {
        let targetQueue = slots[owner]?.queue ?? Self.orphanedOperationQueue
        return await withCheckedContinuation { continuation in
            targetQueue.async { continuation.resume(returning: body()) }
        }
    }

    nonisolated func describe(_ error: Error) -> String {
        if let transportError = error as? TransportError {
            if let hint = transportError.hint, !hint.isEmpty {
                return CLI.redactSecrets(transportError.message + "\n" + hint)
            }
            return CLI.redactSecrets(transportError.message)
        }
        return CLI.redactSecrets(error.localizedDescription)
    }
}

enum Backups {
    /// Имя файла собирается из адреса роутера — приводим его к безопасному виду.
    static func safeHost(_ host: String) -> String {
        host.replacingOccurrences(of: "[^A-Za-z0-9_.-]+", with: "_", options: .regularExpression)
    }

    private static let namePattern = try! NSRegularExpression(
        pattern: "^(.+)_\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}_running-config$")

    /// Чей это снимок. Снимки всех роутеров лежат в одной папке, и без
    /// разбора имени их не отфильтровать.
    static func host(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return RouterConfigParser.capture(namePattern, in: name, group: 1) ?? ""
    }

    @discardableResult
    static func saveRunningConfig(host: String, text: String, keep: Int) -> URL? {
        let safeHost = safeHost(host)
        let url = AppPaths.backups
            .appendingPathComponent("\(safeHost)_\(Format.stamp())_running-config")
            .appendingPathExtension(SecureBackup.pathExtension)

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
