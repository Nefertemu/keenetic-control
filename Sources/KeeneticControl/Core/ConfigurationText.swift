import Foundation

/// Проверяет ответ show *-config перед разбором или резервным копированием.
/// Ошибки CLI распознаются как отдельные сообщения, а не как слова внутри
/// description, hostname и других законных строк конфигурации.
enum ConfigurationText {
    private static let replyError = try! NSRegularExpression(
        pattern: #"^(?:[A-Za-z][A-Za-z0-9_]*(?:::[A-Za-z][A-Za-z0-9_]*)+:?\s+)?(?:error\[\d+\]|error\s*:|argument parse error\b|unknown command\b|invalid (?:argument|value|command|input)\b|command failed\b|syntax error\b|not enough memory\b|ошибка(?:\s|:|$)|неизвестная команда\b)"#,
        options: [.caseInsensitive])

    static func validated(_ raw: String) throws -> String {
        let text = CLI.normalizeNewlines(raw)
        let hasError = text.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return replyError.firstMatch(in: trimmed,
                                         range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasError,
              !text.lowercased().contains("<html"), !text.lowercased().contains("<!doctype"),
              !text.contains("\u{0000}") else {
            throw TransportError(
                "Роутер не вернул конфигурацию: получен пустой ответ или сообщение об ошибке.",
                hint: "Повтори чтение конфигурации перед изменением роутера.")
        }
        return text
    }
    /// Снимок должен иметь законченный CLI-блок. Отсутствие объектов допустимо
    /// только в распознаваемой конфигурации, а не в произвольном UTF-8 файле.
    /// Проверка не может обнаружить потерю целого законченного блока legacy
    /// файла; новые зашифрованные контейнеры защищены аутентификацией целиком.
    static func validatedBackup(_ raw: String) throws -> String {
        let prepared = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        let text = try validated(prepared)
        let lines = text.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let last = lines.last, last == "!" || last == "exit",
              lines.contains(where: { line in
                  line == "system" || line == "dns-proxy"
                      || ["hostname ", "system ", "interface ", "object-group fqdn ", "ip ", "ipv6 ", "dns-proxy "]
                      .contains { line.hasPrefix($0) }
              }) else {
            throw TransportError("Копия не похожа на полную конфигурацию Keenetic.",
                                 hint: "Файл пуст, обрезан или не содержит завершения конфигурации. Сними новую копию перед восстановлением.")
        }
        let groups = RouterConfigParser.parseFqdnGroups(text)
        var inGroup = false
        var inDNSProxy = false
        var seenGroups = Set<String>()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let top = !(line.first?.isWhitespace ?? false)
            if top { inGroup = trimmed.hasPrefix("object-group fqdn "); inDNSProxy = trimmed == "dns-proxy" }
            if top && trimmed.hasPrefix("object-group fqdn ") {
                let tokens = trimmed.split(whereSeparator: \.isWhitespace)
                guard top, tokens.count == 3, safeToken(String(tokens[2])),
                      seenGroups.insert(String(tokens[2])).inserted else {
                    throw TransportError("В копии повреждено объявление списка.")
                }
            }
            if inGroup && !top && trimmed != "!" && !trimmed.isEmpty {
                if trimmed.hasPrefix("include ") {
                    let entry = CLI.unquote(String(trimmed.dropFirst(8)))
                    let parsed = Domains.parseList(entry)
                    guard parsed.skipped.isEmpty, parsed.domains.count == 1,
                          entry.range(of: #"^[A-Za-z0-9_.:/-]+$"#, options: .regularExpression) != nil,
                          !entry.contains("://") else {
                        throw TransportError("В копии повреждена запись списка.")
                    }
                } else if trimmed.hasPrefix("description ") {
                    let value = String(trimmed.dropFirst(12))
                    if value.hasPrefix("\"") && !value.hasSuffix("\"") {
                        throw TransportError("В копии обрезано имя списка.")
                    }
                } else {
                    throw TransportError("Копия содержит неподдерживаемую строку списка.", hint: "Обнови приложение или выбери другую копию.")
                }
            }
            if (top && trimmed.hasPrefix("dns-proxy route object-group"))
                || (inDNSProxy && !top && trimmed.hasPrefix("route object-group")) {
                let flat = trimmed.hasPrefix("dns-proxy ") ? trimmed : "dns-proxy " + trimmed
                let tokens = flat.split(whereSeparator: \.isWhitespace).map(String.init)
                guard tokens.count >= 5, tokens.prefix(3) == ["dns-proxy", "route", "object-group"],
                      safeToken(tokens[3]), safeToken(tokens[4]),
                      tokens.dropFirst(5).allSatisfy({ $0 == "auto" || $0 == "reject" }),
                      Set(tokens.dropFirst(5)).count == tokens.dropFirst(5).count,
                      groups[tokens[3]] != nil || groups.values.filter({ $0.descriptionText == tokens[3] }).count == 1 else {
                    throw TransportError("В копии повреждён или неоднозначен маршрут списка.")
                }
            }

        }
        let staticRoutes = StaticRouteParser.parseWithDiagnostics(config: text)
        guard staticRoutes.problems.isEmpty else {
            throw TransportError("В копии повреждён или не поддерживается статический маршрут.",
                                 hint: "Маршрут не может быть точно восстановлен этой версией приложения. Отдельная строка disable должна следовать сразу за своим маршрутом того же семейства.")
        }
        for group in groups.values {
            _ = try DomainListSyncPlanner.validatedRouteChain(group, sourceTitle: group.ident)
        }
        return text
    }

    static func canonicalRouteLine(_ line: String) -> String {
        var tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.count > 5 { tokens = Array(tokens.prefix(5)) + tokens.dropFirst(5).sorted() }
        return tokens.joined(separator: " ")
    }

    /// Включает и осиротевшие ссылки: обычный parser привязывает маршруты
    /// только к существующим группам и потому не видит проигнорированное no.
    static func dnsRouteLines(_ raw: String) -> Set<String> {
        var result = Set<String>()
        var inside = false
        for line in CLI.normalizeNewlines(raw).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let top = !(line.first?.isWhitespace ?? false)
            if top { inside = trimmed == "dns-proxy" }
            if top && trimmed.hasPrefix("dns-proxy route object-group ") {
                result.insert(canonicalRouteLine(trimmed))
            } else if inside && !top && trimmed.hasPrefix("route object-group ") {
                result.insert(canonicalRouteLine("dns-proxy " + trimmed))
            }
        }
        return result
    }

    private static func safeToken(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil
    }

}
