import XCTest
@testable import KeeneticControl

@MainActor
private final class ReadGate<Value> {
    let started = XCTestExpectation(description: "Read started")
    private var continuation: CheckedContinuation<Value, Error>?
    func read() async throws -> Value {
        try await withCheckedThrowingContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func finish(_ result: Result<Value, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor
final class LatestReadControllerTests: XCTestCase {
    func testPreviousTargetCannotReplaceNewResult() async {
        let controller = LatestReadController<String, String>()
        let old = ReadGate<String>()
        let task = Task { await controller.load(for: "old") { try await old.read() } }
        await fulfillment(of: [old.started], timeout: 2)
        await controller.load(for: "new") { "new report" }
        old.finish(.success("old report"))
        await task.value
        XCTAssertEqual(controller.value, "new report")
        XCTAssertFalse(controller.isRunning)
    }

    func testLateErrorDoesNotStopNewRequest() async {
        let controller = LatestReadController<String, String>()
        let old = ReadGate<String>(), new = ReadGate<String>()
        let first = Task { await controller.load(for: "A") { try await old.read() } }
        await fulfillment(of: [old.started], timeout: 2)
        let second = Task { await controller.load(for: "B") { try await new.read() } }
        await fulfillment(of: [new.started], timeout: 2)
        old.finish(.failure(TransportError("Old failure")))
        await first.value
        XCTAssertTrue(controller.isRunning)
        XCTAssertNil(controller.error)
        new.finish(.success("B"))
        await second.value
        XCTAssertEqual(controller.value, "B")
    }

    func testChangingInputImmediatelyHidesOldReport() async {
        let controller = LatestReadController<String, String>()
        await controller.load(for: "A") { "A" }
        controller.invalidate(for: "B")
        XCTAssertNil(controller.value)
        XCTAssertNil(controller.error)
    }

    func testReturningToSameTargetRejectsFirstGeneration() async {
        let controller = LatestReadController<String, String>(), old = ReadGate<String>()
        let task = Task { await controller.load(for: "A") { try await old.read() } }
        await fulfillment(of: [old.started], timeout: 2)
        controller.invalidate(for: "B")
        await controller.load(for: "A") { "fresh A" }
        old.finish(.success("stale A"))
        await task.value
        XCTAssertEqual(controller.value, "fresh A")
    }

    func testCancelledReadCannotPublishSuccessfulLateAnswer() async {
        let controller = LatestReadController<String, String>(), gate = ReadGate<String>()
        let task = Task { await controller.load(for: "A") { try await gate.read() } }
        await fulfillment(of: [gate.started], timeout: 2)
        task.cancel()
        gate.finish(.success("late"))
        await task.value
        XCTAssertNil(controller.value)
        XCTAssertNil(controller.error)
        XCTAssertFalse(controller.isRunning)
    }

    func testDuplicateRequestDoesNotStartSecondLoad() async {
        let controller = LatestReadController<String, String>(), gate = ReadGate<String>()
        let task = Task { await controller.load(for: "A") { try await gate.read() } }
        await fulfillment(of: [gate.started], timeout: 2)
        await controller.load(for: "A") { XCTFail("Duplicate load"); return "duplicate" }
        gate.finish(.success("first"))
        await task.value
        XCTAssertEqual(controller.value, "first")
    }
}
