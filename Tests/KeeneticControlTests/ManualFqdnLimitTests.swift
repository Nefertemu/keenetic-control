import XCTest
@testable import KeeneticControl

final class ManualFqdnLimitTests: XCTestCase {
    private func entries(_ count: Int) -> String { (0..<count).map { "d\($0).example" }.joined(separator: "\n") }

    func testAccepts300ButRejects301EvenWithLegacyOversizedLimit() throws {
        let allowed = try ManualFqdnPlanner.plan(ident: "manual", description: "Manual", entriesText: entries(300), limit: 1000)
        XCTAssertEqual(allowed.addCount, 300)
        XCTAssertEqual(allowed.groupEntryLimit, 300)
        XCTAssertTrue(allowed.verifyBeforeSave)
        XCTAssertThrowsError(try ManualFqdnPlanner.plan(ident: "manual", description: "Manual", entriesText: entries(301)))
        XCTAssertThrowsError(try ManualFqdnPlanner.plan(ident: "manual", description: "Manual", entriesText: entries(301), limit: 1000))
    }

    func testLowerVerificationLimitAlsoConstrainsManualCreation() throws {
        XCTAssertEqual(try ManualFqdnPlanner.plan(ident: "manual", description: "Manual", entriesText: entries(100), limit: 100).addCount, 100)
        XCTAssertThrowsError(try ManualFqdnPlanner.plan(ident: "manual", description: "Manual", entriesText: entries(101), limit: 100))
    }

    func testNameClaimedAfterPreviewCannotSilentlyAppendToAnotherList() throws {
        let plan = try ManualFqdnPlanner.plan(ident: "manual", description: "Manual", entriesText: entries(5))
        let occupied = ["manual": FqdnGroup(ident: "manual", descriptionText: "Created in web UI", includes: ["existing.example"])]
        XCTAssertFalse(PlanVerifier.preconditionProblems(plan: plan, groups: occupied).isEmpty)
        XCTAssertTrue(PlanVerifier.preconditionProblems(plan: plan, groups: [:]).isEmpty)
    }
}
