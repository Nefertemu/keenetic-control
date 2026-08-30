import Foundation

/// Схема входа `x-ndw4-interactive` новых прошивок Keenetic.
/// Это SCRAM: пароль никогда не уходит на роутер, обе стороны доказывают
/// знание общего секрета, и клиент проверяет подпись сервера — то есть
/// подставной роутер не сможет притвориться настоящим.
///
/// Три обмена:
///   1) клиент шлёт логин и свой nonce, получает соль и параметры Argon2id;
///   2) клиент шлёт доказательство, получает подпись сервера и проверяет её;
///   3) клиент шлёт финальное доказательство и получает сессию.
///
/// Порядок и формулы повторяют реализацию из веб-панели роутера.
enum NDW4 {
    private static let clientKeyLabel = "NDW4 Interactive Client Key"
    private static let serverKeyLabel = "NDW4 Interactive Server Key"
    /// Argon2 выделяет память до начала вычислений. 64 МиБ с запасом хватает
    /// штатной схеме Keenetic, но не позволяет ответу удалённого сервера
    /// занять гигабайт памяти процесса.
    private static let maximumMemoryCostKiB = 1 << 16

    struct Reply {
        let status: Int
        /// Разобранное содержимое заголовка x-ndm-data.
        let data: [String: Any]?
    }

    /// Отправка одного шага: JSON внутрь, статус и x-ndm-data наружу.
    typealias Send = ([String: Any]) throws -> Reply

    struct Failure: LocalizedError {
        let message: String
        /// Подпись сервера не сошлась — роутер не знает пароля либо он подменён.
        let serverUntrusted: Bool
        /// Осечка на первой фазе значит, что роутер объявил схему, но не ведёт
        /// её. Пароль тут ни при чём, и второй раз пробовать бессмысленно.
        let handshakeUnsupported: Bool
        init(_ message: String, serverUntrusted: Bool = false,
             handshakeUnsupported: Bool = false) {
            self.message = message
            self.serverUntrusted = serverUntrusted
            self.handshakeUnsupported = handshakeUnsupported
        }
        var errorDescription: String? { message }
    }

    static func authenticate(login: String, password: String, send: Send) throws {
        // --- Фаза 1: наш nonce в обмен на соль и параметры вывода ключа.
        let clientNonce = randomBytes(16)
        let clientNonceB64 = Data(clientNonce).base64EncodedString()

        let first = try send(["login": login, "nonce": clientNonceB64])
        guard first.status == 401 else {
            throw Failure("Фаза 1: неожиданный ответ HTTP \(first.status).", handshakeUnsupported: true)
        }
        guard let payload = first.data,
              let salt = payload["salt"] as? String,
              let serverNonce = payload["nonce"] as? String,
              let iterations = intValue(payload["iter"]),
              let memoryCost = intValue(payload["memcost"])
        else {
            throw Failure("Фаза 1: роутер не прислал соль и параметры.", handshakeUnsupported: true)
        }
        guard let saltBytes = Data(base64Encoded: salt) else {
            throw Failure("Фаза 1: соль не разбирается.", handshakeUnsupported: true)
        }

        // Параметры приходят от роутера: на абсурдных значениях мы бы
        // выделили гигабайты памяти или считали ключ часами.
        guard (1...16).contains(iterations),
              (8...maximumMemoryCostKiB).contains(memoryCost)
        else {
            throw Failure("Фаза 1: роутер прислал неправдоподобные параметры "
                          + "(проходов \(iterations), памяти \(memoryCost) КиБ).", handshakeUnsupported: true)
        }
        guard saltBytes.count >= 8, saltBytes.count <= 64 else {
            throw Failure("Фаза 1: длина соли \(saltBytes.count) байт выглядит неправильной.", handshakeUnsupported: true)
        }

        // --- Вывод ключей из пароля.
        let salted = try Argon2.hash(
            password: Array(password.utf8),
            salt: [UInt8](saltBytes),
            parameters: .init(iterations: iterations, memoryKiB: memoryCost,
                              parallelism: 1, tagLength: 64))

        let clientKey = SHA3.hmac512(key: salted, message: clientKeyLabel)
        let storedKey = SHA3.hash512(clientKey)
        let serverKey = SHA3.hmac512(key: salted, message: serverKeyLabel)

        let authMessage = "login1=\(login),nonce1=\(clientNonceB64)"
            + ";iter2=\(iterations),memcost2=\(memoryCost),nonce2=\(serverNonce),salt2=\(salt)"
            + ";login3=\(login),nonce3=\(serverNonce)"

        let clientProof = xor(clientKey, SHA3.hmac512(key: storedKey, message: authMessage))

        // --- Фаза 2: доказательство клиента в обмен на подпись сервера.
        let second = try send([
            "login": login,
            "nonce": serverNonce,
            "proof": Data(clientProof).base64EncodedString(),
        ])
        guard second.status == 401 else {
            throw Failure("Фаза 2: неожиданный ответ HTTP \(second.status).")
        }
        guard let signature = second.data?["signature"] as? String,
              let signatureBytes = Data(base64Encoded: signature)
        else {
            throw Failure("Фаза 2: роутер не прислал подпись.")
        }

        // --- Проверяем сервер: он должен знать тот же секрет.
        let expected = SHA3.hmac512(key: serverKey, message: authMessage)
        guard constantTimeEqual(expected, [UInt8](signatureBytes)) else {
            throw Failure("Подпись роутера не сошлась — он не знает пароля.",
                          serverUntrusted: true)
        }

        // --- Фаза 3: финальное доказательство, в ответ — сессия.
        let finalMessage = authMessage + ";signature4=\(signature)"
        let finalProof = xor(clientKey, SHA3.hmac512(key: storedKey, message: finalMessage))

        let third = try send([
            "login": login,
            "nonce": serverNonce,
            "signature-proof": Data(finalProof).base64EncodedString(),
        ])
        guard third.status == 200 else {
            throw Failure("Фаза 3: роутер не открыл сессию (HTTP \(third.status)).")
        }
    }

    // MARK: - Мелочи

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text)
        default: return nil
        }
    }

    private static func xor(_ left: [UInt8], _ right: [UInt8]) -> [UInt8] {
        precondition(left.count == right.count)
        var result = [UInt8](repeating: 0, count: left.count)
        for index in 0..<left.count { result[index] = left[index] ^ right[index] }
        return result
    }

    /// Сравнение без ранних выходов: время не должно зависеть от данных.
    private static func constantTimeEqual(_ left: [UInt8], _ right: [UInt8]) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<left.count { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for index in 0..<count { bytes[index] = UInt8.random(in: 0...255) }
        }
        return bytes
    }
}
