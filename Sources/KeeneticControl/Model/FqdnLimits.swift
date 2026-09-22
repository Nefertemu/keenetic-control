import Foundation

/// Лимит прошивки применяется на всех путях: импорт, сверка и проверка.
enum FqdnLimits {
    static let maximumEntries = 300

    static func clamp(_ value: Int) -> Int { min(maximumEntries, max(1, value)) }

    static func effective(chunkSize: Int, verificationLimit: Int = maximumEntries) -> Int {
        min(clamp(chunkSize), clamp(verificationLimit))
    }
}
