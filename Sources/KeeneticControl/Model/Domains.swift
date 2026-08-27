import Foundation

enum Domains {
    private static let labelPattern = try! NSRegularExpression(
        pattern: "^(?!-)[a-z0-9_-]{1,63}(?<!-)$")

    /// Приводит строку любого популярного формата списков к чистому домену,
    /// IP-адресу или подсети. Возвращает nil, если строку понять нельзя.
    static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        for marker in ["#", "!", ";", "//"] where value.hasPrefix(marker) { return nil }

        let tokens = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = tokens.first else { return nil }
        // Формат hosts-файла: «0.0.0.0 example.com».
        value = (tokens.count >= 2 && IPTools.isIP(first)) ? tokens[1] : first

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

        guard !value.isEmpty, !value.contains("?") else { return nil }

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
        guard labels.count >= 2 else { return nil }
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

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("!")
                || trimmed.hasPrefix(";") || trimmed.hasPrefix("//") { continue }

            guard let domain = normalize(String(raw)) else {
                result.skipped.append(trimmed)
                continue
            }
            if seen.contains(domain) {
                result.duplicates += 1
                continue
            }
            seen.insert(domain)
            result.domains.append(domain)
        }

        return result
    }

    /// Списки подсетей отдаются отдельными файлами по семействам адресов.
    static func parseSubnets(_ text: String) -> (v4: [String], v6: [String]) {
        var v4: [String] = []
        var v6: [String] = []
        var seen = Set<String>()

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }
            for marker in ["#", "!", ";", "//"] where value.hasPrefix(marker) { value = "" }
            if value.isEmpty { continue }
            value = String(value.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? "")

            var normalized: String?
            if value.contains("/") {
                normalized = IPTools.normalizeNetwork(value)
            } else if let ipv4 = IPTools.parseIPv4(value) {
                normalized = "\(IPTools.formatIPv4(ipv4))/32"
            } else if let ipv6 = IPTools.parseIPv6(value) {
                normalized = "\(IPTools.formatIPv6(ipv6))/128"
            }

            guard let network = normalized, !seen.contains(network) else { continue }
            seen.insert(network)
            if network.contains(":") { v6.append(network) } else { v4.append(network) }
        }

        return (v4, v6)
    }
}
