import Foundation

/// Одна попытка подключения для нескольких читателей. Отмена одного ожидания
/// не мешает остальным; отмена последнего прерывает сетевую работу.
@MainActor
final class ConnectionAttempt {
    private var worker: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var result: Result<Void, Error>?
    private(set) var isCancelled = false

    func start(_ operation: @escaping () async throws -> Void) {
        worker = Task {
            let outcome: Result<Void, Error>
            do { try await operation(); outcome = .success(()) }
            catch { outcome = .failure(error) }
            finish(outcome)
            worker = nil
        }
    }

    func wait() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result) }
                else { waiters[id] = continuation }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor in
                self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
                if self.waiters.isEmpty, self.result == nil { self.cancel() }
            }
        }
    }

    func cancel() {
        isCancelled = true
        worker?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ outcome: Result<Void, Error>) {
        guard result == nil else { return }
        result = outcome
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume(with: outcome) }
    }
}
