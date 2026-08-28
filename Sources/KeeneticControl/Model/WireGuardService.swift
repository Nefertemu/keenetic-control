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
        var result = WireGuardUpdateResult(interface: interface)
        // Обновление длинное: если за это время переключат роутер, подпись
        // о ходе работы должна остаться у своего.
        let owner = session.activeRouterID

        // --- Снимок «до» -------------------------------------------------
        session.setActivity("Снимаю резервную копию перед обновлением…", owner: owner)
        let configBefore = try await session.readConfigText()
        result.backupURL = Backups.saveRunningConfig(
            host: session.router.host, text: configBefore,
            keep: Store.shared.settings.keepBackups)

        if let startup = try? await session.readStartupConfig() {
            let url = AppPaths.wireguard.appendingPathComponent(
                "\(interface)_\(Format.stamp())_startup-config.txt")
            try? startup.write(to: url, atomically: true, encoding: .utf8)
        }
        session.setActivity(nil, owner: owner)

        let stateBefore = WireGuardState.parse(config: configBefore, interface: interface)
        result.routesBefore = routeCount(configBefore)

        guard stateBefore.peerKeys.count <= 2 else {
            throw TransportError(
                "На интерфейсе \(interface) больше двух пиров — автоматическое обновление остановлено.",
                hint: "Разберись с лишними пирами в веб-панели и попробуй снова.")
        }
        guard WireGuardVault.hasBaseline(router: session.router, interface: interface) else {
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
                title: "WireGuard: подготовка пира", saveConfig: false)

            let afterStage = WireGuardState.parse(
                config: try await session.readConfigText(), interface: interface)

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
            try await session.runCommands(rest, title: "WireGuard: применение конфига", saveConfig: false)

            // --- Фаза 3: старый пир прочь — только теперь.
            let removals = WireGuardPlanner.removeOldPeers(
                interface: interface, oldKeys: stateBefore.peerKeys, newKey: newKey)
            if !removals.isEmpty {
                try await session.runCommands(removals, title: "WireGuard: удаление старого пира", saveConfig: false)
            }

            // --- Финальная проверка набора пиров.
            let configAfterPeers = try await session.readConfigText()
            let peersAfter = WireGuardState.parse(config: configAfterPeers, interface: interface).peerKeys
            guard peersAfter == [newKey] else {
                throw TransportError(
                    "После обновления набор пиров не сошёлся: \(peersAfter.joined(separator: ", "))")
            }

            // --- Поднимаем интерфейс.
            try await session.runCommands(
                WireGuardPlanner.bringUp(interface: interface),
                title: "WireGuard: включение", saveConfig: false)

        } catch {
            log(.error, "Обновление \(interface) не прошло: \(session.describe(error))")
            result.rolledBack = await rollbackQuietly(session: session, interface: interface)
            if result.rolledBack {
                throw TransportError(
                    "Обновление не удалось — конфигурация откачена на rollback-базу.",
                    hint: session.describe(error))
            }
            throw error
        }

        // --- Снимок «после» ----------------------------------------------
        let configAfter = try await session.readConfigText()
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
        try await saveRouterConfig(session: session)

        WireGuardVault.saveBaseline(config.sourceText, router: session.router, interface: interface)
        log(.ok, "WireGuard \(interface) обновлён. Новый конфиг стал rollback-базой.")

        _ = try? await session.refresh()
        return result
    }

    /// Ручной откат на сохранённую rollback-базу.
    static func rollback(session: RouterSession, interface: String) async throws {
        guard let baseline = WireGuardVault.baseline(router: session.router, interface: interface) else {
            throw TransportError("Для \(interface) не сохранена rollback-база.")
        }

        log(.warn, "WireGuard \(interface): откат на сохранённую rollback-базу.")

        let configBefore = try await session.readConfigText()
        Backups.saveRunningConfig(host: session.router.host, text: configBefore,
                                  keep: Store.shared.settings.keepBackups)

        let stateBefore = WireGuardState.parse(config: configBefore, interface: interface)
        let stages = try WireGuardPlanner.stages(interface: interface, config: baseline)

        try await session.runCommands(stages.flatMap(\.commands),
                                      title: "WireGuard: откат", saveConfig: false)

        let removals = WireGuardPlanner.removeOldPeers(
            interface: interface, oldKeys: stateBefore.peerKeys, newKey: baseline.publicKey)
        if !removals.isEmpty {
            try await session.runCommands(removals, title: "WireGuard: чистка пиров", saveConfig: false)
        }

        try await session.runCommands(WireGuardPlanner.bringUp(interface: interface),
                                      title: "WireGuard: включение", saveConfig: false)
        try await saveRouterConfig(session: session)

        log(.ok, "WireGuard \(interface): откат завершён.")
        _ = try? await session.refresh()
    }

    // MARK: - Вспомогательное

    private static func rollbackQuietly(session: RouterSession, interface: String) async -> Bool {
        do {
            try await rollback(session: session, interface: interface)
            return true
        } catch {
            log(.error, "Автоматический откат тоже не удался: \(session.describe(error))")
            log(.warn, "Восстанови конфигурацию вручную из резервной копии.")
            return false
        }
    }

    private static func saveRouterConfig(session: RouterSession) async throws {
        try await session.runCommands(["system configuration save"],
                                      title: "Сохранение конфигурации", saveConfig: false)
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
