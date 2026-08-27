import Foundation

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

    var id: String { ident }

    var isUp: Bool { state == "up" || link == "up" || connected == "yes" }

    var displayName: String {
        descriptionText.isEmpty ? ident : "\(ident) · \(descriptionText)"
    }

    var statusText: String {
        var parts: [String] = []
        if !type.isEmpty { parts.append(type) }
        let status = state.isEmpty ? link : state
        if !status.isEmpty { parts.append(status) }
        if connected == "yes" { parts.append("connected") }
        if defaultGW == "yes" { parts.append("шлюз по умолчанию") }
        if isGlobal == "yes" { parts.append("global") }
        return parts.joined(separator: ", ")
    }

    var isVPN: Bool {
        let haystack = ([ident, type, descriptionText] + aliases).joined(separator: " ")
        return RouterConfigParser.vpnPattern.firstMatch(
            in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
    }
}

struct FqdnGroup: Identifiable, Hashable {
    var ident: String
    var descriptionText: String = ""
    var includes: Set<String> = []
    var routeLines: [String] = []

    var id: String { ident }
    var count: Int { includes.count }

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
                targetKey = groups.first { $0.value.descriptionText == ident }?.key
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
                let text: String
                switch raw {
                case let value as String: text = value
                case let value as Bool:   text = value ? "yes" : "no"
                case let value as NSNumber: text = value.stringValue
                default: continue
                }
                apply(key: key.lowercased(), value: text, to: &item)
            }
            result[ident] = item
        }
        return result
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
            item.aliases.formUnion(incoming.aliases)
            merged[ident] = item
        }
        return merged
    }

    /// Интерфейсы, на которые осмысленно вешать маршруты: VPN — первыми.
    static func likelyRouteInterfaces(_ items: [String: KeeneticInterface]) -> [KeeneticInterface] {
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

        let filtered = all.filter { !isLocalOrService($0) }
        let pool = filtered.isEmpty ? all : filtered

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
