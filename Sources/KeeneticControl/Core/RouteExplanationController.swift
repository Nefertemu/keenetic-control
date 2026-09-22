import Combine
import Foundation

struct RouteExplanationScope: Equatable {
    let router: RouterPresentationContext
    let query: String
    let readAt: Date?
}

@MainActor
final class RouteExplanationController: ObservableObject {
    @Published private(set) var report: RouteExplanationReport?
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false
    private var scope: RouteExplanationScope?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func invalidate(for scope: RouteExplanationScope) {
        guard self.scope != scope else { return }
        reset()
        self.scope = scope
    }

    func reset() {
        task?.cancel()
        task = nil
        generation = UUID()
        scope = nil
        report = nil
        error = nil
        isRunning = false
    }

    func search(scope: RouteExplanationScope, state: RouterState) {
        reset()
        self.scope = scope
        isRunning = true
        let request = generation
        task = Task {
            let worker = Task.detached(priority: .userInitiated) {
                try RouteExplanation.explain(scope.query, state: state)
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard generation == request, !Task.isCancelled else { return }
                report = result
            } catch is CancellationError {
                // Closing the screen or changing router invalidates the result.
            } catch {
                guard generation == request, !Task.isCancelled else { return }
                self.error = RouterConnectionManager.describeError(error)
            }
            guard generation == request else { return }
            isRunning = false
            task = nil
        }
    }
}
