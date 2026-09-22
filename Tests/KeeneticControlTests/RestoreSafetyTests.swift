import XCTest
@testable import KeeneticControl

final class RestoreSafetyTests: XCTestCase {
    private let empty = "hostname router\n!\n"
    private let backup = """
    hostname router
    object-group fqdn one
        description "Original"
        include old.example
    !
    dns-proxy route object-group one Wireguard0 auto
    ip route 10.0.0.0 255.0.0.0 Wireguard0 metric 8 auto
    !
    """
    private let current = """
    hostname router
    object-group fqdn one
        description "Changed"
        include new.example
    !
    object-group fqdn extra
        include extra.example
    !
    dns-proxy route object-group one ISP
    ip route default ISP auto
    !
    """

    func testRejectsEmptyCLIErrorHTMLAndTruncatedLegacyFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, invalid) in ["", " \n", "error: command failed\n!",
            "<html><body>Login</body></html>\n!", "hostname r\nobject-group fqdn one\n    include old.example",
            "hostname router\ninterface Wireguard0\n    description \"unfinished\n    !",
            "hostname router\nobject-group fqdn one\n    include INVALID-CONTENT\n!",
            "hostname router\ndns-proxy route object-group missing Wireguard0\n!",
            "hostname router\nip route invalid\n!"].enumerated() {
            let file = directory.appendingPathComponent("legacy-\(index).txt")
            try invalid.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try Restore.validatedComparison(backup: Backups.read(file), current: current), "Accepted \(index)")
        }
    }

    func testAcceptsCompleteConfigurationWithNoManagedObjects() throws {
        let difference = try Restore.validatedComparison(backup: empty, current: current)
        XCTAssertEqual(Set(difference.extraGroups.map(\.ident)), ["one", "extra"])
        XCTAssertEqual(difference.extraRoutes.count, 1)
        XCTAssertNoThrow(try ConfigurationText.validatedBackup(RegressionFixtures.sampleConfig))
        XCTAssertNoThrow(try ConfigurationText.validatedBackup("system\n    hostname router\n!\n"))
        XCTAssertEqual(try ConfigurationText.validatedBackup("\u{FEFF}" + empty + "  \n"), empty + "  \n")
    }

    func testPolicyScopedRoutesAreNotTreatedAsGlobalRoutes() throws {
        let config = "hostname router\nip policy Office\n    dns-proxy route object-group policy-only Wireguard0 auto\n!\n"
        XCTAssertNoThrow(try ConfigurationText.validatedBackup(config))
        XCTAssertTrue(ConfigurationText.dnsRouteLines(config).isEmpty)
    }

    func testRestoresDescriptionAndVerifiesWholeTarget() throws {
        let difference = try Restore.validatedComparison(backup: backup, current: current)
        let plan = try Restore.validatedPlan(difference, chunkSize: 300, title: "Restore")
        XCTAssertTrue(plan.verifyBeforeSave)
        XCTAssertTrue(plan.commands.contains("object-group fqdn one description \"Original\""))
        XCTAssertEqual(plan.expectedAbsentGroups, ["extra"])
        XCTAssertTrue(PlanVerifier.problems(plan: plan, groups: RouterConfigParser.parseFqdnGroups(backup), limit: 300,
                                           staticRoutes: StaticRouteParser.parse(config: backup)).isEmpty)
        let errors = PlanVerifier.problems(plan: plan, groups: RouterConfigParser.parseFqdnGroups(current), limit: 300,
                                          staticRoutes: StaticRouteParser.parse(config: current))
        XCTAssertTrue(errors.contains { $0.contains("не удалён") })
        XCTAssertTrue(errors.contains { $0.contains("имя списка") })
        XCTAssertTrue(errors.contains { $0.contains("Статические") })
    }

    func testBaselineIgnoresUnrelatedGroupsButRejectsTouchedChanges() throws {
        let difference = try Restore.validatedComparison(backup: backup, current: current)
        let plan = Restore.plan(difference, chunkSize: 300, title: "Restore")
        var groups = RouterConfigParser.parseFqdnGroups(current)
        let statics = StaticRouteParser.parse(config: current)
        groups["unrelated"] = FqdnGroup(ident: "unrelated", includes: ["safe.example"])
        XCTAssertTrue(PlanVerifier.preconditionProblems(plan: plan, groups: groups, staticRoutes: statics).isEmpty)
        groups["extra"]?.includes.insert("new-in-web-panel.example")
        XCTAssertFalse(PlanVerifier.preconditionProblems(plan: plan, groups: groups, staticRoutes: statics).isEmpty)
    }

    func testSelectiveListRestorePreservesOtherListsStaticsAndCurrentChain() throws {
        let whole = try Restore.validatedComparison(backup: backup, current: current)
        let selected = Restore.selecting(.init(groupIDs: ["one"], restoreContents: true,
                                               restoreChains: false, restoreStaticRoutes: false), from: whole)
        let plan = try Restore.validatedPlan(selected, chunkSize: 300, title: "Selected")
        XCTAssertFalse(plan.commands.contains { $0.contains("extra") || $0.contains("dns-proxy") || $0.contains("ip route") })
        XCTAssertEqual(plan.expectedGroupContents["one"], ["old.example"])
        XCTAssertEqual(plan.exactRouteChains["one"]?.map(\.interface), ["ISP"])
        XCTAssertNil(plan.expectedStaticRoutes)
    }

    func testChainOnlyRestoreDoesNotChangeNamesContentsOrRecreateMissingGroup() throws {
        let whole = try Restore.validatedComparison(backup: backup, current: current)
        let selected = Restore.selecting(.init(groupIDs: ["one"], restoreContents: false,
                                               restoreChains: true, restoreStaticRoutes: false), from: whole)
        let plan = try Restore.validatedPlan(selected, chunkSize: 300, title: "Chain")
        XCTAssertEqual(plan.commands, ["no dns-proxy route object-group one ISP",
                                       "dns-proxy route object-group one Wireguard0 auto"])
        XCTAssertEqual(plan.expectedDescriptions["one"], "Changed")
        let missing = try Restore.validatedComparison(backup: backup, current: empty)
        XCTAssertTrue(Restore.selecting(.init(restoreContents: false, restoreStaticRoutes: false), from: missing).isEmpty)
    }

    func testSelectiveRestoreRepairsDescriptionBasedReferencesWithoutChangingPriority() throws {
        let namedBackup = backup.replacingOccurrences(of: "route object-group one", with: "route object-group Original")
        let namedCurrent = current.replacingOccurrences(of: "route object-group one", with: "route object-group Changed")
        let difference = try Restore.validatedComparison(backup: namedBackup, current: namedCurrent)
        let chains = Restore.selecting(.init(groupIDs: ["one"], restoreContents: false,
                                             restoreStaticRoutes: false), from: difference)
        let chainPlan = try Restore.validatedPlan(chains, chunkSize: 300, title: "Chain")
        XCTAssertTrue(chainPlan.commands.contains("dns-proxy route object-group one Wireguard0 auto"))
        let contents = Restore.selecting(.init(groupIDs: ["one"], restoreChains: false,
                                               restoreStaticRoutes: false), from: difference)
        let contentsPlan = try Restore.validatedPlan(contents, chunkSize: 300, title: "Contents")
        XCTAssertTrue(contentsPlan.commands.contains("no dns-proxy route object-group Changed ISP"))
        XCTAssertTrue(contentsPlan.commands.contains("dns-proxy route object-group one ISP"))
        XCTAssertEqual(contentsPlan.exactRouteChains["one"]?.map(\.interface), ["ISP"])
    }

    func testStaticOnlyRestoreDoesNotTouchGroups() throws {
        let whole = try Restore.validatedComparison(backup: backup, current: current)
        let selected = Restore.selecting(.init(groupIDs: [], restoreContents: false, restoreChains: false), from: whole)
        let plan = try Restore.validatedPlan(selected, chunkSize: 300, title: "Routes")
        XCTAssertTrue(plan.commands.allSatisfy { $0.hasPrefix("ip route") || $0.hasPrefix("no ip route") })
        XCTAssertEqual(plan.commands.count, 2)
        XCTAssertNotNil(plan.configurationBaselines.first?.staticRoutes)
    }

    func testDisabledStaticRoutesRemainDisabledWhenRestored() throws {
        for (route, modifier) in [("ip route 10.0.0.0 255.0.0.0 Wireguard0 metric 9 auto", "ip route disable"),
                                  ("ipv6 route 2001:db8::/32 Wireguard1 auto", "ipv6 route disable")] {
            let saved = "hostname router\n\(route)\n\(modifier)\n!\n"
            let enabled = "hostname router\n\(route)\n!\n"
            let difference = try Restore.validatedComparison(backup: saved, current: enabled)
            XCTAssertEqual(difference.extraRoutes.count, 1)
            XCTAssertEqual(difference.missingRoutes.count, 1)
            XCTAssertTrue(try XCTUnwrap(difference.missingRoutes.first).disabled)
            let plan = try Restore.validatedPlan(difference, chunkSize: 300, title: "Restore disabled")
            XCTAssertEqual(plan.commands, ["no " + route, route, modifier])
            XCTAssertFalse(PlanVerifier.problems(plan: plan, groups: [:], limit: 300,
                staticRoutes: StaticRouteParser.parse(config: enabled)).isEmpty, "Ignored disable must be detected")
            XCTAssertTrue(PlanVerifier.problems(plan: plan, groups: [:], limit: 300,
                staticRoutes: StaticRouteParser.parse(config: saved)).isEmpty)
        }
    }

    func testEnabledSnapshotDetectsDisabledCurrentRouteAndReEnablesExplicitly() throws {
        let route = "ip route default ISP auto"
        let enabled = "hostname router\n\(route)\n!\n"
        let disabled = "hostname router\n\(route)\nip route disable\n!\n"
        let difference = try Restore.validatedComparison(backup: enabled, current: disabled)
        XCTAssertFalse(difference.isEmpty)
        let plan = try Restore.validatedPlan(difference, chunkSize: 300, title: "Restore enabled")
        XCTAssertEqual(plan.commands, ["no " + route, route])
        XCTAssertFalse(PlanVerifier.preconditionProblems(plan: plan, groups: [:],
            staticRoutes: StaticRouteParser.parse(config: enabled)).isEmpty,
            "An external enable/disable change after preview invalidates the plan")
        XCTAssertTrue(PlanVerifier.problems(plan: plan, groups: [:], limit: 300,
            staticRoutes: StaticRouteParser.parse(config: enabled)).isEmpty)
    }

    func testBackupRejectsUnboundDuplicateAndWrongFamilyDisableModifiers() {
        let route = "ip route default ISP auto"
        for lines in ["ip route disable", "\(route)\n!\nip route disable",
                      "\(route)\nip route disable\nip route disable",
                      "\(route)\nipv6 route disable",
                      "\(route)\nhostname other\nip route disable"] {
            XCTAssertThrowsError(try ConfigurationText.validatedBackup("hostname router\n\(lines)\n!\n"), lines)
        }
    }

    func testMalformedStaticResultAndBaselineAreRejectedOnlyWhenStaticsAreTouched() throws {
        let route = "hostname router\nip route default ISP auto\n!\n"
        let orphan = "hostname router\nip route disable\n!\n"
        let adding = try Restore.validatedPlan(Restore.validatedComparison(backup: route, current: empty), chunkSize: 300, title: "Add")
        XCTAssertFalse(PlanVerifier.preconditionProblems(plan: adding, groups: [:],
            staticRoutes: StaticRouteParser.parse(config: orphan), configText: orphan).isEmpty)
        let deleting = try Restore.validatedPlan(Restore.validatedComparison(backup: empty, current: route), chunkSize: 300, title: "Delete")
        XCTAssertFalse(PlanVerifier.problems(plan: deleting, groups: [:], limit: 300,
            staticRoutes: StaticRouteParser.parse(config: orphan), configText: orphan).isEmpty)
        let unrelated = Plan(title: "No static changes")
        XCTAssertTrue(PlanVerifier.preconditionProblems(plan: unrelated, groups: [:], configText: orphan).isEmpty)
        XCTAssertTrue(PlanVerifier.problems(plan: unrelated, groups: [:], limit: 300, configText: orphan).isEmpty)
    }

    func testMergingPlansPreservesEachRouteDisablePairAndDeduplicatesWholePairs() throws {
        let first = "hostname router\nip route 10.0.0.0 255.0.0.0 Wireguard0 auto\nip route disable\n!\n"
        let second = "hostname router\nip route 172.16.0.0 255.240.0.0 Wireguard0 auto\nip route disable\n!\n"
        let a = try Restore.validatedPlan(Restore.validatedComparison(backup: first, current: empty), chunkSize: 300, title: "A")
        let b = try Restore.validatedPlan(Restore.validatedComparison(backup: second, current: empty), chunkSize: 300, title: "B")
        XCTAssertEqual(Planner.merge(title: "Both", plans: [a, b]).commands, a.commands + b.commands)
        XCTAssertEqual(Planner.merge(title: "Repeated", plans: [a, b, a]).commands, a.commands + b.commands)
    }

    func testImportChunkPreferenceDoesNotRejectValidExistingBackupGroup() throws {
        let config = "object-group fqdn saved\n" + (0..<200).map { "    include d\($0).example\n" }.joined() + "!\n"
        let difference = try Restore.validatedComparison(backup: config, current: empty)
        XCTAssertNoThrow(try Restore.validatedPlan(difference, chunkSize: 100, title: "Restore"))
        XCTAssertThrowsError(try Restore.validatedPlan(difference, chunkSize: 100, title: "Restore", verificationLimit: 100))
    }

    func testOversizedBackupCannotProduceExecutableRestore() throws {
        let huge = "object-group fqdn huge\n" + (0..<301).map { "    include d\($0).example\n" }.joined() + "!\n"
        let difference = try Restore.validatedComparison(backup: huge, current: empty)
        XCTAssertThrowsError(try Restore.validatedPlan(difference, chunkSize: 999, title: "Too big"))
        let plan = Restore.plan(difference, chunkSize: 999, title: "Too big")
        XCTAssertFalse(PlanVerifier.preconditionProblems(plan: plan, groups: [:]).isEmpty)
    }
}

@MainActor
final class RestoreExecutionTests: XCTestCase {
    private let empty = "hostname router\n!\n"

    func testChangedListAfterPreviewStopsBeforeBackupOrWrites() async throws {
        let original = "object-group fqdn remove-me\n    include one.example\n!\n"
        let changed = original.replacingOccurrences(of: "one.example", with: "user-added.example")
        let plan = Restore.plan(try Restore.validatedComparison(backup: empty, current: original), chunkSize: 300, title: "Restore")
        let transport = FakeTransport(), fixture = SessionFixture(transport)
        transport.onRead = { changed }
        let session = fixture.session(); defer { session.disconnectAll() }
        do { _ = try await session.apply(plan: plan, dryRun: false, saveConfig: true); XCTFail("Stale restore executed") } catch {}
        XCTAssertEqual(transport.commands, ["show running-config"])
        XCTAssertTrue(fixture.backups.isEmpty)
    }

    func testSilentDeleteAndStaticWriteFailuresNeverSave() async throws {
        let cases = [
            (empty, "object-group fqdn ignored\n    include x.example\n!\n"),
            ("hostname router\nip route default ISP auto\n!\n", empty),
            (empty, "hostname router\nip route default ISP auto\n!\n")
        ]
        for (backup, current) in cases {
            let transport = FakeTransport(), fixture = SessionFixture(transport)
            transport.onRead = { current } // Router acknowledges command but retains old config.
            let session = fixture.session(); defer { session.disconnectAll() }
            let plan = try Restore.validatedPlan(Restore.validatedComparison(backup: backup, current: current), chunkSize: 300, title: "Restore")
            let outcome = try await session.apply(plan: plan, dryRun: false, saveConfig: true)
            XCTAssertFalse(outcome.problems.isEmpty)
            XCTAssertFalse(transport.commands.contains("system configuration save"))
            XCTAssertNotNil(outcome.backupURL)
        }
    }

    func testIgnoredStaticDisableDoesNotSaveAccidentallyEnabledRoute() async throws {
        let route = "ip route 192.0.2.0 255.255.255.0 Wireguard0 auto"
        let saved = "hostname router\n\(route)\nip route disable\n!\n"
        let enabled = "hostname router\n\(route)\n!\n"
        let original = empty
        let transport = FakeTransport(), fixture = SessionFixture(transport)
        transport.onRead = { transport.commands.contains(route) ? enabled : original }
        let session = fixture.session(); defer { session.disconnectAll() }
        let plan = try Restore.validatedPlan(Restore.validatedComparison(backup: saved, current: original), chunkSize: 300, title: "Restore disabled")
        let outcome = try await session.apply(plan: plan, dryRun: false, saveConfig: true)
        XCTAssertTrue(outcome.problems.contains { $0.contains("Статические маршруты не совпали") })
        XCTAssertFalse(transport.commands.contains("system configuration save"))
    }

    func testIgnoredRouteRemovalIsFoundEvenAfterTheGroupWasDeleted() async throws {
        let original = "object-group fqdn remove-me\n    include one.example\n!\ndns-proxy route object-group remove-me Wireguard0 auto\n!\n"
        let orphaned = "hostname router\ndns-proxy\n    route object-group remove-me Wireguard0 auto\n!\n"
        let transport = FakeTransport(), fixture = SessionFixture(transport)
        transport.onRead = { transport.commands.contains("no object-group fqdn remove-me") ? orphaned : original }
        let session = fixture.session(); defer { session.disconnectAll() }
        let plan = try Restore.validatedPlan(Restore.validatedComparison(backup: empty, current: original), chunkSize: 300, title: "Restore")
        let outcome = try await session.apply(plan: plan, dryRun: false, saveConfig: true)
        XCTAssertTrue(outcome.problems.contains { $0.contains("Маршрут списка не снят") })
        XCTAssertFalse(transport.commands.contains("system configuration save"))
    }

    func testSuccessfulRestoreVerifiesBeforeSave() async throws {
        let original = "object-group fqdn remove-me\n    include one.example\n!\n"
        let target = empty
        let transport = FakeTransport(), fixture = SessionFixture(transport)
        transport.onRead = { transport.commands.contains("no object-group fqdn remove-me") ? target : original }
        let session = fixture.session(); defer { session.disconnectAll() }
        let plan = try Restore.validatedPlan(Restore.validatedComparison(backup: target, current: original), chunkSize: 300, title: "Restore")
        let outcome = try await session.apply(plan: plan, dryRun: false, saveConfig: true)
        XCTAssertTrue(outcome.problems.isEmpty)
        XCTAssertEqual(Array(transport.commands.suffix(2)), ["show running-config", "system configuration save"])
    }
}
