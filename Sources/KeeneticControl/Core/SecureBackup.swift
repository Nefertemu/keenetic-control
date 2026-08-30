import CryptoKit
import Foundation

enum SecureBackupError: LocalizedError {
    case invalidKey
    case invalidContainer
    case unreadableText

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "Ключ шифрования резервных копий повреждён."
        case .invalidContainer:
            return "Зашифрованная резервная копия повреждена или создана с другим ключом."
        case .unreadableText:
            return "После расшифровки резервная копия не является текстовой конфигурацией."
        }
    }
}

/// Аутентифицированный контейнер для конфигураций, которые могут содержать
/// пароли и приватные ключи. AES-GCM одновременно скрывает содержимое и
/// обнаруживает любое повреждение/подмену файла.
enum SecureBackup {
    static let pathExtension = "kcbackup"
    private static let keyAccount = "backup-encryption-key-v1"
    private static let magic = Data([0x4b, 0x43, 0x42, 0x4b, 0x01]) // KCBK + версия 1
    private static let keyLock = NSLock()

    static func isEncrypted(_ data: Data) -> Bool { data.starts(with: magic) }

    static func seal(_ text: String, keyData: Data) throws -> Data {
        guard keyData.count == 32 else { throw SecureBackupError.invalidKey }
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(Data(text.utf8), using: key, authenticating: magic)
        guard let combined = sealed.combined else { throw SecureBackupError.invalidContainer }
        return magic + combined
    }

    static func open(_ data: Data, keyData: Data) throws -> String {
        guard keyData.count == 32 else { throw SecureBackupError.invalidKey }
        guard isEncrypted(data), data.count > magic.count else {
            throw SecureBackupError.invalidContainer
        }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(data.dropFirst(magic.count)))
            let clear = try AES.GCM.open(
                box, using: SymmetricKey(data: keyData), authenticating: magic)
            guard let text = String(data: clear, encoding: .utf8) else {
                throw SecureBackupError.unreadableText
            }
            return text
        } catch let error as SecureBackupError {
            throw error
        } catch {
            throw SecureBackupError.invalidContainer
        }
    }

    /// Новый ключ создаётся один раз и остаётся только в Keychain этого Mac.
    /// Блокировка нужна, потому что два роутера могут одновременно сделать
    /// первый бэкап; без неё один файл мог быть зашифрован уже перезаписанным
    /// ключом и стать нечитаемым.
    static func encryptionKey() throws -> Data {
        keyLock.lock()
        defer { keyLock.unlock() }

        if let existing = try Keychain.loadData(account: keyAccount) {
            guard existing.count == 32 else { throw SecureBackupError.invalidKey }
            return existing
        }

        let generated = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try Keychain.saveData(generated, account: keyAccount)
        guard let stored = try Keychain.loadData(account: keyAccount), stored.count == 32 else {
            throw SecureBackupError.invalidKey
        }
        return stored
    }

    static func write(_ text: String, to url: URL) throws {
        let container = try seal(text, keyData: encryptionKey())
        try container.write(to: url, options: .atomic)
        // Защита остаётся полезной и поверх шифрования: другие локальные
        // пользователи не должны даже перечислять/копировать эти файлы.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if isEncrypted(data) {
            return try open(data, keyData: encryptionKey())
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SecureBackupError.unreadableText
        }
        return text
    }
}
