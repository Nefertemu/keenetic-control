import Foundation

struct WireGuardUpdateResult {
    var interface: String
    /// «Dataforest · Wireguard0» — чтобы в итоговом окне было видно,
    /// какой именно туннель обновился.
    var label: String = ""
    var warnings: [String] = []
    var routesBefore: Int = 0
    var routesAfter: Int = 0
    var backupURL: URL?
    var rolledBack: Bool = false
}

/// Безопасное обновление: бэкап → подготовка → проверка → применение →
/// повторная проверка → сохранение. При любой осечке — откат на rollback-базу.
@MainActor
enum WireGuardService {

    static func safeUpdate(session: RouterSession,
                           interface: String,
                           config: WireGuardConfig) async throws -> WireGuardUpdateResult {
        guard config.peers.count == 1 else {
            throw TransportError(
                "Безопасное обновление WireGuard работает только с конфигом с одним [Peer].")
        }
        var result = WireGuardUpdateResult(interface: interface)
        // Обновление длинное: если за это время переключат роутер, подпись
        // о ходе работы должна остаться у своего.
        let operation = session.beginOperation()
        let owner = operation.routerID
        let router = session.router

        // --- Снимок «до» -------------------------------------------------
        let configBefore: String
        do {
            session.setActivity("Снимаю резервную копию перед обновлением…", owner: owner)
            defer { session.setActivity(nil, owner: owner) }
            configBefore = try await session.readConfigText(operation: operation)
            guard let protectedBackup = Backups.saveRunningConfig(
                host: router.host, text: configBefore,
                keep: Store.shared.settings.keepBackups) else {
                throw TransportError(
                    "Обновление отменено: защищённая резервная копия не создана.",
                    hint: "Проверь доступ приложения к связке ключей и свободное место на диске.")
            }
            result.backupURL = protectedBackup

            if let startup = try? await session.readStartupConfig(operation: operation) {
                let url = AppPaths.wireguard.appendingPathComponent(
                    "\(interface)_\(Format.stamp())_startup-config")
                    .appendingPathExtension(SecureBackup.pathExtension)
                do {
                    try SecureBackup.write(startup, to: url)
                } catch {
                    throw TransportError(
                        "Обновление отменено: startup-config не удалось зашифровать.",
                        hint: error.localizedDescription)
                }
            }
        }

        let stateBefore = WireGuardState.parse(config: configBefore, interface: interface)
        result.routesBefore = routeCount(configBefore)

        guard stateBefore.peerKeys.count <= 2 else {
            throw TransportError(
                "На интерфейсе \(interface) больше двух пиров — автоматическое обновление остановлено.",
                hint: "Разберись с лишними пирами в веб-панели и попробуй снова.")
        }
        guard WireGuardVault.hasBaseline(router: router, interface: interface) else {
            throw TransportError(
                "Не задана rollback-база для \(interface).",
                hint: "Загрузи ТЕКУЩИЙ рабочий .conf и нажми «Сделать rollback-базой» — "
                    + "без неё откатывать нечего.")
        }

        let newKey = config.publicKey
        let stages = try WireGuardPlanner.stages(interface: interface, config: config)

        log(.info, "WireGuard \(interface): начинаю безопасное обновление (\(config.flavour)).")

        do {
            // --- Фаза 1: гасим интерфейс и готовим нового пира без AllowedIPs.
            try await session.runCommands(
                stages[0].commands + stages[1].commands,
                title: "WireGuard: подготовка пира", saveConfig: false, operation: operation)

            let afterStage = WireGuardState.parse(
                config: try await session.readConfigText(operation: operation), interface: interface)

            for oldKey in stateBefore.peerKeys where oldKey != newKey {
                guard afterStage.peerKeys.contains(oldKey) else {
                    throw TransportError(
                        "Keenetic удалил старого пира при подготовке нового.",
                        hint: "Запускаю откат на rollback-базу.")
                }
            }
            guard afterStage.peerKeys.contains(newKey) else {
                throw TransportError("Новый пир не появился на интерфейсе.")
            }

            // --- Фаза 2: адреса, обфускация, приватный ключ, AllowedIPs.
            let rest = stages.dropFirst(2).flatMap(\.commands)
            try await session.runCommands(rest, title: "WireGuard: применение конфига",
                                          saveConfig: false, operation: operation)

            // --- Фаза 3: старый пир прочь — только теперь.
            let removals = WireGuardPlanner.removeOldPeers(
                interface: interface, oldKeys: stateBefore.peerKeys, newKey: newKey)
            if !removals.isEmpty {
                try await session.runCommands(removals, title: "WireGuard: удаление старого пира",
                                              saveConfig: false, operation: operation)
            }

            // --- Финальная проверка набора пиров.
            let configAfterPeers = try await session.readConfigText(operation: operation)
            let peersAfter = WireGuardState.parse(config: configAfterPeers, interface: interface).peerKeys
            guard peersAfter == [newKey] else {
                throw TransportError(
                    "После обновления набор пиров не сошёлся: \(peersAfter.joined(separator: ", "))")
            }

            // --- Поднимаем интерфейс.
            try await session.runCommands(
                WireGuardPlanner.bringUp(interface: interface),
                title: "WireGuard: включение", saveConfig: false, operation: operation)

            // --- Снимок «после» ----------------------------------------------
        let configAfter = try await session.readConfigText(operation: operation)
        result.routesAfter = routeCount(configAfter)

        if result.routesAfter < result.routesBefore {
            result.warnings.append(
                "Маршрутов стало меньше: было \(result.routesBefore), стало \(result.routesAfter). "
                + "Проверь dns-proxy и статические маршруты.")
        }

        let stateAfter = WireGuardState.parse(config: configAfter, interface: interface)
        if !stateAfter.isUp {
            result.warnings.append("Интерфейс \(interface) остался выключенным.")
        }

        // --- Сохраняем и обновляем rollback-базу.
        try await saveRouterConfig(session: session, operation: operation)

        WireGuardVault.saveBaseline(config.sourceText, router: router, interface: interface)
        log(.ok, "WireGuard \(interface) обновлён. Новый конфиг стал rollback-базой.")

        _ = try? await session.refresh(operation: operation)
        } catch {
            log(.error, "Обновление \(interface) не прошло: \(session.describe(error))")
            result.rolledBack = await rollbackQuietly(session: session, interface: interface,
                                                       operation: operation, router: router)
            if result.rolledBack {
                throw TransportError(
                    "Обновление не удалось — конфигурация откачена на rollback-базу.",
                    hint: session.describe(error))
            }
            throw error
        }
        return result
    }

    /// Ручной откат на сохранённую rollback-базу.
    static func rollback(session: RouterSession, interface: String) async throws {
        let operation = session.beginOperation()
        let router = session.router
        try await rollback(session: session, interface: interface, operation: operation, router: router)
    }

    /// Откат всегда возвращает состояние тому же роутеру, на котором началась
    /// операция. Это особенно важно после частичного обновления: переключение
    /// интерфейса в UI не должно послать rollback на другой роутер.
    private static func rollback(session: RouterSession, interface: String,
                                 operation: RouterOperation,
                                 router: RouterProfile) async throws {
        guard let baseline = WireGuardVault.baseline(router: router, interface: interface) else {
            throw TransportError("Для \(interface) не сохранена rollback-база.")
        }

        log(.warn, "WireGuard \(interface): откат на сохранённую rollback-базу.")

        let configBefore = try await session.readConfigText(operation: operation)
        guard Backups.saveRunningConfig(host: router.host, text: configBefore,
                                        keep: Store.shared.settings.keepBackups) != nil else {
            throw TransportError(
                "Откат остановлен: защищённая резервная копия текущего состояния не создана.",
                hint: "Проверь доступ приложения к связке ключей и свободное место на диске.")
        }

        let stateBefore = WireGuardState.parse(config: configBefore, interface: interface)
        let stages = try WireGuardPlanner.stages(interface: interface, config: baseline)

        try await session.runCommands(stages.flatMap(\.commands),
                                      title: "WireGuard: откат", saveConfig: false, operation: operation)

        let removals = WireGuardPlanner.removeOldPeers(
            interface: interface, oldKeys: stateBefore.peerKeys, newKey: baseline.publicKey)
        if !removals.isEmpty {
            try await session.runCommands(removals, title: "WireGuard: чистка пиров",
                                          saveConfig: false, operation: operation)
        }

        try await session.runCommands(WireGuardPlanner.bringUp(interface: interface),
                                      title: "WireGuard: включение", saveConfig: false, operation: operation)
        try await saveRouterConfig(session: session, operation: operation)

        log(.ok, "WireGuard \(interface): откат завершён.")
        _ = try? await session.refresh(operation: operation)
    }

    // MARK: - Вспомогательное

    private static func rollbackQuietly(session: RouterSession, interface: String,
                                        operation: RouterOperation,
                                        router: RouterProfile) async -> Bool {
        do {
            try await rollback(session: session, interface: interface, operation: operation, router: router)
            return true
        } catch {
            log(.error, "Автоматический откат тоже не удался: \(session.describe(error))")
            log(.warn, "Восстанови конфигурацию вручную из резервной копии.")
            return false
        }
    }

    private static func saveRouterConfig(session: RouterSession,
                                         operation: RouterOperation) async throws {
        try await session.runCommands(["system configuration save"],
                                      title: "Сохранение конфигурации",
                                      saveConfig: false, operation: operation)
    }

    /// Сколько всего маршрутов знает роутер — грубая, но надёжная проверка.
    static func routeCount(_ configText: String) -> Int {
        var count = 0
        for raw in configText.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ip route ") || trimmed.hasPrefix("ipv6 route ")
                || trimmed.hasPrefix("dns-proxy route object-group ")
                || trimmed.hasPrefix("route object-group ") {
                count += 1
            }
        }
        return count
    }
}
