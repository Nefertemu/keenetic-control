import CryptoKit
import Foundation

/// Транспорт поверх веб-панели Keenetic (RCI). Работает там, где закрыт SSH,
/// и умеет отдавать структурированный JSON вместо разбора текста терминала.
final class RCITransport: KeeneticTransport {
    let kind: TransportKind = .http

    private let profile: RouterProfile
    private let password: String?
    private let session: URLSession
    private let baseURL: URL
    private var authorized = false

    init(profile: RouterProfile, password: String?) throws {
        self.profile = profile
        self.password = password

        guard let url = URL(string: profile.effectiveWebURL) else {
            throw TransportError("Некорректный адрес веб-панели: \(profile.effectiveWebURL)")
        }
        self.baseURL = url

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = HTTPCookieStorage()
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: - Авторизация

    func connect() throws {
        try authenticate()
        log(.ok, "RCI: подключено к \(baseURL.absoluteString)")
    }

    private func authenticate() throws {
        let (_, probe) = try perform(request(path: "auth", method: "GET"))

        if probe.statusCode == 200 {
            authorized = true
            return
        }
        guard probe.statusCode == 401 else {
            throw TransportError("Неожиданный ответ /auth: HTTP \(probe.statusCode).",
                                 hint: "Проверь адрес веб-панели роутера.")
        }

        let realm = probe.value(forHTTPHeaderField: "X-NDM-Realm")
        let challenge = probe.value(forHTTPHeaderField: "X-NDM-Challenge")

        guard let realm, let challenge, !realm.isEmpty, !challenge.isEmpty else {
            throw TransportError("Роутер не вернул X-NDM-Realm или X-NDM-Challenge.",
                                 hint: "Похоже, по этому адресу не веб-панель Keenetic.")
        }
        guard let password, !password.isEmpty else {
            throw TransportError("Для \(profile.host) не задан пароль.",
                                 hint: "Открой «Роутеры» и впиши пароль администратора.")
        }

        let md5 = hex(Insecure.MD5.hash(data: Data("\(profile.user):\(realm):\(password)".utf8)))
        let sha = hex(SHA256.hash(data: Data((challenge + md5).utf8)))

        var login = request(path: "auth", method: "POST")
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(
            withJSONObject: ["login": profile.user, "password": sha])

        let (body, response) = try perform(login)
        guard (200..<300).contains(response.statusCode) else {
            throw TransportError(
                "Авторизация не прошла: HTTP \(response.statusCode).",
                hint: "Проверь логин «\(profile.user)» и пароль администратора.")
        }
        _ = body
        authorized = true
    }

    private func hex<H: Sequence>(_ digest: H) -> String where H.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Команды

    func run(_ command: String, timeout: TimeInterval) throws -> String {
        if isConfigDump(command) { return try fetchText(command, timeout: timeout) }
        let result = try rci(method: "POST", path: "rci/parse", body: command)
        return RCITransport.renderStatus(result, command: command)
    }

    func runBatch(_ commands: [String], timeout: TimeInterval) throws -> String {
        // RCI умеет принимать массив команд одним запросом.
        guard !commands.isEmpty else { return "" }
        if commands.count == 1 { return try run(commands[0], timeout: timeout) }

        let payload = commands.map { ["parse": $0] }
        let result = try rci(method: "POST", path: "rci/", body: payload)
        return RCITransport.renderStatus(result, command: commands.joined(separator: "; "))
    }

    func fetchText(_ command: String, timeout: TimeInterval) throws -> String {
        let path: String
        if command.hasPrefix("show startup-config") {
            path = "ci/startup-config.txt"
        } else if isConfigDump(command) {
            path = "ci/running-config.txt"
        } else {
            return try run(command, timeout: timeout)
        }

        let text = try textGET(path)
        guard text.count > 200 else {
            throw TransportError("Роутер вернул подозрительно короткий \(path).")
        }
        return text
    }

    func close() {
        session.invalidateAndCancel()
        authorized = false
    }

    private func isConfigDump(_ command: String) -> Bool {
        command.hasPrefix("show running-config") || command.hasPrefix("show startup-config")
    }

    // MARK: - Структурированный доступ

    /// Сырой JSON от RCI — нужен для WireGuard и состояния интерфейсов.
    func json(method: String, path: String, body: Any? = nil) throws -> Any? {
        try rci(method: method, path: path, body: body)
    }

    @discardableResult
    private func rci(method: String, path: String, body: Any?) throws -> Any? {
        if !authorized { try authenticate() }

        var attempt = 0
        while true {
            var httpRequest = request(path: path, method: method)
            if method != "GET" {
                httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let payload = body ?? [String: Any]()
                httpRequest.httpBody = try JSONSerialization.data(
                    withJSONObject: payload, options: [.fragmentsAllowed])
            }

            let (data, response) = try perform(httpRequest)

            if response.statusCode == 401, attempt == 0 {
                attempt += 1
                authorized = false
                try authenticate()
                continue
            }

            guard (200..<300).contains(response.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                throw TransportError("RCI \(method) \(path) → HTTP \(response.statusCode). \(text)")
            }

            if data.isEmpty { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
    }

    private func textGET(_ path: String) throws -> String {
        if !authorized { try authenticate() }

        var attempt = 0
        while true {
            let (data, response) = try perform(request(path: path, method: "GET"))

            if response.statusCode == 401, attempt == 0 {
                attempt += 1
                authorized = false
                try authenticate()
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw TransportError("GET \(path) → HTTP \(response.statusCode).")
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private func request(path: String, method: String) -> URLRequest {
        let url = URL(string: path, relativeTo: baseURL) ?? baseURL
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("KeeneticControl/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// URLSession асинхронный, а транспорт — синхронный: ждём на семафоре.
    /// Вызывается только с фоновой очереди сессии роутера.
    private func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error>?

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(TransportError(RCITransport.describe(error)))
            } else if let http = response as? HTTPURLResponse {
                result = .success((data ?? Data(), http))
            } else {
                result = .failure(TransportError("Пустой ответ от роутера."))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        case nil: throw TransportError("Запрос к роутеру не завершился.")
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Адрес не разрешается: проверь имя роутера."
        case NSURLErrorCannotConnectToHost:
            return "Роутер не принимает соединение по этому адресу и порту."
        case NSURLErrorTimedOut:
            return "Роутер не ответил вовремя."
        default:
            return nsError.localizedDescription
        }
    }

    // MARK: - Ответы RCI в текст

    /// Превращаем JSON-ответ в строки, понятные общему детектору ошибок.
    static func renderStatus(_ value: Any?, command: String) -> String {
        var lines: [String] = []
        collect(value, into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func collect(_ value: Any?, into lines: inout [String]) {
        switch value {
        case let dictionary as [String: Any]:
            if let errors = dictionary["ndmErrors"], !(errors is NSNull) {
                lines.append("error: \(errors)")
            }

            let status = (dictionary["status"] as? String)?.lowercased()
            if let message = dictionary["message"] as? String, !message.isEmpty {
                lines.append(status == "error" ? "error: \(message)" : message)
            } else if status == "error" {
                lines.append("error: команда отклонена роутером")
            }

            for (key, nested) in dictionary where key != "message" && key != "status" {
                collect(nested, into: &lines)
            }

        case let array as [Any]:
            for item in array { collect(item, into: &lines) }

        default:
            break
        }
    }
}
