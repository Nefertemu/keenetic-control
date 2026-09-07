import Foundation
import Combine

/// Результат чтения принадлежит конкретным параметрам экрана. Запоздавший
/// ответ и его defer не могут заменить новый результат или погасить индикатор.
@MainActor
final class LatestReadController<Scope: Equatable, Value>: ObservableObject {
    @Published private(set) var value: Value?
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false
    private var scope: Scope?
    private var generation = UUID()

    func invalidate(for newScope: Scope) {
        guard scope != newScope else { return }
        reset()
        scope = newScope
    }

    func reset() {
        generation = UUID()
        scope = nil
        value = nil
        error = nil
        isRunning = false
    }

    func load(for newScope: Scope, operation: () async throws -> Value) async {
        invalidate(for: newScope)
        guard !isRunning, !Task.isCancelled else { return }
        let request = UUID()
        generation = request
        isRunning = true
        value = nil
        error = nil
        defer { if generation == request { isRunning = false } }
        do {
            let result = try await operation()
            guard generation == request, !Task.isCancelled else { return }
            value = result
        } catch is CancellationError {
            // Отмена устаревшего чтения — обычный переход между экранами.
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            self.error = RouterConnectionManager.describeError(error)
        }
    }
}

struct DiagnosticsInput: Hashable {
    var router: RouterPresentationContext
    var interface: String
    var target: String
    var configText: String
}

struct DiagnosticsReadResult {
    var report: RouterDiagnosticsReport
    var warning: String?
}

struct TunnelProbeInput: Hashable {
    var router: RouterPresentationContext
    var interfaces: [String]
    var target: String
    var method: InterfaceProbeMethod
    var port: String
    var interval: Int
}

/// Контекст живого Ping-Check. Переименованный или перенастроенный профиль
/// считается новым запросом; время обычного чтения и счётчики — нет.
struct TunnelStatusInput: Hashable {
    let router: RouterPresentationContext
    let interface: String
    let binding: PingCheckBinding?
    let profile: PingCheckProfile?

    init(router: RouterProfile, interface: String, state: RouterState?) {
        self.router = RouterPresentationContext(router)
        self.interface = interface
        let selectedBinding = state?.pingCheckBindings[interface]
        binding = selectedBinding
        profile = state?.pingCheckProfiles.first { $0.name == selectedBinding?.profile }
    }
}
