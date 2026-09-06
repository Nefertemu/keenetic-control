import Foundation

/// Выполнение планов: резервная копия, команды, сохранение и проверка.
/// Пул соединений и поколения операций принадлежат только менеджеру.
@MainActor
final class RouterPlanExecutor {
    private let connections: RouterConnectionManager
    private var writing: Set<UUID> = []

    private func beginWriting(_ owner: UUID) throws {
        guard writing.insert(owner).inserted else {
            throw TransportError("На этом роутере уже выполняется изменение.",
                                 hint: "Дождись завершения текущего плана.")
        }
    }

    init(connections: RouterConnectionManager) {
        self.connections = connections
    }

    // MARK: - Применение плана

    func apply(plan: Plan, dryRun: Bool, saveConfig: Bool) async throws -> ApplyOutcome {
        guard !plan.isEmpty else { return ApplyOutcome(applied: true) }
        let profile = connections.router
        let operation = connections.beginOperation()
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
        try beginWriting(owner)
        defer {
            writing.remove(owner)
            if connections.isCurrent(operation) { connections.store(activity: nil, owner: owner) }
        }

        let transport = try await connections.transport(for: operation)
        // Бэкап должен отражать то, что на роутере сейчас, а не час назад.
        let configText: String
        if let current = connections.readState(for: owner), !current.configText.isEmpty,
           Date().timeIntervalSince(current.readAt) < 300 {
            configText = current.configText
        } else {
            connections.store(activity: "Читаю конфигурацию перед изменением…", owner: owner)
            configText = try await connections.watch(transport, budget: 200, owner: owner) {
                try transport.fetchText("show running-config", timeout: 180)
            }
        }
        try connections.requireCurrent(operation)

        guard let backupURL = connections.dependencies.backup(
            profile, configText, connections.dependencies.settings().keepBackups) else {
            throw TransportError(
                "Изменения отменены: не удалось создать защищённую резервную копию.",
                hint: "Проверь доступ приложения к связке ключей и свободное место на диске.")
        }
        log(.info, "Защищённая резервная копия: \(backupURL.lastPathComponent)")

        let started = Date()
        let batchSize = max(1, connections.dependencies.settings().batchSize)
        let limit = connections.dependencies.settings().maxDomainsPerList

        connections.store(progress: ProgressInfo(label: plan.title, done: 0, total: plan.commands.count),
              owner: owner)
        defer { if connections.isCurrent(operation) { connections.store(progress: nil, owner: owner) } }

        log(.info, "\(plan.title): отправляю \(Format.commands(plan.commands.count)).")

        do {
            try await execute(plan.commands, transport: transport, batchSize: batchSize,
                              operation: operation)
        } catch {
            log(.error, "Выполнение остановлено: \(connections.describe(error))")
            log(.warn, "Конфигурация НЕ сохранена. Часть команд могла примениться — проверь бэкап.")
            throw error
        }

        if saveConfig {
            try connections.requireCurrent(operation)
            connections.store(activity: "Сохраняю конфигурацию роутера…", owner: owner)
            let output = try await connections.watch(transport, budget: 200, owner: owner) {
                try transport.run("system configuration save", timeout: 180)
            }
            try connections.requireCurrent(operation)
            if CLI.failed(output) {
                log(.error, "Не удалось сохранить конфигурацию: \(output)")
                throw TransportError("Роутер не сохранил конфигурацию.", hint: output)
            }
            log(.ok, "Конфигурация сохранена.")
        }

        connections.store(activity: "Перечитываю конфигурацию для проверки…", owner: owner)
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
            try connections.requireCurrent(operation)
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
            let output = try await connections.watch(transport, budget: 150, owner: owner) { () -> String in
                batch.count == 1
                    ? try transport.run(batch[0], timeout: 120)
                    : try transport.runBatch(batch, timeout: 120)
            }
            try connections.requireCurrent(operation)

            if CLI.failed(output) {
                if batch.count > 1 {
                    log(.warn, "Ошибка внутри пачки — повторяю команды по одной…")
                    for command in batch {
                        try connections.requireCurrent(operation)
                        let single = try await connections.watch(transport, budget: 150, owner: owner) {
                            try transport.run(command, timeout: 120)
                        }
                        try connections.requireCurrent(operation)
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
            connections.bumpProgress(done, owner: owner)
        }
    }

    private func verify(plan: Plan, transport: KeeneticTransport, limit: Int,
                        operation: RouterOperation) async throws -> [String] {
        let owner = operation.routerID
        try connections.requireCurrent(operation)
        let configText = try await connections.watch(transport, budget: 200, owner: owner) {
            try transport.fetchText("show running-config", timeout: 180)
        }
        try connections.requireCurrent(operation)
        let groups = RouterConfigParser.parseFqdnGroups(configText)
        let problems = PlanVerifier.problems(plan: plan, groups: groups, limit: limit)

        // Обновляем состояние из уже прочитанной конфигурации — лишний раз не ходим.
        let previous = connections.readState(for: owner)
        let pingCheck = PingCheckParser.parse(config: configText)
        connections.store(state: RouterState(
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
                              operation: connections.beginOperation())
    }

    /// Выполнить команды на уже выбранном владельце операции. Если владелец
    /// больше не активен, но его соединение ещё живо, работа продолжается
    /// именно на нём; к новому роутеру команды не переедут.
    @discardableResult
    func runCommands(_ commands: [String], title: String, saveConfig: Bool,
                     owner: UUID) async throws -> String {
        try await runCommands(commands, title: title, saveConfig: saveConfig,
                              operation: try connections.beginOperation(owner: owner))
    }

    /// Выполнить команды, не меняя цель при редактировании активного профиля.
    @discardableResult
    func runCommands(_ commands: [String], title: String, saveConfig: Bool,
                     operation: RouterOperation) async throws -> String {
        guard !commands.isEmpty else { return "" }
        try connections.requireCurrent(operation)
        let owner = operation.routerID
        try beginWriting(owner)
        defer { writing.remove(owner) }
        let transport = try await connections.transport(for: operation)

        connections.store(progress: ProgressInfo(label: title, done: 0,
                                     total: commands.count + (saveConfig ? 1 : 0)), owner: owner)
        defer { if connections.isCurrent(operation) { connections.store(progress: nil, owner: owner) } }

        var outputs: [String] = []
        for (index, command) in commands.enumerated() {
            try connections.requireCurrent(operation)
            log(.cmd, CLI.redactSecrets(command))
            let output = try await connections.watch(transport, budget: 150, owner: owner) {
                try transport.run(command, timeout: 120)
            }
            try connections.requireCurrent(operation)
            if CLI.failed(output) {
                throw TransportError("Роутер отверг команду: \(CLI.redactSecrets(command))",
                                     hint: CLI.redactSecrets(output))
            }
            if !output.isEmpty { outputs.append(CLI.redactSecrets(output)) }
            connections.bumpProgress(index + 1, owner: owner)
        }

        if saveConfig {
            try connections.requireCurrent(operation)
            let output = try await connections.watch(transport, budget: 200, owner: owner) {
                try transport.run("system configuration save", timeout: 180)
            }
            try connections.requireCurrent(operation)
            if CLI.failed(output) {
                throw TransportError("Роутер не сохранил конфигурацию.", hint: output)
            }
            connections.bumpProgress(commands.count + 1, owner: owner)
            log(.ok, "Конфигурация сохранена.")
        }

        return outputs.joined(separator: "\n")
    }

}
