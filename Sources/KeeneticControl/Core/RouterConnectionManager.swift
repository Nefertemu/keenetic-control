import Foundation
import SwiftUI

/// Отмена может прийти, пока блок ещё ждёт свою очередь. Проверяем её
/// также внутри очереди, чтобы отменённая запись вообще не вызывала транспорт.
private final class OperationCancellation {
    private let lock = NSLock()
    private var failure: Error?
    private var started = false

    /// Не прерываем чужую операцию, если наша ещё ждёт в очереди.
    func cancel(_ error: Error = CancellationError()) -> Bool {
        lock.withLock { failure = error; return started }
    }
    func begin() throws {
        try lock.withLock {
            if let failure { throw failure }
            started = true
        }
    }
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
    var connectTask: ConnectionAttempt?
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
final class RouterConnectionManager: ObservableObject {
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

    let dependencies: RouterSessionDependencies

    init(router: RouterProfile, dependencies: RouterSessionDependencies) {
        self.dependencies = dependencies
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

    func beginOperation(owner: UUID) throws -> RouterOperation {
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

    func requireCurrent(_ operation: RouterOperation) throws {
        try Task.checkCancellation()
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
        target.authRejected = nil

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
        if router.id == profile.id { router = profile }
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
    func store(transport newValue: KeeneticTransport?,
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

    func store(status newStatus: ConnectionStatus, owner: UUID) {
        if owner == router.id {
            status = newStatus
        } else if let slot = slots[owner] {
            objectWillChange.send()
            slot.status = newStatus
        }
    }

    func store(state newValue: RouterState, owner: UUID) {
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

    func store(activity newValue: String?, owner: UUID) {
        if owner == router.id {
            activity = newValue
        } else if let slot = slots[owner] {
            objectWillChange.send()
            slot.activity = newValue
        }
    }

    func store(progress newValue: ProgressInfo?, owner: UUID) {
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
        if let message = profile.validationError { throw TransportError(message) }
        let slot = slot(for: profile)
        dropIfProfileChanged(profile)
        if slot.status.isOnline, slot.transport != nil { return }

        // Пароль уже отвергли. Каждая новая попытка — ещё одна отметка в
        // счётчике защиты роутера, а не шанс на успех.
        if let rejected = slot.authRejected {
            store(status: .failed(rejected), owner: profile.id)
            throw TransportError(rejected, isAuthFailure: true)
        }

        try Task.checkCancellation()
        if let running = slot.connectTask, !running.isCancelled {
            try await running.wait()
            return
        }

        store(status: .connecting, owner: profile.id)
        let owner = profile.id
        let generation = slot.connectionGeneration
        let attempt = ConnectionAttempt()
        slot.connectTask = attempt
        attempt.start { [self] in
            defer {
                if slot.connectTask === attempt {
                    slot.connectTask = nil
                    clearActivity(owner: owner)
                }
            }
            do {
                let opened = try await openTransport(profile: profile)
                guard !attempt.isCancelled,
                      isCurrentConnection(profile, generation: generation) else {
                    opened.abort()
                    throw CancellationError()
                }
                // Сначала публикуем транспорт, затем возобновляем всех ожидающих.
                store(transport: opened, status: .online(profile.transport), owner: owner)
            } catch {
                guard slot.connectTask === attempt,
                      isCurrentConnection(profile, generation: generation) else { throw error }
                if error is CancellationError {
                    store(transport: nil, status: .offline, owner: owner)
                    throw error
                }
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
        try await attempt.wait()
    }

    /// Связь с роутером бывает капризной — одна осечка не повод сдаваться.
    private func openTransport(profile: RouterProfile) async throws -> KeeneticTransport {
        // Связка ключей может показать системный запрос доступа и держать
        // вызов сколько угодно — на главном потоке это заморозило бы окно.
        let password = await dependencies.password(profile)
        try Task.checkCancellation()
        let attempts = 3
        var lastError: Error = TransportError("Не удалось подключиться.")

        for attempt in 1...attempts {
            try Task.checkCancellation()
            store(activity: attempt == 1
                    ? "Подключаюсь к \(profile.endpoint)…"
                    : "Попытка \(attempt) из \(attempts): \(profile.endpoint)…",
                  owner: profile.id)

            let created = try dependencies.makeTransport(profile, password)

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
                    try await dependencies.retryDelay()
                }
            }
        }

        throw lastError
    }

    /// Сторож: если операция залипла дольше отведённого, рвём транспорт.
    /// Иначе последовательная очередь встанет намертво и интерфейс замрёт
    /// на «Подключаюсь…» без единой записи в журнале.
    func watch<T>(_ transport: KeeneticTransport, budget: TimeInterval, owner: UUID,
                          _ body: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let cancellation = OperationCancellation()
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            if cancellation.cancel(TransportError("Превышено время ожидания операции.")) {
                transport.abort()
            }
            log(.warn, "Операция превысила \(Int(budget)) с — соединение оборвано.")
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler(operation: {
            do {
                let result = try await background(owner: owner) {
                    try cancellation.begin()
                    return try body()
                }
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }, onCancel: {
            // `background` ждёт блокирующий SSH/HTTP-вызов. Отмена Swift-задачи
            // сама его не прерывает, а abort() разбудит ожидание немедленно.
            if cancellation.cancel() { transport.abort() }
        })
    }

    /// То же самое для транспорта конкретной операции.
    private func guarded<T>(operation: RouterOperation, budget: TimeInterval,
                            preserveConnectionOnFailure: Bool = false,
                            _ body: @escaping (KeeneticTransport) throws -> T) async throws -> T {
        try requireCurrent(operation)
        var active = try await transport(for: operation)
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
            guard isCurrent(operation) else { throw error }
            if !Task.isCancelled,
               (error as? TransportError)?.isSessionFailure == true {
                // Роутер закрыл давно простаивавшую сессию между isAlive и
                // запросом. Для этих трёх вызовов body только читает данные
                // или выполняет диагностический ping, поэтому один повтор
                // безопасен и не дублирует пользовательские изменения.
                if slots[operation.routerID]?.transport === active {
                    active.abort()
                    store(transport: nil,
                          status: .failed("Сессия прервалась · переподключаюсь…"),
                          owner: operation.routerID)
                }
                active = try await transport(for: operation)
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
                    guard isCurrent(operation), slots[operation.routerID]?.transport === active else { throw error }
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
        closing.abort()
        await background(owner: owner) { closing.close() }
    }

    /// Все операции идут через это: гарантируем живое соединение ровно с тем
    /// профилем, с которым началась операция.
    func transport(for operation: RouterOperation) async throws -> KeeneticTransport {
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
        defer { if !quiet, isCurrent(operation) { clearActivity(owner: owner) } }
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

    func readConfigText() async throws -> String {
        try await readConfigText(operation: beginOperation())
    }

    func readConfigText(owner: UUID) async throws -> String {
        try await readConfigText(operation: try beginOperation(owner: owner))
    }

    func readConfigText(operation: RouterOperation) async throws -> String {
        try await guarded(operation: operation, budget: 200) { transport in
            try transport.fetchText("show running-config", timeout: 180)
        }
    }

    func readStartupConfig() async throws -> String {
        try await readStartupConfig(operation: beginOperation())
    }

    func readStartupConfig(owner: UUID) async throws -> String {
        try await readStartupConfig(operation: try beginOperation(owner: owner))
    }

    func readStartupConfig(operation: RouterOperation) async throws -> String {
        let transport = try await transport(for: operation)
        let text = try await watch(transport, budget: 200, owner: operation.routerID) {
            try transport.fetchText("show startup-config", timeout: 180)
        }
        try requireCurrent(operation)
        return text
    }

    // MARK: - Загрузка списков доменов

    func loadSource(_ spec: SourceSpec, forceRefresh: Bool) async throws -> SourceData {
        let ttl = dependencies.settings().cacheTTLMinutes
        let operation = beginOperation()
        let owner = operation.routerID
        store(activity: "Загружаю «\(spec.title)»…", owner: owner)
        defer { if isCurrent(operation) { clearActivity(owner: owner) } }
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

    nonisolated func describe(_ error: Error) -> String { Self.describeError(error) }

    nonisolated static func describeError(_ error: Error) -> String {
        if let transportError = error as? TransportError {
            if let hint = transportError.hint, !hint.isEmpty {
                return CLI.redactSecrets(transportError.message + "\n" + hint)
            }
            return CLI.redactSecrets(transportError.message)
        }
        return CLI.redactSecrets(error.localizedDescription)
    }
}
