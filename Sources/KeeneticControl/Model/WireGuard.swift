import Foundation

struct WireGuardConfig {
    var interfaceValues: [String: String] = [:]
    var peers: [[String: String]] = []
    var sourceText: String = ""
    var fileName: String = ""

    subscript(_ key: String) -> String {
        interfaceValues[key.lowercased()] ?? ""
    }

    var peer: [String: String] { peers.first ?? [:] }
    func peerValue(_ key: String) -> String { peer[key.lowercased()] ?? "" }

    var privateKey: String { self["PrivateKey"] }
    var address: String { self["Address"] }
    var listenPort: String { self["ListenPort"] }
    var mtu: String { self["MTU"] }
    var publicKey: String { peerValue("PublicKey") }
    var endpoint: String { peerValue("Endpoint") }
    var allowedIPs: String { peerValue("AllowedIPs") }
    var presharedKey: String { peerValue("PresharedKey") }
    var keepalive: String { peerValue("PersistentKeepalive") }

    /// AmneziaWG узнаём по обфускационным параметрам.
    var isAmnezia: Bool {
        ["jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4"]
            .contains { !(interfaceValues[$0] ?? "").isEmpty }
    }

    /// AmneziaWG 2.0 добавляет I1…I5.
    var isAmnezia2: Bool {
        ["i1", "i2", "i3", "i4", "i5"].contains { !(interfaceValues[$0] ?? "").isEmpty }
    }

    var flavour: String {
        if isAmnezia2 { return "AmneziaWG 2.0" }
        if isAmnezia { return "AmneziaWG" }
        return "WireGuard"
    }

    /// Что показать пользователю до применения.
    var summaryRows: [(String, String)] {
        var rows: [(String, String)] = [("Тип", flavour)]
        if !address.isEmpty { rows.append(("Адрес интерфейса", address)) }
        if !listenPort.isEmpty { rows.append(("ListenPort", listenPort)) }
        if !mtu.isEmpty { rows.append(("MTU", mtu)) }
        if !publicKey.isEmpty { rows.append(("PublicKey пира", publicKey)) }
        if !endpoint.isEmpty { rows.append(("Endpoint", endpoint)) }
        if !allowedIPs.isEmpty { rows.append(("AllowedIPs", allowedIPs)) }
        if !keepalive.isEmpty { rows.append(("Keepalive", keepalive + " с")) }
        rows.append(("PresharedKey", presharedKey.isEmpty ? "нет" : "есть"))
        rows.append(("Пиров в файле", String(peers.count)))
        return rows
    }

    static func parse(text: String, fileName: String = "") throws -> WireGuardConfig {
        var config = WireGuardConfig()
        config.sourceText = text
        config.fileName = fileName

        var section = ""
        var currentPeer: [String: String] = [:]

        func closePeer() {
            if !currentPeer.isEmpty { config.peers.append(currentPeer); currentPeer = [:] }
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let comment = line.firstIndex(where: { $0 == "#" || $0 == ";" }) {
                line = String(line[line.startIndex..<comment]).trimmingCharacters(in: .whitespaces)
            }
            if line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).lowercased()
                if name == "peer" { closePeer() }
                section = name
                continue
            }

            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            if section == "peer" { currentPeer[key] = value }
            else if section == "interface" { config.interfaceValues[key] = value }
        }
        closePeer()

        guard !config.interfaceValues.isEmpty else {
            throw TransportError("В файле нет секции [Interface].")
        }
        guard config.peers.count == 1 else {
            if config.peers.isEmpty {
                throw TransportError("В файле нет ни одной секции [Peer].")
            }
            throw TransportError(
                "В файле \(config.peers.count) пиров, а безопасное обновление поддерживает ровно один.",
                hint: "Не загружай такой файл частично: выбери отдельный .conf с одним [Peer] "
                    + "или настрой интерфейс вручную в веб-панели.")
        }
        guard !config.privateKey.isEmpty else {
            throw TransportError("В [Interface] отсутствует PrivateKey.")
        }
        guard !config.publicKey.isEmpty else {
            throw TransportError("В [Peer] отсутствует PublicKey.")
        }
        guard !config.allowedIPs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TransportError(
                "В [Peer] отсутствует AllowedIPs.",
                hint: "Без маршрутов безопасное обновление могло бы отключить туннель после удаления старого пира.")
        }
        return config
    }
}

/// Готовит последовательность команд Keenetic CLI. Порядок важен и повторяет
/// проверенный сценарий: сначала подготовка, потом ключ, потом старый пир прочь.
enum WireGuardPlanner {
    struct Stage {
        var title: String
        var commands: [String]
    }

    static func stages(interface: String, config: WireGuardConfig) throws -> [Stage] {
        guard interface.range(of: "^Wireguard\\d+$", options: .regularExpression) != nil else {
            throw TransportError("Некорректное имя интерфейса: \(interface)")
        }
        guard config.peers.count == 1 else {
            throw TransportError(
                "Безопасное обновление WireGuard работает только с конфигом с одним [Peer].")
        }
        guard !config.allowedIPs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TransportError("В конфиге WireGuard нет AllowedIPs.")
        }
        try validateKey(config.privateKey, label: "PrivateKey")
        try validateKey(config.publicKey, label: "PublicKey")
        if !config.presharedKey.isEmpty {
            try validateKey(config.presharedKey, label: "PresharedKey")
        }
        if !config.endpoint.isEmpty {
            try validateEndpoint(config.endpoint)
        }
        let key = CLI.quote(config.publicKey)
        var stages: [Stage] = []

        stages.append(Stage(title: "Выключаю интерфейс", commands: ["interface \(interface) down"]))

        // 1. Новый пир создаётся БЕЗ AllowedIPs, старый пока не трогаем.
        var staging = ["interface \(interface) wireguard peer \(key)"]
        if !config.endpoint.isEmpty {
            staging.append("interface \(interface) wireguard peer \(key) endpoint \(config.endpoint)")
        }
        if !config.presharedKey.isEmpty {
            staging.append("interface \(interface) wireguard peer \(key) preshared-key "
                           + CLI.quote(config.presharedKey))
        }
        if let keepalive = Int(config.keepalive.trimmingCharacters(in: .whitespaces)), keepalive > 0 {
            staging.append("interface \(interface) wireguard peer \(key) keepalive-interval \(keepalive)")
        }
        stages.append(Stage(title: "Готовлю нового пира", commands: staging))

        // 2. Адреса, MTU, порт.
        var setup: [String] = []
        for entry in config.address.split(separator: ",") {
            let value = entry.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if value.contains(":") {
                guard let parts = splitPrefix(value) else {
                    throw TransportError("Некорректный IPv6-адрес интерфейса: \(value)")
                }
                setup.append("interface \(interface) ipv6 address \(parts.0)/\(parts.1)")
            } else if value.contains("/") {
                guard let parsed = IPTools.ipv4CIDRToAddressMask(value) else {
                    throw TransportError("Некорректный адрес интерфейса: \(value)")
                }
                setup.append("interface \(interface) ip address \(parsed.address) \(parsed.mask)")
            } else if IPTools.isIPv4(value) {
                setup.append("interface \(interface) ip address \(value) 255.255.255.255")
            } else {
                throw TransportError("Некорректный адрес интерфейса: \(value)")
            }
        }

        if !config.mtu.isEmpty {
            guard let mtu = Int(config.mtu.trimmingCharacters(in: .whitespaces)), (576...9000).contains(mtu) else {
                throw TransportError("Некорректный MTU: \(config.mtu)")
            }
            setup.append("interface \(interface) ip mtu \(mtu)")
        }
        if !config.listenPort.isEmpty {
            guard let port = Int(config.listenPort.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
                throw TransportError("Некорректный ListenPort: \(config.listenPort)")
            }
            setup.append("interface \(interface) wireguard listen-port \(port)")
        }
        if !setup.isEmpty {
            stages.append(Stage(title: "Адрес, MTU, порт", commands: setup))
        }

        // 3. Обфускация AmneziaWG.
        stages.append(Stage(title: "Параметры обфускации", commands: [try ascCommand(interface: interface, config: config)]))

        // 4. Приватный ключ — только после успешной подготовки.
        stages.append(Stage(
            title: "Приватный ключ",
            commands: ["interface \(interface) wireguard private-key " + CLI.quote(config.privateKey)]))

        // 5. AllowedIPs: сначала чистим, потом задаём.
        var allowed = ["interface \(interface) wireguard peer \(key) no allow-ips"]
        for entry in config.allowedIPs.split(separator: ",") {
            let value = entry.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if value.contains(":") {
                guard let parts = splitPrefix(value) else {
                    throw TransportError("Некорректный AllowedIPs: \(value)")
                }
                allowed.append("interface \(interface) wireguard peer \(key) allow-ips \(parts.0) \(parts.1)")
            } else {
                let cidr = value.contains("/") ? value : "\(value)/32"
                guard let parsed = IPTools.ipv4CIDRToAddressMask(cidr) else {
                    throw TransportError("Некорректный AllowedIPs: \(value)")
                }
                allowed.append("interface \(interface) wireguard peer \(key) allow-ips \(parsed.address) \(parsed.mask)")
            }
        }
        allowed.append("interface \(interface) wireguard peer \(key) connect")
        stages.append(Stage(title: "Маршруты пира (AllowedIPs)", commands: allowed))

        return stages
    }

    /// Ключи в конфиге должны оставаться одним CLI-аргументом. CLI.quote
    /// экранирует кавычки, но перевод строки всё равно разделил бы команды
    /// в SSH-терминале, поэтому отбрасываем любые неожиданные символы заранее.
    private static func validateKey(_ value: String, label: String) throws {
        guard !value.isEmpty else {
            throw TransportError("\(label) содержит недопустимые символы.")
        }
        for byte in value.utf8 {
            let asciiAlphaNumeric = (48...57).contains(byte)
                || (65...90).contains(byte) || (97...122).contains(byte)
            let extra = byte == 43 || byte == 47 || byte == 61 || byte == 95 || byte == 45
            guard asciiAlphaNumeric || extra else {
                throw TransportError("\(label) содержит недопустимые символы.")
            }
        }
    }

    private static func isDecimal(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        for scalar in value.unicodeScalars where !(48...57).contains(scalar.value) {
            return false
        }
        return true
    }

    private static func hasControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }

    private static func hasForbiddenEndpointCharacter(_ value: String) -> Bool {
        value.contains { ";|$<>\"'\\!".contains($0) }
    }

    private static func validateEndpoint(_ value: String) throws {
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !hasControl(value),
              !hasForbiddenEndpointCharacter(value)
        else {
            throw TransportError("Endpoint содержит недопустимые служебные символы.")
        }
    }

    /// Команды удаления старых пиров — выполняются только после проверки нового.
    static func removeOldPeers(interface: String, oldKeys: [String], newKey: String) -> [String] {
        oldKeys.filter { $0 != newKey }
            .map { "interface \(interface) no wireguard peer \(CLI.quote($0))" }
    }

    static func bringUp(interface: String) -> [String] { ["interface \(interface) up"] }

    /// Переименовать туннель в UI Keenetic — это его `description`, а не имя
    /// `WireguardN` (идентификатор менять на лету прошивка не позволяет).
    static func planRename(interface: String, current: String, desired: String) throws -> Plan {
        guard interface.range(of: "^Wireguard\\d+$", options: .regularExpression) != nil else {
            throw TransportError("Некорректное имя интерфейса: \(interface)")
        }
        let clean = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TransportError("Имя интерфейса не может содержать переводы строк или служебные символы.")
        }
        var plan = Plan(title: "Переименование \(interface)")
        guard clean != current else { return plan }
        if clean.isEmpty {
            plan.commands = ["interface \(interface) no description"]
            plan.notes.append("У интерфейса будет убрана подпись; техническое имя \(interface) останется.")
        } else {
            plan.commands = ["interface \(interface) description \(CLI.quote(clean))"]
            plan.notes.append("Техническое имя \(interface) не меняется — изменяется только подпись в приложении и веб-панели.")
        }
        return plan
    }

    private static func ascCommand(interface: String, config: WireGuardConfig) throws -> String {
        guard config.isAmnezia else { return "interface \(interface) no wireguard asc" }

        func number(_ name: String) throws -> String {
            let value = (config.interfaceValues[name.lowercased()] ?? "").trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { throw TransportError("В AmneziaWG отсутствует параметр \(name).") }
            guard Int(value) != nil, isDecimal(value)
            else { throw TransportError("Некорректный \(name): \(value)") }
            return value
        }

        let head = try ["Jc", "Jmin", "Jmax", "S1", "S2"].map(number).joined(separator: " ")

        var headers: [String] = []
        for name in ["H1", "H2", "H3", "H4"] {
            let value = (config.interfaceValues[name.lowercased()] ?? "")
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " ", with: "")
            guard isDecimal(value) else { throw TransportError("Некорректный \(name): \(value)") }
            headers.append(value)
        }

        var command = "interface \(interface) wireguard asc \(head) \(headers.joined(separator: " "))"

        guard config.isAmnezia2 else { return command }

        func optionalNumber(_ name: String) throws -> String {
            let value = (config.interfaceValues[name.lowercased()] ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard value.isEmpty || isDecimal(value) else {
                throw TransportError("Некорректный \(name): \(value)")
            }
            return value.isEmpty ? "0" : value
        }

        command += " \(try optionalNumber("S3")) \(try optionalNumber("S4"))"

        for name in ["I1", "I2", "I3", "I4", "I5"] {
            var value = (config.interfaceValues[name.lowercased()] ?? "").trimmingCharacters(in: .whitespaces)
            if value == "0" { value = "" }
            guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw TransportError("Параметр \(name) содержит перевод строки или служебный символ.")
            }
            command += " " + CLI.quote(value)
        }
        return command
    }

    private static func splitPrefix(_ value: String) -> (String, String)? {
        let parts = value.split(separator: "/", maxSplits: 1)
        if parts.count == 2, let prefix = Int(parts[1]), (0...128).contains(prefix),
           IPTools.isIPv6(String(parts[0])) {
            return (String(parts[0]), String(prefix))
        }
        if IPTools.isIPv6(value) { return (value, "128") }
        return nil
    }
}

/// Живое состояние интерфейса WireGuard, вытащенное из running-config.
struct WireGuardState {
    var interface: String
    var peerKeys: [String] = []
    var listenPort: String = ""
    var addresses: [String] = []
    var mtu: Int?
    var isUp: Bool = false
    var descriptionText: String = ""
    /// У клиентского туннеля endpoint задан в конфигурации. У VPN-сервера
    /// адреса клиентов появляются динамически и команды `endpoint` нет.
    var hasConfiguredEndpoint = false
    var peerAcceptsDefaultRoute = false
    var securityLevel = ""

    var isClientTunnel: Bool {
        let name = descriptionText.lowercased()
        let explicitlyServer = name.contains("vpn server")
            || name.contains("wireguard server")
            || name.contains("wg server")
            || name.contains("vpn-сервер")
            || name.contains("сервер vpn")
        return hasConfiguredEndpoint && peerAcceptsDefaultRoute
            && securityLevel.lowercased() != "private" && !explicitlyServer
    }

    static func parse(config text: String, interface: String) -> WireGuardState {
        var state = WireGuardState(interface: interface)
        var inside = false

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let topLevel = !line.isEmpty && !(line.first?.isWhitespace ?? false)

            if topLevel {
                inside = (trimmed == "interface \(interface)")
                continue
            }
            guard inside else { continue }

            if trimmed.hasPrefix("wireguard peer ") {
                let key = CLI.unquote(String(trimmed.dropFirst("wireguard peer ".count)))
                if !key.isEmpty, !state.peerKeys.contains(key) { state.peerKeys.append(key) }
            } else if trimmed.hasPrefix("wireguard listen-port ") {
                state.listenPort = String(trimmed.dropFirst("wireguard listen-port ".count))
            } else if trimmed.hasPrefix("endpoint ") {
                state.hasConfiguredEndpoint = true
            } else if trimmed.hasPrefix("allow-ips ") {
                let value = String(trimmed.dropFirst("allow-ips ".count))
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if value == "0.0.0.0 0.0.0.0" || value == "0.0.0.0/0"
                    || value == ":: 0" || value == "::/0" {
                    state.peerAcceptsDefaultRoute = true
                }
            } else if trimmed.hasPrefix("ip address ") {
                state.addresses.append(String(trimmed.dropFirst("ip address ".count)))
            } else if trimmed.hasPrefix("security-level ") {
                state.securityLevel = String(trimmed.dropFirst("security-level ".count))
            } else if trimmed.hasPrefix("ip mtu ") {
                state.mtu = Int(trimmed.dropFirst("ip mtu ".count)
                    .trimmingCharacters(in: .whitespaces))
            } else if trimmed.hasPrefix("description ") {
                state.descriptionText = CLI.unquote(String(trimmed.dropFirst("description ".count)))
            } else if trimmed == "up" {
                state.isUp = true
            } else if trimmed == "down" {
                state.isUp = false
            }
        }
        return state
    }

    /// Имена клиентских WireGuard-туннелей. Серверный интерфейс не является
    /// выходом в VPN: его нельзя пинговать как маршрут и назначать спискам.
    static func interfaceNames(config text: String) -> [String] {
        allInterfaceNames(config: text).filter {
            parse(config: text, interface: $0).isClientTunnel
        }
    }

    /// Полный список нужен только для диагностики и разбора конфигурации.
    static func allInterfaceNames(config text: String) -> [String] {
        var names: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard !line.isEmpty, !(line.first?.isWhitespace ?? false) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("interface Wireguard") else { continue }
            let name = String(trimmed.dropFirst("interface ".count))
            if name.range(of: "^Wireguard\\d+$", options: .regularExpression) != nil, !names.contains(name) {
                names.append(name)
            }
        }
        return names.sorted {
            (Int($0.dropFirst("Wireguard".count)) ?? 0) < (Int($1.dropFirst("Wireguard".count)) ?? 0)
        }
    }
}

/// Rollback-база: рабочий .conf, к которому можно вернуться.
/// Ключи чувствительные, поэтому лежат в связке ключей, а не в файле.
enum WireGuardVault {
    private static func account(router: RouterProfile, interface: String) -> String {
        "wg-baseline-\(router.id.uuidString)-\(interface)"
    }

    static func saveBaseline(_ text: String, router: RouterProfile, interface: String) {
        Keychain.save(text, account: account(router: router, interface: interface))
    }

    static func baseline(router: RouterProfile, interface: String) -> WireGuardConfig? {
        guard let text = Keychain.load(account: account(router: router, interface: interface)) else { return nil }
        return try? WireGuardConfig.parse(text: text, fileName: "rollback-база")
    }

    static func hasBaseline(router: RouterProfile, interface: String) -> Bool {
        Keychain.load(account: account(router: router, interface: interface)) != nil
    }

    static func clearBaseline(router: RouterProfile, interface: String) {
        Keychain.delete(account: account(router: router, interface: interface))
    }

    /// Все возможные имена rollback-баз роутера — для полной уборки.
    static func baselineAccounts(router: RouterProfile) -> [String] {
        (0...15).map { account(router: router, interface: "Wireguard\($0)") }
    }
}
