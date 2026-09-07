import XCTest
@testable import KeeneticControl

final class RestoreDataTests: XCTestCase {
    private func config(_ interfaces: [String]) -> String {
        (["object-group fqdn domain-list0", "    include example.com", "!"]
         + interfaces.map { "dns-proxy route object-group domain-list0 \($0) auto" }
         + ["object-group fqdn untouched", "    include untouched.example", "!",
            "dns-proxy route object-group untouched ISP auto"])
            .joined(separator: "\n")
    }

    func testRestoreDetectsReorderedFailoverAndPreservesSnapshotPriority() {
        let backup = config(["Wireguard2", "Wireguard0"])
        let current = config(["Wireguard0", "Wireguard2"])
        let difference = Restore.compare(backup: backup, current: current)
        XCTAssertFalse(difference.isEmpty)
        let plan = Restore.plan(difference, chunkSize: 300, title: "Restore")
        XCTAssertEqual(plan.commands, [
            "no dns-proxy route object-group domain-list0 Wireguard0 auto",
            "no dns-proxy route object-group domain-list0 Wireguard2 auto",
            "dns-proxy route object-group domain-list0 Wireguard2 auto",
            "dns-proxy route object-group domain-list0 Wireguard0 auto"
        ])
        XCTAssertEqual(plan.exactRouteChains["domain-list0"]?.map(\.interface), ["Wireguard2", "Wireguard0"])
        XCTAssertFalse(PlanVerifier.problems(plan: plan, groups: RouterConfigParser.parseFqdnGroups(current), limit: 300).isEmpty)
        XCTAssertTrue(PlanVerifier.problems(plan: plan, groups: RouterConfigParser.parseFqdnGroups(backup), limit: 300).isEmpty)
    }

    func testRestoreMissingPrimaryRouteRebuildsWholeChain() {
        let difference = Restore.compare(backup: config(["Wireguard2", "Wireguard0"]),
                                         current: config(["Wireguard0"]))
        let plan = Restore.plan(difference, chunkSize: 300, title: "Restore")
        XCTAssertEqual(plan.commands, [
            "no dns-proxy route object-group domain-list0 Wireguard0 auto",
            "dns-proxy route object-group domain-list0 Wireguard2 auto",
            "dns-proxy route object-group domain-list0 Wireguard0 auto"
        ])
        XCTAssertTrue(plan.commands.allSatisfy { !$0.contains("untouched") })
    }

    func testRestoreVerifiesRemovingLastRouteAndDoesNotTouchEqualChains() {
        let difference = Restore.compare(backup: config([]), current: config(["Wireguard0"]))
        let plan = Restore.plan(difference, chunkSize: 300, title: "Restore")
        XCTAssertEqual(plan.exactRouteChains["domain-list0"], [])
        XCTAssertFalse(PlanVerifier.problems(plan: plan, groups: RouterConfigParser.parseFqdnGroups(config(["Wireguard0"])), limit: 300).isEmpty)
        XCTAssertTrue(Restore.compare(backup: config(["Wireguard0"]), current: config(["Wireguard0"])).isEmpty)
    }

    func testRouterChangeCountsOnlyActualRouteAdditionsAndRemovals() {
        let added = RouterChange(at: Date(), difference: Restore.compare(
            backup: config(["Wireguard0"]), current: config(["Wireguard0", "Wireguard1"])))
        XCTAssertEqual(added.lines, ["назначено маршрутов списков: 1"])

        let removed = RouterChange(at: Date(), difference: Restore.compare(
            backup: config(["Wireguard0", "Wireguard1"]), current: config(["Wireguard1"])))
        XCTAssertEqual(removed.lines, ["снято маршрутов списков: 1"])
    }

    func testRouterChangeReportsReorderingWithoutInventingRouteAssignments() {
        let reordered = RouterChange(at: Date(), difference: Restore.compare(
            backup: config(["Wireguard0", "Wireguard1"]), current: config(["Wireguard1", "Wireguard0"])))
        XCTAssertTrue(reordered.touchesManagedSettings)
        XCTAssertEqual(reordered.lines, ["изменён порядок маршрутов в domain-list0"])

        let combined = RouterChange(at: Date(), difference: Restore.compare(
            backup: config(["Wireguard0", "Wireguard1"]), current: config(["Wireguard1", "Wireguard0", "Wireguard2"])))
        XCTAssertEqual(combined.lines, ["назначено маршрутов списков: 1",
                                       "изменён порядок маршрутов в domain-list0"])
    }
}
