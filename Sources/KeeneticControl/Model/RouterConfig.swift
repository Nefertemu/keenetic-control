import Foundation

/// Живое состояние пира WireGuard из `show interface`.
///
/// Имена полей и их смысл взяты из кода веб-панели самого роутера:
/// она читает `wireguard.peer[]` и берёт оттуда `public-key`,
/// `last-handshake`, `rxbytes`, `txbytes`, `endpoint` и `online`.
/// `last-handshake` — это СКОЛЬКО СЕКУНД НАЗАД было рукопожатие
/// (панель прогоняет его через тот же форматтер длительности, что и
/// время работы), а значение `2147483647` означает «не было ни разу».
struct WireGuardPeerState: Hashable {
    /// Сторож «рукопожатия не было» — ровно так его трактует панель.
    static let never = 2_147_483_647

    var publicKey: String = ""
    var endpoint: String = ""
    var online: Bool = false
    var received: Int = 0
    var sent: Int = 0
    /// Секунд назад. nil — рукопожатия не было.
    var handshakeAge: Int?

    var isFresh: Bool {
        guard online, let age = handshakeAge else { return false }
        // WireGuard шлёт keepalive обычно раз в 25 с; три минуты тишины —
        // это уже не «живой» туннель.
        return age <= 180
    }
}

/// Что роутер думает о проверке связи на интерфейсе прямо сейчас.
/// Разбор повторяет логику веб-панели: она смотрит в `details`,
/// и «running» считает единственным успешным состоянием.
enum PingCheckLiveState: Hashable {
    /// Профиль на интерфейс не назначен.
    case notConfigured
    /// Профиль есть, но роутер про проверку ничего не сказал. Это НЕ значит,
    /// что проверка падает, — мы просто не знаем. Показывать такое как
    /// состояние роутера нельзя, поэтому в сводке оно молчит.
    case unknown
    case passing
    case failing

    /// Есть ли что показать человеку.
    var isKnown: Bool { self == .passing || self == .failing }

    var title: String {
        switch self {
        case .notConfigured: return "проверки нет"
        case .unknown:       return "роутер не сообщил"
        case .passing:       return "связь есть"
        case .failing:       return "связи нет"
        }
    }

    /// Почему пусто — объяснение для подсказки.
    var explanation: String {
        switch self {
        case .notConfigured: return "Профиль Ping-Check на этот интерфейс не назначен."
        case .unknown:       return "Профиль назначен, но роутер не прислал результат проверки."
        case .passing:       return "Роутер проверяет связь, и она проходит."
        case .failing:       return "Роутер проверяет связь, и она не проходит."
        }
    }
}

struct KeeneticInterface: Identifiable, Hashable {
    var ident: String
    var descriptionText: String = ""
    var type: String = ""
    var link: String = ""
    var connected: String = ""
    var state: String = ""
    var isGlobal: String = ""
    var defaultGW: String = ""
    var securityLevel: String = ""
    var aliases: Set<String> = []
    /// Значение details["ping-check"]["status"], если роутер его прислал.
    var pingCheckStatus: String?
    /// Профиль и счётчики из `show ping-check` (если прошивка их показывает).
    var pingCheckProfile: String?
    var pingCheckFailureCount: Int?
    var pingCheckSuccessCount: Int?
    var pingCheckResolvedAddresses: [String] = []
    /// Пиры WireGuard с их живой статистикой.
    var peers: [WireGuardPeerState] = []

    var id: String { ident }

    var isUp: Bool { state == "up" || link == "up" || connected == "yes" }

    /// Имя, которое дал человек, — впереди: по нему и опознают интерфейс.
    /// Технический идентификатор идёт следом, он нужен для команд.
    var displayName: String {
        descriptionText.isEmpty ? ident : "\(descriptionText) · \(ident)"
    }

    /// Одно слово для тесных мест: примечание, если оно есть.
    var shortName: String { descriptionText.isEmpty ? ident : descriptionText }

    var statusText: String {
        var parts: [String] = []
        // Тип — собственное имя из прошивки (Wireguard, Vlan, GigabitEthernet),
        // его не переводим. А состояние — обычные слова, и они были по-английски
        // рядом с русским «шлюз по умолчанию».
        if !type.isEmpty { parts.append(type) }
        switch state.isEmpty ? link : state {
        case "up":   parts.append("включён")
        case "down": parts.append("выключен")
        case let other where !other.isEmpty: parts.append(other)
        default: break
        }
        if connected == "yes" { parts.append("есть связь") }
        if defaultGW == "yes" { parts.append("шлюз по умолчанию") }
        if isGlobal == "yes" { parts.append("выход в интернет") }
        return parts.joined(separator: ", ")
    }

    /// Состояние проверки связи. Назначен ли профиль, знает не сам
    /// интерфейс, а конфигурация — поэтому спрашиваем отдельно.
    func pingCheck(configured: Bool) -> PingCheckLiveState {
        guard configured else { return .notConfigured }
        guard let status = pingCheckStatus else { return .unknown }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        switch normalized {
        case "pass", "passed", "running", "ok", "up", "online", "ready":
            return .passing
        case "fail", "failed", "failure", "error", "down", "offline",
             "stopped", "not ready", "notready":
            return .failing
        default:
            return .unknown
        }
    }

    /// Самое свежее рукопожатие среди пиров — по нему судят о туннеле.
    var freshestHandshake: Int? {
        peers.compactMap(\.handshakeAge).min()
    }

    var isVPN: Bool {
        let haystack = ([ident, type, descriptionText] + aliases).joined(separator: " ")
        let lower = haystack.lowercased()
        if lower.contains("vpn server") || lower.contains("wireguard server")
            || lower.contains("wg server") || lower.contains("vpn-сервер")
            || lower.contains("сервер vpn") {
            return false
        }
        return RouterConfigParser.vpnPattern.firstMatch(
            in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
    }
}

/// Разбор имени интерфейса на семейство и номер: «Wireguard0» → «Wireguard» + «0».
/// Нужен, чтобы несколько соседних туннелей показывать одной строкой
/// «Wireguard 0, 3», а не повторять слово целиком для каждого.
enum InterfaceName {
    static func split(_ ident: String) -> (family: String, number: String?) {
        let digits = ident.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < ident.count else { return (ident, nil) }
        return (String(ident.dropLast(digits.count)), String(digits.reversed()))
    }
}

struct FqdnGroup: Identifiable, Hashable {
    var ident: String
    var descriptionText: String = ""
    var includes: Set<String> = []
    var routeLines: [String] = []

    var id: String { ident }
    var count: Int { includes.count }

    /// Маршруты в том порядке, в котором они лежат в running-config.
    /// Для резервирования порядок является частью конфигурации: одинаковый
    /// набор интерфейсов в другой последовательности — уже другой результат.
    var routeAssignments: [DnsRouteAssignment] {
        routeLines.compactMap(DnsRouteAssignment.parse)
    }

    /// На какие интерфейсы уже направлен этот список.
    var routedInterfaces: [String] {
        var result: [String] = []
        for line in routeLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = RouterConfigParser.routeTargetPattern.firstMatch(in: trimmed, range: range),
                  let captured = Range(match.range(at: 1), in: trimmed) else { continue }
            let value = String(trimmed[captured])
            if !result.contains(value) { result.append(value) }
        }
        return result
    }

    func isRouted(to interfaceIdent: String) -> Bool {
        let pattern = "(?:^|\\s)\(NSRegularExpression.escapedPattern(for: interfaceIdent))(?:\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return routeLines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
        }
    }
}

/// Нормализованная часть `dns-proxy route object-group`: целевой интерфейс
/// и два флага, которыми управляет приложение. Сырой текст специально не
/// участвует в сравнении — плоская и вложенная формы running-config означают
/// одно и то же.
struct DnsRouteAssignment: Hashable {
    var interface: String
    var auto: Bool
    var reject: Bool

    static func parse(_ line: String) -> DnsRouteAssignment? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 5,
              tokens[0] == "dns-proxy",
              tokens[1] == "route",
              tokens[2] == "object-group" else { return nil }
        let flags = Set(tokens.dropFirst(5).map { $0.lowercased() })
        return DnsRouteAssignment(interface: tokens[4],
                                  auto: flags.contains("auto"),
                                  reject: flags.contains("reject"))
    }
}

enum RouterConfigParser {
    static let vpnPattern = try! NSRegularExpression(
        pattern: "(wireguard|awg|amnezia|openvpn|openconnect|sstp|l2tp|pptp|pppoe|ipsec"
            + "|zerotier|gre|eoip|ipip|proxy|tun|tap|xray|vless)",
        options: [.caseInsensitive])

    static let routeTargetPattern = try! NSRegularExpression(
        pattern: "^dns-proxy\\s+route\\s+object-group\\s+\\S+\\s+(\\S+)")

    // MARK: - object-group fqdn

    static func parseFqdnGroups(_ text: String) -> [String: FqdnGroup] {
        var groups: [String: FqdnGroup] = [:]
        var currentIdent: String?

        let groupHead = try! NSRegularExpression(pattern: "^object-group\\s+fqdn\\s+(\\S+)\\s*$")

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let topLevel = !line.isEmpty && !(line.first?.isWhitespace ?? false)

            if let ident = capture(groupHead, in: trimmed, group: 1) {
                if groups[ident] == nil { groups[ident] = FqdnGroup(ident: ident) }
                currentIdent = ident
                continue
            }

            if topLevel { currentIdent = nil; continue }
            guard let ident = currentIdent else { continue }

            if trimmed.hasPrefix("description ") {
                groups[ident]?.descriptionText = CLI.unquote(String(trimmed.dropFirst("description ".count)))
                continue
            }
            if trimmed.hasPrefix("include ") {
                let value = CLI.unquote(String(trimmed.dropFirst("include ".count))).lowercased()
                if !value.isEmpty { groups[ident]?.includes.insert(value) }
            }
        }

        attachRoutes(&groups, text: text)
        return groups
    }

    /// Маршруты бывают в плоском и вложенном виде — поддерживаем оба.
    private static func attachRoutes(_ groups: inout [String: FqdnGroup], text: String) {
        let flat = try! NSRegularExpression(
            pattern: "^dns-proxy\\s+route\\s+object-group\\s+(\\S+)\\s+(.+)$")
        let nested = try! NSRegularExpression(
            pattern: "^route\\s+object-group\\s+(\\S+)\\s+(.+)$")

        var insideDNSProxy = false

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let topLevel = !line.isEmpty && !(line.first?.isWhitespace ?? false)
            if topLevel { insideDNSProxy = (trimmed == "dns-proxy") }

            var name: String?
            var routeLine = trimmed

            if let ident = capture(flat, in: trimmed, group: 1) {
                name = ident
            } else if insideDNSProxy, !topLevel, let ident = capture(nested, in: trimmed, group: 1) {
                name = ident
                routeLine = "dns-proxy " + trimmed
            }

            guard let ident = name else { continue }

            // Маршрут может ссылаться на список по имени, а не по идентификатору.
            var targetKey: String? = groups[ident] != nil ? ident : nil
            if targetKey == nil {
                // Описание не обязано быть уникальным, а порядок обхода
                // словаря не определён: без сортировки один и тот же конфиг
                // разбирался бы по-разному от запуска к запуску.
                targetKey = groups.filter { $0.value.descriptionText == ident }
                    .keys.sorted().first
            }
            guard let key = targetKey else { continue }

            if !(groups[key]?.routeLines.contains(routeLine) ?? true) {
                groups[key]?.routeLines.append(routeLine)
            }
        }
    }

    // MARK: - Интерфейсы

    static func parseConfigInterfaces(_ text: String) -> [String: KeeneticInterface] {
        var result: [String: KeeneticInterface] = [:]
        var currentIdent: String?
        let head = try! NSRegularExpression(pattern: "^interface\\s+(\\S+)\\s*$")

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let topLevel = !line.isEmpty && !(line.first?.isWhitespace ?? false)

            if let ident = capture(head, in: trimmed, group: 1) {
                if result[ident] == nil { result[ident] = KeeneticInterface(ident: ident) }
                currentIdent = ident
                continue
            }
            if topLevel { currentIdent = nil; continue }

            guard let ident = currentIdent, trimmed.hasPrefix("description ") else { continue }
            if result[ident]?.descriptionText.isEmpty ?? false {
                result[ident]?.descriptionText = CLI.unquote(String(trimmed.dropFirst("description ".count)))
            }
        }
        return result
    }

    /// Разбор текстового `show interface` (SSH).
    static func parseInterfaceStatus(_ text: String) -> [String: KeeneticInterface] {
        var result: [String: KeeneticInterface] = [:]
        var current: KeeneticInterface?

        func flush() {
            guard var item = current, !item.ident.isEmpty else { current = nil; return }
            if var existing = result[item.ident] {
                if !item.descriptionText.isEmpty { existing.descriptionText = item.descriptionText }
                if !item.type.isEmpty { existing.type = item.type }
                if !item.link.isEmpty { existing.link = item.link }
                if !item.connected.isEmpty { existing.connected = item.connected }
                if !item.state.isEmpty { existing.state = item.state }
                if !item.isGlobal.isEmpty { existing.isGlobal = item.isGlobal }
                if !item.defaultGW.isEmpty { existing.defaultGW = item.defaultGW }
                if !item.securityLevel.isEmpty { existing.securityLevel = item.securityLevel }
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
                existing.aliases.formUnion(item.aliases)
                result[item.ident] = existing
            } else {
                item.aliases.insert(item.ident)
                result[item.ident] = item
            }
            current = nil
        }

        let head = try! NSRegularExpression(
            pattern: "^Interface,\\s*name\\s*=\\s*\"?(.+?)\"?\\s*:\\s*$", options: [.caseInsensitive])
        let quotedID = try! NSRegularExpression(pattern: "^\"id\"\\s*:\\s*\"([^\"]+)\"\\s*,?\\s*$")
        let plainID = try! NSRegularExpression(pattern: "^id\\s*:\\s*(\\S+)\\s*$", options: [.caseInsensitive])
        let keyValue = try! NSRegularExpression(
            pattern: "^\"?([a-zA-Z0-9_-]+)\"?\\s*:\\s*\"?([^\",}]*)\"?\\s*,?\\s*$")

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let name = capture(head, in: line, group: 1) {
                flush()
                current = KeeneticInterface(ident: "", aliases: [name])
                continue
            }

            if let ident = capture(quotedID, in: line, group: 1) ?? capture(plainID, in: line, group: 1) {
                if let existing = current, !existing.ident.isEmpty, existing.ident != ident { flush() }
                if current == nil {
                    current = KeeneticInterface(ident: ident)
                } else {
                    current?.ident = ident
                }
                continue
            }

            guard current != nil,
                  let key = capture(keyValue, in: line, group: 1)?.lowercased(),
                  let value = capture(keyValue, in: line, group: 2)?.trimmingCharacters(in: .whitespaces)
            else { continue }

            apply(key: key, value: value, to: &current!)
        }

        flush()
        return result
    }

    /// Разбор `rci/show/interface` (HTTP RCI).
    static func parseInterfaceStatus(json: Any?) -> [String: KeeneticInterface] {
        guard let dictionary = json as? [String: Any] else { return [:] }
        var result: [String: KeeneticInterface] = [:]

        for (name, value) in dictionary {
            guard let payload = value as? [String: Any] else { continue }
            let ident = (payload["id"] as? String) ?? name
            var item = result[ident] ?? KeeneticInterface(ident: ident)
            item.aliases.insert(name)

            for (key, raw) in payload {
                let lowered = key.lowercased()

                // Вложенные объекты: проверка связи и пиры WireGuard.
                // Панель читает ping-check из details, но полагаться на точное
                // место не будем — ищем ключ на любой глубине.
                if lowered == "details", let details = raw as? [String: Any] {
                    item.pingCheckStatus = findPingCheckStatus(details)
                    continue
                }
                if lowered == "wireguard", let wireguard = raw as? [String: Any] {
                    item.peers = parsePeers(wireguard["peer"])
                    continue
                }

                let text: String
                switch raw {
                case let value as String: text = value
                case let value as Bool:   text = value ? "yes" : "no"
                case let value as NSNumber: text = value.stringValue
                default: continue
                }
                apply(key: lowered, value: text, to: &item)
            }
            result[ident] = item
        }
        return result
    }

    /// Состояние проверки связи внутри произвольно вложенного объекта.
    /// Возвращает nil, если роутер про неё ничего не сказал, — и это НЕ
    /// то же самое, что «проверка не проходит».
    static func findPingCheckStatus(_ value: Any?, depth: Int = 0) -> String? {
        guard depth < 4, let map = value as? [String: Any] else { return nil }

        if let check = map["ping-check"] {
            if let nested = check as? [String: Any] {
                return (nested["status"] as? String) ?? ""
            }
            if let text = check as? String { return text }
            return ""
        }
        for nested in map.values {
            if let found = findPingCheckStatus(nested, depth: depth + 1) { return found }
        }
        return nil
    }

    /// `wireguard.peer` бывает и массивом, и одиночным объектом.
    static func parsePeers(_ raw: Any?) -> [WireGuardPeerState] {
        let items: [[String: Any]]
        switch raw {
        case let array as [[String: Any]]: items = array
        case let single as [String: Any]:  items = [single]
        default: return []
        }

        return items.map { entry in
            var peer = WireGuardPeerState()
            peer.publicKey = (entry["public-key"] as? String) ?? ""
            peer.endpoint = (entry["remote-endpoint-address"] as? String)
                ?? (entry["endpoint"] as? String) ?? ""
            peer.online = (entry["online"] as? Bool)
                ?? ((entry["online"] as? NSNumber)?.boolValue ?? false)
            peer.received = (entry["rxbytes"] as? NSNumber)?.intValue ?? 0
            peer.sent = (entry["txbytes"] as? NSNumber)?.intValue ?? 0

            if let age = (entry["last-handshake"] as? NSNumber)?.intValue,
               age < WireGuardPeerState.never {
                peer.handshakeAge = age
            }
            return peer
        }
    }

    private static func apply(key: String, value: String, to item: inout KeeneticInterface) {
        switch key {
        case "description":     item.descriptionText = value
        case "type":            item.type = value
        case "link":            item.link = value
        case "connected":       item.connected = value
        case "state":           item.state = value
        case "global":          item.isGlobal = value
        case "defaultgw":       item.defaultGW = value
        case "security-level":  item.securityLevel = value
        case "interface-name":  if !value.isEmpty { item.aliases.insert(value) }
        default: break
        }
    }

    static func merge(config: [String: KeeneticInterface],
                      status: [String: KeeneticInterface]) -> [String: KeeneticInterface] {
        var merged = config
        for (ident, incoming) in status {
            var item = merged[ident] ?? KeeneticInterface(ident: ident)
            if !incoming.descriptionText.isEmpty { item.descriptionText = incoming.descriptionText }
            if !incoming.type.isEmpty { item.type = incoming.type }
            if !incoming.link.isEmpty { item.link = incoming.link }
            if !incoming.connected.isEmpty { item.connected = incoming.connected }
            if !incoming.state.isEmpty { item.state = incoming.state }
            if !incoming.isGlobal.isEmpty { item.isGlobal = incoming.isGlobal }
            if !incoming.defaultGW.isEmpty { item.defaultGW = incoming.defaultGW }
            if !incoming.securityLevel.isEmpty { item.securityLevel = incoming.securityLevel }
            if incoming.pingCheckStatus != nil { item.pingCheckStatus = incoming.pingCheckStatus }
            if incoming.pingCheckProfile != nil { item.pingCheckProfile = incoming.pingCheckProfile }
            if incoming.pingCheckFailureCount != nil {
                item.pingCheckFailureCount = incoming.pingCheckFailureCount
            }
            if incoming.pingCheckSuccessCount != nil {
                item.pingCheckSuccessCount = incoming.pingCheckSuccessCount
            }
            if !incoming.pingCheckResolvedAddresses.isEmpty {
                item.pingCheckResolvedAddresses = incoming.pingCheckResolvedAddresses
            }
            if !incoming.peers.isEmpty { item.peers = incoming.peers }
            item.aliases.formUnion(incoming.aliases)
            merged[ident] = item
        }
        return merged
    }

    /// Накладывает отдельный ответ `show ping-check` на уже разобранные
    /// интерфейсы. Статус может прийти раньше или позже `show interface`, а
    /// у некоторых прошивок интерфейс вообще есть только в этом ответе.
    static func applyPingCheck(_ infos: [String: PingCheckLiveInfo],
                               to interfaces: inout [String: KeeneticInterface]) {
        for (ident, info) in infos {
            var item = interfaces[ident] ?? KeeneticInterface(ident: ident)
            if let status = info.status { item.pingCheckStatus = status }
            if let profile = info.profile { item.pingCheckProfile = profile }
            if let count = info.failureCount { item.pingCheckFailureCount = count }
            if let count = info.successCount { item.pingCheckSuccessCount = count }
            if !info.resolvedAddresses.isEmpty {
                item.pingCheckResolvedAddresses = info.resolvedAddresses
            }
            item.aliases.insert(ident)
            interfaces[ident] = item
        }
    }

    /// Интерфейсы, на которые осмысленно вешать маршруты: VPN — первыми.
    static func likelyRouteInterfaces(_ items: [String: KeeneticInterface],
                                      wireGuardClients: Set<String>? = nil) -> [KeeneticInterface] {
        let all = Array(items.values)
        let accessPoint = try! NSRegularExpression(pattern: "^WifiMaster\\d+$")

        func isLocalOrService(_ item: KeeneticInterface) -> Bool {
            let ident = item.ident
            if ident.contains("/AccessPoint") { return true }
            let range = NSRange(ident.startIndex..., in: ident)
            if accessPoint.firstMatch(in: ident, range: range) != nil { return true }
            for prefix in ["Bridge", "Switch", "Loopback"] where ident.hasPrefix(prefix) { return true }
            return ["accesspoint", "radio", "bridge", "switch", "loopback"].contains(item.type.lowercased())
        }

        let eligible = all.filter { item in
            guard item.ident.range(of: "^Wireguard\\d+$", options: .regularExpression) != nil,
                  let wireGuardClients else { return true }
            return wireGuardClients.contains(item.ident)
        }
        let filtered = eligible.filter { !isLocalOrService($0) }
        let pool = filtered.isEmpty ? eligible : filtered

        func rank(_ item: KeeneticInterface) -> Int {
            if item.isVPN { return 0 }
            if item.defaultGW == "yes" || item.isGlobal == "yes" { return 1 }
            if item.securityLevel == "public" { return 2 }
            return 3
        }

        return pool.sorted { left, right in
            let lhs = (rank(left), left.isUp ? 0 : 1, left.ident.lowercased())
            let rhs = (rank(right), right.isUp ? 0 : 1, right.ident.lowercased())
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.2 < rhs.2
        }
    }

    static func sortedGroups(_ groups: [String: FqdnGroup]) -> [FqdnGroup] {
        let tail = try! NSRegularExpression(pattern: "(\\d+)$")
        func number(_ ident: String) -> Int {
            let range = NSRange(ident.startIndex..., in: ident)
            guard let match = tail.firstMatch(in: ident, range: range),
                  let captured = Range(match.range(at: 1), in: ident),
                  let value = Int(ident[captured]) else { return Int.max }
            return value
        }
        return groups.values.sorted {
            let lhs = number($0.ident), rhs = number($1.ident)
            return lhs == rhs ? $0.ident < $1.ident : lhs < rhs
        }
    }

    static func capture(_ regex: NSRegularExpression, in text: String, group: Int) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > group,
              let captured = Range(match.range(at: group), in: text) else { return nil }
        return String(text[captured])
    }
}
