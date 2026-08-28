import Foundation

struct StaticRoute: Identifiable, Hashable {
    enum Family: String, CaseIterable, Identifiable {
        case ipv4, ipv6
        var id: String { rawValue }
        var title: String { self == .ipv4 ? "IPv4" : "IPv6" }
        var keyword: String { self == .ipv4 ? "ip route" : "ipv6 route" }
    }

    var family: Family = .ipv4
    /// «default», «10.0.0.0/8», «1.2.3.4» — в человекочитаемом виде.
    var destination: String = ""
    /// Интерфейс или адрес шлюза.
    var via: String = ""
    var auto: Bool = true
    var reject: Bool = false
    var comment: String = ""
    /// Строка из running-config — по ней и удаляем.
    var rawLine: String = ""

    var id: String { rawLine.isEmpty ? command : rawLine }

    var searchText: String {
        [destination, via, comment, family.title].joined(separator: " ").lowercased()
    }

    /// Команда добавления в терминах Keenetic CLI.
    var command: String {
        var text = "\(family.keyword) \(destinationCLI) \(via)"
        if auto { text += " auto" }
        if reject { text += " reject" }
        if !comment.isEmpty {
            text += " !" + comment.replacingOccurrences(of: "!", with: " ")
        }
        return text
    }

    var deleteCommand: String {
        "no " + (rawLine.isEmpty ? command : rawLine)
    }

    private var destinationCLI: String {
        let value = destination.trimmingCharacters(in: .whitespaces)
        if value.lowercased() == "default" { return "default" }

        if family == .ipv4 {
            if value.contains("/"), let parsed = IPTools.ipv4CIDRToAddressMask(value) {
                return "\(parsed.address) \(parsed.mask)"
            }
            return value
        }

        if value.contains("/") { return value }
        return IPTools.isIPv6(value) ? "\(value)/128" : value
    }

    static func validate(family: Family, destination: String, via: String) throws {
        let destination = destination.trimmingCharacters(in: .whitespaces)
        let via = via.trimmingCharacters(in: .whitespaces)

        guard !destination.isEmpty else { throw TransportError("Укажи сеть или узел назначения.") }
        guard !via.isEmpty else { throw TransportError("Укажи интерфейс или шлюз.") }
        guard !via.contains("!"), !via.contains("\n") else { throw TransportError("Некорректный интерфейс или шлюз.") }
        if destination.lowercased() == "default" { return }

        if family == .ipv4 {
            if destination.contains("/") {
                guard IPTools.ipv4CIDRToAddressMask(destination) != nil else {
                    throw TransportError("Некорректный IPv4/CIDR: \(destination)")
                }
            } else if !IPTools.isIPv4(destination) {
                throw TransportError("Некорректный IPv4: \(destination)")
            }
        } else {
            if destination.contains("/") {
                let parts = destination.split(separator: "/", maxSplits: 1)
                guard parts.count == 2, IPTools.isIPv6(String(parts[0])),
                      let prefix = Int(parts[1]), (0...128).contains(prefix) else {
                    throw TransportError("Некорректный IPv6/CIDR: \(destination)")
                }
            } else if !IPTools.isIPv6(destination) {
                throw TransportError("Некорректный IPv6: \(destination)")
            }
        }
    }
}

enum StaticRouteParser {
    /// Разбирает `ip route` / `ipv6 route` из running-config.
    static func parse(config text: String) -> [StaticRoute] {
        var routes: [StaticRoute] = []
        // Идентификатор маршрута — его строка. Повтор в конфигурации дал бы
        // два элемента с одним id: ForEach на таком ломается, а выделение
        // цепляло бы оба сразу.
        var seen = Set<String>()

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard !line.isEmpty, !(line.first?.isWhitespace ?? false) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let route = parse(line: trimmed), seen.insert(route.id).inserted else { continue }
            routes.append(route)
        }
        return routes
    }

    static func parse(line: String) -> StaticRoute? {
        var text = line.trimmingCharacters(in: .whitespaces)

        let family: StaticRoute.Family
        if text.hasPrefix("ip route ") {
            family = .ipv4
            text = String(text.dropFirst("ip route ".count))
        } else if text.hasPrefix("ipv6 route ") {
            family = .ipv6
            text = String(text.dropFirst("ipv6 route ".count))
        } else {
            return nil
        }

        var route = StaticRoute(family: family, rawLine: line.trimmingCharacters(in: .whitespaces))

        // Комментарий отделён восклицательным знаком.
        if let mark = text.firstIndex(of: "!") {
            route.comment = String(text[text.index(after: mark)...]).trimmingCharacters(in: .whitespaces)
            text = String(text[text.startIndex..<mark]).trimmingCharacters(in: .whitespaces)
        }

        var tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return nil }

        // Флаги в хвосте.
        var flags: [String] = []
        while let last = tokens.last?.lowercased(),
              ["auto", "reject", "!"].contains(last) {
            flags.append(last)
            tokens.removeLast()
        }
        route.auto = flags.contains("auto")
        route.reject = flags.contains("reject")

        // Необязательная метрика.
        if tokens.count >= 2, tokens[tokens.count - 2].lowercased() == "metric" {
            tokens.removeLast(2)
        }

        guard !tokens.isEmpty else { return nil }
        let head = tokens.removeFirst()

        if head.lowercased() == "default" {
            route.destination = "default"
        } else if head.lowercased() == "host", !tokens.isEmpty {
            route.destination = tokens.removeFirst()
        } else if family == .ipv4, let mask = tokens.first,
                  let prefix = IPTools.ipv4MaskToPrefix(mask) {
            tokens.removeFirst()
            route.destination = prefix == 32 ? head : "\(head)/\(prefix)"
        } else {
            route.destination = head
        }

        route.via = tokens.joined(separator: " ")
        guard !route.via.isEmpty else { return nil }
        return route
    }

    /// Импорт из Windows-BAT, CMD и текстовых списков.
    /// Понимает и `route add …`, и готовые строки `ip route …`.
    static func parseImport(_ text: String) -> (routes: [StaticRoute], skipped: [String]) {
        var routes: [StaticRoute] = []
        var skipped: [String] = []
        var seen = Set<String>()

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.lowercased().hasPrefix("@echo") || line.lowercased().hasPrefix("rem ")
                || line.hasPrefix("::") || line.hasPrefix("#") { continue }
            if line.lowercased().hasPrefix("chcp") || line.lowercased() == "pause" { continue }

            var route: StaticRoute?

            if line.lowercased().hasPrefix("ip route ") || line.lowercased().hasPrefix("ipv6 route ") {
                route = parse(line: line)
            } else {
                if line.lowercased().hasPrefix("route ") { line = String(line.dropFirst("route ".count)) }
                route = parseWindowsRoute(line)
            }

            guard var found = route else {
                skipped.append(line)
                continue
            }
            found.rawLine = ""
            let key = found.command
            if seen.contains(key) { continue }
            seen.insert(key)
            routes.append(found)
        }

        return (routes, skipped)
    }

    /// `add 1.2.3.0 mask 255.255.255.0 192.168.1.1 metric 1`
    private static func parseWindowsRoute(_ line: String) -> StaticRoute? {
        var tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        if tokens[0].lowercased() == "add" || tokens[0].lowercased() == "-p" { tokens.removeFirst() }
        if tokens.first?.lowercased() == "add" { tokens.removeFirst() }
        guard let destination = tokens.first else { return nil }
        tokens.removeFirst()

        var route = StaticRoute()

        if destination.contains(":") {
            route.family = .ipv6
            route.destination = destination
        } else if destination.contains("/") {
            guard IPTools.ipv4CIDRToAddressMask(destination) != nil else { return nil }
            route.destination = destination
        } else {
            guard IPTools.isIPv4(destination) else { return nil }
            route.destination = destination
        }

        var mask: String?
        var index = 0
        while index < tokens.count {
            let token = tokens[index].lowercased()
            if token == "mask", index + 1 < tokens.count {
                mask = tokens[index + 1]
                index += 2
                continue
            }
            if token == "metric" || token == "if" { index += 2; continue }
            if token == "-p" { index += 1; continue }
            if route.via.isEmpty { route.via = tokens[index] }
            index += 1
        }

        if let mask, let prefix = IPTools.ipv4MaskToPrefix(mask), !route.destination.contains("/") {
            route.destination = prefix == 32 ? route.destination : "\(route.destination)/\(prefix)"
        }

        guard !route.via.isEmpty else { return nil }
        return route
    }

    /// Что Windows не умеет: IPv6, запрещающие маршруты и маршрут по умолчанию.
    /// Раньше такие строки просто исчезали из выгрузки — без единого слова.
    static func batUnsupported(_ routes: [StaticRoute]) -> [StaticRoute] {
        routes.filter { $0.family != .ipv4 || $0.reject || $0.destination.lowercased() == "default" }
    }

    /// Экспорт в BAT — так же, как это делает windows-версия.
    static func exportBAT(_ routes: [StaticRoute]) -> String {
        var lines = ["@echo off", "chcp 65001 > nul", "rem Экспорт маршрутов Keenetic — \(Format.humanDate(Date()))", ""]

        let unsupported = Set(batUnsupported(routes).map(\.id))
        for route in routes {
            // Непереносимое остаётся в файле комментарием: из выгрузки
            // ничего не пропадает молча.
            guard !unsupported.contains(route.id) else {
                lines.append("rem не переносится в Windows: "
                             + (route.rawLine.isEmpty ? route.command : route.rawLine))
                continue
            }
            let destination = route.destination

            let address: String
            let mask: String
            if destination.contains("/"), let parsed = IPTools.ipv4CIDRToAddressMask(destination) {
                address = parsed.address
                mask = parsed.mask
            } else {
                address = destination
                mask = "255.255.255.255"
            }

            var line = "route -p add \(address) mask \(mask) \(route.via)"
            if !route.comment.isEmpty { line += "  rem \(route.comment)" }
            lines.append(line)
        }

        lines.append("")
        lines.append("pause")
        return lines.joined(separator: "\r\n")
    }

    /// Экспорт в формате команд Keenetic — чтобы залить на другой роутер.
    static func exportCLI(_ routes: [StaticRoute]) -> String {
        routes.map { $0.rawLine.isEmpty ? $0.command : $0.rawLine }.joined(separator: "\n") + "\n"
    }
}
