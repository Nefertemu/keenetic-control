import SwiftUI

private struct LiveRouterReadsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Экраны можно отрисовать по готовому снимку без запуска сетевых опросов.
    var liveRouterReadsEnabled: Bool {
        get { self[LiveRouterReadsKey.self] }
        set { self[LiveRouterReadsKey.self] = newValue }
    }
}
