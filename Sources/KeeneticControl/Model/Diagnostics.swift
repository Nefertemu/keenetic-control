import Foundation

enum DiagnosticSeverity: String, Hashable {
    case pass
    case warning
    case failure
    case info

    var title: String {
        switch self {
        case .pass:    return "готово"
        case .warning: return "внимание"
        case .failure: return "ошибка"
        case .info:    return "информация"
        }
    }
}

struct DiagnosticCheck: Identifiable, Hashable {
    let id: String
    var title: String
    var value: String
    var detail: String
    var severity: DiagnosticSeverity

    init(id: String, title: String, value: String, detail: String,
         severity: DiagnosticSeverity) {
        self.id = id
        self.title = title
        self.value = value
        self.detail = detail
        self.severity = severity
    }
}

struct RouterDiagnosticsReport: Identifiable, Hashable {
    let id: UUID
    var createdAt: Date
    var interface: String
    var target: String
    var dns: DiagnosticCheck
    var route: DiagnosticCheck
    var mtu: DiagnosticCheck

    init(id: UUID = UUID(), createdAt: Date = Date(), interface: String,
         target: String, dns: DiagnosticCheck, route: DiagnosticCheck,
         mtu: DiagnosticCheck) {
        self.id = id
        self.createdAt = createdAt
        self.interface = interface
        self.target = target
        self.dns = dns
        self.route = route
        self.mtu = mtu
    }

    var checks: [DiagnosticCheck] { [dns, route, mtu] }
}

enum RouterDiagnosticsBuilder {
    static func build(state: RouterState, interface: String, target: String,
                      now: Date = Date()) -> RouterDiagnosticsReport {
        let cleanInterface = interface.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let interfaceState = state.interfaces[cleanInterface]
        let pingState = state.pingCheck(for: cleanInterface)

        let dns = dnsCheck(state: state, target: cleanTarget,
                           pingState: pingState, resolved: interfaceState?.pingCheckResolvedAddresses ?? [])
        let route = routeCheck(state: state, interface: cleanInterface)
        let mtu = mtuCheck(state: state, interface: cleanInterface)

        return RouterDiagnosticsReport(createdAt: now, interface: cleanInterface,
                                       target: cleanTarget, dns: dns,
                                       route: route, mtu: mtu)
    }

    private static func dnsCheck(state: RouterState, target: String,
                                 pingState: PingCheckLiveState,
                                 resolved: [String]) -> DiagnosticCheck {
        let addresses = resolved.filter(IPTools.isIP)
        if target.isEmpty {
            return DiagnosticCheck(id: "dns", title: "DNS",
                                   value: "цель не задана",
                                   detail: "Укажи домен или IP-адрес для проверки.",
                                   severity: .warning)
        }
        if IPTools.isIP(target) {
            return DiagnosticCheck(id: "dns", title: "DNS", value: "не требуется",
                                   detail: "Цель \(target) — IP-адрес, резолвинг не нужен.",
                                   severity: .info)
        }
        if !addresses.isEmpty {
            let servers = state.nameServers.isEmpty
                ? "DNS-серверы роутер не перечислил."
                : "Серверы: \(state.nameServers.joined(separator: ", "))."
            return DiagnosticCheck(id: "dns", title: "DNS",
                                   value: "резолвинг работает",
                                   detail: "\(target) → \(addresses.joined(separator: ", ")). \(servers)",
                                   severity: .pass)
        }

        let reason: String
        switch pingState {
        case .failing:
            reason = "Ping-Check не проходит, поэтому проверь DNS и доступность цели."
        case .unknown:
            reason = "Роутер пока не прислал resolved address — повтори проверку."
        case .passing:
            reason = "Проверка проходит, но адрес резолвинга в ответе не показан."
        case .notConfigured:
            reason = "На интерфейс не назначен профиль Ping-Check."
        }
        return DiagnosticCheck(id: "dns", title: "DNS", value: "нет данных",
                               detail: reason, severity: .warning)
    }

    private static func routeCheck(state: RouterState, interface: String) -> DiagnosticCheck {
        let groups = state.groups.values.filter { $0.isRouted(to: interface) }
        let routes = state.staticRoutes.filter { $0.via == interface }
        let total = groups.count + routes.count
        guard total > 0 else {
            return DiagnosticCheck(id: "route", title: "Маршрут", value: "не найден",
                                   detail: "В текущей конфигурации нет FQDN- или статического маршрута на \(interface).",
                                   severity: .warning)
        }

        var parts: [String] = []
        if !groups.isEmpty { parts.append(Format.lists(groups.count)) }
        if !routes.isEmpty { parts.append(Format.routes(routes.count) + " статических") }
        return DiagnosticCheck(id: "route", title: "Маршрут", value: "найден",
                               detail: "На \(interface): \(parts.joined(separator: " · ")).",
                               severity: .pass)
    }

    private static func mtuCheck(state: RouterState, interface: String) -> DiagnosticCheck {
        let wireguard = WireGuardState.parse(config: state.configText, interface: interface)
        guard let mtu = wireguard.mtu else {
            return DiagnosticCheck(id: "mtu", title: "MTU", value: "не задан",
                                   detail: "Роутер использует значение по умолчанию прошивки. Явное значение помогает избежать фрагментации VPN.",
                                   severity: .warning)
        }

        if mtu < 1280 {
            return DiagnosticCheck(id: "mtu", title: "MTU", value: "\(mtu) байт",
                                   detail: "Значение слишком маленькое для обычного IPv6-трафика.",
                                   severity: .failure)
        }
        if mtu > 1500 {
            return DiagnosticCheck(id: "mtu", title: "MTU", value: "\(mtu) байт",
                                   detail: "Проверь, что внешний канал действительно поддерживает такой размер пакета.",
                                   severity: .warning)
        }
        return DiagnosticCheck(id: "mtu", title: "MTU", value: "\(mtu) байт",
                               detail: "Значение интерфейса выглядит безопасно для туннеля.",
                               severity: .pass)
    }
}
