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
            guard uri.hasPrefix("http://") || uri.hasPrefix("https://") else {
                throw TransportError("Адрес должен начинаться с http:// или https://")
            }
        } else {
            guard !profile.host.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw TransportError("Укажи узел, который будет проверяться.")
            }
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
}

/// Привязка профиля к интерфейсу.
struct PingCheckBinding: Hashable {
    var profile: String
    /// Перезапускать интерфейс при потере связи.
    var restart: Bool
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
            commands.append("\(head) uri \(profile.uri)")
            if let old = existing, !old.host.isEmpty { commands.append("\(head) no host") }
        } else {
            commands.append("\(head) host \(profile.host)")
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
