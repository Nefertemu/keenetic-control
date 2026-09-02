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

    /// В веб-адресе не должно быть логина/пароля: пароль хранится отдельно в
    /// Keychain, а URL попадает в профиль, журнал и резервные копии настроек.
    var hasEmbeddedWebCredentials: Bool {
        guard !webURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let components = webURLComponents(webURL)
        else { return false }
        return components.user != nil || components.password != nil
    }

    /// Убираем встроенные учётные данные перед сохранением профиля. Заодно
    /// приводим URL к тому же виду, который фактически использует RCI.
    mutating func removeEmbeddedWebCredentials() {
        guard hasEmbeddedWebCredentials else { return }
        webURL = normalizeWebURL(webURL)
    }

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
        "\(transport.rawValue)|\(host)|\(port)|\(user)|\(effectiveWebURL)"
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
        guard var components = webURLComponents(value) else { return value }
        components.user = nil
        components.password = nil
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? value
    }

    /// URLComponents не распознаёт голый адрес как host, поэтому сначала
    /// добавляем тот же scheme, который использовался ранее при нормализации.
    private func webURLComponents(_ value: String) -> URLComponents? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            let bareHost = String(text.split(separator: "/").first ?? "")
                .split(separator: ":").first.map(String.init) ?? text
            text = (RouterProfile.looksLocal(bareHost) ? "http://" : "https://") + text
        }
        return URLComponents(string: text)
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
    /// Интервал активной проверки всех клиентских WireGuard-туннелей.
    var wireGuardProbeIntervalSeconds: Int = 3
    /// Как часто само перечитывать конфигурацию подключённого роутера,
    /// чтобы правки из веб-панели появлялись без нажатия «Обновить».
    /// 0 — не перечитывать.
    var autoReloadSeconds: Int = 60
    /// Последний выбранный роутер — чтобы запуск не сбрасывал его на первый.
    var lastRouterID: String = ""
    /// Фоновая сверка источников с роутером.
    var autoUpdateEnabled: Bool = false
    var autoUpdateHours: Int = 24
    /// Пусто — сверять все источники.
    var autoUpdateSources: [String] = []
    var autoUpdateNotify: Bool = true
    var lastAutoUpdate: Date?
    /// Проверка новых версий приложения на GitHub.
    var checkAppUpdates: Bool = true
    var lastUpdateCheck: Date?

    static let `default` = AppSettings()

    init() {}

    /// Читаем каждое поле по отдельности и по отсутствию берём значение по
    /// умолчанию. Синтезированный декодер спотыкается на любом новом поле,
    /// и тогда файл настроек считается битым — а это молча сбрасывало бы
    /// ВСЕ настройки при первом запуске новой версии.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ default: T) -> T {
            ((try? box.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? `default`
        }

        chunkSize = value(.chunkSize, fallback.chunkSize)
        maxDomainsPerList = value(.maxDomainsPerList, fallback.maxDomainsPerList)
        batchSize = value(.batchSize, fallback.batchSize)
        cacheTTLMinutes = value(.cacheTTLMinutes, fallback.cacheTTLMinutes)
        defaultAuto = value(.defaultAuto, fallback.defaultAuto)
        defaultReject = value(.defaultReject, fallback.defaultReject)
        keepBackups = value(.keepBackups, fallback.keepBackups)
        removeStaleByDefault = value(.removeStaleByDefault, fallback.removeStaleByDefault)
        saveConfigAfterApply = value(.saveConfigAfterApply, fallback.saveConfigAfterApply)
        wireGuardProbeIntervalSeconds = value(
            .wireGuardProbeIntervalSeconds, fallback.wireGuardProbeIntervalSeconds)
        autoReloadSeconds = value(.autoReloadSeconds, fallback.autoReloadSeconds)
        lastRouterID = value(.lastRouterID, fallback.lastRouterID)
        autoUpdateEnabled = value(.autoUpdateEnabled, fallback.autoUpdateEnabled)
        autoUpdateHours = value(.autoUpdateHours, fallback.autoUpdateHours)
        autoUpdateSources = value(.autoUpdateSources, fallback.autoUpdateSources)
        autoUpdateNotify = value(.autoUpdateNotify, fallback.autoUpdateNotify)
        checkAppUpdates = value(.checkAppUpdates, fallback.checkAppUpdates)
        lastUpdateCheck = try? box.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        lastAutoUpdate = try? box.decodeIfPresent(Date.self, forKey: .lastAutoUpdate)
    }
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
    /// Личные источники доменов — рядом со встроенным каталогом.
    @Published var customSources: [CustomSource] = [] {
        didSet { persistSources() }
    }
    /// Сохранённые последовательности резервирования.
    @Published var failoverProfiles: [FailoverProfile] = [] {
        didSet { persistFailover() }
    }
    @Published var selectedRouterID: UUID? {
        didSet {
            guard !loading, let id = selectedRouterID else { return }
            settings.lastRouterID = id.uuidString
        }
    }

    /// Встроенные источники плюс свои — в этом порядке.
    var allSources: [SourceSpec] { SourceCatalog.all + customSources.map(\.spec) }

    func source(for key: String) -> SourceSpec? { allSources.first { $0.key == key } }

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
            routers = saved.map { router in
                var sanitized = router
                sanitized.removeEmbeddedWebCredentials()
                return sanitized
            }
        } else {
            routers = Store.seedRouters
        }

        if let data = try? Data(contentsOf: AppPaths.settingsFile),
           let saved = try? decoder.decode(AppSettings.self, from: data) {
            settings = saved
        } else {
            settings = .default
        }

        if let data = try? Data(contentsOf: AppPaths.sourcesFile),
           let saved = try? decoder.decode([CustomSource].self, from: data) {
            customSources = saved
        }

        if let data = try? Data(contentsOf: AppPaths.failoverFile),
           let saved = try? decoder.decode([FailoverProfile].self, from: data) {
            failoverProfiles = saved
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
        var sanitized = router
        sanitized.removeEmbeddedWebCredentials()
        routers.append(sanitized)
        selectedRouterID = sanitized.id
    }

    func update(_ router: RouterProfile) {
        var sanitized = router
        sanitized.removeEmbeddedWebCredentials()
        guard let index = routers.firstIndex(where: { $0.id == sanitized.id }) else { return }
        routers[index] = sanitized
    }

    func remove(_ router: RouterProfile) {
        routers.removeAll { $0.id == router.id }
        // Профили резервирования держат имена интерфейсов ЭТОГО роутера —
        // без него они бессмысленны и только копятся в файле.
        failoverProfiles.removeAll { $0.routerID == router.id }
        if selectedRouterID == router.id { selectedRouterID = routers.first?.id }

        // Связка ключей умеет показать системный запрос и ждать ответа
        // сколько угодно — из списка роутер убираем сразу, чистим следом.
        let accounts = [router.keychainAccount] + WireGuardVault.baselineAccounts(router: router)
        Task.detached {
            // Вместе с роутером убираем и его rollback-базы WireGuard,
            // иначе они остаются в связке ключей навсегда.
            for name in accounts { Keychain.delete(account: name) }
        }
    }

    private func persistRouters() {
        guard !loading else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sanitized = routers.map { router in
            var copy = router
            copy.removeEmbeddedWebCredentials()
            return copy
        }
        try? encoder.encode(sanitized).write(to: AppPaths.routersFile, options: .atomic)
    }

    func addSource(_ source: CustomSource) { customSources.append(source) }

    func updateSource(_ source: CustomSource) {
        guard let index = customSources.firstIndex(where: { $0.id == source.id }) else { return }
        customSources[index] = source
    }

    func removeSource(_ source: CustomSource) {
        // Кэш личного источника больше никому не нужен.
        try? FileManager.default.removeItem(at: source.spec.cacheFile)
        try? FileManager.default.removeItem(at: source.spec.subnetCacheFile)
        customSources.removeAll { $0.id == source.id }
    }

    /// Профили резервирования выбранного роутера.
    func failoverProfiles(for routerID: UUID) -> [FailoverProfile] {
        failoverProfiles.filter { $0.routerID == routerID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func saveFailover(_ profile: FailoverProfile) {
        if let index = failoverProfiles.firstIndex(where: { $0.id == profile.id }) {
            failoverProfiles[index] = profile
        } else {
            failoverProfiles.append(profile)
        }
    }

    func removeFailover(_ profile: FailoverProfile) {
        failoverProfiles.removeAll { $0.id == profile.id }
    }

    private func persistFailover() {
        guard !loading else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(failoverProfiles).write(to: AppPaths.failoverFile, options: .atomic)
    }

    private func persistSources() {
        guard !loading else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(customSources).write(to: AppPaths.sourcesFile, options: .atomic)
    }

    private func persistSettings() {
        guard !loading else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(settings).write(to: AppPaths.settingsFile, options: .atomic)
    }
}
