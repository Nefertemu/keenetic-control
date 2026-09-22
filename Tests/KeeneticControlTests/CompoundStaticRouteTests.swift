import XCTest
@testable import KeeneticControl

final class CompoundStaticRouteTests: XCTestCase {
    func testDocumentedIPv4AndIPv6GatewayInterfaceFormsRoundTrip() throws {
        let lines = [
            "ip route default 10.185.40.1 ISP",
            "ip route 203.0.113.10 Wireguard0 auto",
            "ip route 198.51.100.11 Wireguard1 auto",
            "ip route 192.0.2.12 Wireguard2 auto",
            "ip route 10.0.0.0 255.0.0.0 192.168.1.1 GigabitEthernet0/Vlan10 metric 20 auto reject !Office network",
            "ipv6 route default fe80::1 ISP auto",
            "ipv6 route default ISP fe80::1 auto",
            "ipv6 route 2001:db8::/32 GigabitEthernet0/Vlan10 2001:db8::1 metric 7 auto reject",
            "ipv6 route 2001:db8::/32 2001:db8::1 Wireguard0 metric 7 auto reject"
        ]
        for line in lines {
            let route = try XCTUnwrap(StaticRouteParser.parse(line: line), line)
            let repeated = try XCTUnwrap(StaticRouteParser.parse(line: route.command), route.command)
            XCTAssertEqual(repeated.command, route.command)
            XCTAssertEqual(route.deleteCommand, "no " + line)
            XCTAssertEqual(repeated.via, route.via)
            XCTAssertEqual(repeated.metric, route.metric)
            XCTAssertEqual(repeated.comment, route.comment)
            XCTAssertEqual(repeated.auto, route.auto)
            XCTAssertEqual(repeated.reject, route.reject)
        }
    }

    func testCompleteBackupAndRestorePreserveDefaultGatewayInterface() throws {
        let backup = "hostname fixture\nip route default 10.185.40.1 ISP\nip route 203.0.113.10 Wireguard0 auto\nip route 198.51.100.11 Wireguard1 auto\nip route 192.0.2.12 Wireguard2 auto\nipv6 route default fe80::1 ISP auto\n!\n"
        let current = "hostname fixture\n!\n"
        XCTAssertEqual(try ConfigurationText.validatedBackup(backup), backup)
        let difference = try Restore.validatedComparison(backup: backup, current: current)
        let plan = Restore.plan(difference, chunkSize: 300, title: "Restore")
        XCTAssertTrue(plan.commands.contains("ip route default 10.185.40.1 ISP"))
        XCTAssertTrue(plan.commands.contains("ipv6 route default fe80::1 ISP auto"))
        XCTAssertEqual(plan.expectedStaticRoutes, Set(StaticRouteParser.parse(config: backup).map(\.command)))
    }

    func testCompoundTargetsRejectWrongFamilyFlagsAndCommandInjection() {
        let invalidIPv4 = [
            "ISP Wireguard0", "192.168.1.1 192.168.1.2", "192.168.1.1 ISP extra",
            "192.168.1.1 auto", "192.168.1.1 reject", "192.168.1.1 metric",
            "192.168.1.1 default", "192.168.1.1 host", "192.168.1.1 no",
            "192.168.1.1 ISP;reboot", "192.168.1.1 ISP\nsystem reboot",
            "192.168.1.1 ISP\t", "192.168.1.1 \"ISP\"", "192.168.1.1 ISP!comment",
            "192.168.1.1 $(reboot)", "192.168.1.1 `reboot`", "fe80::1 ISP", "::1", "auto"
        ]
        for via in invalidIPv4 {
            XCTAssertThrowsError(try StaticRoute.validate(family: .ipv4, destination: "default", via: via), via)
        }
        for via in ["192.168.1.1 ISP", "fe80::1 fe80::2", "fe80::1%en0 ISP", "fe80::1 ISP reject",
                    "ISP 192.168.1.1", "ISP fe80::1%en0", "auto fe80::1", "ISP fe80::1 extra"] {
            XCTAssertThrowsError(try StaticRoute.validate(family: .ipv6, destination: "default", via: via), via)
        }
    }

    func testIPv6GatewayAndInterfaceLabelsAreCorrectForBothDocumentedOrders() throws {
        var state = RouteExplanationFixtures.state
        state.configText = "ipv6 route 2001:db8::/32 Wireguard0 fe80::1\nipv6 route default fe80::2 Wireguard1"
        state.staticRoutes = StaticRouteParser.parse(config: state.configText)
        let report = try RouteExplanation.explain("2001:db8::1234", state: state)
        XCTAssertEqual(report.unsupportedStaticCount, 0)
        XCTAssertEqual(report.staticRoutes.map(\.targetLabel), [
            "\(state.label(for: "Wireguard0")) · шлюз fe80::1",
            "\(state.label(for: "Wireguard1")) · шлюз fe80::2"
        ])
    }

    func testUnsupportedExtraArgumentsStillInvalidateBackup() {
        for line in ["ip route default 10.185.40.1 ISP future-option", "ipv6 route default fe80::1 ISP rule", "ip route default fe80::1 ISP"] {
            XCTAssertNil(StaticRouteParser.parse(line: line))
            XCTAssertThrowsError(try ConfigurationText.validatedBackup("hostname fixture\n\(line)\n!\n"))
        }
    }
}
