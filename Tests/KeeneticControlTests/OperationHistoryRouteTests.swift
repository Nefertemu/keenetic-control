import XCTest
@testable import KeeneticControl

final class OperationHistoryRouteTests: XCTestCase {
    private let config = """
    object-group fqdn domain-list0
     description Services
     include example.org
    !
    dns-proxy route object-group domain-list0 Wireguard0 auto
    dns-proxy route object-group domain-list0 Wireguard1
    """

    func testExactChainPreservesFlagOnlyChangeAndCodableFormat() throws {
        var plan = Plan(title: "Запрет обхода")
        plan.exactRouteChains["domain-list0"] = [
            DnsRouteAssignment(interface: "Wireguard0", auto: true, reject: true),
            DnsRouteAssignment(interface: "Wireguard1", auto: false, reject: false)
        ]
        let record = OperationHistoryRecord(profile: RouterProfile(), plan: plan, configText: config, backupURL: nil)
        let change = try XCTUnwrap(record.changes.first)
        XCTAssertEqual(change.routesBefore, ["Wireguard0 · auto", "Wireguard1"])
        XCTAssertEqual(change.routesAfter, ["Wireguard0 · auto · reject", "Wireguard1"])
        XCTAssertNotEqual(change.routesBefore, change.routesAfter)
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(OperationHistoryRecord.self, from: data), record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(json["changes"] as? [[String: Any]])
        XCTAssertNotNil(rows.first?["routesAfter"] as? [String], "Keep existing history files readable")
    }

    func testRouteTargetsReplaceFlagsAtExistingPosition() throws {
        var plan = Plan(title: "Изменить флаги")
        plan.routeTargets = [PlannedDnsRoute(group: "domain-list0", interface: "Wireguard0", auto: false, reject: false)]
        let record = OperationHistoryRecord(profile: RouterProfile(), plan: plan, configText: config, backupURL: nil)
        let change = try XCTUnwrap(record.changes.first)
        XCTAssertEqual(change.routesBefore, ["Wireguard0 · auto", "Wireguard1"])
        XCTAssertEqual(change.routesAfter, ["Wireguard0", "Wireguard1"])
    }

    func testRemoveAndAppendRetainRemainingChainOrderAndFlags() throws {
        var plan = Plan(title: "Сменить резерв")
        plan.unrouteTargets = [("domain-list0", "Wireguard0")]
        plan.routeTargets = [PlannedDnsRoute(group: "domain-list0", interface: "Wireguard2", auto: true, reject: true)]
        let record = OperationHistoryRecord(profile: RouterProfile(), plan: plan, configText: config, backupURL: nil)
        XCTAssertEqual(record.changes.first?.routesAfter, ["Wireguard1", "Wireguard2 · auto · reject"])
    }

    func testDeletedGroupHasNoRemainingRouteDespiteOtherMetadata() throws {
        var plan = Plan(title: "Удалить список")
        plan.commands = ["no object-group fqdn domain-list0"]
        plan.exactRouteChains["domain-list0"] = [DnsRouteAssignment(interface: "Wireguard0", auto: true, reject: true)]
        let record = OperationHistoryRecord(profile: RouterProfile(), plan: plan, configText: config, backupURL: nil)
        XCTAssertEqual(record.changes.first?.routesBefore, ["Wireguard0 · auto", "Wireguard1"])
        XCTAssertEqual(record.changes.first?.routesAfter, [])
        XCTAssertEqual(record.changes.first?.isDeleted, true)
    }
}
