import Foundation
import XCTest
@testable import KeeneticControl

/// Блокирующий транспорт как настоящий SSH, но без сети и таймерных гонок.
final class TransportGate {
    let started = XCTestExpectation(description: "Transport entered")
    private let condition = NSCondition()
    private var released = false

    func wait() throws {
        started.fulfill()
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !released {
            guard condition.wait(until: deadline) else {
                throw TransportError("Test gate timed out")
            }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Пауза между стадиями операции без блокировки очереди транспорта.
@MainActor
final class OperationGate {
    let started = XCTestExpectation(description: "Operation paused between stages")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class FakeTransport: KeeneticTransport {
    let kind: TransportKind = .ssh
    private let lock = NSLock()
    private var alive = false
    private var recorded: [String] = []
    private var aborts = 0
    private var batches: [[String]] = []
    var onConnect: () throws -> Void = {}
    var onRead: () throws -> String = { RegressionFixtures.sampleConfig }
    var onRun: (String) throws -> String = { _ in "" }
    var onAbort: () -> Void = {}
    var onBatch: (([String]) throws -> String)?

    var isAlive: Bool { lock.withLock { alive } }
    var commands: [String] { lock.withLock { recorded } }
    var abortCount: Int { lock.withLock { aborts } }
    var batchCommands: [[String]] { lock.withLock { batches } }

    func connect() throws {
        try onConnect()
        lock.withLock { alive = true }
    }
    func run(_ command: String, timeout: TimeInterval) throws -> String {
        lock.withLock { recorded.append(command) }
        return try onRun(command)
    }
    func runBatch(_ commands: [String], timeout: TimeInterval) throws -> String {
        lock.withLock { batches.append(commands) }
        if let onBatch {
            lock.withLock { recorded.append(contentsOf: commands) }
            return try onBatch(commands)
        }
        return try commands.map { try run($0, timeout: timeout) }.joined(separator: "\n")
    }
    func fetchText(_ command: String, timeout: TimeInterval, quiet: Bool) throws -> String {
        lock.withLock { recorded.append(command) }
        return try onRead()
    }
    func close() { lock.withLock { alive = false } }
    func abort() {
        lock.withLock { alive = false; aborts += 1 }
        onAbort()
    }
}

@MainActor
final class SessionFixture {
    let profile = RouterProfile(name: "Fixture", host: "fixture.invalid")
    var transports: [FakeTransport]
    private(set) var opened: [RouterProfile] = []
    private(set) var backups: [String] = []
    var backupSucceeds = true
    var settings = AppSettings.default
    private let historyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("session-history-\(UUID())")
    lazy var operationHistory = OperationHistoryStore(directory: historyDirectory)

    deinit { try? FileManager.default.removeItem(at: historyDirectory) }

    init(_ transports: FakeTransport...) { self.transports = transports }

    func session() -> RouterSession {
        RouterSession(router: profile, dependencies: RouterSessionDependencies(
            makeTransport: { [self] profile, _ in
                opened.append(profile)
                guard !transports.isEmpty else { throw TransportError("Unexpected connection") }
                return transports.removeFirst()
            },
            password: { _ in nil },
            retryDelay: { try Task.checkCancellation() },
            settings: { [self] in settings },
            backup: { [self] _, text, _ in
                backups.append(text)
                return backupSucceeds ? URL(fileURLWithPath: "/test/backup.kcb") : nil
            }, operationHistory: { [self] in operationHistory }))
    }
}
