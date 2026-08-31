import Foundation

/// Профиль Ping-Check. В веб-панели Keenetic их не настроить — только через
/// командную строку, поэтому приложение даёт им нормальный интерфейс.
///
/// Все параметры, диапазоны и значения по умолчанию взяты из официального
/// справочника команд Keenetic (раздел «ping-check profile»).
struct PingCheckProfile: Identifiable, Hashable {
    enum Mode: String, CaseIterable, Identifiable {
        case icmp
        case connect
        case tls
        case uri

        var id: String { rawValue }

        var title: String {
            switch self {
            case .icmp:    return "ICMP"
            case .connect: return "TCP"
            case .tls:     return "TLS"
            case .uri:     return "URI"
            }
        }

        var explanation: String {
            switch self {
            case .icmp:    return "Обычный ping до узла."
            case .connect: return "Установка TCP-соединения на указанный порт."
            case .tls:     return "Установка TLS-соединения."
            case .uri:     return "Запрос по адресу HTTP или HTTPS."
            }
        }

        /// Режиму uri нужен адрес, остальным — имя узла.
        var usesURI: Bool { self == .uri }
        var usesPort: Bool { self == .connect }
    }

    /// Пределы из справочника: выходить за них роутер не даст.
    enum Limits {
        static let fails = 1...10
        static let success = 1...10
        static let timeout = 1...10
        static let updateInterval = 3...3600
        static let port = 1...65534
    }

    /// Значения, которые роутер подставляет сам, если параметр не задан.
    enum Defaults {
        static let maxFails = 5
        static let minSuccess = 5
        static let timeout = 2
    }

    var name: String
    var host: String = ""
    var uri: String = ""
    var mode: Mode = .icmp
    var port: Int?
    var maxFails: Int?
    var minSuccess: Int?
    var updateInterval: Int?
    var timeout: Int?
    /// Перезапуск питания USB-модема. Роутер включает его по умолчанию.
    var powerCycle: Bool = true
    /// «default» роутер держит внутри себя и в конфигурацию не пишет.
    var isBuiltIn: Bool = false

    var id: String { name }

    var target: String { mode.usesURI ? uri : host }

    /// Короткая сводка параметров для списка.
    var summary: String {
        var parts: [String] = [mode.rawValue]
        if !target.isEmpty { parts.append(target) }
        if mode.usesPort, let port { parts.append("порт \(port)") }
        if let updateInterval { parts.append("каждые \(updateInterval) с") }
        parts.append("отказ после \(maxFails ?? Defaults.maxFails)")
        parts.append("подъём после \(minSuccess ?? Defaults.minSuccess)")
        parts.append("тайм-аут \(timeout ?? Defaults.timeout) с")
        if !powerCycle { parts.append("без power-cycle") }
        return parts.joined(separator: " · ")
    }

    static func validate(_ profile: PingCheckProfile) throws {
        let name = profile.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw TransportError("Укажи имя профиля.") }
        guard name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw TransportError("Имя профиля: латиница, цифры, дефис и подчёркивание.")
        }

        if profile.mode.usesURI {
            let uri = profile.uri.trimmingCharacters(in: .whitespaces)
            guard !uri.isEmpty else { throw TransportError("Для режима URI укажи адрес.") }
            guard let components = URLComponents(string: uri),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  components.host != nil,
                  components.user == nil, components.password == nil else {
                throw TransportError("Адрес должен начинаться с http:// или https://")
            }
            try validateCLIValue(uri, label: "Адрес")
        } else {
            let host = profile.host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else {
                throw TransportError("Укажи узел, который будет проверяться.")
            }
            try validateCLIValue(host, label: "Узел")
        }

        if profile.mode.usesPort {
            guard let port = profile.port, Limits.port.contains(port) else {
                throw TransportError("Для режима TCP нужен порт "
                                     + "от \(Limits.port.lowerBound) до \(Limits.port.upperBound).")
            }
        }

        func inRange(_ label: String, _ value: Int?, _ range: ClosedRange<Int>) throws {
            guard let value else { return }
            guard range.contains(value) else {
                throw TransportError("\(label): роутер принимает "
                                     + "от \(range.lowerBound) до \(range.upperBound).")
            }
        }
        try inRange("Отказов до отключения", profile.maxFails, Limits.fails)
        try inRange("Успехов до подъёма", profile.minSuccess, Limits.success)
        try inRange("Тайм-аут ответа", profile.timeout, Limits.timeout)
        try inRange("Интервал проверки", profile.updateInterval, Limits.updateInterval)
    }

    /// Значения попадают прямо в интерактивную CLI-команду. Перевод строки
    /// превращался в дополнительную команду в SSH, а разделители команд —
    /// в неожиданные аргументы даже без shell. URL-пунктуация вроде /, ?, &
    /// разрешена, но управляющие символы и кавычки — нет.
    private static func validateCLIValue(_ value: String, label: String) throws {
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw TransportError("\(label) не должен содержать пробелы или переводы строк.")
        }
        let forbidden = CharacterSet(charactersIn: "\r\n;|$<>\"'\\")
        guard value.rangeOfCharacter(from: forbidden) == nil else {
            throw TransportError("\(label) содержит недопустимый служебный символ.")
        }
    }
}

/// Привязка профиля к интерфейсу.
struct PingCheckBinding: Hashable {
    var profile: String
    /// Перезапускать интерфейс при потере связи.
    var restart: Bool
}

/// Живой результат Ping-Check. В старых прошивках он приходит текстом из
/// `show ping-check`, в новых — JSON из `show/ping-check`. Поля намеренно
/// необязательные: разные версии Keenetic показывают разный набор счётчиков.
struct PingCheckLiveInfo: Hashable {
    var profile: String?
    var status: String?
    var failureCount: Int?
    var successCount: Int?
    var resolvedAddresses: [String]

    init(profile: String? = nil,
         status: String? = nil,
         failureCount: Int? = nil,
         successCount: Int? = nil,
         resolvedAddresses: [String] = []) {
        self.profile = profile
        self.status = status
        self.failureCount = failureCount
        self.successCount = successCount
        self.resolvedAddresses = resolvedAddresses
    }

    var normalizedStatus: String? {
        guard let status else { return nil }
        let value = status.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return value.isEmpty ? nil : value
    }

    var state: PingCheckLiveState {
        switch normalizedStatus {
        case "pass", "passed", "running", "ok", "up", "online", "ready":
            return .passing
        case "fail", "failed", "failure", "error", "down", "offline",
             "stopped", "not ready", "notready":
            return .failing
        default:
            return .unknown
        }
    }
}

/// Разбор живого состояния профилей Ping-Check. Поле `interface` у RCI —
/// словарь с именами интерфейсов, а SSH-вывод — последовательность строк.
/// Держим оба варианта здесь, чтобы транспорт не знал о форме данных.
enum PingCheckStatusParser {
    static func parseCLI(_ text: String) -> [String: PingCheckLiveInfo] {
        let normalized = CLI.stripNoise(CLI.normalizeNewlines(text))
        var result: [String: PingCheckLiveInfo] = [:]
        var profile: String?
        var currentInterface: String?
        var awaitingInterfaceName = false

        let profilePattern = try! NSRegularExpression(
            pattern: "^(?:ping-check\\s+)?profile\\s*:\\s*(.+?)\\s*$",
            options: [.caseInsensitive])
        let interfacePattern = try! NSRegularExpression(
            pattern: "^(?:interface|ifname)\\s*:\\s*(.+?)\\s*$",
            options: [.caseInsensitive])
        // KeeneticOS 5.x prints an interface as a nested block:
        // `interface:` followed by `name: Wireguard0`. Older versions put
        // the name on the same line, so both forms are accepted.
        let interfaceHeader = try! NSRegularExpression(
            pattern: "^interface\\s*:\\s*$", options: [.caseInsensitive])
        let interfaceNamePattern = try! NSRegularExpression(
            pattern: "^name\\s*:\\s*(.+?)\\s*$", options: [.caseInsensitive])
        let statusPattern = try! NSRegularExpression(
            pattern: "^status\\s*:\\s*(.+?)\\s*$", options: [.caseInsensitive])
        let failurePattern = try! NSRegularExpression(
            pattern: "^(?:fail(?:ure)?[ -]?count|fail count)\\s*:\\s*(\\d+)",
            options: [.caseInsensitive])
        let successPattern = try! NSRegularExpression(
            pattern: "^(?:success(?:ful)?[ -]?count|success count)\\s*:\\s*(\\d+)",
            options: [.caseInsensitive])
        let addressPattern = try! NSRegularExpression(
            pattern: "^addresses?\\s*:\\s*(.+?)\\s*$", options: [.caseInsensitive])

        func capture(_ regex: NSRegularExpression, _ line: String) -> String? {
            guard let match = regex.firstMatch(in: line,
                                               range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { return nil }
            return CLI.unquote(String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        func update(_ body: (inout PingCheckLiveInfo) -> Void) {
            guard let currentInterface else { return }
            var info = result[currentInterface] ?? PingCheckLiveInfo(profile: profile)
            if info.profile == nil { info.profile = profile }
            body(&info)
            result[currentInterface] = info
        }

        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.lowercased() == "pingcheck:" || line.lowercased() == "ping-check:" {
                // Новый блок профиля начинается с profile:. Интерфейс не
                // переносим между блоками, иначе статус мог бы приклеиться
                // к следующему профилю без интерфейса.
                profile = nil
                currentInterface = nil
                awaitingInterfaceName = false
                continue
            }
            if let value = capture(profilePattern, line) {
                profile = value
                currentInterface = nil
                awaitingInterfaceName = false
                continue
            }
            if let value = capture(interfacePattern, line) {
                currentInterface = value
                result[value] = result[value] ?? PingCheckLiveInfo(profile: profile)
                awaitingInterfaceName = false
                continue
            }
            if interfaceHeader.firstMatch(in: line,
                                          range: NSRange(line.startIndex..., in: line)) != nil {
                currentInterface = nil
                awaitingInterfaceName = true
                continue
            }
            if awaitingInterfaceName, let value = capture(interfaceNamePattern, line) {
                currentInterface = value
                result[value] = result[value] ?? PingCheckLiveInfo(profile: profile)
                awaitingInterfaceName = false
                continue
            }
            if let value = capture(statusPattern, line) {
                update { $0.status = value }
                continue
            }
            if let value = capture(failurePattern, line), let count = Int(value) {
                update { $0.failureCount = count }
                continue
            }
            if let value = capture(successPattern, line), let count = Int(value) {
                update { $0.successCount = count }
                continue
            }
            if let value = capture(addressPattern, line), IPTools.isIP(value) {
                update { $0.resolvedAddresses.append(value) }
            }
        }
        return result
    }

    static func parseJSON(_ value: Any?) -> [String: PingCheckLiveInfo] {
        var result: [String: PingCheckLiveInfo] = [:]

        func string(_ value: Any?) -> String? {
            switch value {
            case let value as String: return value
            case let value as NSNumber: return value.stringValue
            default: return nil
            }
        }

        func integer(_ value: Any?) -> Int? {
            switch value {
            case let value as NSNumber: return value.intValue
            case let value as String: return Int(value.trimmingCharacters(in: .whitespaces))
            default: return nil
            }
        }

        func addresses(_ value: Any?) -> [String] {
            if let array = value as? [Any] {
                return array.flatMap(addresses)
            }
            if let map = value as? [String: Any] {
                let lowered = map.reduce(into: [String: Any]()) { result, pair in
                    if result[pair.key.lowercased()] == nil { result[pair.key.lowercased()] = pair.value }
                }
                let direct = ["address", "ip", "addr"].compactMap { string(lowered[$0]) }
                    .filter(IPTools.isIP)
                return direct + map.values.flatMap(addresses)
            }
            guard let value = string(value), IPTools.isIP(value) else { return [] }
            return [value]
        }

        func info(from map: [String: Any], profile: String?) -> PingCheckLiveInfo? {
            let lowered = map.reduce(into: [String: Any]()) { result, pair in
                if result[pair.key.lowercased()] == nil { result[pair.key.lowercased()] = pair.value }
            }
            let status = string(lowered["status"])
                ?? string((lowered["state"] as? [String: Any])?["status"])
            let failure = integer(lowered["failcount"] ?? lowered["fail-count"]
                                  ?? lowered["failurecount"] ?? lowered["failure-count"])
            let success = integer(lowered["successcount"] ?? lowered["success-count"])
            let cache = lowered["ipcache"] ?? lowered["ip-cache"] ?? lowered["cache"]
            let resolved = addresses(cache)
            guard status != nil || failure != nil || success != nil || !resolved.isEmpty else {
                return nil
            }
            return PingCheckLiveInfo(profile: profile, status: status,
                                     failureCount: failure, successCount: success,
                                     resolvedAddresses: Array(Set(resolved)).sorted())
        }

        func merge(_ incoming: PingCheckLiveInfo, for interface: String) {
            var existing = result[interface] ?? PingCheckLiveInfo()
            if existing.profile == nil { existing.profile = incoming.profile }
            if incoming.status != nil { existing.status = incoming.status }
            if incoming.failureCount != nil { existing.failureCount = incoming.failureCount }
            if incoming.successCount != nil { existing.successCount = incoming.successCount }
            if !incoming.resolvedAddresses.isEmpty {
                existing.resolvedAddresses = Array(Set(existing.resolvedAddresses
                    + incoming.resolvedAddresses)).sorted()
            }
            result[interface] = existing
        }

        func walk(_ raw: Any?, profile: String? = nil, interface: String? = nil) {
            if let array = raw as? [Any] {
                for item in array { walk(item, profile: profile, interface: interface) }
                return
            }
            guard let map = raw as? [String: Any] else { return }

            let keys = map.reduce(into: [String: Any]()) { result, pair in
                if result[pair.key.lowercased()] == nil { result[pair.key.lowercased()] = pair.value }
            }
            let currentProfile = string(keys["profile"]) ?? profile
            if let currentInterface = string(keys["interface"]) {
                if let parsed = info(from: map, profile: currentProfile) {
                    merge(parsed, for: currentInterface)
                }
                walkChildren(map, profile: currentProfile, interface: currentInterface)
                return
            }

            if let interfaces = keys["interface"] as? [String: Any] {
                for (name, payload) in interfaces {
                    if let payload = payload as? [String: Any],
                       let parsed = info(from: payload, profile: currentProfile) {
                        merge(parsed, for: name)
                    }
                    walk(payload, profile: currentProfile, interface: name)
                }
            }

            if let interface, let parsed = info(from: map, profile: currentProfile) {
                merge(parsed, for: interface)
            }
            walkChildren(map, profile: currentProfile, interface: interface)
        }

        func walkChildren(_ map: [String: Any], profile: String?, interface: String?) {
            for (key, child) in map {
                let lowered = key.lowercased()
                guard lowered != "interface", lowered != "profile", lowered != "status",
                      lowered != "state", lowered != "ipcache", lowered != "ip-cache" else { continue }
                walk(child, profile: profile, interface: interface)
            }
        }

        walk(value)
        return result
    }
}

enum PingCheckParser {
    /// Разбирает профили и их привязки из running-config.
    static func parse(config text: String) -> (profiles: [PingCheckProfile],
                                               bindings: [String: PingCheckBinding]) {
        var profiles: [String: PingCheckProfile] = [:]
        var bindings: [String: PingCheckBinding] = [:]

        var currentProfile: String?
        var currentInterface: String?

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let topLevel = !line.isEmpty && !(line.first?.isWhitespace ?? false)

            if topLevel {
                currentProfile = nil
                currentInterface = nil

                if trimmed.hasPrefix("ping-check profile ") {
                    let name = String(trimmed.dropFirst("ping-check profile ".count))
                        .trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        currentProfile = name
                        if profiles[name] == nil { profiles[name] = PingCheckProfile(name: name) }
                    }
                } else if trimmed.hasPrefix("interface ") {
                    currentInterface = String(trimmed.dropFirst("interface ".count))
                        .trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if let name = currentProfile {
                apply(setting: trimmed, to: &profiles[name]!)
                continue
            }

            guard let interface = currentInterface, trimmed.hasPrefix("ping-check ") else { continue }
            let rest = String(trimmed.dropFirst("ping-check ".count))
            if rest == "restart" || rest.hasPrefix("restart ") {
                bindings[interface, default: PingCheckBinding(profile: "", restart: false)].restart = true
            } else if rest.hasPrefix("profile ") {
                let name = String(rest.dropFirst("profile ".count)).trimmingCharacters(in: .whitespaces)
                bindings[interface, default: PingCheckBinding(profile: "", restart: false)].profile = name
            }
        }

        // Профиль, на который ссылаются, но которого нет в конфигурации, —
        // встроенный в прошивку (обычно «default»).
        for binding in bindings.values where !binding.profile.isEmpty {
            if profiles[binding.profile] == nil {
                profiles[binding.profile] = PingCheckProfile(name: binding.profile, isBuiltIn: true)
            }
        }

        return (profiles.values.sorted { $0.name < $1.name }, bindings)
    }

    private static func apply(setting: String, to profile: inout PingCheckProfile) {
        if setting == "power-cycle" { profile.powerCycle = true; return }
        if setting == "no power-cycle" { profile.powerCycle = false; return }

        let parts = setting.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let value = parts[1].trimmingCharacters(in: .whitespaces)

        switch parts[0] {
        case "host":            profile.host = CLI.unquote(value)
        case "uri":             profile.uri = CLI.unquote(value)
        case "mode":            profile.mode = PingCheckProfile.Mode(rawValue: value) ?? .icmp
        case "port":            profile.port = Int(value)
        case "max-fails":       profile.maxFails = Int(value)
        case "min-success":     profile.minSuccess = Int(value)
        case "update-interval": profile.updateInterval = Int(value)
        case "timeout":         profile.timeout = Int(value)
        default: break
        }
    }
}

// MARK: - Планы изменений

extension PingCheckParser {
    /// Команды приводят профиль к заданному виду.
    ///
    /// Справочник описывает контекстную форму (`ping-check profile X`, затем
    /// `host ...`, затем `exit`), но по RCI она невозможна: каждый запрос там
    /// независимый, контекст между ними не живёт. Поэтому используется плоская
    /// форма — путь целиком в одной команде, `no` перед последним звеном,
    /// как уже сделано для WireGuard и object-group.
    ///
    /// Проверено на живом роутере: создание профиля четырьмя такими командами
    /// и последующее удаление прошли без ошибок, значения легли в конфигурацию
    /// ровно как заданы.
    static func planSave(_ profile: PingCheckProfile, existing: PingCheckProfile?) -> Plan {
        var plan = Plan(title: existing == nil
                        ? "Новый профиль Ping-Check «\(profile.name)»"
                        : "Изменение профиля «\(profile.name)»")
        let head = "ping-check profile \(profile.name)"
        var commands = [head]

        // mode и update-interval снять нельзя — у них нет формы no,
        // поэтому просто всегда задаём их явно.
        commands.append("\(head) mode \(profile.mode.rawValue)")

        if profile.mode.usesURI {
            commands.append("\(head) uri \(profile.uri.trimmingCharacters(in: .whitespaces))")
            if let old = existing, !old.host.isEmpty { commands.append("\(head) no host") }
        } else {
            commands.append("\(head) host \(profile.host.trimmingCharacters(in: .whitespaces))")
            if let old = existing, !old.uri.isEmpty { commands.append("\(head) no uri") }
        }

        if profile.mode.usesPort, let port = profile.port {
            commands.append("\(head) port \(port)")
        } else if let old = existing, old.port != nil {
            commands.append("\(head) no port")
        }

        if let value = profile.updateInterval { commands.append("\(head) update-interval \(value)") }

        func setting(_ key: String, _ value: Int?, _ previous: Int?) {
            if let value {
                commands.append("\(head) \(key) \(value)")
            } else if previous != nil {
                commands.append("\(head) no \(key)")
            }
        }
        setting("max-fails", profile.maxFails, existing?.maxFails)
        setting("min-success", profile.minSuccess, existing?.minSuccess)
        setting("timeout", profile.timeout, existing?.timeout)

        if profile.powerCycle != (existing?.powerCycle ?? true) {
            commands.append(profile.powerCycle ? "\(head) power-cycle" : "\(head) no power-cycle")
        }

        plan.commands = commands
        if existing == nil {
            plan.notes.append("Значения, оставленные пустыми, роутер подставит сам: "
                              + "отказ после \(PingCheckProfile.Defaults.maxFails), "
                              + "подъём после \(PingCheckProfile.Defaults.minSuccess), "
                              + "тайм-аут \(PingCheckProfile.Defaults.timeout) с.")
        }
        return plan
    }

    static func planDelete(_ profile: PingCheckProfile, usedBy interfaces: [String]) -> Plan {
        var plan = Plan(title: "Удаление профиля «\(profile.name)»")
        // Сначала снимаем профиль с интерфейсов, иначе роутер не даст его удалить.
        for interface in interfaces {
            plan.commands.append("interface \(interface) no ping-check profile")
        }
        plan.commands.append("no ping-check profile \(profile.name)")
        if !interfaces.isEmpty {
            plan.notes.append("Профиль снимается с интерфейсов: " + interfaces.joined(separator: ", "))
        }
        return plan
    }

    static func planAssign(interface: String, profile: String?, restart: Bool,
                           current: PingCheckBinding?) -> Plan {
        var plan = Plan(title: "Ping-Check для \(interface)")

        if let profile, !profile.isEmpty {
            if current?.profile != profile {
                plan.commands.append("interface \(interface) ping-check profile \(profile)")
            }
        } else if let current, !current.profile.isEmpty {
            plan.commands.append("interface \(interface) no ping-check profile")
        }

        let hadRestart = current?.restart ?? false
        if restart != hadRestart {
            plan.commands.append(restart
                ? "interface \(interface) ping-check restart"
                : "interface \(interface) no ping-check restart")
        }
        return plan
    }
}
