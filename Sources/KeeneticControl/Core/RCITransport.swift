import CryptoKit
import Foundation

/// Транспорт поверх веб-панели Keenetic (RCI). Работает там, где закрыт SSH,
/// и умеет отдавать структурированный JSON вместо разбора текста терминала.
final class RCITransport: KeeneticTransport {
    let kind: TransportKind = .http
    var isAlive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return authorized && !closed
    }

    private let profile: RouterProfile
    private let password: String?
    private let session: URLSession
    /// `URLSession` после invalidateAndCancel() использовать повторно нельзя:
    /// Foundation не возвращает ошибку, а бросает Objective-C exception и
    /// валит всё приложение. Переключение роутера может закрыть транспорт с
    /// другого потока ровно между проверкой состояния и dataTask(with:),
    /// поэтому создание задач и закрытие сериализуем одним замком.
    private let stateLock = NSLock()
    /// Роутер может увести с http на https. Дальше работаем по конечному
    /// адресу: иначе POST после 302 потеряет тело и авторизация не пройдёт.
    private var baseURL: URL
    private var authorized = false
    private var closed = false
    /// Новые прошивки объявляют схему x-ndw4 и перестают принимать старую,
    /// даже когда пароль верный. Отличаем это от настоящей ошибки пароля.
    private var advertisesModernAuth = false

    init(profile: RouterProfile, password: String?) throws {
        self.profile = profile
        self.password = password

        guard let url = URL(string: profile.effectiveWebURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil,
              url.user == nil,
              url.password == nil
        else {
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
        try adoptRedirect(from: probe)

        let offered = probe.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
        advertisesModernAuth = offered.lowercased().contains("ndw4")
        let modernEndpoint = RCITransport.endpoint(in: offered) ?? "auth"

        if probe.statusCode == 200 {
            try markAuthorized()
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

        // Новые прошивки принимают только x-ndw4; старая схема у них отвечает,
        // но отвергает даже верный пароль. Пробуем сначала её.
        //
        // Но не вслепую: каждая неудачная схема — отдельный неудачный вход в
        // счётчике роутера, а после пяти он отключает веб-панель для этого
        // адреса. Роутер, который объявил x-ndw4, но не ведёт её, мы
        // запоминаем и больше на нём эту схему не пробуем.
        if advertisesModernAuth, !RCITransport.skipsModernAuth(host: baseURL.host ?? profile.host) {
            do {
                try runModernAuth(login: profile.user, password: password, endpoint: modernEndpoint)
                try markAuthorized()
                log(.ok, "RCI: вход по схеме x-ndw4 (\(realm)).")
                return
            } catch let failure as NDW4.Failure where failure.serverUntrusted {
                throw TransportError(
                    "Роутер не подтвердил, что знает пароль.",
                    hint: "Подпись сервера в схеме x-ndw4 не сошлась: либо пароль неверный, "
                        + "либо по этому адресу отвечает не твой роутер.",
                    isAuthFailure: true)
            } catch {
                if (error as? NDW4.Failure)?.handshakeUnsupported == true {
                    RCITransport.rememberModernAuthUnusable(host: baseURL.host ?? profile.host)
                    log(.warn, "RCI: роутер объявляет x-ndw4, но не ведёт её "
                        + "(\(error.localizedDescription)). Дальше — только старая схема.")
                } else {
                    log(.warn, "RCI: x-ndw4 не прошла (\(error.localizedDescription)), "
                        + "пробую старую схему.")
                }
            }
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
                "Роутер не принял логин или пароль (HTTP \(response.statusCode)).",
                hint: "Веб-панель по адресу \(baseURL.absoluteString) представилась как "
                    + "«\(realm)» и ждёт пароль пользователя «\(profile.user)». "
                    + "У веб-панели он может отличаться от пароля для SSH — "
                    + "проверить можно скриптом Tools/check-rci-password.sh.",
                isAuthFailure: true)
        }
        _ = body
        try markAuthorized()
    }

    /// Один шаг схемы x-ndw4: JSON туда, статус и заголовок x-ndm-data обратно.
    private func runModernAuth(login: String, password: String, endpoint: String) throws {
        try NDW4.authenticate(login: login, password: password) { payload in
            var step = self.request(path: endpoint, method: "POST")
            step.setValue("application/json", forHTTPHeaderField: "Content-Type")
            step.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (_, response) = try self.perform(step)

            var parsed: [String: Any]?
            if let encoded = response.value(forHTTPHeaderField: "X-NDM-Data"),
               let raw = Data(base64Encoded: encoded),
               let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                parsed = object
            }
            return NDW4.Reply(status: response.statusCode, data: parsed)
        }
    }

    /// `show interface` без аргумента `details` не содержит ни состояния
    /// проверки связи, ни прочих подробностей — веб-панель роутера просит их
    /// явно: `showInterfaceApi.read({details: "yes"})`. Форму запроса
    /// прошивки понимают по-разному, поэтому пробуем обе и запоминаем ту,
    /// что сработала.
    static func interfaceStatusJSON(_ transport: RCITransport, logResult: Bool = true) -> Any? {
        let attempts: [(String, () throws -> Any?)] = [
            ("GET с параметром", {
                try transport.json(method: "GET", path: "rci/show/interface?details=yes")
            }),
            ("POST с телом", {
                try transport.json(method: "POST", path: "rci/show/interface",
                                   body: ["details": "yes"])
            }),
            ("без подробностей", {
                try transport.json(method: "GET", path: "rci/show/interface")
            }),
        ]

        var fallback: Any?
        for (name, attempt) in attempts {
            guard let result = try? attempt() else { continue }
            if hasDetails(result) {
                if logResult { log(.info, "RCI: состояние интерфейсов с подробностями (\(name)).") }
                return result
            }
            if fallback == nil { fallback = result }
        }
        if fallback != nil, logResult {
            log(.warn, "RCI: роутер отдал состояние интерфейсов без секции details — "
                + "проверка связи показана не будет.")
        }
        return fallback
    }

    /// Состояние Ping-Check живёт отдельным RCI-методом. `show/interface`
    /// показывает интерфейс и пиры, но не обязан включать счётчики проверки.
    /// На старых прошивках встречается вариант без дефиса, поэтому оставляем
    /// его безопасным запасным путём.
    static func pingCheckStatusJSON(_ transport: RCITransport) -> Any? {
        let attempts = [
            "rci/show/ping-check",
            "rci/show/pingcheck",
        ]
        for path in attempts {
            if let result = try? transport.json(method: "GET", path: path) {
                return result
            }
        }
        return nil
    }

    /// RCI запускает сетевые тесты как продолженную операцию: POST начинает
    /// ping/traceroute, а GET того же endpoint раз в секунду отдаёт следующие
    /// строки. Поле `continued` — маркер присутствия, не обязательно Bool.
    func ping(interface: String, target: String, count: Int = 3,
              method: InterfaceProbeMethod = .icmp, port: Int? = nil,
              sourceAddress: String? = nil) throws -> InterfacePingResult {
        let values = try InterfacePingProbe.validate(interface: interface, target: target)
        guard (1...10).contains(count) else {
            throw TransportError("Количество ping-запросов должно быть от 1 до 10.")
        }

        let path: String
        let body: [String: Any]
        if method == .icmp {
            path = IPTools.isIPv6(values.1) ? "rci/tools/ping6" : "rci/tools/ping"
            body = ["host": values.1, "count": count, "source": values.0]
        } else {
            // Заодно валидируем адрес и порт тем же кодом, что строит SSH-команду.
            _ = try InterfacePingProbe.command(interface: values.0, target: values.1,
                                               count: count, method: method, port: port,
                                               sourceAddress: sourceAddress)
            guard let source = sourceAddress?.split(whereSeparator: { $0.isWhitespace }).first
            else { throw TransportError("У интерфейса \(values.0) нет IPv4-адреса.") }
            if method == .tcp {
                path = "rci/tools/iperf3"
                body = [
                    "host": values.1,
                    "port": port ?? method.defaultPort,
                    "ipv4": true,
                    "tcp": true,
                    "time": 1,
                    "streams": 1,
                    "source-address": String(source),
                ]
            } else {
                path = "rci/tools/traceroute"
                body = [
                    "host": values.1,
                    "count": 1,
                    "wait-time": 1,
                    "max-ttl": 16,
                    "port": port ?? method.defaultPort,
                    "source-address": String(source),
                    "type": method.rawValue,
                ]
            }
        }
        let startedAt = Date()
        var reply = try rci(method: "POST", path: path, body: body)
        var lines: [String] = []
        let deadline = Date().addingTimeInterval(method == .icmp ? TimeInterval(count + 15) : 28)

        while true {
            guard let object = reply as? [String: Any] else {
                throw TransportError("RCI-сетевой тест вернул ответ неизвестного формата.")
            }
            if let messages = object["message"] as? [String] {
                lines.append(contentsOf: messages)
            } else if let message = object["message"] as? String, !message.isEmpty {
                lines.append(message)
            }
            guard object.keys.contains("continued") else { break }
            guard Date() < deadline else {
                throw TransportError("Тайм-аут ожидания сетевого теста.")
            }
            Thread.sleep(forTimeInterval: 1)
            reply = try rci(method: "GET", path: path, body: nil)
        }

        return InterfacePingProbe.parse(lines.joined(separator: "\n"),
                                        interface: values.0, target: values.1,
                                        method: method, port: port,
                                        sourceAddress: sourceAddress,
                                        elapsedMilliseconds: method == .tcp
                                            ? Date().timeIntervalSince(startedAt) * 1000
                                            : nil)
    }

    /// Хоть у одного интерфейса есть подробности — значит форма запроса верная.
    private static func hasDetails(_ value: Any?) -> Bool {
        guard let map = value as? [String: Any] else { return false }
        return map.values.contains { ($0 as? [String: Any])?["details"] != nil }
    }

    /// Роутеры, которые объявляют x-ndw4, но спотыкаются на первой фазе.
    /// Живёт до перезапуска приложения — прошивку могут и обновить.
    private static let modernAuthLock = NSLock()
    private static var modernAuthBlacklist: Set<String> = []

    static func skipsModernAuth(host: String) -> Bool {
        modernAuthLock.lock()
        defer { modernAuthLock.unlock() }
        return modernAuthBlacklist.contains(host)
    }

    static func rememberModernAuthUnusable(host: String) {
        modernAuthLock.lock()
        modernAuthBlacklist.insert(host)
        modernAuthLock.unlock()
    }

    /// endpoint="/auth" из заголовка WWW-Authenticate. Роутер вправе
    /// выбрать другой путь на себе, но не адрес другого сервера: дальше по
    /// этому endpoint уйдёт доказательство знания пароля.
    static func endpoint(in header: String) -> String? {
        guard let range = header.range(of: "endpoint=\"") else { return nil }
        let tail = header[range.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        let value = String(tail[tail.startIndex..<end])
        guard !value.isEmpty,
              !value.contains("\\"),
              !value.hasPrefix("//"),
              let components = URLComponents(string: value),
              components.scheme == nil,
              components.host == nil,
              components.user == nil,
              components.password == nil
        else { return nil }

        let path = value.hasPrefix("/") ? String(value.dropFirst()) : value
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..")
        else { return nil }
        return path
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

    func fetchText(_ command: String, timeout: TimeInterval, quiet: Bool = false) throws -> String {
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
                if !quiet {
                    log(.info, "RCI: конфигурация получена из /\(path) (\(Format.bytes(text.utf8.count))).")
                }
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
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        authorized = false
        // Держим замок до invalidate: perform() либо уже создал задачу, и
        // она будет штатно отменена, либо увидит closed и не полезет в
        // инвалидированную сессию.
        session.invalidateAndCancel()
        stateLock.unlock()
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
        if !isAuthorized { try authenticate() }

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
                clearAuthorization()
                try authenticate()
                continue
            }

            guard (200..<300).contains(response.statusCode) else {
                let preview = RCITransport.responsePreview(data)
                throw TransportError(
                    "RCI \(method) \(path) → HTTP \(response.statusCode).",
                    hint: preview.isEmpty ? nil : "Ответ роутера: \(preview)")
            }

            return try RCITransport.decodeJSONResponse(data, method: method, path: path)
        }
    }

    /// RCI-методы возвращают JSON, кроме документированных ответов без тела.
    /// Раньше ошибка декодирования превращалась в `nil`, а вызывающий код
    /// принимал такой ответ за успешное выполнение команды.
    static func decodeJSONResponse(_ data: Data, method: String, path: String) throws -> Any? {
        guard !data.isEmpty else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let preview = responsePreview(data)
            throw TransportError(
                "RCI \(method) \(path) вернул ответ не в формате JSON.",
                hint: preview.isEmpty
                    ? "Ответ непустой, но в нём нет читаемого текста."
                    : "Начало ответа: \(preview)")
        }
    }

    /// В ошибку кладём только короткое, однострочное и обезличенное начало
    /// ответа. Помимо общих CLI-секретов закрываем типичные поля HTTP/JSON:
    /// роутер или прокси не должны случайно вернуть пароль, токен или cookie
    /// целиком в журнал приложения.
    private static func responsePreview(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let sampleLimit = 2_048
        let previewLimit = 240
        var text = String(decoding: data.prefix(sampleLimit), as: UTF8.self)
        text = CLI.redactSecrets(text)

        let range = NSRange(text.startIndex..., in: text)
        text = responseSecretPattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: "$1•••")

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            scalars.append(CharacterSet.controlCharacters.contains(scalar) ? " " : scalar)
        }
        let compact = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        guard !compact.isEmpty else { return "" }
        let truncated = compact.count > previewLimit || data.count > sampleLimit
        return String(compact.prefix(previewLimit)) + (truncated ? "…" : "")
    }

    private static let responseSecretPattern = try! NSRegularExpression(
        pattern: #"(?i)([\"']?(?:password|passwd|token|secret|authorization|cookie|set-cookie)[\"']?\s*[:=]\s*)(?:\"(?:\\.|[^\"])*\"|'(?:\\.|[^'])*'|[^\s,;}\]]+)"#)

    private func textGET(_ path: String) throws -> String {
        if !isAuthorized { try authenticate() }

        var attempt = 0
        while true {
            let (data, response) = try perform(request(path: path, method: "GET"))

            if response.statusCode == 401, attempt == 0 {
                attempt += 1
                clearAuthorization()
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

    /// Запоминаем адрес, на который роутер увёл нас редиректом. Переход на
    /// HTTPS и смена порта у того же роутера нормальны, а перенос авторизации
    /// на другой хост, подстановка учётных данных или откат с HTTPS на HTTP
    /// нельзя принимать молча: следующим запросом туда может уйти
    /// подтверждение знания пароля.
    private func adoptRedirect(from response: HTTPURLResponse) throws {
        guard let final = response.url,
              var components = URLComponents(url: final, resolvingAgainstBaseURL: false)
        else { return }
        guard let scheme = final.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              final.user == nil,
              final.password == nil
        else {
            throw TransportError(
                "Веб-панель перенаправила вход на небезопасный адрес.",
                hint: "Проверь конечный адрес веб-панели в «Роутеры и настройки».")
        }
        guard final.host?.caseInsensitiveCompare(baseURL.host ?? "") == .orderedSame else {
            throw TransportError(
                "Веб-панель перенаправила вход на другой адрес.",
                hint: "Для безопасности пароль не будет отправлен на \(final.host ?? "неизвестный адрес"). "
                    + "Укажи конечный адрес веб-панели вручную в «Роутеры и настройки».")
        }
        if baseURL.scheme?.caseInsensitiveCompare("https") == .orderedSame, scheme == "http" {
            throw TransportError(
                "Веб-панель пытается переключить защищённое соединение на HTTP.",
                hint: "Для безопасности пароль не будет отправлен по незащищённому соединению.")
        }
        components.path = "/"
        components.user = nil
        components.password = nil
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
        request.setValue("KeeneticControl/1.1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// URLSession асинхронный, а транспорт — синхронный: ждём на семафоре.
    /// Вызывается только с фоновой очереди сессии роутера.
    private func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<(Data, HTTPURLResponse), Error>?

        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            throw TransportError("HTTP-сессия роутера уже закрыта.", isSessionFailure: true)
        }
        let task = session.dataTask(with: request) { data, response, error in
            let value: Result<(Data, HTTPURLResponse), Error>
            if let error {
                value = .failure(TransportError(
                    RCITransport.describe(error),
                    isSessionFailure: (error as NSError).code == NSURLErrorCancelled))
            } else if let http = response as? HTTPURLResponse {
                value = .success((data ?? Data(), http))
            } else {
                value = .failure(TransportError("Пустой ответ от роутера."))
            }

            lock.lock()
            result = value
            lock.unlock()
            semaphore.signal()
        }
        task.resume()
        stateLock.unlock()

        // URLSession должен вызвать callback и при отмене, но отдельный предел
        // нужен как последняя страховка от зависшего сетевого стека: watchdog
        // сессии оборвёт транспорт, а эта очередь не останется ждать навечно.
        guard semaphore.wait(timeout: .now() + 60) == .success else {
            task.cancel()
            throw TransportError("Роутер не ответил за 60 с.")
        }

        lock.lock()
        let finished = result
        lock.unlock()
        switch finished {
        case .success(let value): return value
        case .failure(let error): throw error
        case nil: throw TransportError("Запрос к роутеру не завершился.")
        }
    }

    private var isAuthorized: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return authorized && !closed
    }

    private func markAuthorized() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else {
            throw TransportError("HTTP-сессия роутера уже закрыта.", isSessionFailure: true)
        }
        authorized = true
    }

    private func clearAuthorization() {
        stateLock.lock()
        authorized = false
        stateLock.unlock()
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
