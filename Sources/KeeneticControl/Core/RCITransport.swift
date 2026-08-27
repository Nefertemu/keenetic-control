import CryptoKit
import Foundation

/// Транспорт поверх веб-панели Keenetic (RCI). Работает там, где закрыт SSH,
/// и умеет отдавать структурированный JSON вместо разбора текста терминала.
final class RCITransport: KeeneticTransport {
    let kind: TransportKind = .http

    private let profile: RouterProfile
    private let password: String?
    private let session: URLSession
    /// Роутер может увести с http на https. Дальше работаем по конечному
    /// адресу: иначе POST после 302 потеряет тело и авторизация не пройдёт.
    private var baseURL: URL
    private var authorized = false
    /// Новые прошивки объявляют схему x-ndw4 и перестают принимать старую,
    /// даже когда пароль верный. Отличаем это от настоящей ошибки пароля.
    private var advertisesModernAuth = false

    init(profile: RouterProfile, password: String?) throws {
        self.profile = profile
        self.password = password

        guard let url = URL(string: profile.effectiveWebURL) else {
            throw TransportError("Некорректный адрес веб-панели: \(profile.effectiveWebURL)")
        }
        self.baseURL = url

        let configuration = URLSessionConfiguration.ephemeral
        // Хранилище cookie у ephemeral уже своё и изолированное. Свой экземпляр
        // HTTPCookieStorage() cookie не удерживает — роутер тогда видит запрос
        // вне сессии, в которой выдал челлендж, и отвечает 400.
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
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
        adoptRedirect(from: probe)

        let offered = (probe.value(forHTTPHeaderField: "WWW-Authenticate") ?? "").lowercased()
        advertisesModernAuth = offered.contains("ndw4")

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
                                 hint: "Открой «Роутеры» и впиши пароль администратора.",
                                 isAuthFailure: true)
        }

        let md5 = hex(Insecure.MD5.hash(data: Data("\(profile.user):\(realm):\(password)".utf8)))
        let sha = hex(SHA256.hash(data: Data((challenge + md5).utf8)))

        var login = request(path: "auth", method: "POST")
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(
            withJSONObject: ["login": profile.user, "password": sha])

        let (body, response) = try perform(login)
        guard (200..<300).contains(response.statusCode) else {
            if advertisesModernAuth {
                throw TransportError(
                    "Роутер требует новую схему авторизации веб-панели (x-ndw4).",
                    hint: "Прошивка этого Keenetic («\(realm)») перешла на новый механизм "
                        + "входа и старую схему больше не принимает — даже с верным паролем. "
                        + "Приложение её пока не умеет.\n"
                        + "Для этого роутера выбери транспорт SSH — там всё работает.",
                    isAuthFailure: true)
            }
            throw TransportError(
                "Роутер не принял логин или пароль (HTTP \(response.statusCode)).",
                hint: "Веб-панель по адресу \(baseURL.absoluteString) представилась как "
                    + "«\(realm)» и ждёт пароль пользователя «\(profile.user)». "
                    + "У веб-панели он может отличаться от пароля для SSH — "
                    + "проверить можно скриптом Tools/check-rci-password.sh.",
                isAuthFailure: true)
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
        let candidates: [String]
        if command.hasPrefix("show startup-config") {
            candidates = ["ci/startup-config.txt", "rci/show/startup-config"]
        } else if isConfigDump(command) {
            candidates = ["ci/running-config.txt", "rci/show/running-config"]
        } else {
            return try run(command, timeout: timeout)
        }

        // Прошивки отдают конфигурацию по разным адресам, а на неизвестный путь
        // веб-панель молча возвращает свой HTML со статусом 200. Поэтому мало
        // получить ответ — надо убедиться, что это действительно конфигурация.
        var problems: [String] = []

        for path in candidates {
            let raw: String
            do { raw = try textGET(path) }
            catch {
                problems.append("\(path): \(error.localizedDescription)")
                continue
            }

            let text = CLI.normalizeNewlines(RCITransport.unwrapConfig(raw))
            if RCITransport.looksLikeConfig(text) {
                log(.info, "RCI: конфигурация получена из /\(path) (\(Format.bytes(text.utf8.count))).")
                return text
            }

            let head = text.prefix(120).replacingOccurrences(of: "\n", with: " ")
            problems.append("\(path): не похоже на конфигурацию "
                            + "(\(Format.bytes(text.utf8.count)), начало: «\(head)»)")
        }

        let dump = RCITransport.saveDiagnostic(problems)
        throw TransportError(
            "Роутер не отдал конфигурацию по известным адресам.",
            hint: problems.joined(separator: "\n")
                + (dump == nil ? "" : "\nПодробности: \(dump!.path)"))
    }

    /// Ответ может прийти как JSON с текстом внутри — достаём его.
    static func unwrapConfig(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return raw }

        var longest = ""
        func walk(_ value: Any) {
            switch value {
            case let text as String:
                if text.utf8.count > longest.utf8.count { longest = text }
            case let array as [Any]:
                array.forEach(walk)
            case let dictionary as [String: Any]:
                dictionary.values.forEach(walk)
            default:
                break
            }
        }
        walk(object)
        return longest.isEmpty ? raw : longest
    }

    /// Конфигурация Keenetic — это строки CLI, а не HTML и не JSON.
    static func looksLikeConfig(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 200 else { return false }
        if trimmed.hasPrefix("<") || trimmed.lowercased().hasPrefix("<!doctype") { return false }

        let markers = ["\ninterface ", "\nsystem\n", "\nip ", "\nobject-group ", "\ndns-proxy"]
        let padded = "\n" + trimmed
        return markers.contains { padded.contains($0) }
    }

    private static func saveDiagnostic(_ problems: [String]) -> URL? {
        let url = AppPaths.logs.appendingPathComponent("rci-config-fetch.txt")
        let text = "\(Date())\n" + problems.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func close() {
        session.invalidateAndCancel()
        authorized = false
    }

    func abort() { close() }

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
            // Битый байт не должен превращать весь ответ в пустую строку.
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
    }

    /// Запоминаем адрес, на который роутер увёл нас редиректом.
    private func adoptRedirect(from response: HTTPURLResponse) {
        guard let final = response.url,
              var components = URLComponents(url: final, resolvingAgainstBaseURL: false)
        else { return }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        guard let pinned = components.url, pinned.absoluteString != baseURL.absoluteString
        else { return }
        log(.info, "RCI: роутер увёл на \(pinned.absoluteString) — работаю оттуда.")
        baseURL = pinned
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
