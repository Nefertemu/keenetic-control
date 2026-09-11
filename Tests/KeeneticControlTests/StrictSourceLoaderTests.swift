import Foundation
import XCTest
@testable import KeeneticControl

final class StrictSourceLoaderTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let spec: SourceSpec
        let domains: URL
        let v4: URL
        let v6: URL

        init(subnets: Bool = true) throws {
            let id = UUID().uuidString
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("strict-source-\(id)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            domains = directory.appendingPathComponent("domains.txt")
            v4 = directory.appendingPathComponent("ipv4.txt")
            v6 = directory.appendingPathComponent("ipv6.txt")
            spec = SourceSpec(key: "strict-test-\(id)", title: "Strict fixture", subtitle: "", descriptionPrefix: "strict-test",
                              icon: "globe", urls: [domains.path], cacheName: "strict-test-\(id).txt",
                              subnetURLs: subnets ? [v4.path, v6.path] : [], minDomains: 1)
        }

        func write(domains: String = "keep.example.org\n", v4: String = "192.0.2.0/24\n",
                   v6: String = "2001:db8::/32\n") throws {
            try domains.write(to: self.domains, atomically: true, encoding: .utf8)
            try v4.write(to: self.v4, atomically: true, encoding: .utf8)
            try v6.write(to: self.v6, atomically: true, encoding: .utf8)
        }

        func cleanup() {
            for url in [directory, spec.cacheFile, spec.subnetCacheFile]
                where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        func load(strict: Bool = true, forceRefresh: Bool = true) throws -> SourceData {
            try SourceLoader.load(spec, ttlMinutes: 60, forceRefresh: forceRefresh, requireFreshComplete: strict)
        }
    }

    func testStrictDownloadAcceptsCommentsCRLFAndDuplicates() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(domains: "# Domain list\r\n\r\nkeep.example.org\r\nkeep.example.org\r\n! Comment\r\n",
                          v4: "# IPv4\r\n192.0.2.0/24\r\n192.0.2.0/24\r\n; Another comment\r\n",
                          v6: "// IPv6\r\n2001:db8::/32\r\n\r\n")
        let loaded = try fixture.load()
        XCTAssertFalse(loaded.fromCache)
        XCTAssertNotNil(loaded.fetchedAt)
        XCTAssertTrue(loaded.skipped.isEmpty)
        XCTAssertEqual(Set(loaded.entries), ["keep.example.org", "192.0.2.0/24", "2001:db8::/32"])
        XCTAssertEqual(loaded.duplicates, 1)
    }

    func testStrictDownloadRejectsPartiallyParsedDomains() throws {
        let fixture = try Fixture(subnets: false)
        defer { fixture.cleanup() }
        try fixture.write(domains: "keep.example.org\n<malformed format>\n")
        XCTAssertThrowsError(try fixture.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.spec.cacheFile.path),
                       "A partially parsed strict download must not replace the cache")
        let preview = try fixture.load(strict: false)
        XCTAssertEqual(preview.entries, ["keep.example.org"])
        XCTAssertEqual(preview.skipped, ["<malformed format>"])
    }

    func testStrictDownloadRejectsPartiallyParsedSubnetComponent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(v4: "192.0.2.0/24\n198.51.100.0/INVALID\n")
        XCTAssertThrowsError(try fixture.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.spec.subnetCacheFile.path),
                       "An incomplete subnet set must not be stamped as complete")
        let preview = try fixture.load(strict: false)
        XCTAssertEqual(preview.subnetsV4, ["192.0.2.0/24"])
        XCTAssertEqual(preview.subnetsV6, ["2001:db8::/32"])
    }

    func testStrictDownloadRejectsMissingComponentDespiteCompleteCache() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write()
        _ = try fixture.load()
        try FileManager.default.removeItem(at: fixture.v6)
        XCTAssertThrowsError(try fixture.load())
        let preview = try fixture.load(strict: false)
        XCTAssertTrue(preview.fromCache)
        XCTAssertEqual(preview.subnetsV6, ["2001:db8::/32"])
    }

    func testStrictDownloadNeverFallsBackToDomainCache() throws {
        let fixture = try Fixture(subnets: false)
        defer { fixture.cleanup() }
        try fixture.write()
        _ = try fixture.load()
        try FileManager.default.removeItem(at: fixture.domains)
        XCTAssertThrowsError(try fixture.load())
        let preview = try fixture.load(strict: false)
        XCTAssertTrue(preview.fromCache)
        XCTAssertEqual(preview.entries, ["keep.example.org"])
    }

    func testStrictFlagAlwaysBypassesFreshCache() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write()
        _ = try fixture.load()
        try fixture.write(domains: "changed.example.org\n", v4: "198.51.100.0/24\n")
        let loaded = try fixture.load(forceRefresh: false)
        XCTAssertFalse(loaded.fromCache)
        XCTAssertEqual(Set(loaded.entries), ["changed.example.org", "198.51.100.0/24", "2001:db8::/32"])
    }

    func testStrictDownloadRejectsEmptySubnetComponent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(v6: "# nothing here\n\n")
        XCTAssertThrowsError(try fixture.load())
    }

    func testDelegatedTopLevelDomainsNormalizeIdempotentlyWithoutAcceptingErrorWords() throws {
        let cases = [(".ua", "ua"), ("ua", "ua"), ("UA.", "ua"), ("*.ua", "ua"),
                     (".com", "com"), (".рф", "xn--p1ai"), (".ua # zone", "ua"),
                     ("0.0.0.0 ua # zone", "ua")]
        for (raw, expected) in cases {
            XCTAssertEqual(Domains.normalize(raw), expected, raw)
            XCTAssertEqual(Domains.normalize(expected), expected, "Planner normalization must be stable")
        }
        for invalid in ["localhost", "ERROR", "unknown", ".unknown", ".not-a-real-tld", ".123", ".",
                        "network failure", "page not found", "0.0.0.0 ua unexpected-data"] {
            XCTAssertNil(Domains.normalize(invalid), invalid)
        }
    }

    func testStrictSourceRejectsFailureMessagesBeginningWithRegisteredTopLevelDomain() throws {
        let fixture = try Fixture(subnets: false)
        defer { fixture.cleanup() }
        for errorMessage in ["network failure", "page not found"] {
            try fixture.write(domains: "keep.example.org\n\(errorMessage)\n")
            XCTAssertThrowsError(try fixture.load(), errorMessage)
            XCTAssertEqual(Domains.parseList(errorMessage).skipped, [errorMessage])
        }
    }

    func testStrictSourceContainingTopLevelZoneCanBePlannedAndRepeated() throws {
        let fixture = try Fixture(subnets: false)
        defer { fixture.cleanup() }
        // inside-raw.lst начинает список с .ua — это весь доменный суффикс,
        // а не ошибка и не строка, которую можно молча выбросить перед удалением.
        try fixture.write(domains: ".ua\nkeep.example.org\n")
        let loaded = try fixture.load()
        XCTAssertEqual(loaded.entries, ["ua", "keep.example.org"])
        XCTAssertTrue(loaded.skipped.isEmpty)
        var group = FqdnGroup(ident: "domain-list0", descriptionText: fixture.spec.descriptionPrefix,
                              includes: ["keep.example.org"])
        var reserved: Set<String> = [group.ident]
        let plan = try DomainListSyncPlanner.plan(groups: [group.ident: group], data: loaded,
                                                  reservedIDs: &reserved)
        XCTAssertEqual(plan.addCount, 1)
        XCTAssertEqual(plan.removeCount, 0)
        XCTAssertTrue(plan.commands.contains("object-group fqdn domain-list0 include ua"))
        group.includes.insert("ua")
        let repeated = try DomainListSyncPlanner.plan(groups: [group.ident: group], data: loaded,
                                                      reservedIDs: &reserved)
        XCTAssertTrue(repeated.isEmpty)
    }

    /// Явный smoke-test публичных источников; обычный прогон полностью локален.
    func testLiveCatalogSourcesAreFreshAndComplete() throws {
        guard ProcessInfo.processInfo.environment["KC_LIVE_DOMAIN_SOURCES"] == "1" else {
            throw XCTSkip("Live source downloads require KC_LIVE_DOMAIN_SOURCES=1")
        }
        for spec in SourceCatalog.all {
            do {
                let loaded = try SourceLoader.load(spec, ttlMinutes: 0, forceRefresh: true,
                                                   requireFreshComplete: true)
                XCTAssertEqual(loaded.spec, spec)
                XCTAssertFalse(loaded.fromCache, spec.key)
                XCTAssertTrue(loaded.skipped.isEmpty, spec.key)
                XCTAssertNotNil(loaded.fetchedAt, spec.key)
                XCTAssertGreaterThanOrEqual(loaded.entries.count, spec.minDomains, spec.key)
                if !spec.subnetURLs.isEmpty {
                    XCTAssertGreaterThan(loaded.subnetCount, 0, spec.key)
                }
                print("SOURCE \(spec.key): entries=\(loaded.entries.count), domains=\(loaded.domainCount), "
                    + "ipv4=\(loaded.subnetsV4.count), ipv6=\(loaded.subnetsV6.count), fresh=true")
            } catch {
                XCTFail("\(spec.key): \(RouterConnectionManager.describeError(error))")
            }
        }
    }
}
