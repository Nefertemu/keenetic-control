import Foundation

struct TransportError: LocalizedError {
    let message: String
    var hint: String?
    /// Роутер не принял логин или пароль — повторять бессмысленно.
    var isAuthFailure: Bool

    init(_ message: String, hint: String? = nil, isAuthFailure: Bool = false) {
        self.message = message
        self.hint = hint
        self.isAuthFailure = isAuthFailure
    }
    var errorDescription: String? { message }
}

/// Общий знаменатель для SSH и HTTP RCI: выполнить команду Keenetic CLI.
protocol KeeneticTransport: AnyObject {
    var kind: TransportKind { get }
    /// Сторож долгих операций может оборвать сокет/pty, пока ссылка на
    /// транспорт ещё лежит в слоте. Перед повторным запросом проверяем это,
    /// чтобы не возвращать пользователю «сессия не подключена» бесконечно.
    var isAlive: Bool { get }
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
    /// Такие аргументы не должны попадать ни в журнал, ни в подсказку
    /// ошибки. Значение бывает кавычечным (как его собирает quote) или
    /// одним токеном — закрываем обе формы.
    private static let secretArgumentPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(private-key|preshared-key)\s+(?:"(?:\\.|[^"])*"|\S+)"#)

    /// Прошивка отдаёт конфигурацию с CRLF. В Swift «\r\n» — ОДИН символ,
    /// поэтому split(separator: "\n") такой текст не разбивает вовсе: парсеры
    /// получают весь конфиг одной строкой и не находят в нём ничего.
    /// Приводим переводы строк к «\n» на границе транспорта.
    /// Работаем на уровне скаляров: строковые API сравнивают по графемам,
    /// а там «\r\n» — единое целое, и даже contains("\r") вернёт false.
    static func normalizeNewlines(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        var afterCR = false

        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                scalars.append("\n")
                afterCR = true
            } else if scalar == "\n" && afterCR {
                afterCR = false          // «\r\n» уже дало один перевод строки
            } else {
                scalars.append(scalar)
                afterCR = false
            }
        }
        return String(scalars)
    }

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

    /// Маскируем секреты WireGuard в сообщениях, которые увидит пользователь
    /// или которые сохраняются на диск. Команды роутеру отдаются исходными.
    static func redactSecrets(_ text: String) -> String {
        secretArgumentPattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "$1 •••")
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
