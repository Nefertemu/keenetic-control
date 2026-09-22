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
    /// Интерфейс, адрес шлюза или шлюз и интерфейс через пробел.
    var via: String = ""
    /// Приоритет маршрута. Его нельзя терять при импорте/откате: от метрики
    /// зависит, какой из одинаковых маршрутов выберет роутер.
    var metric: Int?
    var auto: Bool = true
    var reject: Bool = false
    var disabled: Bool = false
    var comment: String = ""
    /// Строка из running-config — по ней и удаляем.
    var rawLine: String = ""

    var id: String {
        (rawLine.isEmpty ? command : rawLine) + (disabled ? "\n\(family.keyword) disable" : "")
    }

    /// A disabled route is represented by two adjacent CLI commands. Keep the
    /// setting in comparisons without making command a multiline CLI string.
    var configurationKey: String { additionCommands.joined(separator: "\n") }
    var additionCommands: [String] {
        disabled ? [command, "\(family.keyword) disable"] : [command]
    }

    var searchText: String {
        [destination, via, metric.map(String.init) ?? "", comment, family.title, disabled ? "отключён disabled" : ""]
            .joined(separator: " ").lowercased()
    }

    /// Команда добавления в терминах Keenetic CLI.
    var command: String {
        var text = "\(family.keyword) \(destinationCLI) \(via)"
        if let metric { text += " metric \(metric)" }
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

    static func validate(family: Family, destination: String, via: String,
                         metric: Int? = nil, comment: String = "") throws {
        guard !containsControl(via) else {
            throw TransportError("Интерфейс или шлюз содержит служебные символы.")
        }
        let destination = destination.trimmingCharacters(in: .whitespaces)
        let via = via.trimmingCharacters(in: .whitespaces)

        guard !destination.isEmpty else { throw TransportError("Укажи сеть или узел назначения.") }
        guard !via.isEmpty else { throw TransportError("Укажи интерфейс или шлюз.") }
        try validateVia(via, family: family)
        guard !containsControl(comment) else {
            throw TransportError("Комментарий не может содержать перевод строки или служебные символы.")
        }
        if let metric, metric < 0 { throw TransportError("Метрика не может быть отрицательной.") }
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
                let parts = destination.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, IPTools.isIPv6(String(parts[0])),
                      let prefix = Int(parts[1]), (0...128).contains(prefix) else {
                    throw TransportError("Некорректный IPv6/CIDR: \(destination)")
                }
            } else if !IPTools.isIPv6(destination) {
                throw TransportError("Некорректный IPv6: \(destination)")
            }
        }
    }

    /// Keenetic accepts an interface, a gateway, or a gateway followed by its
    /// interface. The latter is common for default routes received from an ISP.
    /// Accept that documented pair without opening the field to CLI options.
    private static func validateVia(_ value: String, family: Family) throws {
        guard !containsControl(value), !value.contains(where: { "!;\"'\\".contains($0) }) else {
            throw TransportError("Интерфейс или шлюз содержит служебные символы.")
        }
        let parts = value.split(separator: " ").map(String.init)
        func gateway(_ token: String) -> Bool {
            guard !token.contains("%") else { return false }
            return family == .ipv4 ? IPTools.isIPv4(token) : IPTools.isIPv6(token)
        }
        func interface(_ token: String) -> Bool {
            guard !["auto", "reject", "metric", "default", "host", "no"].contains(token.lowercased()),
                  !IPTools.isIP(token) else { return false }
            return token.range(of: #"^[A-Za-z][A-Za-z0-9_./-]*$"#, options: .regularExpression) != nil
        }
        let valid: Bool
        switch parts.count {
        case 1: valid = gateway(parts[0]) || interface(parts[0])
        case 2:
            // IPv6's documented CLI order is interface + gateway; preserve
            // the gateway + interface form emitted by other configurations.
            valid = (gateway(parts[0]) && interface(parts[1]))
                || (family == .ipv6 && interface(parts[0]) && gateway(parts[1]))
        default: valid = false
        }
        guard valid else {
            throw TransportError("Укажи интерфейс, IP-шлюз нужного семейства или шлюз и интерфейс через пробел.",
                                 hint: "Например: ISP, 192.168.1.1 или 192.168.1.1 ISP. Флаги auto, reject и метрика задаются отдельно.")
        }
    }

    private static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

enum StaticRouteParser {
    /// Разбирает `ip route` / `ipv6 route` из running-config.
    static func parse(config text: String) -> [StaticRoute] {
        parseWithDiagnostics(config: text).routes
    }

    /// `ip route disable` affects the route immediately before it. It is not a
    /// standalone route or a global routing switch. Keep unknown/orphan forms
    /// visible to backup validation and offline route explanations.
    /// Keenetic 5.0 discussion: https://forum.keenetic.ru/topic/23888/
    static func parseWithDiagnostics(config text: String) -> (routes: [StaticRoute], problems: [String]) {
        var routes: [StaticRoute] = []
        var problems: [String] = []
        var pendingIndex: Int?
        // Идентификатор маршрута — его строка. Повтор в конфигурации дал бы
        // два элемента с одним id: ForEach на таком ломается, а выделение
        // цепляло бы оба сразу.
        for raw in CLI.normalizeNewlines(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard !line.isEmpty, !(line.first?.isWhitespace ?? false) else {
                pendingIndex = nil
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let family = disableFamily(trimmed) {
                if let index = pendingIndex, routes[index].family == family, !routes[index].disabled {
                    routes[index].disabled = true
                } else { problems.append(trimmed) }
                pendingIndex = nil
            } else if let route = parse(line: trimmed) {
                routes.append(route)
                pendingIndex = routes.count - 1
            } else {
                pendingIndex = nil
                if trimmed.lowercased().hasPrefix("ip route ") || trimmed.lowercased().hasPrefix("ipv6 route ") {
                    problems.append(trimmed)
                }
            }
        }
        var seen = Set<String>()
        return (routes.filter { seen.insert($0.configurationKey).inserted }, problems)
    }

    private static func disableFamily(_ line: String) -> StaticRoute.Family? {
        switch line.lowercased() {
        case "ip route disable": return .ipv4
        case "ipv6 route disable": return .ipv6
        default: return nil
        }
    }

    static func hasInvalidDisable(in skipped: [String]) -> Bool {
        skipped.contains { line in
            let tokens = line.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            return Array(tokens.prefix(3)) == ["ip", "route", "disable"]
                || Array(tokens.prefix(3)) == ["ipv6", "route", "disable"]
        }
    }

    static func parse(line: String) -> StaticRoute? {
        var text = line.trimmingCharacters(in: .whitespaces)

        let family: StaticRoute.Family
        if text.lowercased().hasPrefix("ip route ") {
            family = .ipv4
            text = String(text.dropFirst("ip route ".count))
        } else if text.lowercased().hasPrefix("ipv6 route ") {
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
            guard let value = Int(tokens[tokens.count - 1]), value >= 0 else { return nil }
            route.metric = value
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
        guard (try? StaticRoute.validate(family: route.family,
                                         destination: route.destination,
                                         via: route.via,
                                         metric: route.metric,
                                         comment: route.comment)) != nil else { return nil }
        return route
    }

    /// Импорт из Windows-BAT, CMD и текстовых списков.
    /// Понимает и `route add …`, и готовые строки `ip route …`.
    static func parseImport(_ text: String) -> (routes: [StaticRoute], skipped: [String]) {
        var routes: [StaticRoute] = []
        var skipped: [String] = []
        var pendingIndex: Int?

        for raw in CLI.normalizeNewlines(text).split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { pendingIndex = nil; continue }
            if line.lowercased().hasPrefix("@echo") || line.lowercased().hasPrefix("rem ")
                || line.hasPrefix("::") || line.hasPrefix("#") { pendingIndex = nil; continue }
            if line.lowercased().hasPrefix("chcp") || line.lowercased() == "pause" { pendingIndex = nil; continue }
            if line.lowercased() == "setlocal disabledelayedexpansion"
                || line.lowercased() == "endlocal" { pendingIndex = nil; continue }

            if let family = disableFamily(line) {
                if let index = pendingIndex, routes[index].family == family, !routes[index].disabled {
                    routes[index].disabled = true
                } else { skipped.append(line) }
                pendingIndex = nil
                continue
            }

            var route: StaticRoute?

            let isCLI = line.lowercased().hasPrefix("ip route ") || line.lowercased().hasPrefix("ipv6 route ")
            if isCLI {
                route = parse(line: line)
            } else {
                if line.lowercased().hasPrefix("route ") { line = String(line.dropFirst("route ".count)) }
                route = parseWindowsRoute(line)
            }

            guard var found = route else {
                pendingIndex = nil
                skipped.append(line)
                continue
            }
            found.rawLine = ""
            routes.append(found)
            pendingIndex = isCLI ? routes.count - 1 : nil
        }

        var seen = Set<String>()
        return (routes.filter { seen.insert($0.configurationKey).inserted }, skipped)
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
        var hasInterface = false
        var hasPersistent = false
        var index = 0
        while index < tokens.count {
            let token = tokens[index].lowercased()
            if token == "mask" {
                guard mask == nil, route.family == .ipv4, index + 1 < tokens.count,
                      IPTools.ipv4MaskToPrefix(tokens[index + 1]) != nil else { return nil }
                mask = tokens[index + 1]
                index += 2
                continue
            }
            if token == "metric" {
                guard route.metric == nil, index + 1 < tokens.count,
                      let metric = Int(tokens[index + 1]), metric >= 0 else { return nil }
                route.metric = metric
                index += 2
                continue
            }
            if token == "if" {
                // Индекс сетевой карты Windows не является именем интерфейса
                // Keenetic, но неполную или ошибочную запись принимать нельзя.
                guard !hasInterface, index + 1 < tokens.count,
                      let value = Int(tokens[index + 1]), value > 0 else { return nil }
                hasInterface = true
                index += 2
                continue
            }
            if token == "-p" {
                guard !hasPersistent else { return nil }
                hasPersistent = true
                index += 1
                continue
            }
            // Старые версии приложения дописывали rem в конец команды.
            // Сохраняем возможность импортировать такие выгрузки.
            if token == "rem", !route.via.isEmpty {
                route.comment = tokens.dropFirst(index + 1).joined(separator: " ")
                break
            }
            guard route.via.isEmpty else { return nil }
            route.via = tokens[index]
            index += 1
        }

        if let mask, let prefix = IPTools.ipv4MaskToPrefix(mask) {
            if route.destination.contains("/") {
                guard let cidr = IPTools.ipv4CIDRToAddressMask(route.destination), cidr.mask == mask else {
                    return nil
                }
            } else {
                route.destination = prefix == 32 ? route.destination : "\(route.destination)/\(prefix)"
            }
        }

        guard !route.via.isEmpty else { return nil }
        guard (try? StaticRoute.validate(family: route.family, destination: route.destination,
                                         via: route.via, metric: route.metric,
                                         comment: route.comment)) != nil else { return nil }
        return route
    }

    /// В Windows вместо интерфейса Keenetic нужен IPv4-адрес шлюза.
    /// Раньше такие строки просто исчезали из выгрузки — без единого слова.
    static func batUnsupported(_ routes: [StaticRoute]) -> [StaticRoute] {
        routes.filter {
            $0.disabled || $0.family != .ipv4 || $0.reject || $0.destination.lowercased() == "default"
                || !IPTools.isIPv4($0.via)
        }
    }

    /// Экспорт в BAT — так же, как это делает windows-версия.
    static func exportBAT(_ routes: [StaticRoute]) -> String {
        var lines = ["@echo off", "setlocal DisableDelayedExpansion", "chcp 65001 > nul",
                     "rem Экспорт маршрутов Keenetic — \(Format.humanDate(Date()))", ""]

        let unsupported = Set(batUnsupported(routes).map(\.id))
        for route in routes {
            // Непереносимое остаётся в файле комментарием: из выгрузки
            // ничего не пропадает молча.
            guard !unsupported.contains(route.id) else {
                lines.append("rem " + (route.disabled ? "отключён, не переносится в Windows: " : "не переносится в Windows: ")
                             + batComment(route.rawLine.isEmpty ? route.command : route.rawLine))
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
            if let metric = route.metric { line += " metric \(metric)" }
            if !route.comment.isEmpty { lines.append("rem " + batComment(route.comment)) }
            lines.append(line)
        }

        lines.append("")
        lines.append("endlocal")
        lines.append("pause")
        return lines.joined(separator: "\r\n")
    }

    /// REM — отдельная команда cmd.exe; метасимволы даже в комментарии
    /// способны перенаправить вывод или запустить следующую команду.
    private static func batComment(_ text: String) -> String {
        text.map { character -> String in
            if character.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { return " " }
            if character == "%" { return "%%" }
            if "^&|<>()\"".contains(character) { return "^" + String(character) }
            return String(character)
        }.joined()
    }

    /// Экспорт в формате команд Keenetic — чтобы залить на другой роутер.
    static func exportCLI(_ routes: [StaticRoute]) -> String {
        routes.flatMap { route in
            [route.rawLine.isEmpty ? route.command : route.rawLine]
                + (route.disabled ? ["\(route.family.keyword) disable"] : [])
        }.joined(separator: "\n") + "\n"
    }
}
