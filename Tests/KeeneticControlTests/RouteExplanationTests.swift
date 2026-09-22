import XCTest
@testable import KeeneticControl

enum RouteExplanationFixtures {
    static var state: RouterState {
        let config = """
        object-group fqdn domain-list0
         description "Точный список сервисов"
         include api.example.org
         include 10.1.0.0/16
         include 2001:db8:1234::/48
        !
        object-group fqdn domain-list1
         description "Общий список корпоративных сервисов с очень длинным названием подразделения разработки"
         include example.org
         include 10.0.0.0/8
        !
        dns-proxy route object-group domain-list0 Wireguard0 auto reject
        dns-proxy route object-group domain-list0 Wireguard1 auto
        dns-proxy route object-group domain-list1 Wireguard2 auto
        interface Wireguard0
         description "Основной туннель"
        !
        interface Wireguard1
         description "Резервный туннель с длинным названием дата-центра"
        !
        interface Wireguard2
         description "Корпоративный туннель"
        !
        ip route default ISP auto
        ip route 10.0.0.0 255.0.0.0 Wireguard2 auto
        ip route 10.1.0.0 255.255.0.0 Wireguard0 metric 20 auto reject
        ip route 10.1.0.0 255.255.0.0 Wireguard1 metric 10 auto
        ipv6 route ::/0 ISP auto
        ipv6 route 2001:db8:1234::/48 Wireguard0 auto
        """
        return RouterState(configText: config, groups: RouterConfigParser.parseFqdnGroups(config),
                           interfaces: RouterConfigParser.parseConfigInterfaces(config),
                           staticRoutes: StaticRouteParser.parse(config: config),
                           readAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}

final class RouteExplanationTests: XCTestCase {
    func testNormalizesDomainURLIDNAndIPv6WithoutNetwork() throws {
        XCTAssertEqual(try RouteExplanationQuery.parse(" HTTPS://API.Example.ORG:443/path?q=x#part ").value, "api.example.org")
        XCTAssertEqual(try RouteExplanationQuery.parse("ПРИМЕР.РФ.").value, "xn--e1afmkfd.xn--p1ai")
        XCTAssertEqual(try RouteExplanationQuery.parse("пример。рф").value, "xn--e1afmkfd.xn--p1ai")
        XCTAssertEqual(try RouteExplanationQuery.parse("https://пример.рф/page").value, "xn--e1afmkfd.xn--p1ai")
        XCTAssertEqual(try RouteExplanationQuery.parse("2001:0db8::1").value, "2001:db8::1")
        XCTAssertEqual(try RouteExplanationQuery.parse("https://[2001:db8::1]:8443/page").value, "2001:db8::1")
        XCTAssertEqual(try RouteExplanationQuery.parse("127.0.0.1").kind, .ipv4)
    }

    func testRejectsAmbiguousInputInsteadOfSearchingOnlyItsFirstToken() {
        for text in ["", "first.example.org second.example.org", "0.0.0.0 example.org", "10.0.0.0/8",
                     "*.example.org", "||example.org^", ".example.org", "example.org..", "example.org/path", "fe80::1%en0"] {
            XCTAssertThrowsError(try RouteExplanationQuery.parse(text), text)
        }
    }

    func testDomainMatchesExactAndParentAtLabelBoundaries() throws {
        let report = try RouteExplanation.explain("https://API.example.org/page", state: RouteExplanationFixtures.state)
        XCTAssertEqual(report.groups.map(\.ident), ["domain-list0", "domain-list1"])
        XCTAssertEqual(report.groups[0].entries[0].kind, .exactDomain)
        XCTAssertEqual(report.groups[1].entries[0].kind, .domainSuffix)
        XCTAssertTrue(report.hasCompetingLists)
        XCTAssertTrue(report.staticRoutes.isEmpty, "A domain lookup must not invent a DNS answer or default route")
        XCTAssertTrue(try RouteExplanation.explain("badexample.org", state: RouteExplanationFixtures.state).groups.isEmpty)
        XCTAssertTrue(try RouteExplanation.explain("example.org.evil.test", state: RouteExplanationFixtures.state).groups.isEmpty)
    }

    func testKeepsConfiguredRouteOrderFlagsAndNames() throws {
        let group = try XCTUnwrap(RouteExplanation.explain("api.example.org", state: RouteExplanationFixtures.state).groups.first)
        XCTAssertEqual(group.steps.map(\.interface), ["Wireguard0", "Wireguard1"])
        XCTAssertEqual(group.steps.map(\.position), [1, 2])
        XCTAssertEqual(group.steps.map(\.auto), [true, true])
        XCTAssertEqual(group.steps.map(\.reject), [true, false])
        XCTAssertTrue(group.steps[0].label.contains("Основной туннель"))
    }

    func testIPv4LongestPrefixKeepsEqualCandidatesWithoutGuessingByMetric() throws {
        let report = try RouteExplanation.explain("10.1.2.3", state: RouteExplanationFixtures.state)
        XCTAssertEqual(report.staticRoutes.map(\.prefix), [16, 16, 8, 0])
        XCTAssertEqual(report.staticRoutes.prefix(2).map(\.route.metric), [20, 10])
        XCTAssertEqual(report.longestStaticPrefix, 16)
        XCTAssertEqual(report.groups.map(\.entries).flatMap { $0 }.map(\.value), ["10.1.0.0/16", "10.0.0.0/8"])
    }

    func testIPv6OnlyUsesIPv6GroupsAndStaticRules() throws {
        let report = try RouteExplanation.explain("2001:db8:1234::42", state: RouteExplanationFixtures.state)
        XCTAssertEqual(report.staticRoutes.map(\.prefix), [48, 0])
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups[0].entries[0].value, "2001:db8:1234::/48")
    }

    func testNetworkBoundariesAndNonByteIPv6Prefix() {
        XCTAssertEqual(RouteExplanation.contains(network: "0.0.0.0/0", address: "255.255.255.255"), 0)
        XCTAssertEqual(RouteExplanation.contains(network: "10.1.2.3/32", address: "10.1.2.3"), 32)
        XCTAssertNil(RouteExplanation.contains(network: "10.1.2.3/32", address: "10.1.2.4"))
        XCTAssertNil(RouteExplanation.contains(network: "10.0.0.0/8", address: "11.0.0.0"))
        XCTAssertEqual(RouteExplanation.contains(network: "2001:db8::/33", address: "2001:db8:7fff::1"), 33)
        XCTAssertNil(RouteExplanation.contains(network: "2001:db8::/33", address: "2001:db8:8000::1"))
        XCTAssertEqual(RouteExplanation.contains(network: "::/0", address: "ffff::"), 0)
        XCTAssertEqual(RouteExplanation.contains(network: "::1", address: "0:0:0:0:0:0:0:1"), 128)
        XCTAssertNil(RouteExplanation.contains(network: "0.0.0.0/0", address: "::1"))
        XCTAssertNil(RouteExplanation.contains(network: "::/129", address: "::1"))
    }

    func testCompoundGatewayRulesAndUnknownOptionsAreExplicit() throws {
        var state = RouteExplanationFixtures.state
        state.groups["domain-list0"]!.routeLines = [
            "dns-proxy route object-group domain-list0 192.168.1.1 Wireguard0 auto reject",
            "dns-proxy route object-group domain-list0 fe80::1 auto",
            "dns-proxy route object-group domain-list0 Wireguard1 future-option"
        ]
        state.configText += "\nip route 10.1.2.0 255.255.255.0 192.168.1.1 Wireguard0 auto reject"
        state.configText += "\nip route 10.1.2.3 Wireguard0 unknown-setting"
        state.staticRoutes = StaticRouteParser.parse(config: state.configText)
        let report = try RouteExplanation.explain("10.1.2.3", state: state)
        XCTAssertEqual(report.groups[0].steps.map(\.target), ["192.168.1.1 Wireguard0", "fe80::1"])
        XCTAssertEqual(report.groups[0].steps[0].interface, "Wireguard0")
        XCTAssertNil(report.groups[0].steps[1].interface)
        XCTAssertEqual(report.groups[0].unparsedRules.count, 1)
        XCTAssertEqual(report.staticRoutes.first?.prefix, 24)
        XCTAssertEqual(report.staticRoutes.first?.route.via, "192.168.1.1 Wireguard0")
        XCTAssertEqual(report.unsupportedStaticCount, 1)
    }

    func testUnroutedMatchDoesNotInventAnInterface() throws {
        let group = FqdnGroup(ident: "unrouted", includes: ["example.org"])
        let report = try RouteExplanation.explain("example.org", state: RouterState(groups: [group.ident: group]))
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertTrue(report.groups[0].steps.isEmpty)
        XCTAssertFalse(report.hasCompetingLists)
    }

    func testEquivalentIDNEntriesAreShownOnce() throws {
        let group = FqdnGroup(ident: "international", includes: ["ПРИМЕР.РФ", "xn--e1afmkfd.xn--p1ai"])
        let report = try RouteExplanation.explain("https://пример.рф", state: RouterState(groups: [group.ident: group]))
        XCTAssertEqual(report.groups[0].entries.count, 1)
        XCTAssertEqual(report.groups[0].entries[0].kind, .exactDomain)
    }

    func testPolicyRoutesAreNeverAttachedAsGlobalRoutes() throws {
        let config = """
        object-group fqdn domain-list0
         include example.org
        !
        dns-proxy
         route object-group domain-list0 Wireguard0 auto
        !
        ip policy Policy0
         dns-proxy route object-group domain-list0 Wireguard1 auto reject
        !
        ip policy Policy1
         dns-proxy
          route object-group domain-list0 Wireguard2 auto
        !
        """
        let groups = RouterConfigParser.parseFqdnGroups(config)
        XCTAssertEqual(groups["domain-list0"]?.routedInterfaces, ["Wireguard0"])
        let report = try RouteExplanation.explain("example.org", state: RouterState(configText: config, groups: groups))
        XCTAssertEqual(report.groups[0].steps.map(\.interface), ["Wireguard0"])
        XCTAssertFalse(report.hasCompetingLists)
    }

    func testUnknownAddressDoesNotMeanThereIsNoLiveRoute() throws {
        let report = try RouteExplanation.explain("192.0.2.9", state: RouterState())
        XCTAssertFalse(report.hasMatches)
        XCTAssertNil(report.longestStaticPrefix)
    }
}

@MainActor
final class RouteExplanationControllerTests: XCTestCase {
    func testNewestSearchOwnsResult() async throws {
        let controller = RouteExplanationController()
        let state = RouteExplanationFixtures.state
        let router = RouterPresentationContext(SessionFixture().profile)
        controller.search(scope: .init(router: router, query: "api.example.org", readAt: state.readAt), state: state)
        controller.search(scope: .init(router: router, query: "10.1.2.3", readAt: state.readAt), state: state)
        try await finish(controller)
        XCTAssertEqual(controller.report?.query.value, "10.1.2.3")
        XCTAssertNil(controller.error)
    }

    func testRouterOrSnapshotChangeInvalidatesPendingAndCompletedResults() async throws {
        let controller = RouteExplanationController()
        let fixture = SessionFixture()
        let state = RouteExplanationFixtures.state
        var profile = fixture.profile
        let first = RouteExplanationScope(router: RouterPresentationContext(profile), query: "api.example.org", readAt: state.readAt)
        controller.search(scope: first, state: state)
        try await finish(controller)
        XCTAssertNotNil(controller.report)
        profile.host = "other.example.invalid"
        controller.invalidate(for: .init(router: RouterPresentationContext(profile), query: first.query, readAt: state.readAt))
        XCTAssertNil(controller.report)
        controller.search(scope: first, state: state)
        controller.invalidate(for: .init(router: first.router, query: first.query, readAt: state.readAt.addingTimeInterval(1)))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(controller.report)
        XCTAssertFalse(controller.isRunning)
    }

    func testInvalidQueryShowsErrorAndNewQueryClearsIt() async throws {
        let controller = RouteExplanationController()
        let router = RouterPresentationContext(SessionFixture().profile)
        controller.search(scope: .init(router: router, query: "two domains.org", readAt: nil), state: RouterState())
        try await finish(controller)
        XCTAssertNotNil(controller.error)
        controller.invalidate(for: .init(router: router, query: "example.org", readAt: nil))
        XCTAssertNil(controller.error)
        XCTAssertNil(controller.report)
    }

    private func finish(_ controller: RouteExplanationController) async throws {
        for _ in 0..<200 {
            if !controller.isRunning { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Offline explanation did not finish")
    }
}
