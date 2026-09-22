import CommonCrypto
import CryptoKit
import Foundation

/// Переносимый формат v1: KCPB + version + rounds (BE32) + salt(16) +
/// AES-GCM nonce/ciphertext/tag. Весь заголовок аутентифицирован как AAD.
/// PBKDF2-HMAC-SHA256 600 000: OWASP Password Storage Cheat Sheet.
/// Никакой зависимости от Keychain исходного Mac.
enum PortableBackup {
    static let pathExtension = "kcportable"
    static let iterations: UInt32 = 600_000
    static let maximumFileSize = 32 * 1024 * 1024
    private static let magic = Data([0x4b, 0x43, 0x50, 0x42, 0x01])
    private static let headerSize = 25

    enum Failure: LocalizedError {
        case password, invalidFile, authentication, derivation
        var errorDescription: String? {
            switch self {
            case .password: return "Используй пароль от 12 символов, не длиннее 1024 байт."
            case .invalidFile: return "Файл переносимой копии повреждён, слишком велик или имеет неподдерживаемый формат."
            case .authentication: return "Пароль не подошёл или копия повреждена."
            case .derivation: return "Не удалось создать ключ шифрования."
            }
        }
    }

    static func seal(_ text: String, password: String) throws -> Data {
        guard password.count >= 12, password.utf8.count <= 1024 else { throw Failure.password }
        let validated = try ConfigurationText.validatedBackup(text)
        guard validated.utf8.count <= maximumFileSize - headerSize - 28 else { throw Failure.invalidFile }
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        var rounds = iterations.bigEndian
        let header = magic + withUnsafeBytes(of: &rounds) { Data($0) } + salt
        var keyData = try derive(password: password, salt: salt, rounds: iterations)
        defer { keyData.resetBytes(in: 0..<keyData.count) }
        let box = try AES.GCM.seal(Data(validated.utf8), using: SymmetricKey(data: keyData), authenticating: header)
        guard let combined = box.combined else { throw Failure.invalidFile }
        return header + combined
    }

    static func open(_ data: Data, password: String) throws -> String {
        // Reject hostile costs and sizes before attempting a KDF.
        guard data.count > headerSize + 28, data.count <= maximumFileSize,
              data.starts(with: magic), password.utf8.count <= 1024 else { throw Failure.invalidFile }
        let rounds = data[5..<9].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard rounds == iterations else { throw Failure.invalidFile }
        var keyData = try derive(password: password, salt: Data(data[9..<25]), rounds: rounds)
        defer { keyData.resetBytes(in: 0..<keyData.count) }
        let clear: Data
        do {
            clear = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(data.dropFirst(headerSize))),
                                    using: SymmetricKey(data: keyData), authenticating: Data(data.prefix(headerSize)))
        } catch { throw Failure.authentication }
        guard let text = String(data: clear, encoding: .utf8) else { throw Failure.invalidFile }
        return try ConfigurationText.validatedBackup(text)
    }

    static func read(_ url: URL, password: String) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size <= maximumFileSize else { throw Failure.invalidFile }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // A file can grow after the metadata check; never allocate beyond the
        // format limit even when another process replaces or appends to it.
        var data = Data()
        while data.count <= maximumFileSize {
            let block = try handle.read(upToCount: min(64 * 1024, maximumFileSize + 1 - data.count)) ?? Data()
            if block.isEmpty { break }
            data.append(block)
        }
        return try open(data, password: password)
    }

    static func write(_ text: String, to url: URL, password: String) throws {
        let data = try seal(text, password: password)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func derive(password: String, salt: Data, rounds: UInt32) throws -> Data {
        var result = Data(count: 32)
        var passwordData = Data(password.utf8)
        defer { passwordData.resetBytes(in: 0..<passwordData.count) }
        let status = result.withUnsafeMutableBytes { output in
            passwordData.withUnsafeBytes { pass in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        pass.baseAddress?.assumingMemoryBound(to: Int8.self), passwordData.count,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                        output.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.derivation }
        return result
    }
}
