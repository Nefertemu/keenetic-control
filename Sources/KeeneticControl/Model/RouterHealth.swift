import Foundation

/// Замечание по текущему состоянию роутера.
struct RouterIssue: Identifiable, Hashable {
    enum Severity: Int, Comparable {
        case danger = 0
        case warning = 1
        case info = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var id: String
    var severity: Severity
    var title: String
    var detail: String
}

/// Что не в порядке прямо сейчас.
///
/// Обзор повторял списки интерфейсов и доменов с других экранов — то есть
/// показывал ровно то, что и так видно. Полезнее другое: сразу назвать
/// вещи, из-за которых трафик не пойдёт, и не заставлять сверять их глазами.
enum RouterHealth {

    static func issues(state: RouterState, maxDomainsPerList: Int) -> [RouterIssue] {
        var result: [RouterIssue] = []
        result.append(contentsOf: brokenRouteTargets(state))
        result.append(contentsOf: downInterfacesWithRoutes(state))
        result.append(contentsOf: failingChecks(state))
        result.append(contentsOf: staleHandshakes(state))
        result.append(contentsOf: oversizedLists(state, limit: maxDomainsPerList))
        result.append(contentsOf: unroutedLists(state))
        return result.sorted { left, right in
            left.severity == right.severity ? left.id < right.id : left.severity < right.severity
        }
    }

    /// Маршрут ведёт на интерфейс, которого в конфигурации нет. Домены из
    /// такого списка не поедут никуда, а по самому списку это не видно.
    private static func brokenRouteTargets(_ state: RouterState) -> [RouterIssue] {
        guard !state.interfaces.isEmpty else { return [] }
        var affected: [String: Set<String>] = [:]
        for group in state.groups.values {
            for target in group.routedInterfaces where state.interfaces[target] == nil {
                affected[target, default: []].insert(group.ident)
            }
        }
        return affected.keys.sorted().map { target in
            let lists = affected[target] ?? []
            return RouterIssue(
                id: "missing-interface-\(target)",
                severity: .danger,
                title: "Маршрут ведёт на несуществующий интерфейс \(target)",
                detail: "Такой интерфейс в конфигурации не найден, поэтому "
                      + "\(Format.lists(lists.count)) никуда не направлены.")
        }
    }

    /// Интерфейс выключен, а списки на него направлены.
    private static func downInterfacesWithRoutes(_ state: RouterState) -> [RouterIssue] {
        var affected: [String: Int] = [:]
        for group in state.groups.values {
            for target in group.routedInterfaces {
                guard let item = state.interfaces[target], !item.isUp else { continue }
                affected[target, default: 0] += 1
            }
        }
        return affected.keys.sorted().map { target in
            RouterIssue(
                id: "down-\(target)",
                severity: .danger,
                title: "\(state.shortLabel(for: target)) выключен, но на него идут маршруты",
                detail: "На интерфейс направлено \(Format.lists(affected[target] ?? 0)). "
                      + "Пока он выключен, эти домены идут в обход туннеля.")
        }
    }

    /// Проверка связи назначена и НЕ проходит.
    private static func failingChecks(_ state: RouterState) -> [RouterIssue] {
        state.interfaces.keys.sorted().compactMap { ident in
            guard state.pingCheck(for: ident) == .failing else { return nil }
            return RouterIssue(
                id: "ping-fail-\(ident)",
                severity: .danger,
                title: "\(state.shortLabel(for: ident)): проверка связи не проходит",
                detail: "Роутер считает канал нерабочим. Если включён перезапуск, "
                      + "туннель будет подниматься заново.")
        }
    }

    /// Туннель включён, но рукопожатия давно не было.
    private static func staleHandshakes(_ state: RouterState) -> [RouterIssue] {
        state.interfaces.keys.sorted().compactMap { ident in
            guard let item = state.interfaces[ident], item.isUp, !item.peers.isEmpty,
                  item.peers.contains(where: { $0.online })
            else { return nil }
            guard let age = item.freshestHandshake else {
                return RouterIssue(
                    id: "no-handshake-\(ident)",
                    severity: .warning,
                    title: "\(state.shortLabel(for: ident)): рукопожатия не было",
                    detail: "Интерфейс включён, но пир ни разу не ответил.")
            }
            guard age > 180 else { return nil }
            return RouterIssue(
                id: "stale-handshake-\(ident)",
                severity: .warning,
                title: "\(state.shortLabel(for: ident)): молчит \(Format.ago(seconds: age))",
                detail: "WireGuard обычно подтверждает связь чаще. Похоже, туннель повис.")
        }
    }

    private static func oversizedLists(_ state: RouterState, limit: Int) -> [RouterIssue] {
        guard limit > 0 else { return [] }
        let over = state.groups.values.filter { $0.includes.count > limit }
        guard !over.isEmpty else { return [] }
        let names = over.map { "\($0.ident)=\($0.includes.count)" }.sorted()
        return [RouterIssue(
            id: "oversized",
            severity: .warning,
            title: "Списки крупнее лимита в \(limit) записей",
            detail: names.joined(separator: ", ") + ". Прошивка плохо переносит "
                  + "очень длинные object-group.")]
    }

    private static func unroutedLists(_ state: RouterState) -> [RouterIssue] {
        let idle = state.groups.values.filter { $0.routeLines.isEmpty && !$0.includes.isEmpty }
        guard !idle.isEmpty else { return [] }
        return [RouterIssue(
            id: "unrouted",
            severity: .warning,
            title: "\(Format.lists(idle.count)) без маршрута",
            detail: "Домены загружены, но никуда не направлены — на них ничего "
                  + "не меняется до назначения маршрута.")]
    }
}
