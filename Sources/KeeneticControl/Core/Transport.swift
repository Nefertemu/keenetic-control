import Foundation

struct TransportError: LocalizedError {
    let message: String
    var hint: String?
    init(_ message: String, hint: String? = nil) {
        self.message = message
        self.hint = hint
    }
    var errorDescription: String? { message }
}

/// Общий знаменатель для SSH и HTTP RCI: выполнить команду Keenetic CLI.
protocol KeeneticTransport: AnyObject {
    var kind: TransportKind { get }
    func connect() throws
    func run(_ command: String, timeout: TimeInterval) throws -> String
    func runBatch(_ commands: [String], timeout: TimeInterval) throws -> String
    /// Длинные текстовые выгрузки (running-config и подобное).
    func fetchText(_ command: String, timeout: TimeInterval) throws -> String
    func close()
    /// Оборвать всё немедленно из другого потока — сторож операций.
    func abort()
}

extension KeeneticTransport {
    func run(_ command: String) throws -> String { try run(command, timeout: 90) }
}

enum CLI {
    static let ansi = try! NSRegularExpression(
        pattern: "\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])")

    /// Убираем цвета и «забой» — Keenetic любит и то и другое.
    static func stripNoise(_ text: String) -> String {
        var value = ansi.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "")

        var previous: String
        repeat {
            previous = value
            value = removeBackspaces(value)
        } while previous != value

        return value.replacingOccurrences(of: "\r", with: "")
    }

    private static func removeBackspaces(_ text: String) -> String {
        var result: [Character] = []
        for character in text {
            if character == "\u{08}" {
                if !result.isEmpty { result.removeLast() }
            } else {
                result.append(character)
            }
        }
        return String(result)
    }

    private static let errorPattern = try! NSRegularExpression(
        pattern: "(error\\[\\d+\\]|\\berror\\s*:|argument parse error|unknown command"
            + "|invalid (?:argument|value|command|input)|command failed|syntax error"
            + "|not enough memory|\\bошибка\\b|неизвестная команда)",
        options: [.caseInsensitive])

    private static let echoPrefixes = [
        "object-group ", "no object-group ", "dns-proxy ", "no dns-proxy ",
        "ip route ", "no ip route ", "ipv6 route ", "no ipv6 route ",
        "interface ", "show ", "system ",
    ]

    /// Ищем сообщение CLI об ошибке, а не слово error внутри имени домена.
    static func failed(_ output: String) -> Bool {
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if echoPrefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if errorPattern.firstMatch(in: trimmed, range: range) != nil { return true }
        }
        return false
    }

    /// Терминал возвращает наши же команды — выкидываем эхо из вывода.
    static func stripEcho(_ output: String, commands: [String]) -> String {
        let echoes = Set(commands.map { $0.trimmingCharacters(in: .whitespaces) })
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !echoes.contains($0.trimmingCharacters(in: .whitespaces)) }

        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Кавычим строку так, как её понимает Keenetic CLI.
    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Разбираем то, что CLI вернул в кавычках.
    static func unquote(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
            text = text.replacingOccurrences(of: "\\\"", with: "\"")
            text = text.replacingOccurrences(of: "\\\\", with: "\\")
        }
        return text
    }
}
