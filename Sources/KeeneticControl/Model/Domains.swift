import Foundation

enum Domains {
    private static let labelPattern = try! NSRegularExpression(
        pattern: "^(?!-)[a-z0-9_-]{1,63}(?<!-)$")

    private static let commentMarkers = ["#", "!", ";", "//"]

    /// Комментарий начинается отдельным словом: // внутри https:// не режется.
    private static func contentTokens(_ raw: String) -> [String] {
        let tokens = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return Array(tokens.prefix { token in
            !commentMarkers.contains(where: token.hasPrefix)
        })
    }

    /// Нормализация одного значения не должна молча терять соседние записи.
    static func normalize(_ raw: String) -> String? {
        guard let entries = lineEntries(raw), entries.count == 1 else { return nil }
        return entries[0]
    }

    private static func lineEntries(_ raw: String) -> [String]? {
        let tokens = contentTokens(raw)
        guard let first = tokens.first else { return [] }
        if tokens.count > 1, IPTools.isIP(first) {
            guard !first.contains("%") else { return nil }
            // В hosts каждый алиас важен. Невалидный хвост отклоняет всю
            // строку, иначе строгая загрузка приняла бы обрезанный источник.
            var aliases: [String] = []
            for token in tokens.dropFirst() {
                guard let name = normalizeToken(token), !IPTools.isIP(name),
                      !name.contains("/"), !token.contains("://") else { return nil }
                aliases.append(name)
            }
            return aliases
        }
        guard tokens.count == 1, let entry = normalizeToken(first) else { return nil }
        return [entry]
    }

    private static func normalizeToken(_ token: String) -> String? {
        var value = token
        if value.hasPrefix("||") { value = String(value.dropFirst(2)) }
        while value.hasSuffix("^") { value = String(value.dropLast()) }

        if value.contains("://") {
            guard let host = URLComponents(string: value)?.host else { return nil }
            value = host
        }

        value = value.trimmingCharacters(in: .whitespaces).lowercased()
        while value.hasSuffix(".") { value = String(value.dropLast()) }
        if value.hasPrefix("*.") { value = String(value.dropFirst(2)) }
        while value.hasPrefix(".") { value = String(value.dropFirst()) }

        guard !value.isEmpty, !value.contains("?"), !value.contains("%") else { return nil }

        // Подсети и голые адреса Keenetic кладёт в object-group наравне с доменами.
        if value.contains("/") {
            return IPTools.normalizeNetwork(value)
        }
        if let ipv4 = IPTools.parseIPv4(value) { return IPTools.formatIPv4(ipv4) }
        if let ipv6 = IPTools.parseIPv6(value) { return IPTools.formatIPv6(ipv6) }
        if value.contains(":") { return nil }

        guard let ascii = Punycode.encode(domain: value) else { return nil }
        value = ascii

        guard value.count <= 253 else { return nil }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // Списки могут содержать целую зону (.ua); Keenetic включает все
        // поддомены указанного имени. Уже очищенное ua должно повторно
        // нормализоваться так же при планировании, а случайное ERROR — нет.
        if labels.count < 2 {
            guard IanaTopLevelDomains.all.contains(value) else { return nil }

        }
        for label in labels {
            let range = NSRange(label.startIndex..., in: label)
            guard labelPattern.firstMatch(in: label, range: range) != nil else { return nil }
        }
        // Последняя метка из одних цифр — это не домен.
        guard let last = labels.last, Int(last) == nil else { return nil }

        return value
    }

    struct ParseResult {
        var domains: [String] = []
        var skipped: [String] = []
        var duplicates: Int = 0
    }

    static func parseList(_ text: String) -> ParseResult {
        var result = ParseResult()
        var seen = Set<String>()

        for raw in CLI.normalizeNewlines(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("!")
                || trimmed.hasPrefix(";") || trimmed.hasPrefix("//") { continue }

            guard let entries = lineEntries(String(raw)) else {
                result.skipped.append(trimmed)
                continue
            }
            for domain in entries {
                if !seen.insert(domain).inserted {
                    result.duplicates += 1
                    continue
                }
                result.domains.append(domain)
            }
        }

        return result
    }

    struct SubnetParseResult {
        var v4: [String]
        var v6: [String]
        var skipped: [String]
    }

    /// Списки подсетей отдаются отдельными файлами по семействам адресов.
    static func parseSubnets(_ text: String) -> (v4: [String], v6: [String]) {
        let parsed = parseSubnetsWithDiagnostics(text)
        return (parsed.v4, parsed.v6)
    }

    /// Автоматическое удаление требует полного разбора каждого компонента.
    /// Неверные строки сохраняем отдельно, чтобы отличить пустой комментарий
    /// от повреждения, которое раньше могло незаметно обрезать набор подсетей.
    static func parseSubnetsWithDiagnostics(_ text: String) -> SubnetParseResult {
        var v4: [String] = []
        var v6: [String] = []
        var skipped: [String] = []
        var seen = Set<String>()

        for raw in CLI.normalizeNewlines(text).split(separator: "\n", omittingEmptySubsequences: false) {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }
            for marker in ["#", "!", ";", "//"] where value.hasPrefix(marker) { value = "" }
            if value.isEmpty { continue }
            let tokens = contentTokens(value)
            guard tokens.count == 1, let token = tokens.first, !token.contains("%") else {
                skipped.append(value)
                continue
            }
            value = token

            var normalized: String?
            if value.contains("/") {
                normalized = IPTools.normalizeNetwork(value)
            } else if let ipv4 = IPTools.parseIPv4(value) {
                normalized = "\(IPTools.formatIPv4(ipv4))/32"
            } else if let ipv6 = IPTools.parseIPv6(value) {
                normalized = "\(IPTools.formatIPv6(ipv6))/128"
            }

            guard let network = normalized else {
                skipped.append(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                continue
            }
            guard !seen.contains(network) else { continue }
            seen.insert(network)
            if network.contains(":") { v6.append(network) } else { v4.append(network) }
        }

        return SubnetParseResult(v4: v4, v6: v6, skipped: skipped)
    }
}
