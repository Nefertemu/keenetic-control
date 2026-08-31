import Foundation

/// Как именно проверяем ресурс из выбранного туннеля. Для TCP KeeneticOS
/// открывает настоящее соединение клиентом iperf3 (чужой HTTPS-сервер затем
/// закономерно отвергает протокол, но сам TCP connect уже доказан). UDP
/// проверяется трассировкой, потому что у него нет рукопожатия.
enum InterfaceProbeMethod: String, CaseIterable, Identifiable, Hashable {
    case icmp
    case tcp
    case udp

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var usesPort: Bool { self != .icmp }
    var defaultPort: Int {
        switch self {
        case .icmp: return 0
        case .tcp:  return 443
        case .udp:  return 53
        }
    }
    var explanation: String {
        switch self {
        case .icmp: return "ICMP Echo через каждый туннель"
        case .tcp:  return "TCP-соединение через адрес туннеля"
        case .udp:  return "UDP-проба до конечного узла через адрес туннеля"
        }
    }
}

/// Результат активного теста, который роутер отправил через конкретный
/// интерфейс. Это не состояние встроенного Ping-Check: здесь хранятся
/// измеренные RTT и потери текущего запуска.
struct InterfacePingResult: Hashable {
    var interface: String
    var target: String
    var method: InterfaceProbeMethod = .icmp
    var port: Int? = nil
    var source: String?
    var transmitted: Int
    var received: Int
    var rtt: [Double]
    var checkedAt: Date
    var error: String?

    var lossPercent: Double {
        guard transmitted > 0 else { return received > 0 ? 0 : 100 }
        return max(0, min(100, 100 * Double(transmitted - received) / Double(transmitted)))
    }

    var latestRTT: Double? { rtt.last }
    var minimumRTT: Double? { rtt.min() }
    var maximumRTT: Double? { rtt.max() }
    var averageRTT: Double? {
        guard !rtt.isEmpty else { return nil }
        return rtt.reduce(0, +) / Double(rtt.count)
    }
    var isReachable: Bool { received > 0 && error == nil }
}

enum InterfacePingProbe {
    private static let safeInterface = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$"#)
    private static let safeTarget = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$"#)
    private static let timePattern = try! NSRegularExpression(
        pattern: #"\btime\s*[=<]\s*([0-9]+(?:[.,][0-9]+)?)\s*ms\b"#,
        options: [.caseInsensitive])
    private static let traceTimePattern = try! NSRegularExpression(
        pattern: #"\b([0-9]+(?:[.,][0-9]+)?)\s*ms\b"#,
        options: [.caseInsensitive])
    private static let sourcePattern = try! NSRegularExpression(
        pattern: #"\bfrom\s+([^:\s]+)\s*:"#,
        options: [.caseInsensitive])
    private static let summaryPattern = try! NSRegularExpression(
        pattern: #"(\d+)\s+packets?\s+transmitted,\s*(\d+)\s+packets?\s+received"#,
        options: [.caseInsensitive])
    private static let traceTargetPattern = try! NSRegularExpression(
        pattern: #"traceroute\s+to\s+\S+\s+\(([^)]+)\)"#,
        options: [.caseInsensitive])
    private static let traceHopPattern = try! NSRegularExpression(
        pattern: #"^\s*(\d+)\s+"#, options: [.anchorsMatchLines])

    static func validate(interface: String, target: String) throws -> (String, String) {
        let cleanInterface = interface.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matches(safeInterface, cleanInterface) else {
            throw TransportError("Некорректное имя интерфейса для ping.")
        }
        let validName = matches(safeTarget, cleanTarget)
            && !cleanTarget.contains("..")
            && !cleanTarget.hasSuffix(".")
        guard IPTools.isIP(cleanTarget) || validName else {
            throw TransportError("Укажи корректный домен или IP-адрес для ping.")
        }
        return (cleanInterface, cleanTarget)
    }

    static func command(interface: String, target: String, count: Int = 3,
                        method: InterfaceProbeMethod = .icmp, port: Int? = nil,
                        sourceAddress: String? = nil) throws -> String {
        let values = try validate(interface: interface, target: target)
        guard (1...10).contains(count) else {
            throw TransportError("Количество ping-запросов должно быть от 1 до 10.")
        }
        if method == .icmp {
            // Порядок аргументов важен для парсера KeeneticOS: count идёт до
            // source-interface. Проверено на 5.01.
            let tool = IPTools.isIPv6(values.1) ? "ping6" : "ping"
            return "tools \(tool) \(values.1) count \(count) source-interface \(values.0)"
        }

        guard !IPTools.isIPv6(values.1) else {
            throw TransportError("TCP/UDP-трассировка этой версии KeeneticOS поддерживает только IPv4.")
        }
        guard let sourceAddress,
              let source = sourceAddress.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
              IPTools.parseIPv4(source) != nil else {
            throw TransportError("У интерфейса \(values.0) не найден IPv4-адрес для \(method.title)-проверки.")
        }
        let checkedPort = port ?? method.defaultPort
        guard (1...65535).contains(checkedPort) else {
            throw TransportError("Порт должен быть от 1 до 65535.")
        }
        if method == .tcp {
            // Это реальный TCP connect. Если на другом конце не iperf3 (обычный
            // HTTPS-сайт), Keenetic напишет `unknown control message`; для нас
            // это успех — соединение на порт уже было установлено.
            return "tools iperf3 \(values.1) ipv4 tcp port \(checkedPort) time 1 "
                + "source-address \(source)"
        }

        // У UDP нет рукопожатия, поэтому остаётся маршрутная проба.
        return "tools traceroute \(values.1) count 1 wait-time 1 max-ttl 16 "
            + "port \(checkedPort) source-address \(source) type \(method.rawValue)"
    }

    static func parse(_ raw: String, interface: String, target: String,
                      method: InterfaceProbeMethod = .icmp, port: Int? = nil,
                      sourceAddress: String? = nil,
                      elapsedMilliseconds: Double? = nil,
                      checkedAt: Date = Date()) -> InterfacePingResult {
        let text = CLI.stripNoise(raw)
        var times: [Double]
        let source: String?
        if method == .icmp {
            times = captures(timePattern, in: text, group: 1).compactMap {
                Double($0.replacingOccurrences(of: ",", with: "."))
            }
            source = capture(sourcePattern, in: text, group: 1)
        } else if method == .tcp {
            times = []
            source = sourceAddress
        } else {
            let resolved = capture(traceTargetPattern, in: text, group: 1) ?? target
            let finalLine = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .last { line in
                    firstMatch(traceHopPattern, in: line) != nil
                        && (line.contains("(\(resolved))")
                            || line.range(of: #"^\s*\d+\s+"# + NSRegularExpression.escapedPattern(for: resolved)
                                          + #"(?:\s|$)"#, options: .regularExpression) != nil)
                }
            times = finalLine.map { line in
                captures(traceTimePattern, in: line, group: 1).compactMap {
                    Double($0.replacingOccurrences(of: ",", with: "."))
                }
            } ?? []
            source = sourceAddress
        }

        var transmitted = method == .icmp ? max(times.count, 0) : 1
        var received: Int
        if method == .tcp {
            let lower = text.lowercased()
            // `unknown control message` означает: TCP/порт доступны, но
            // сервер говорит не на протоколе iperf3 — ровно ожидаемый ответ
            // от HTTPS/DNS/любого другого обычного сервиса.
            let connected = lower.contains("unknown control message")
                || lower.contains("connected to")
                || lower.contains("server is busy")
                || lower.contains("bits/sec")
            received = connected ? 1 : 0
            // iperf3 intentionally does not print a connect RTT when the
            // peer is an ordinary HTTPS/DNS service. The transport measures
            // the complete router-side operation, which is still useful as
            // a latency indicator for this interface.
            if received > 0, let elapsedMilliseconds, elapsedMilliseconds > 0 {
                times = [elapsedMilliseconds]
            }
        } else {
            received = times.count
        }
        if method == .icmp, let match = firstMatch(summaryPattern, in: text),
           let sent = integer(match, group: 1, in: text),
           let got = integer(match, group: 2, in: text) {
            transmitted = sent
            received = got
        }

        let problem: String?
        if method == .tcp, received > 0 {
            problem = nil
        } else if CLI.failed(text) || text.localizedCaseInsensitiveContains("Failed to") {
            problem = text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && (CLI.failed($0) || $0.localizedCaseInsensitiveContains("Failed to")) }
                ?? "Keenetic не принял команду проверки."
        } else if transmitted == 0 && times.isEmpty {
            problem = "Роутер не вернул статистику ping."
        } else if method == .tcp {
            problem = "TCP/\(port ?? method.defaultPort): соединение не установлено. "
                + "Цель должна уже иметь маршрут через этот туннель."
        } else if method != .icmp && times.isEmpty {
            let hopCount = captures(traceHopPattern, in: text, group: 1).compactMap(Int.init).max() ?? 0
            problem = "\(method.title)/\(port ?? method.defaultPort): конечный узел не ответил"
                + (hopCount > 0 ? " (проверено хопов: \(hopCount))." : ".")
        } else {
            problem = nil
        }

        return InterfacePingResult(interface: interface, target: target,
                                   method: method, port: method.usesPort ? (port ?? method.defaultPort) : nil,
                                   source: source, transmitted: transmitted,
                                   received: received, rtt: times,
                                   checkedAt: checkedAt, error: problem)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func capture(_ regex: NSRegularExpression, in text: String,
                                group: Int) -> String? {
        guard let match = firstMatch(regex, in: text),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    private static func captures(_ regex: NSRegularExpression, in text: String,
                                 group: Int) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > group,
                  let range = Range(match.range(at: group), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func integer(_ match: NSTextCheckingResult, group: Int,
                                in text: String) -> Int? {
        guard match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text) else { return nil }
        return Int(text[range])
    }
}
