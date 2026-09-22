import XCTest
@testable import KeeneticControl

final class DisabledStaticRouteTests: XCTestCase {
    private let config = """
    ip route 203.0.113.10 Wireguard0 auto
    ip route disable
    ip route 198.51.100.11 Wireguard1 auto
    ip route disable
    ip route 192.0.2.12 Wireguard2 auto
    ip route disable
    ip route default 192.168.1.1 ISP
    ipv6 route 2001:db8::/32 Wireguard0 auto
    ipv6 route disable
    """

    func testContextualDisablePreservesRoutesRatherThanCreatingUnknownRules() {
        let parsed = StaticRouteParser.parseWithDiagnostics(config: config)
        XCTAssertTrue(parsed.problems.isEmpty)
        XCTAssertEqual(parsed.routes.map(\.disabled), [true, true, true, false, true])
        XCTAssertEqual(parsed.routes[0].additionCommands,
                       ["ip route 203.0.113.10 Wireguard0 auto", "ip route disable"])
        XCTAssertEqual(parsed.routes.last?.additionCommands,
                       ["ipv6 route 2001:db8::/32 Wireguard0 auto", "ipv6 route disable"])
        XCTAssertFalse(parsed.routes[0].command.contains("\n"))
        XCTAssertEqual(parsed.routes[0].deleteCommand, "no ip route 203.0.113.10 Wireguard0 auto")
        var enabled = parsed.routes[0]
        enabled.disabled = false
        XCTAssertNotEqual(enabled.id, parsed.routes[0].id)
        XCTAssertNotEqual(enabled.configurationKey, parsed.routes[0].configurationKey)
    }

    func testDisabledCLIExportAndImportRoundTripWithoutLosingState() {
        let routes = StaticRouteParser.parse(config: config)
        let exported = StaticRouteParser.exportCLI(routes)
        XCTAssertEqual(StaticRouteParser.parse(config: exported).map(\.configurationKey), routes.map(\.configurationKey))
        let imported = StaticRouteParser.parseImport(exported)
        XCTAssertTrue(imported.skipped.isEmpty)
        XCTAssertEqual(imported.routes.map(\.configurationKey), routes.map(\.configurationKey))
        XCTAssertTrue(imported.routes.allSatisfy { $0.rawLine.isEmpty })
        XCTAssertEqual(StaticRouteParser.parseImport(exported + exported).routes.count, routes.count)
    }

    func testUnattachedDuplicateAndWrongFamilyDisableAreExplicitProblems() {
        let invalid = [
            "ip route disable",
            "ip route 203.0.113.10 Wireguard0\nip route disable\nip route disable",
            "ipv6 route 2001:db8::/32 Wireguard0\nip route disable",
            "ip route 203.0.113.10 Wireguard0\nipv6 route disable",
            "ip route 203.0.113.10 Wireguard0\n!\nip route disable",
            "ip route 203.0.113.10 Wireguard0\nip route future-argument\nip route disable"
        ]
        for text in invalid {
            XCTAssertFalse(StaticRouteParser.parseWithDiagnostics(config: text).problems.isEmpty, text)
            XCTAssertFalse(StaticRouteParser.parseImport(text).skipped.isEmpty, text)
            XCTAssertTrue(StaticRouteParser.hasInvalidDisable(in: StaticRouteParser.parseImport(text).skipped), text)
        }
    }

    func testInvalidDisableDetectionIncludesCaseWhitespaceAndExtraArguments() {
        XCTAssertTrue(StaticRouteParser.hasInvalidDisable(in: [" IPv6\troute disable trailing"]))
        XCTAssertFalse(StaticRouteParser.hasInvalidDisable(in: ["unrelated unsupported line"]))
    }

    func testNestedPolicyAndInterfaceRoutesCannotDisableGlobalRoute() {
        let text = """
        ip route 203.0.113.10 Wireguard0
        ip policy Policy0
         ip route 198.51.100.11 Wireguard1
         ip route disable
        !
        ip route disable
        """
        let parsed = StaticRouteParser.parseWithDiagnostics(config: text)
        XCTAssertEqual(parsed.routes.count, 1)
        XCTAssertFalse(parsed.routes[0].disabled)
        XCTAssertEqual(parsed.problems, ["ip route disable"])
    }

    func testDisabledBATRouteNeverBecomesEnabledCommand() throws {
        let route = try XCTUnwrap(StaticRouteParser.parse(config:
            "ip route 203.0.113.10 192.168.1.1\nip route disable").first)
        let bat = StaticRouteParser.exportBAT([route])
        XCTAssertEqual(StaticRouteParser.batUnsupported([route]), [route])
        XCTAssertTrue(bat.contains("отключён"))
        XCTAssertFalse(CLI.normalizeNewlines(bat).split(separator: "\n").contains { $0.hasPrefix("route ") })
        XCTAssertTrue(StaticRouteParser.parseImport(bat).routes.isEmpty)
    }

    func testExplanationShowsDisabledMatchButSelectsLongestEnabledPrefix() throws {
        let config = "ip route 203.0.113.10 Wireguard0 auto\nip route disable\nip route default 192.168.1.1 ISP"
        let state = RouterState(configText: config, staticRoutes: StaticRouteParser.parse(config: config))
        let report = try RouteExplanation.explain("203.0.113.10", state: state)
        XCTAssertEqual(report.staticRoutes.map(\.prefix), [32, 0])
        XCTAssertEqual(report.staticRoutes.map(\.route.disabled), [true, false])
        XCTAssertEqual(report.longestStaticPrefix, 0)
        XCTAssertEqual(report.unsupportedStaticCount, 0)
    }

    func testOnlyDisabledMatchesHaveNoLongestEnabledPrefix() throws {
        let config = "ipv6 route 2001:db8::/32 Wireguard0 auto\nipv6 route disable"
        let state = RouterState(configText: config, staticRoutes: StaticRouteParser.parse(config: config))
        let report = try RouteExplanation.explain("2001:db8::1", state: state)
        XCTAssertEqual(report.staticRoutes.count, 1)
        XCTAssertNil(report.longestStaticPrefix)
        XCTAssertEqual(report.unsupportedStaticCount, 0)
    }
}
