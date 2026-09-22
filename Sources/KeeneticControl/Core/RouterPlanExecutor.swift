import Foundation

/// Однокнопочное обновление показывает копию даже после частичной записи.
struct DomainListApplicationError: LocalizedError {
    let cause: Error
    let backupURL: URL
    var historyID: UUID?
    var errorDescription: String? { RouterConnectionManager.describeError(cause) }
}

/// Выполнение планов: резервная копия, команды, сохранение и проверка.
/// Пул соединений и поколения операций принадлежат только менеджеру.
@MainActor
final class RouterPlanExecutor {
    private let connections: RouterConnectionManager
    private var writing: [UUID: UUID] = [:]
    @TaskLocal private static var inheritedWriteLease: UUID?

    /// true означает, что именно этот вызов должен освободить блокировку.
    private func beginWriting(_ owner: UUID) throws -> Bool {
        if let lease = writing[owner] {
            guard lease == Self.inheritedWriteLease else {
                throw TransportError("На этом роутере уже выполняется изменение.",
                                     hint: "Дождись завершения текущего плана.")
            }
            return false
        }
        writing[owner] = UUID()
        connections.setWriting(true, owner: owner)
        return true
    }

    private func finishWriting(_ owner: UUID, acquired: Bool) {
        guard acquired else { return }
        writing.removeValue(forKey: owner)
        connections.setWriting(false, owner: owner)
    }

    /// Удерживает право записи и между стадиями составного обновления:
    /// чтением, проверкой нового пира, применением и возможным откатом.
    func withExclusiveWriteOperation<T>(operation: RouterOperation,
                                        _ body: @MainActor () async throws -> T) async throws -> T {
        try connections.requireCurrent(operation)
        let owner = operation.routerID
        let acquired = try beginWriting(owner)
        defer { finishWriting(owner, acquired: acquired) }
        let lease = writing[owner]!
        return try await Self.$inheritedWriteLease.withValue(lease) {
            try await body()
        }
    }

    init(connections: RouterConnectionManager) {
        self.connections = connections
    }

    // MARK: - Применение плана

    func apply(plan: Plan, dryRun: Bool, saveConfig: Bool,
               preWriteCheck: (() throws -> Void)? = nil) async throws -> ApplyOutcome {
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
        try validateCommandContexts(plan.commands)
        let acquired = try beginWriting(owner)
        defer {
            finishWriting(owner, acquired: acquired)
            if connections.isCurrent(operation) { connections.store(activity: nil, owner: owner) }
        }

        let transport = try await connections.transport(for: operation)
        // Даже свежий кэш мог устареть после правки в веб-панели или прямых
        // команд WireGuard. Копия должна содержать состояние перед записью.
        connections.store(activity: "Читаю конфигурацию перед изменением…", owner: owner)
        let rawConfigText = try await connections.watch(transport, budget: 200, owner: owner) {
            try transport.fetchText("show running-config", timeout: 180)
        }
        try connections.requireCurrent(operation)
        let configText = try ConfigurationText.validated(rawConfigText)
        try preWriteCheck?()

        let preconditions = PlanVerifier.preconditionProblems(
            plan: plan, groups: RouterConfigParser.parseFqdnGroups(configText),
            staticRoutes: StaticRouteParser.parse(config: configText), configText: configText)
        guard preconditions.isEmpty else {
            throw TransportError("Списки изменились после сверки. Обновление остановлено до записи.",
                                 hint: preconditions.joined(separator: "\n"))
        }

        guard let backupURL = connections.dependencies.backup(
            profile, configText, connections.dependencies.settings().keepBackups) else {
            throw TransportError(
                "Изменения отменены: не удалось создать защищённую резервную копию.",
                hint: "Проверь доступ приложения к связке ключей и свободное место на диске.")
        }
        log(.info, "Защищённая резервная копия: \(backupURL.lastPathComponent)")

        let history = connections.dependencies.operationHistory()
        let historyID = history.begin(profile: profile, plan: plan,
                                      configText: configText, backupURL: backupURL)

        let started = Date()
        let batchSize = max(1, connections.dependencies.settings().batchSize)
        let limit = connections.dependencies.settings().maxDomainsPerList

        connections.store(progress: ProgressInfo(label: plan.title, done: 0, total: plan.commands.count),
              owner: owner)
        defer { if connections.isCurrent(operation) { connections.store(progress: nil, owner: owner) } }

        log(.info, "\(plan.title): отправляю \(Format.commands(plan.commands.count)).")

        func save() async throws {
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

        do {
            try await execute(plan.commands, transport: transport, batchSize: batchSize,
                              operation: operation)
            var problems: [String] = []
            if plan.verifyBeforeSave {
                connections.store(activity: "Перечитываю конфигурацию для проверки…", owner: owner)
                problems = try await verify(plan: plan, transport: transport, limit: limit,
                                            operation: operation)
            }
            if saveConfig && problems.isEmpty { try await save() }
            if !plan.verifyBeforeSave {
                connections.store(activity: "Перечитываю конфигурацию для проверки…", owner: owner)
                problems = try await verify(plan: plan, transport: transport, limit: limit,
                                            operation: operation)
            }

            let elapsed = Date().timeIntervalSince(started)
            if problems.isEmpty {
                log(.ok, "Готово за \(Format.duration(elapsed)): " + plan.summary.joined(separator: ", "))
            } else {
                for problem in problems { log(.warn, "Проверка: \(problem)") }
            }
            history.finish(historyID, status: problems.isEmpty
                           ? (saveConfig ? .saved : .temporary) : .needsAttention, problems: problems)
            return ApplyOutcome(applied: true, problems: problems, backupURL: backupURL,
                                elapsed: elapsed, historyID: historyID)
        } catch {
            history.finish(historyID, status: .failed,
                           problems: ["Часть команд могла примениться. Проверь конфигурацию и копию перед повтором.",
                                      connections.describe(error)])
            log(.error, "Выполнение остановлено: \(connections.describe(error))")
            log(.warn, "Часть команд могла примениться — проверь резервную копию.")
            if plan.verifyBeforeSave {
                throw DomainListApplicationError(cause: error, backupURL: backupURL, historyID: historyID)
            }
            throw error
        }
    }

    /// `ip route disable` относится к предыдущему маршруту. Пара идёт одним
    /// запросом, без постороннего чтения между командами и без повтора после
    /// неоднозначной ошибки. Отдельное disable никогда не отправляется.
    private func isStaticRoutePair(_ commands: [String], at index: Int) -> Bool {
        guard index + 1 < commands.count,
              let route = StaticRouteParser.parse(line: commands[index]) else { return false }
        return commands[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == route.family.keyword + " disable"
    }

    private func validateCommandContexts(_ commands: [String]) throws {
        var index = 0
        while index < commands.count {
            if isStaticRoutePair(commands, at: index) { index += 2; continue }
            let line = commands[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard line != "ip route disable", line != "ipv6 route disable" else {
                throw TransportError("Отключение маршрута не связано с его объявлением.",
                                     hint: "Составь план заново: отдельная команда disable не будет отправлена.")
            }
            index += 1
        }
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
            let contextualPair = isStaticRoutePair(commands, at: index)
            if contextualPair {
                chunk = Array(commands[index...index + 1])
            } else if isBulk(commands[index]) {
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
                if batch.count > 1 && !contextualPair {
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
            try ConfigurationText.validated(transport.fetchText("show running-config", timeout: 180))
        }
        try connections.requireCurrent(operation)
        let groups = RouterConfigParser.parseFqdnGroups(configText)
        let problems = PlanVerifier.problems(plan: plan, groups: groups, limit: limit,
                                             staticRoutes: StaticRouteParser.parse(config: configText), configText: configText)

        // Обновляем состояние из уже прочитанной конфигурации — лишний раз не ходим.
        connections.storeConfigurationSnapshot(configText, owner: owner)

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
        try validateCommandContexts(commands)
        try connections.requireCurrent(operation)
        let profile = try connections.profile(for: operation)
        let owner = operation.routerID
        let acquired = try beginWriting(owner)
        defer { finishWriting(owner, acquired: acquired) }
        let transport = try await connections.transport(for: operation)

        connections.store(progress: ProgressInfo(label: title, done: 0,
                                     total: commands.count + (saveConfig ? 1 : 0)), owner: owner)
        defer { if connections.isCurrent(operation) { connections.store(progress: nil, owner: owner) } }

        var outputs: [String] = []
        var commandPlan = Plan(title: title)
        commandPlan.commands = commands
        let history = connections.dependencies.operationHistory()
        let historyID = history.begin(profile: profile, plan: commandPlan,
                                      configText: connections.readState(for: owner)?.configText ?? "", backupURL: nil)
        do {
            var index = 0
            while index < commands.count {
                try connections.requireCurrent(operation)
                let count = isStaticRoutePair(commands, at: index) ? 2 : 1
                let batch = Array(commands[index..<index + count])
                for command in batch { log(.cmd, CLI.redactSecrets(command)) }
                let output = try await connections.watch(transport, budget: 150, owner: owner) {
                    batch.count == 1
                        ? try transport.run(batch[0], timeout: 120)
                        : try transport.runBatch(batch, timeout: 120)
                }
                try connections.requireCurrent(operation)
                if CLI.failed(output) {
                    throw TransportError("Роутер отверг команду: \(CLI.redactSecrets(batch.joined(separator: "\n")))",
                                         hint: CLI.redactSecrets(output))
                }
                if !output.isEmpty { outputs.append(CLI.redactSecrets(output)) }
                index += count
                connections.bumpProgress(index, owner: owner)
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

            let saved = saveConfig || commands.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "system configuration save"
            history.finish(historyID, status: saved ? .saved : .temporary)
            return outputs.joined(separator: "\n")
        } catch {
            history.finish(historyID, status: .failed, problems: [connections.describe(error)])
            throw error
        }
    }

}
