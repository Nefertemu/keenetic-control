import XCTest
@testable import KeeneticControl

final class RouteDataTests: XCTestCase {
    func testInvalidWindowsArgumentsNeverBecomeDifferentRoutes() {
        let invalid = [
            "route add 10.0.0.0 mask 255.0.255.0 192.168.1.1",
            "route add 10.0.0.0 mask nonsense 192.168.1.1",
            "route add 10.0.0.0 192.168.1.1 mask",
            "route add 10.0.0.0 192.168.1.1 metric",
            "route add 10.0.0.0 192.168.1.1 if",
            "route add 10.0.0.0 192.168.1.1 if rubbish",
            "route add 10.0.0.0 192.168.1.1 if -1",
            "route add 10.0.0.0 192.168.1.1 metric 1 metric 2",
            "route add 10.0.0.0 mask 255.0.0.0 mask 255.255.0.0 192.168.1.1",
            "route add 10.0.0.0/8 mask 255.255.0.0 192.168.1.1",
            "route add 2001:db8::/32 mask 255.0.0.0 2001:db8::1",
            "route add 10.0.0.0 192.168.1.1 unexpected"
        ]
        for line in invalid {
            let result = StaticRouteParser.parseImport(line)
            XCTAssertTrue(result.routes.isEmpty, line)
            XCTAssertEqual(result.skipped.count, 1, line)
        }
    }

    func testWindowsImportKeepsNetworkMetricAndLegacyComment() throws {
        let parsed = StaticRouteParser.parseImport(
            "route -p add 10.0.0.0 mask 255.0.0.0 192.168.1.1 metric 42 if 7 rem Office network")
        let route = try XCTUnwrap(parsed.routes.first)
        XCTAssertTrue(parsed.skipped.isEmpty)
        XCTAssertEqual(route.destination, "10.0.0.0/8")
        XCTAssertEqual(route.metric, 42)
        XCTAssertEqual(route.comment, "Office network")
        XCTAssertEqual(route.via, "192.168.1.1")
    }

    func testBATExportsOnlyUsableWindowsGatewaysWithSeparateEscapedComments() {
        let transferable = StaticRoute(destination: "10.0.0.0/8", via: "192.168.1.1",
                                       metric: 20, comment: "Office & backup | <tag> %PATH%")
        let tunnel = StaticRoute(destination: "172.16.0.0/12", via: "Wireguard0")
        let routes = [transferable, tunnel]
        XCTAssertEqual(StaticRouteParser.batUnsupported(routes), [tunnel])
        let exported = StaticRouteParser.exportBAT(routes)
        let lines = exported.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("route ") }, [
            "route -p add 10.0.0.0 mask 255.0.0.0 192.168.1.1 metric 20"
        ])
        XCTAssertTrue(lines.contains("rem Office ^& backup ^| ^<tag^> %%PATH%%"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("rem не переносится в Windows:") && $0.contains("Wireguard0") })
        let imported = StaticRouteParser.parseImport(exported)
        XCTAssertTrue(imported.skipped.isEmpty)
        XCTAssertEqual(imported.routes.map(\.destination), ["10.0.0.0/8"])
        XCTAssertEqual(imported.routes.first?.metric, 20)
    }

    func testConfigRouteParserAcceptsCRLFAndImportAcceptsUppercaseKeywords() {
        let config = "ip route 10.0.0.0 255.0.0.0 Wireguard0 auto\r\n"
        XCTAssertEqual(StaticRouteParser.parse(config: config).map(\.destination), ["10.0.0.0/8"])
        XCTAssertEqual(StaticRouteParser.parseImport(config.uppercased()).routes.count, 1)
    }

    func testCIDRRejectsMissingAddressInsteadOfSkippingLeadingSlash() {
        XCTAssertNil(IPTools.ipv4CIDRToAddressMask("/10.0.0.0/8"))
        XCTAssertThrowsError(try StaticRoute.validate(family: .ipv6, destination: "/2001:db8::/32", via: "Wireguard0"))
    }
}
