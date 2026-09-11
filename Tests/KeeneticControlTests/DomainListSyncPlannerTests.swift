import XCTest
@testable import KeeneticControl

final class DomainListSyncPlannerTests: XCTestCase {
    private let primary = DnsRouteAssignment(interface: "Wireguard2", auto: true, reject: false)
    private let fallback = DnsRouteAssignment(interface: "Wireguard0", auto: false, reject: true)

    private func spec(_ prefix: String = "Example") -> SourceSpec {
        SourceSpec(key: prefix, title: prefix, subtitle: "", descriptionPrefix: prefix,
                   icon: "globe", urls: [], cacheName: "test.txt", minDomains: 1)
    }

    private func entries(_ count: Int) -> [String] {
        (0..<count).map { "d\($0).example.com" }
    }

    private func data(_ values: [String], source: SourceSpec? = nil, cached: Bool = false,
                      skipped: [String] = []) -> SourceData {
        SourceData(spec: source ?? spec(), entries: values, fromCache: cached,
                   fetchedAt: Date(), skipped: skipped, duplicates: 0, subnetsV4: [], subnetsV6: [])
    }

    private func group(_ ident: String, number: Int, entries: [String],
                       chain: [DnsRouteAssignment]? = nil, prefix: String = "Example") -> FqdnGroup {
        let routes = (chain ?? [primary, fallback]).map { assignment in
            "dns-proxy route object-group \(ident) \(assignment.interface)"
                + (assignment.auto ? " auto" : "") + (assignment.reject ? " reject" : "")
        }
        return FqdnGroup(ident: ident, descriptionText: number == 1 ? prefix : "\(prefix) \(number)",
                         includes: Set(entries), routeLines: routes)
    }

    private func plan(_ values: [String], groups: [String: FqdnGroup],
                      chunkSize: Int = 300) throws -> Plan {
        var reserved = Set(groups.keys)
        return try DomainListSyncPlanner.plan(groups: groups, data: data(values),
                                              chunkSize: chunkSize, reservedIDs: &reserved)
    }

    /// Исполняем именно CLI-команды, а не expectedGroupContents/adds. Так
    /// проверяется промежуточное переполнение и порядок назначения маршрутов.
    private func execute(_ plan: Plan, on initial: [String: FqdnGroup], limit: Int = 300,
                         file: StaticString = #filePath, line: UInt = #line) throws -> [String: FqdnGroup] {
        var groups = initial
        for command in plan.commands {
            var tokens = command.split(separator: " ").map(String.init)
            let removing = tokens.first == "no"
            if removing { tokens.removeFirst() }
            if tokens.prefix(2).elementsEqual(["object-group", "fqdn"]) {
                XCTAssertGreaterThanOrEqual(tokens.count, 3, file: file, line: line)
                let ident = tokens[2]
                if tokens.count == 3 {
                    XCTAssertFalse(removing, "Не удаляем существующие части", file: file, line: line)
                    XCTAssertNil(groups[ident], "Новая часть должна иметь свободное имя", file: file, line: line)
                    groups[ident] = FqdnGroup(ident: ident)
                } else if tokens[3] == "description" {
                    let prefix = "object-group fqdn \(ident) description "
                    groups[ident]?.descriptionText = CLI.unquote(String(command.dropFirst(prefix.count)))
                } else if tokens[3] == "include" {
                    var current = try XCTUnwrap(groups[ident], file: file, line: line)
                    if removing {
                        current.includes.remove(tokens[4])
                    } else {
                        current.includes.insert(tokens[4])
                        XCTAssertLessThanOrEqual(current.count, limit, command, file: file, line: line)
                    }
                    groups[ident] = current
                } else {
                    XCTFail("Неожиданная команда \(command)", file: file, line: line)
                }
            } else if tokens.prefix(3).elementsEqual(["dns-proxy", "route", "object-group"]) {
                XCTAssertFalse(removing, "Существующие цепочки не снимаются", file: file, line: line)
                let ident = tokens[3]
                var current = try XCTUnwrap(groups[ident], file: file, line: line)
                XCTAssertTrue(current.includes.isEmpty, "Назначение новой цепочки предшествует include", file: file, line: line)
                current.routeLines.append(command)
                groups[ident] = current
            } else {
                XCTFail("Неожиданная команда \(command)", file: file, line: line)
            }
        }
        return groups
    }

    func testBoundaries300301600601KeepEveryEntryWithinRouterLimit() throws {
        for count in [300, 301, 600, 601] {
            let wanted = entries(count)
            let original = ["domain-list0": group("domain-list0", number: 1, entries: Array(wanted.prefix(300)))]
            let update = try plan(wanted, groups: original)
            let after = try execute(update, on: original)
            XCTAssertEqual(after.count, (count + 299) / 300)
            XCTAssertEqual(Set(after.values.flatMap(\.includes)), Set(wanted))
            XCTAssertEqual(after.values.reduce(0) { $0 + $1.count }, count)
            XCTAssertTrue(PlanVerifier.problems(plan: update, groups: after, limit: 300).isEmpty)
            XCTAssertTrue(update.verifyBeforeSave)
        }
    }

    func testOversizedSettingCannotIncreaseHard300Limit() throws {
        let original = ["old": group("old", number: 1, entries: entries(300))]
        let update = try plan(entries(601), groups: original, chunkSize: 9_000)
        let after = try execute(update, on: original)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(update.groupEntryLimit, 300)
        XCTAssertEqual(Set(after.values.flatMap(\.includes)), Set(entries(601)))
    }

    func testZeroChunkSizeIsClampedAndRepairsExistingOverfullPart() throws {
        let original = ["old": group("old", number: 1, entries: entries(3))]
        let update = try plan(entries(3), groups: original, chunkSize: 0)
        let after = try execute(update, on: original, limit: 1)
        XCTAssertEqual(update.groupEntryLimit, 1)
        XCTAssertEqual(after.values.map(\.count).sorted(), [1, 1, 1])
        XCTAssertEqual(Set(after.values.flatMap(\.includes)), Set(entries(3)))
    }

    func testRemovalsFreeSpaceAndExistingEntriesDoNotMoveBetweenParts() throws {
        let wanted = entries(301)
        let original = [
            "first": group("first", number: 1, entries: Array(wanted.prefix(299)) + ["gone.example.com"]),
            "second": group("second", number: 2, entries: [wanted[299]])
        ]
        let update = try plan(wanted, groups: original)
        let after = try execute(update, on: original)
        XCTAssertEqual(update.commands.first, "no object-group fqdn first include gone.example.com")
        XCTAssertTrue(update.createdGroups.isEmpty)
        XCTAssertEqual(update.adds, ["first": [wanted[300]]])
        XCTAssertEqual(after["second"], original["second"])
        XCTAssertEqual(after["first"]?.count, 300)
    }

    func testNewPartsInheritExactRoutePriorityAndEachFlagBeforeIncludes() throws {
        let original = ["old": group("old", number: 1, entries: entries(300))]
        let update = try plan(entries(601), groups: original)
        let after = try execute(update, on: original)
        XCTAssertEqual(after["old"]?.routeLines, original["old"]?.routeLines)
        XCTAssertEqual(after["old"]?.descriptionText, "Example")
        for created in update.createdGroups {
            XCTAssertEqual(after[created.ident]?.routeAssignments, [primary, fallback])
            XCTAssertEqual(update.exactRouteChains[created.ident], [primary, fallback])
        }
    }

    func testShrinkKeepsEmptyPartAndRoutesForFutureGrowth() throws {
        let values = entries(601)
        let original = [
            "first": group("first", number: 1, entries: Array(values.prefix(300))),
            "second": group("second", number: 2, entries: Array(values.dropFirst(300).prefix(300))),
            "third": group("third", number: 3, entries: [values[600]])
        ]
        let update = try plan([values[0]], groups: original)
        let after = try execute(update, on: original)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(update.removeCount, 600)
        XCTAssertEqual(after["second"]?.includes, [])
        XCTAssertEqual(after["third"]?.routeLines, original["third"]?.routeLines)
        XCTAssertTrue(PlanVerifier.problems(plan: update, groups: after, limit: 300).isEmpty)
        let regrowth = try plan(values, groups: after)
        XCTAssertTrue(regrowth.createdGroups.isEmpty)
        XCTAssertEqual(Set(try execute(regrowth, on: after).values.flatMap(\.includes)), Set(values))
    }

    func testRepeatingUpdateAndReorderedSourceAreIdempotent() throws {
        let original = ["old": group("old", number: 1, entries: ["gone.example.com"])]
        let initial = try plan(entries(601), groups: original)
        let after = try execute(initial, on: original)
        let repeated = try plan(Array(entries(601).reversed()), groups: after)
        XCTAssertTrue(repeated.isEmpty)
        XCTAssertEqual(repeated.expectedGroupContents, initial.expectedGroupContents)
    }

    func testExistingOversizedPartIsSplitWithoutLostDesiredEntries() throws {
        let original = ["old": group("old", number: 1, entries: entries(601))]
        let update = try plan(entries(601), groups: original)
        let after = try execute(update, on: original)
        XCTAssertEqual(after.values.map(\.count).sorted(), [1, 300, 300])
        XCTAssertEqual(update.removeCount, 301)
        XCTAssertEqual(update.addCount, 301)
        XCTAssertEqual(Set(after.values.flatMap(\.includes)), Set(entries(601)))
        XCTAssertTrue(after.values.allSatisfy { $0.routeAssignments == [primary, fallback] })
    }

    func testDuplicateSourceEntriesAndDuplicateStoredCopiesDoNotConsumeCapacity() throws {
        let original = [
            "first": group("first", number: 1, entries: ["one.example.com"]),
            "second": group("second", number: 2, entries: ["one.example.com", "two.example.com"])
        ]
        let update = try plan(["ONE.EXAMPLE.COM.", "one.example.com", "two.example.com"], groups: original)
        let after = try execute(update, on: original)
        XCTAssertEqual(update.addCount, 0)
        XCTAssertEqual(update.removes, ["second": ["one.example.com"]])
        XCTAssertEqual(after.values.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(after["first"], original["first"])
    }

    func testMissingSourceIsNotImportedAndUnmanagedGroupsAreUntouched() throws {
        let foreign = group("foreign", number: 1, entries: entries(20), chain: [], prefix: "Personal")
        let update = try plan(entries(601), groups: [foreign.ident: foreign])
        XCTAssertTrue(update.isEmpty)
        XCTAssertTrue(update.domainListBaselines.isEmpty)

        let original = ["foreign": foreign, "managed": group("managed", number: 1, entries: entries(1))]
        let actual = try execute(plan(entries(301), groups: original), on: original)
        XCTAssertEqual(actual["foreign"], foreign)
    }

    func testDuplicateOrInvalidPartNumbersRejectEntireSourceBeforeAllocation() {
        for description in ["Example 1", "Example 01", "Example 0"] {
            var second = group("second", number: 2, entries: entries(1))
            second.descriptionText = description
            let original = ["first": group("first", number: 1, entries: entries(1)), "second": second]
            var reserved: Set<String> = ["reserved"]
            XCTAssertThrowsError(try DomainListSyncPlanner.plan(groups: original, data: data(entries(601)),
                                                               reservedIDs: &reserved))
            XCTAssertEqual(reserved, ["reserved"])
        }
    }

    func testDifferentRouteOrderOrFlagsRejectSource() {
        for different in [[fallback, primary], [primary], [],
                          [DnsRouteAssignment(interface: primary.interface, auto: false, reject: false), fallback]] {
            let original = ["first": group("first", number: 1, entries: entries(300)),
                            "second": group("second", number: 2, entries: [], chain: different)]
            XCTAssertThrowsError(try plan(entries(601), groups: original))
        }
    }

    func testUnknownDuplicateOrUnparsedRoutesRejectSource() {
        let invalid: [[String]] = [
            ["unsupported route"],
            ["dns-proxy route object-group old Wireguard0 auto mystery"],
            ["dns-proxy route object-group other Wireguard0 auto"],
            ["dns-proxy route object-group old Wireguard0 auto auto"],
            ["dns-proxy route object-group old Wireguard0 auto",
             "dns-proxy route object-group old Wireguard0 reject"]
        ]
        for lines in invalid {
            var old = group("old", number: 1, entries: entries(300))
            old.routeLines = lines
            XCTAssertThrowsError(try plan(entries(301), groups: [old.ident: old]), lines.joined(separator: ", "))
        }
    }

    func testEntirelyUnroutedSourceStaysUnrouted() throws {
        let original = ["old": group("old", number: 1, entries: entries(300), chain: [])]
        let update = try plan(entries(301), groups: original)
        let after = try execute(update, on: original)
        XCTAssertTrue(update.routeTargets.isEmpty)
        XCTAssertTrue(after.values.allSatisfy { $0.routeLines.isEmpty })
        XCTAssertTrue(PlanVerifier.problems(plan: update, groups: after, limit: 300).isEmpty)
    }

    func testUntrustworthyDataCannotDeleteInstalledEntries() {
        let original = ["old": group("old", number: 1, entries: entries(300))]
        var minimum = spec()
        minimum = SourceSpec(key: minimum.key, title: minimum.title, subtitle: "", descriptionPrefix: "Example",
                             icon: "globe", urls: [], cacheName: "test.txt", minDomains: 50)
        for sourceData in [data([]), data(["invalid"]), data(entries(1), cached: true),
                           data(entries(1), skipped: ["malformed"]), data(entries(49), source: minimum)] {
            var reserved = Set(original.keys)
            XCTAssertThrowsError(try DomainListSyncPlanner.plan(groups: original, data: sourceData,
                                                               reservedIDs: &reserved))
            XCTAssertEqual(reserved, Set(original.keys))
        }
    }

    func testMultipleSourcePlansReserveUniqueIDsAndMergeAllVerification() throws {
        let first = group("domain-list0", number: 1, entries: entries(300))
        let second = group("domain-list2", number: 1, entries: entries(300), prefix: "Another")
        let original = [first.ident: first, second.ident: second]
        var reserved = Set(original.keys)
        let firstPlan = try DomainListSyncPlanner.plan(groups: original, data: data(entries(301)), reservedIDs: &reserved)
        let secondPlan = try DomainListSyncPlanner.plan(groups: original, data: data(entries(601), source: spec("Another")),
                                                       reservedIDs: &reserved)
        let merged = Planner.merge(title: "Update", plans: [firstPlan, secondPlan])
        XCTAssertEqual(Set(merged.createdGroups.map(\.ident)).count, 3)
        XCTAssertEqual(merged.domainListBaselines.count, 2)
        XCTAssertEqual(merged.expectedGroupContents.count, 5)
        XCTAssertEqual(merged.groupEntryLimit, 300)
        XCTAssertTrue(merged.verifyBeforeSave)
        XCTAssertTrue(PlanVerifier.preconditionProblems(plan: merged, groups: original).isEmpty)
        XCTAssertTrue(PlanVerifier.problems(plan: merged, groups: try execute(merged, on: original), limit: 300).isEmpty)
    }

    func testPreconditionRejectsEditedRemovedAndNewManagedPartsOrOccupiedNewID() throws {
        let original = ["old": group("old", number: 1, entries: entries(300))]
        let update = try plan(entries(301), groups: original)
        var changed = original
        changed["old"]?.includes.insert("outside.example.com")
        XCTAssertFalse(PlanVerifier.preconditionProblems(plan: update, groups: changed).isEmpty)
        changed = original
        changed["old"]?.routeLines.reverse()
        XCTAssertFalse(PlanVerifier.preconditionProblems(plan: update, groups: changed).isEmpty)
        XCTAssertFalse(PlanVerifier.preconditionProblems(plan: update, groups: [:]).isEmpty)
        changed = original
        changed["new"] = group("new", number: 3, entries: [])
        XCTAssertFalse(PlanVerifier.preconditionProblems(plan: update, groups: changed).isEmpty)
        changed = original
        let created = try XCTUnwrap(update.createdGroups.first)
        changed[created.ident] = group(created.ident, number: 1, entries: [], prefix: "Personal")
        XCTAssertFalse(PlanVerifier.preconditionProblems(plan: update, groups: changed).isEmpty)
        changed = original
        changed["unrelated"] = group("unrelated", number: 1, entries: entries(1), prefix: "Personal")
        XCTAssertTrue(PlanVerifier.preconditionProblems(plan: update, groups: changed).isEmpty)
    }

    func testExactVerificationDetectsUnexpectedMissingOverfullAndMissingEmptyGroup() throws {
        let original = ["old": group("old", number: 1, entries: entries(300)),
                        "empty": group("empty", number: 2, entries: [])]
        let update = try plan(entries(300), groups: original)
        XCTAssertTrue(update.isEmpty)
        XCTAssertTrue(PlanVerifier.problems(plan: update, groups: original, limit: 300).isEmpty)
        var changed = original
        changed["old"]?.includes.insert("unexpected.example.com")
        let problems = PlanVerifier.problems(plan: update, groups: changed, limit: 9_000)
        XCTAssertTrue(problems.contains { $0.contains("лишних записей 1") })
        XCTAssertTrue(problems.contains { $0.contains("301/300") })
        changed = original
        changed["old"]?.includes.remove(entries(1)[0])
        XCTAssertTrue(PlanVerifier.problems(plan: update, groups: changed, limit: 300).contains { $0.contains("отсутствует 1") })
        changed = original
        changed.removeValue(forKey: "empty")
        XCTAssertTrue(PlanVerifier.problems(plan: update, groups: changed, limit: 300).contains { $0.contains("empty") })
    }

    func testVerificationRejectsUnknownRouteFlagEvenIfCommonParserIgnoresIt() throws {
        let original = ["old": group("old", number: 1, entries: entries(1))]
        let update = try plan(entries(1), groups: original)
        var changed = original
        changed["old"]?.routeLines[0] += " mystery"
        XCTAssertEqual(changed["old"]?.routeAssignments, original["old"]?.routeAssignments)
        XCTAssertFalse(PlanVerifier.problems(plan: update, groups: changed, limit: 300).isEmpty)
    }

    func testVerificationDetectsLostDescriptionsThatWouldBreakFutureSourceUpdates() throws {
        let original = ["old": group("old", number: 1, entries: entries(300))]
        let update = try plan(entries(301), groups: original)
        let actual = try execute(update, on: original)
        for ident in ["old", try XCTUnwrap(update.createdGroups.first).ident] {
            var changed = actual
            changed[ident]?.descriptionText = "Unrelated"
            XCTAssertTrue(PlanVerifier.problems(plan: update, groups: changed, limit: 300)
                .contains { $0.contains(ident) && $0.contains("имя части") })
        }
        var concurrentlyExpanded = actual
        concurrentlyExpanded["extra"] = group("extra", number: 8, entries: ["unexpected.example.com"])
        XCTAssertTrue(PlanVerifier.problems(plan: update, groups: concurrentlyExpanded, limit: 300)
            .contains { $0.contains("дополнительные части") })
    }
}
