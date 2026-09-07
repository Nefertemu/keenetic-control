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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasError else {
            throw TransportError(
                "Роутер не вернул конфигурацию: получен пустой ответ или сообщение об ошибке.",
                hint: "Повтори чтение конфигурации перед изменением роутера.")
        }
        return text
    }
}
