import Foundation

/// A configuration explanation is deliberately not a prediction of live traffic.
/// DNS answers, active routes and per-client policies are separate router state.
struct RouteExplanationQuery: Equatable {
    enum Kind: Equatable { case domain, ipv4, ipv6 }
    let value: String
    let kind: Kind

    static func parse(_ input: String) throws -> Self {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count <= 8_192,
              !host.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw TransportError("Введи один домен, URL или IP-адрес без пробелов.")
        }
        if host.contains("://") {
            guard let url = URLComponents(string: host), let name = url.host, !name.isEmpty else {
                throw TransportError("В URL не удалось найти адрес сайта.")
            }
            host = name
        }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        // Darwin may accept a scoped literal while dropping its zone. A Mac
        // zone (for example %en0) cannot identify an interface on the router.
        guard !host.contains("%") else {
            throw TransportError("Укажи IPv6-адрес без зоны интерфейса: зона Mac не описывает интерфейс роутера.")
        }
        if let address = IPTools.parseIPv4(host) {
            return Self(value: IPTools.formatIPv4(address), kind: .ipv4)
        }
        if let address = IPTools.parseIPv6(host) {
            return Self(value: IPTools.formatIPv6(address), kind: .ipv6)
        }
        // A search is one host, not a source-list line: accepting hosts syntax,
        // wildcards or an IP network here would silently change the question.
        guard !host.contains(where: { "/:*|^@?#[]%".contains($0) }) else {
            throw TransportError("Нужен домен или отдельный IP-адрес. Для ссылки укажи https:// в начале.")
        }
        host = host.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: "．", with: ".")
            .replacingOccurrences(of: "｡", with: ".")
        guard !host.hasPrefix("."), !host.hasSuffix(".."),
              let value = Domains.normalize(host), !value.contains("/"), !IPTools.isIP(value) else {
            throw TransportError("Не удалось распознать домен. Например: example.org или https://example.org/page.")
        }
        return Self(value: value, kind: .domain)
    }
}

struct RouteExplanationEntry: Identifiable {
    enum Kind { case exactDomain, domainSuffix, address, subnet }
    let value: String
    let kind: Kind
    /// Domain label count or IP prefix length, for explaining specificity.
    let specificity: Int
    var id: String { value }
    var reason: String {
        switch kind {
        case .exactDomain: return "точное имя"
        case .domainSuffix: return "включает этот поддомен"
        case .address: return "точный IP-адрес"
        case .subnet: return "адрес входит в подсеть /\(specificity)"
        }
    }
}

struct RouteExplanationStep: Identifiable {
    let position: Int
    let target: String
    let label: String
    let interface: String?
    let auto: Bool
    let reject: Bool
    let rawLine: String
    var id: Int { position }

    /// Also understands the documented gateway + interface form. Unknown
    /// options are shown as unparsed rules instead of guessing their meaning.
    static func parse(_ line: String, position: Int, state: RouterState) -> Self? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 5, Array(tokens.prefix(3)) == ["dns-proxy", "route", "object-group"] else { return nil }
        var rest = Array(tokens.dropFirst(4))
        var flags = Set<String>()
        while let last = rest.last, ["auto", "reject"].contains(last) {
            guard flags.insert(last).inserted else { return nil }
            rest.removeLast()
        }
        guard rest.count == 1 || (rest.count == 2 && IPTools.isIP(rest[0])),
              rest.allSatisfy({ !["auto", "reject"].contains($0) }) else { return nil }
        let interface = IPTools.isIP(rest.last!) ? nil : rest.last!
        let target = rest.joined(separator: " ")
        let label: String
        if let interface {
            label = rest.count == 2 ? "\(state.label(for: interface)) · шлюз \(rest[0])" : state.label(for: interface)
        } else {
            label = "Шлюз \(target)"
        }
        return Self(position: position, target: target, label: label, interface: interface,
                    auto: flags.contains("auto"), reject: flags.contains("reject"), rawLine: line)
    }
}

struct RouteExplanationGroup: Identifiable {
    let ident: String
    let name: String
    let entries: [RouteExplanationEntry]
    let steps: [RouteExplanationStep]
    let unparsedRules: [String]
    var id: String { ident }
    var specificity: Int { entries.map(\.specificity).max() ?? 0 }
}

struct RouteExplanationStaticMatch: Identifiable {
    let route: StaticRoute
    let prefix: Int
    let targetLabel: String
    var id: String { route.id }
}

struct RouteExplanationReport {
    let query: RouteExplanationQuery
    let readAt: Date
    let groups: [RouteExplanationGroup]
    let staticRoutes: [RouteExplanationStaticMatch]
    let unsupportedStaticCount: Int
    var longestStaticPrefix: Int? { staticRoutes.first(where: { !$0.route.disabled })?.prefix }
    var hasMatches: Bool { !groups.isEmpty || !staticRoutes.isEmpty }
    var hasCompetingLists: Bool { groups.filter { !$0.steps.isEmpty || !$0.unparsedRules.isEmpty }.count > 1 }
}

enum RouteExplanation {
    static func explain(_ input: String, state: RouterState) throws -> RouteExplanationReport {
        let query = try RouteExplanationQuery.parse(input)
        var groups: [RouteExplanationGroup] = []
        for group in state.sortedGroups {
            try Task.checkCancellation()
            var seenEntries = Set<String>()
            let entries = group.includes.compactMap { match($0, query: query) }
                .filter { seenEntries.insert($0.value).inserted }.sorted {
                $0.specificity == $1.specificity ? $0.value < $1.value : $0.specificity > $1.specificity
            }
            guard !entries.isEmpty else { continue }
            let steps = group.routeLines.enumerated().compactMap {
                RouteExplanationStep.parse($0.element, position: $0.offset + 1, state: state)
            }
            let parsedPositions = Set(steps.map(\.position))
            groups.append(RouteExplanationGroup(
                ident: group.ident, name: group.descriptionText.isEmpty ? group.ident : group.descriptionText,
                entries: entries, steps: steps,
                unparsedRules: group.routeLines.enumerated().filter { !parsedPositions.contains($0.offset + 1) }.map(\.element)))
        }
        groups.sort { $0.specificity == $1.specificity ? $0.ident < $1.ident : $0.specificity > $1.specificity }

        let unparsed = StaticRouteParser.parseWithDiagnostics(config: state.configText).problems
        var seen = Set<String>()
        let routes = state.staticRoutes.filter { seen.insert($0.id).inserted }
        let staticMatches: [RouteExplanationStaticMatch] = query.kind == .domain ? [] : routes.compactMap { route in
            guard (query.kind == .ipv4) == (route.family == .ipv4) else { return nil }
            let network = route.destination == "default"
                ? (route.family == .ipv4 ? "0.0.0.0/0" : "::/0") : route.destination
            guard let prefix = contains(network: network, address: query.value) else { return nil }
            let target = route.via.split(whereSeparator: \.isWhitespace).map(String.init)
            let label: String
            if target.count == 2 {
                let gatewayIndex = IPTools.isIP(target[0]) ? 0 : 1
                label = "\(state.label(for: target[1 - gatewayIndex])) · шлюз \(target[gatewayIndex])"
            } else {
                label = IPTools.isIP(route.via) ? "Шлюз \(route.via)" : state.label(for: route.via)
            }
            return RouteExplanationStaticMatch(route: route, prefix: prefix, targetLabel: label)
        }.sorted {
            // Equal prefixes are peers: metric and liveness do not establish a
            // winner from running-config alone. Preserve their configuration order.
            $0.prefix > $1.prefix
        }
        return RouteExplanationReport(query: query, readAt: state.readAt, groups: groups,
                                      staticRoutes: staticMatches, unsupportedStaticCount: unparsed.count)
    }

    private static func match(_ raw: String, query: RouteExplanationQuery) -> RouteExplanationEntry? {
        guard let value = Domains.normalize(raw) else { return nil }
        if query.kind == .domain {
            guard !value.contains("/"), !IPTools.isIP(value),
                  query.value == value || query.value.hasSuffix("." + value) else { return nil }
            return RouteExplanationEntry(value: value, kind: value == query.value ? .exactDomain : .domainSuffix,
                                         specificity: value.split(separator: ".").count)
        }
        guard let prefix = contains(network: value, address: query.value) else { return nil }
        return RouteExplanationEntry(value: value, kind: value.contains("/") ? .subnet : .address, specificity: prefix)
    }

    /// Returns the matching prefix, including /32 and /128 for plain addresses.
    static func contains(network: String, address: String) -> Int? {
        let parts = network.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let host = String(parts[0])
        if let destination = IPTools.parseIPv4(address), let base = IPTools.parseIPv4(host) {
            guard let prefix = parts.count == 1 ? 32 : Int(parts[1]), (0...32).contains(prefix) else { return nil }
            let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
            return destination & mask == base & mask ? prefix : nil
        }
        if let destination = IPTools.parseIPv6(address), let base = IPTools.parseIPv6(host) {
            guard let prefix = parts.count == 1 ? 128 : Int(parts[1]), (0...128).contains(prefix) else { return nil }
            for index in 0..<16 {
                let bits = min(8, max(0, prefix - index * 8))
                let mask: UInt8 = bits == 0 ? 0 : 0xff << UInt8(8 - bits)
                if destination[index] & mask != base[index] & mask { return nil }
            }
            return prefix
        }
        return nil
    }

}
