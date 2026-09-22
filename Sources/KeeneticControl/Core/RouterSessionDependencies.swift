import Foundation

/// Границы внешних эффектов. Тесты подставляют транспорт, пароль, задержку и
/// хранилище копий, поэтому не обращаются к сети и связке ключей.
struct RouterSessionDependencies {
    var makeTransport: (RouterProfile, String?) throws -> KeeneticTransport
    var password: (RouterProfile) async -> String?
    var retryDelay: () async throws -> Void
    var settings: @MainActor () -> AppSettings
    var backup: (RouterProfile, String, Int) -> URL?
    var operationHistory: @MainActor () -> OperationHistoryStore = { .shared }

    static var live: Self {
        Self(
            makeTransport: { profile, password in
                if profile.transport == .ssh {
                    return SSHTransport(profile: profile, password: password)
                }
                return try RCITransport(profile: profile, password: password)
            },
            password: { profile in
                await Task.detached { profile.resolvedPassword }.value
            },
            retryDelay: { try await Task.sleep(nanoseconds: 1_500_000_000) },
            settings: { Store.shared.settings },
            backup: { profile, text, keep in
                Backups.saveRunningConfig(host: profile.backupHost, text: text, keep: keep)
            })
    }
}
