import XCTest
@testable import KeeneticControl

final class FailoverInterfaceDraftTests: XCTestCase {
    func testRefreshDoesNotRestoreExplicitlyRemovedLastInterface() {
        var draft = FailoverInterfaceDraft()
        draft.reconcile(available: ["Wireguard0", "Wireguard1"], preferred: "Wireguard0")
        draft.order.removeAll()

        draft.reconcile(available: ["Wireguard0", "Wireguard1"], preferred: "Wireguard0")

        XCTAssertEqual(draft.selected, "Wireguard0", "The table filter can remain selected")
        XCTAssertTrue(draft.order.isEmpty, "Refreshing must not silently add a route target")
        draft.pending = "Wireguard1"
        draft.appendPending(available: ["Wireguard0", "Wireguard1"])
        XCTAssertEqual(draft.order, ["Wireguard1"])
    }

    func testProfileWithNoRemainingInterfacesCannotReusePreviousTarget() {
        var draft = FailoverInterfaceDraft()
        draft.reconcile(available: ["Wireguard0"], preferred: "Wireguard0")
        let profile = FailoverProfile(name: "Old tunnels", routerID: UUID(),
                                      interfaces: ["Wireguard8", "Wireguard9"])

        draft.apply(profile.resolve(against: ["Wireguard0"]).present)

        XCTAssertEqual(draft.selected, "")
        XCTAssertTrue(draft.order.isEmpty)
        draft.reconcile(available: ["Wireguard0"], preferred: "Wireguard0")
        XCTAssertTrue(draft.order.isEmpty, "A configuration refresh must not revive the previous target")
    }

    func testRefreshPreservesPriorityAndDiscardsUnavailablePendingInterface() {
        var draft = FailoverInterfaceDraft()
        draft.apply(["Wireguard2", "Wireguard1", "Wireguard0"])
        draft.pending = "Wireguard3"

        draft.reconcile(available: ["Wireguard0", "Wireguard2", "Wireguard4"], preferred: "Wireguard4")

        XCTAssertEqual(draft.order, ["Wireguard2", "Wireguard0"])
        XCTAssertEqual(draft.selected, "Wireguard2")
        XCTAssertEqual(draft.pending, "")
        draft.select("Wireguard4")
        XCTAssertEqual(draft.order, ["Wireguard2", "Wireguard0"], "Changing the table filter cannot rewrite a chain")
    }

    func testInitialReadSelectsDefaultButAddingStaleOrDuplicateChoiceDoesNothing() {
        var draft = FailoverInterfaceDraft()
        draft.reconcile(available: [], preferred: nil)
        draft.reconcile(available: ["ISP", "Wireguard0"], preferred: "Wireguard0")
        XCTAssertEqual(draft.order, ["Wireguard0"])

        draft.pending = "Wireguard0"
        draft.appendPending(available: ["ISP", "Wireguard0"])
        XCTAssertEqual(draft.order, ["Wireguard0"])
        draft.pending = "Wireguard9"
        draft.appendPending(available: ["ISP", "Wireguard0"])
        XCTAssertEqual(draft.order, ["Wireguard0"])
        XCTAssertEqual(draft.pending, "")
    }
}
