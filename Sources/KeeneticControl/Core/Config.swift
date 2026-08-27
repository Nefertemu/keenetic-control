import Foundation

enum TransportKind: String, Codable, CaseIterable, Identifiable {
    case ssh
    case http

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ssh:  return "SSH (командная строка)"
        case .http: return "HTTP RCI (веб-панель)"
        }
    }

    var shortTitle: String {
        switch self {
        case .ssh:  return "SSH"
        case .http: return "RCI"
        }
    }

    var icon: String {
        switch self {
        case .ssh:  return "terminal"
        case .http: return "globe"
        }
    }
}

struct RouterProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = "Роутер"
    var host: String = "192.168.1.1"
    var port: Int = 22
    var user: String = "admin"
    /// Базовый адрес веб-панели для RCI. Пусто — соберём из host автоматически.
    var webURL: String = ""
    var transport: TransportKind = .ssh

    /// Ключ в связке ключей: у каждого роутера свой пароль.
    var keychainAccount: String { "router-\(id.uuidString)" }

    var password: String? {
        get { Keychain.load(account: keychainAccount) }
        nonmutating set {
            if let value = newValue, !value.isEmpty {
                Keychain.save(value, account: keychainAccount)
            } else {
                Keychain.delete(account: keychainAccount)
            }
        }
    }

    /// KEENETIC_PASSWORD_<АДРЕС> — как в консольном скрипте.
    var environmentKey: String {
        host.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .uppercased()
    }

    /// Переменная окружения важнее связки ключей — так же, как в скрипте.
    var environmentPassword: String? {
        let environment = ProcessInfo.processInfo.environment
        for name in ["KEENETIC_PASSWORD_\(environmentKey)", "KEENETIC_PASSWORD"] {
            if let value = environment[name], !value.isEmpty { return value }
        }
        return nil
    }

    /// Пароль, с которым реально идём на роутер.
    var resolvedPassword: String? { environmentPassword ?? password }

    var effectiveWebURL: String {
        let trimmed = webURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return normalizeWebURL(trimmed) }
        return normalizeWebURL("http://\(host)/")
    }

    var subtitle: String {
        switch transport {
        case .ssh:  return "\(user)@\(host):\(port)"
        case .http: return effectiveWebURL
        }
    }

    /// Куда реально уходит подключение — это и показываем пользователю.
    /// Порт 22 у SSH подразумевается и только занимает место.
    var endpoint: String {
        switch transport {
        case .ssh:  return port == 22 ? host : "\(host):\(port)"
        case .http: return effectiveWebURL
        }
    }

    /// По чему судим, что профиль изменился настолько, что старое
    /// соединение к нему уже не относится.
    var connectionKey: String {
        "\(transport.rawValue)|\(host)|\(port)|\(user)|\(webURL)"
    }

    /// Локальная панель живёт по http, KeenDNS и любой внешний адрес — по https.
    static func looksLocal(_ host: String) -> Bool {
        if host.hasSuffix(".local") || host == "localhost" { return true }
        guard let value = IPTools.parseIPv4(host) else { return false }
        let first = (value >> 24) & 0xFF
        let second = (value >> 16) & 0xFF
        return first == 10 || first == 127
            || (first == 192 && second == 168)
            || (first == 172 && (16...31).contains(second))
    }

    /// Приводим адрес к виду «http://host:port/» — без /auth, /rci и прочих путей.
    private func normalizeWebURL(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            let bareHost = String(text.split(separator: "/").first ?? "")
                .split(separator: ":").first.map(String.init) ?? text
            text = (RouterProfile.looksLocal(bareHost) ? "http://" : "https://") + text
        }
        guard var components = URLComponents(string: text) else { return value }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? value
    }
}

struct AppSettings: Codable {
    /// Сколько доменов кладём в одну часть списка.
    var chunkSize: Int = 300
    /// Жёсткий потолок на список — проверка после применения.
    var maxDomainsPerList: Int = 300
    /// Сколько команд `include` отправляем одной пачкой.
    var batchSize: Int = 8
    var cacheTTLMinutes: Int = 60
    var defaultAuto: Bool = true
    var defaultReject: Bool = false
    var keepBackups: Int = 20
    var removeStaleByDefault: Bool = true
    var saveConfigAfterApply: Bool = true
    /// Последний выбранный роутер — чтобы запуск не сбрасывал его на первый.
    var lastRouterID: String = ""

    static let `default` = AppSettings()
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var routers: [RouterProfile] {
        didSet { persistRouters() }
    }
    @Published var settings: AppSettings {
        didSet { persistSettings() }
    }
    @Published var selectedRouterID: UUID? {
        didSet {
            guard !loading, let id = selectedRouterID else { return }
            settings.lastRouterID = id.uuidString
        }
    }

    var selectedRouter: RouterProfile? {
        guard let id = selectedRouterID else { return routers.first }
        return routers.first { $0.id == id } ?? routers.first
    }

    private var loading = true

    private init() {
        let decoder = JSONDecoder()

        if let data = try? Data(contentsOf: AppPaths.routersFile),
           let saved = try? decoder.decode([RouterProfile].self, from: data),
           !saved.isEmpty {
            routers = saved
        } else {
            routers = Store.seedRouters
        }

        if let data = try? Data(contentsOf: AppPaths.settingsFile),
           let saved = try? decoder.decode(AppSettings.self, from: data) {
            settings = saved
        } else {
            settings = .default
        }

        let remembered = UUID(uuidString: settings.lastRouterID)
        selectedRouterID = routers.contains { $0.id == remembered } ? remembered : routers.first?.id
        loading = false
        persistRouters()
    }

    /// На первом запуске — один роутер по стандартному адресу Keenetic.
    /// Остальные добавляются в «Роутеры и настройки» и живут в routers.json.
    private static var seedRouters: [RouterProfile] {
        [RouterProfile(name: "Мой Keenetic", host: "192.168.1.1", port: 22, user: "admin")]
    }

    func add(_ router: RouterProfile) {
        routers.append(router)
        selectedRouterID = router.id
    }

    func update(_ router: RouterProfile) {
        guard let index = routers.firstIndex(where: { $0.id == router.id }) else { return }
        routers[index] = router
    }

    func remove(_ router: RouterProfile) {
        router.password = nil
        // Вместе с роутером убираем и его rollback-базы WireGuard,
        // иначе они остаются в связке ключей навсегда.
        for name in WireGuardVault.baselineAccounts(router: router) {
            Keychain.delete(account: name)
        }
        routers.removeAll { $0.id == router.id }
        if selectedRouterID == router.id { selectedRouterID = routers.first?.id }
    }

    private func persistRouters() {
        guard !loading else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(routers).write(to: AppPaths.routersFile, options: .atomic)
    }

    private func persistSettings() {
        guard !loading else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(settings).write(to: AppPaths.settingsFile, options: .atomic)
    }
}
