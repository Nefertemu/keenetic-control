import Darwin
import Foundation

/// SSH-сессия поверх настоящего псевдотерминала: Keenetic CLI интерактивный,
/// без pty он не отдаёт ни приглашения, ни запроса пароля.
final class SSHTransport: KeeneticTransport {
    let kind: TransportKind = .ssh
    var isAlive: Bool { isOpen }

    private let profile: RouterProfile
    private let password: String?
    /// Точечные live-проверки поднимают отдельный короткий SSH-сеанс. Они не
    /// должны засорять журнал сообщениями «SSH: подключено» каждые несколько
    /// секунд — основное соединение уже показывает пользователю свой статус.
    private let logsConnection: Bool

    /// Дескриптор живёт под замком: `abort()` закрывает его из другого потока,
    /// чтобы разбудить зависший poll() и не держать очередь операций.
    private let lock = NSLock()
    private var master: Int32 = -1
    private var child: pid_t = -1
    private var pendingBytes = Data()
    private var buffer = ""

    private var descriptor: Int32 {
        lock.lock(); defer { lock.unlock() }
        return master
    }

    private var isOpen: Bool { descriptor >= 0 }

    private static let prompt = try! NSRegularExpression(pattern: "\\([^)\\r\\n]+\\)>[ \\t]*")
    private static let more = try! NSRegularExpression(
        pattern: "--More--|press (?:space|any key)[^\\r\\n]*continue", options: [.caseInsensitive])

    init(profile: RouterProfile, password: String?, logsConnection: Bool = true) {
        self.profile = profile
        self.password = password
        self.logsConnection = logsConnection
    }

    deinit { close() }

    // MARK: - Подключение

    func connect() throws {
        try spawn()

        let patterns: [NSRegularExpression] = [
            SSHTransport.prompt,
            regex("are you sure you want to continue connecting[^\\r\\n]*\\?"),
            regex("(?:password|пароль)[^:\\r\\n]*:[ \\t]*$"),
            regex("permission denied"),
            regex("connection (?:refused|closed|timed out)"),
            regex("(?:could not resolve|name or service not known|no route to host|network is unreachable)"),
            regex("host key verification failed"),
        ]

        var passwordAttempts = 0
        let deadline = Date().addingTimeInterval(40)

        while true {
            let outcome = try expect(patterns, deadline: deadline)

            switch outcome {
            case .matched(let index, let before, let after):
                switch index {
                case 0:
                    if logsConnection { log(.ok, "SSH: подключено к \(profile.host)") }
                    return

                case 1:
                    send("yes\n")

                case 2:
                    passwordAttempts += 1
                    guard passwordAttempts <= 3 else {
                        close()
                        throw TransportError("Роутер не принял пароль.",
                                             hint: "Проверь пароль администратора в карточке роутера.",
                                             isAuthFailure: true)
                    }
                    guard let password, !password.isEmpty else {
                        close()
                        throw TransportError(
                            "Роутер \(profile.host) просит пароль, а он не задан.",
                            hint: "Открой «Роутеры», выбери этот роутер и впиши пароль — он ляжет в связку ключей.",
                            isAuthFailure: true)
                    }
                    send(password + "\n")

                case 3:
                    close()
                    throw TransportError(
                        "SSH отклонил авторизацию.",
                        hint: "Проверь логин «\(profile.user)» и пароль.",
                        isAuthFailure: true)

                case 4:
                    // Причина ("Connection refused") лежит в самом совпавшем куске.
                    let tail = CLI.stripNoise(before + after)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    close()
                    throw TransportError(tail.isEmpty ? "SSH-соединение не установлено." : tail,
                                         hint: "Проверь, включён ли доступ по SSH и открыт ли порт \(profile.port).")

                case 5:
                    close()
                    throw TransportError("Адрес не разрешается или недоступен: \(profile.host)")

                case 6:
                    close()
                    throw TransportError(
                        "Не сошёлся ключ хоста.",
                        hint: "Удали старую запись командой:\n  ssh-keygen -R \(profile.host)")

                default:
                    close()
                    throw TransportError("Неожиданный ответ SSH.")
                }

            case .eof(let before):
                let tail = CLI.stripNoise(before).trimmingCharacters(in: .whitespacesAndNewlines)
                close()
                throw TransportError(
                    tail.isEmpty ? "SSH закрыл соединение." : "SSH закрыл соединение: \(tail)",
                    hint: "Проверь, включён ли SSH на роутере и открыт ли порт \(profile.port).")

            case .timeout(let before):
                let tail = CLI.stripNoise(before).trimmingCharacters(in: .whitespacesAndNewlines)
                close()
                throw TransportError(
                    "Не дождался приглашения Keenetic CLI." + (tail.isEmpty ? "" : " Последний ответ: \(tail)"))
            }
        }
    }

    /// Получить один live-снимок Ping-Check в изолированном SSH-сеансе.
    ///
    /// Некоторые версии Keenetic закрывают интерактивный pty сразу после
    /// `show ping-check`. Поэтому повторять команду в основном сеансе нельзя:
    /// следующий цикл увидит «SSH-сессия не подключена» и начнёт бессмысленно
    /// переподключаться. Одноразовый probe сохраняет основную сессию живой и
    /// даёт настоящий ответ роутера, а не устаревшую догадку по интерфейсу.
    static func fetchPingCheck(profile: RouterProfile) throws -> [String: PingCheckLiveInfo] {
        let probe = SSHTransport(
            profile: profile,
            password: profile.resolvedPassword,
            logsConnection: false)
        defer { probe.close() }
        try probe.connect()
        let output = try probe.run("show ping-check", timeout: 20)
        return PingCheckStatusParser.parseCLI(output)
    }

    /// Активный тест живёт в отдельной короткой SSH-сессии. Долгий ping или
    /// traceroute не занимает основной канал приложения и его отмена не
    /// ломает чтение конфигурации или параллельную работу с другим экраном.
    static func ping(profile: RouterProfile, interface: String, target: String,
                     count: Int = 3, method: InterfaceProbeMethod = .icmp,
                     port: Int? = nil, sourceAddress: String? = nil) throws -> InterfacePingResult {
        let command = try InterfacePingProbe.command(
            interface: interface, target: target, count: count,
            method: method, port: port, sourceAddress: sourceAddress)
        let probe = SSHTransport(
            profile: profile,
            password: profile.resolvedPassword,
            logsConnection: false)
        defer { probe.close() }
        try probe.connect()
        let timeout = method == .icmp ? TimeInterval(count + 12) : 28
        let startedAt = Date()
        let output = try probe.run(command, timeout: timeout)
        return InterfacePingProbe.parse(output, interface: interface, target: target,
                                        method: method, port: port,
                                        sourceAddress: sourceAddress,
                                        elapsedMilliseconds: method == .tcp
                                            ? Date().timeIntervalSince(startedAt) * 1000
                                            : nil)
    }

    private func spawn() throws {
        let sshPath = "/usr/bin/ssh"
        guard FileManager.default.isExecutableFile(atPath: sshPath) else {
            throw TransportError("Не найдена команда ssh (\(sshPath)).")
        }

        let arguments = [
            "ssh",
            "-tt",
            "-p", String(profile.port),
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "NumberOfPasswordPrompts=3",
            "-o", "PreferredAuthentications=password,keyboard-interactive,publickey",
            "\(profile.user)@\(profile.host)",
        ]

        // Всё, что нужно ребёнку, готовим ДО fork — между fork и exec
        // можно вызывать только безопасные функции.
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)

        var environment = ProcessInfo.processInfo.environment
        // В приложении, запущенном из Finder, TERM не задан вовсе.
        environment["TERM"] = "vt100"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)

        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        // Широкое «окно» терминала — так CLI не включает постраничный вывод.
        var size = winsize(ws_row: 1000, ws_col: 300, ws_xpixel: 0, ws_ypixel: 0)
        var masterFD: Int32 = -1
        let pid = forkpty(&masterFD, nil, nil, &size)

        if pid < 0 {
            throw TransportError("Не удалось создать псевдотерминал для ssh.")
        }

        if pid == 0 {
            execve(sshPath, &argv, &envp)
            _exit(127)
        }

        lock.lock()
        master = masterFD
        lock.unlock()
        child = pid
        buffer = ""
        pendingBytes = Data()

        // Неблокирующее чтение — таймауты держим сами через poll().
        let flags = fcntl(masterFD, F_GETFL, 0)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
    }

    // MARK: - Команды

    func run(_ command: String, timeout: TimeInterval) throws -> String {
        guard isOpen else {
            throw TransportError("SSH-сессия не подключена.", isSessionFailure: true)
        }
        send(command + "\n")
        let output = try waitForPrompt(timeout: timeout)
        return CLI.stripEcho(output, commands: [command])
    }

    func runBatch(_ commands: [String], timeout: TimeInterval) throws -> String {
        guard isOpen else {
            throw TransportError("SSH-сессия не подключена.", isSessionFailure: true)
        }
        guard !commands.isEmpty else { return "" }

        // Пишем пачку крупными кусками, но не переполняя буфер терминала.
        var payload = ""
        for command in commands {
            let line = command + "\n"
            if !payload.isEmpty, payload.utf8.count + line.utf8.count > 1024 {
                send(payload)
                payload = ""
            }
            payload += line
        }
        if !payload.isEmpty { send(payload) }

        var chunks: [String] = []
        for _ in commands {
            chunks.append(try waitForPrompt(timeout: timeout))
        }
        return CLI.stripEcho(chunks.joined(separator: "\n"), commands: commands)
    }

    func fetchText(_ command: String, timeout: TimeInterval, quiet: Bool = false) throws -> String {
        try run(command, timeout: timeout)
    }

    func close() {
        guard isOpen else { reap(force: false); return }
        send("exit\n")

        // Закрытый pty сам пошлёт ssh SIGHUP — ждать «вежливого» выхода нечего.
        lock.lock()
        let fd = master
        master = -1
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }

        reap(force: false)
        buffer = ""
        pendingBytes = Data()
    }

    /// Аварийный обрыв из другого потока: операция висит дольше отведённого.
    /// Закрытие дескриптора разбудит poll(), и операция честно свалится с ошибкой.
    func abort() {
        lock.lock()
        let fd = master
        master = -1
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
        if child > 0 { kill(child, SIGKILL) }
    }

    /// Подбираем процесс, но никогда не ждём его вечно.
    private func reap(force: Bool) {
        guard child > 0 else { return }
        var status: Int32 = 0

        if force { kill(child, SIGKILL) }

        let deadline = Date().addingTimeInterval(force ? 2.0 : 1.0)
        while Date() < deadline {
            if waitpid(child, &status, WNOHANG) == child { child = -1; return }
            usleep(20_000)
        }

        if !force { reap(force: true); return }
        child = -1     // не дождались — пусть подберёт система, очередь важнее
    }

    // MARK: - Движок ожидания

    private enum Outcome {
        case matched(index: Int, before: String, after: String)
        case eof(before: String)
        case timeout(before: String)
    }

    private func waitForPrompt(timeout: TimeInterval) throws -> String {
        var chunks: [String] = []
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            switch try expect([SSHTransport.prompt, SSHTransport.more], deadline: deadline) {
            case .matched(let index, let before, _):
                chunks.append(before)
                if index == 0 {
                    return CLI.stripNoise(chunks.joined())
                }
                send(" ")   // постраничный вывод — просим следующую страницу

            case .eof:
                throw TransportError("SSH-соединение закрыто роутером.", isSessionFailure: true)

            case .timeout:
                throw TransportError("Тайм-аут ожидания ответа (\(Int(timeout)) с).")
            }
        }
    }

    private func expect(_ patterns: [NSRegularExpression], deadline: Date) throws -> Outcome {
        while true {
            if let outcome = match(patterns) { return outcome }

            let status = readMore(deadline: deadline)
            switch status {
            case .data:
                continue
            case .eof:
                if let outcome = match(patterns) { return outcome }
                let before = buffer
                buffer = ""
                return .eof(before: before)
            case .timedOut:
                if let outcome = match(patterns) { return outcome }
                return .timeout(before: buffer)
            }
        }
    }

    /// Ищем самое раннее совпадение среди шаблонов и отрезаем его из буфера.
    private func match(_ patterns: [NSRegularExpression]) -> Outcome? {
        guard !buffer.isEmpty else { return nil }
        let range = NSRange(buffer.startIndex..., in: buffer)

        var best: (index: Int, range: NSRange)?
        for (index, pattern) in patterns.enumerated() {
            guard let found = pattern.firstMatch(in: buffer, range: range)?.range else { continue }
            if best == nil || found.location < best!.range.location
                || (found.location == best!.range.location && found.length > best!.range.length) {
                best = (index, found)
            }
        }

        guard let hit = best, let matchRange = Range(hit.range, in: buffer) else { return nil }
        let before = String(buffer[buffer.startIndex..<matchRange.lowerBound])
        let after = String(buffer[matchRange])
        buffer = String(buffer[matchRange.upperBound...])
        return .matched(index: hit.index, before: before, after: after)
    }

    private enum ReadStatus { case data, eof, timedOut }

    private func readMore(deadline: Date) -> ReadStatus {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .timedOut }

            let fd = descriptor
            guard fd >= 0 else { return .eof }   // сессию оборвали снаружи

            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let slice = Int32(min(remaining * 1000, 500).rounded(.up))
            let ready = poll(&poller, 1, slice)

            if ready < 0 {
                if errno == EINTR { continue }
                return .eof
            }
            if ready == 0 { continue }   // ещё не время сдаваться

            var raw = [UInt8](repeating: 0, count: 65536)
            let count = raw.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }

            if count > 0 {
                pendingBytes.append(contentsOf: raw[0..<count])
                decodePending()
                return .data
            }
            if count == 0 { return .eof }
            if errno == EAGAIN || errno == EINTR { continue }
            return .eof     // EIO — псевдотерминал закрылся
        }
    }

    /// UTF-8 может прийти разрезанным между чтениями — хвост придерживаем.
    private func decodePending() {
        guard !pendingBytes.isEmpty else { return }

        if let text = String(data: pendingBytes, encoding: .utf8) {
            buffer += text
            pendingBytes.removeAll(keepingCapacity: true)
            return
        }

        for tail in 1...3 where pendingBytes.count > tail {
            let head = pendingBytes.prefix(pendingBytes.count - tail)
            if let text = String(data: head, encoding: .utf8) {
                buffer += text
                pendingBytes = Data(pendingBytes.suffix(tail))
                return
            }
        }

        // Совсем битые байты — не держим их вечно.
        if pendingBytes.count > 8 {
            buffer += String(decoding: pendingBytes, as: UTF8.self)
            pendingBytes.removeAll(keepingCapacity: true)
        }
    }

    private func send(_ text: String) {
        let fd = descriptor
        guard fd >= 0 else { return }
        let data = Array(text.utf8)
        var offset = 0
        while offset < data.count {
            let written = data[offset...].withUnsafeBufferPointer {
                Darwin.write(fd, $0.baseAddress, $0.count)
            }
            if written > 0 {
                offset += written
            } else if errno == EAGAIN || errno == EINTR {
                usleep(5_000)
            } else {
                return
            }
        }
    }

    private func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
