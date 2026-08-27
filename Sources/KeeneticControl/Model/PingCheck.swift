import Foundation

/// Профиль Ping-Check. В веб-панели Keenetic их не настроить — только через
/// командную строку, поэтому приложение даёт им нормальный интерфейс.
struct PingCheckProfile: Identifiable, Hashable {
    enum Mode: String, CaseIterable, Identifiable {
        case icmp, tcp, auto
        var id: String { rawValue }
        var title: String {
            switch self {
            case .icmp: return "ICMP (ping)"
            case .tcp:  return "TCP (порт)"
            case .auto: return "Автоматически"
            }
        }
    }

    var name: String
    var host: String = ""
    var mode: Mode = .icmp
    var port: Int?
    var maxFails: Int?
    var minSuccess: Int?
    var updateInterval: Int?
    var timeout: Int?
    /// «default» роутер держит внутри себя и в конфигурацию не пишет.
    var isBuiltIn: Bool = false

    var id: String { name }

    /// Короткая сводка параметров для списка.
    var summary: String {
        var parts: [String] = [mode.rawValue]
        if !host.isEmpty { parts.append(host) }
        if mode == .tcp, let port { parts.append("порт \(port)") }
        if let updateInterval { parts.append("каждые \(updateInterval) с") }
        if let maxFails { parts.append("отказ после \(maxFails)") }
        if let minSuccess { parts.append("подъём после \(minSuccess)") }
        if let timeout { parts.append("тайм-аут \(timeout) с") }
        return parts.joined(separator: " · ")
    }

    /// Команды, создающие профиль с нуля или приводящие существующий к этому виду.
    func commands() -> [String] {
        let head = "ping-check profile \(name)"
        var result = [head]
        if !host.isEmpty { result.append("\(head) host \(host)") }
        result.append("\(head) mode \(mode.rawValue)")
        if mode == .tcp, let port { result.append("\(head) port \(port)") }
        if let updateInterval { result.append("\(head) update-interval \(updateInterval)") }
        if let maxFails { result.append("\(head) max-fails \(maxFails)") }
        if let minSuccess { result.append("\(head) min-success \(minSuccess)") }
        if let timeout { result.append("\(head) timeout \(timeout)") }
        return result
    }

    static func validate(_ profile: PingCheckProfile) throws {
        let name = profile.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw TransportError("Укажи имя профиля.") }
        guard name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw TransportError("Имя профиля: латиница, цифры, дефис и подчёркивание.")
        }
        guard !profile.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TransportError("Укажи узел, который будет проверяться.")
        }
        if profile.mode == .tcp {
            guard let port = profile.port, (1...65535).contains(port) else {
                throw TransportError("Для режима TCP нужен порт от 1 до 65535.")
            }
        }
        for (label, value) in [("Интервал", profile.updateInterval),
                               ("Порог отказа", profile.maxFails),
                               ("Порог подъёма", profile.minSuccess),
                               ("Тайм-аут", profile.timeout)] {
            if let value, !(1...600).contains(value) {
                throw TransportError("\(label): допустимы значения от 1 до 600.")
            }
        }
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
            if rest == "restart" {
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
        let parts = setting.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let value = parts[1].trimmingCharacters(in: .whitespaces)

        switch parts[0] {
        case "host":            profile.host = CLI.unquote(value)
        case "mode":            profile.mode = PingCheckProfile.Mode(rawValue: value) ?? .icmp
        case "port":            profile.port = Int(value)
        case "max-fails":       profile.maxFails = Int(value)
        case "min-success":     profile.minSuccess = Int(value)
        case "update-interval": profile.updateInterval = Int(value)
        case "timeout":         profile.timeout = Int(value)
        default: break
        }
    }

    // MARK: - Планы изменений

    static func planSave(_ profile: PingCheckProfile, existing: PingCheckProfile?) -> Plan {
        var plan = Plan(title: existing == nil
                        ? "Новый профиль Ping-Check «\(profile.name)»"
                        : "Изменение профиля «\(profile.name)»")
        plan.commands = profile.commands()

        // Параметры, которые были заданы, а теперь очищены, надо снять явно.
        if let existing {
            let head = "ping-check profile \(profile.name)"
            if existing.port != nil, profile.port == nil || profile.mode != .tcp {
                plan.commands.append("\(head) no port")
            }
            if existing.timeout != nil, profile.timeout == nil { plan.commands.append("\(head) no timeout") }
            if existing.minSuccess != nil, profile.minSuccess == nil { plan.commands.append("\(head) no min-success") }
            if existing.maxFails != nil, profile.maxFails == nil { plan.commands.append("\(head) no max-fails") }
            if existing.updateInterval != nil, profile.updateInterval == nil {
                plan.commands.append("\(head) no update-interval")
            }
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
