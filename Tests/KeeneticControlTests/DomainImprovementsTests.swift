import Foundation
import XCTest
@testable import KeeneticControl

final class DomainImprovementsTests: XCTestCase {
    private func spec(_ name: String = UUID().uuidString) -> SourceSpec {
        SourceSpec(key: name, title: name, subtitle: "fixture", descriptionPrefix: "fixture " + name,
                   icon: "globe", urls: ["https://example.invalid/first", "https://example.invalid/second"],
                   cacheName: "async-test-\(name).txt", minDomains: 1)
    }

    func testHostsAliasesAndTrailingCommentsAreComplete() {
        let parsed = Domains.parseList("0.0.0.0 first.example.org second.example.org # alias\r\n"
            + "::1 second.example.org third.example.org ; explanation\n"
            + "fourth.example.org // comment\n")
        XCTAssertEqual(parsed.domains, ["first.example.org", "second.example.org", "third.example.org", "fourth.example.org"])
        XCTAssertEqual(parsed.duplicates, 1)
        XCTAssertTrue(parsed.skipped.isEmpty)
        XCTAssertNil(Domains.normalize("0.0.0.0 first.example.org second.example.org"),
                     "A single-value API must not silently discard aliases")
    }

    func testMalformedTailsRejectWholeLineIncludingHosts() {
        for line in ["first.example.org INVALID-CONTENT", "first.example.org second.example.org",
                     "0.0.0.0 first.example.org INVALID-CONTENT", "0.0.0.0 first.example.org 127.0.0.1",
                     "fe80::1%en0", "fe80::1%en0/64", "fe80::1%en0 first.example.org"] {
            XCTAssertEqual(Domains.parseList(line).skipped, [line])
            XCTAssertTrue(Domains.parseList(line).domains.isEmpty)
            XCTAssertNil(Domains.normalize(line))
        }
        for line in ["10.0.0.0/8 192.168.0.0/16", "10.0.0.0/8 garbage", "fe80::1%en0", "fe80::1%en0/64"] {
            XCTAssertEqual(Domains.parseSubnetsWithDiagnostics(line).skipped, [line])
            XCTAssertTrue(Domains.parseSubnets(line).v4.isEmpty)
        }
        XCTAssertEqual(Domains.parseSubnets("10.0.0.0/8 # network").v4, ["10.0.0.0/8"])
    }

    func testHostsAliasCannotDisappearDuringSync() throws {
        let source = spec()
        let data = SourceData(spec: source,
            entries: Domains.parseList("0.0.0.0 first.example.org second.example.org").domains,
            fromCache: false, fetchedAt: Date(), skipped: [], duplicates: 0, subnetsV4: [], subnetsV6: [])
        let group = FqdnGroup(ident: "domain-list0", descriptionText: source.descriptionPrefix,
                              includes: ["first.example.org", "second.example.org"])
        var reserved: Set<String> = [group.ident]
        let plan = try DomainListSyncPlanner.plan(groups: [group.ident: group], data: data, reservedIDs: &reserved)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.removeCount, 0)
    }

    func testOldSettingsClampOnlyLimitsAndPreserveOtherPreferences() throws {
        let old = Data(#"{"chunkSize":1000,"maxDomainsPerList":2000,"keepBackups":7,"defaultAuto":false,"lastRouterID":"remembered","cacheTTLMinutes":19}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertEqual(settings.chunkSize, 300)
        XCTAssertEqual(settings.maxDomainsPerList, 300)
        XCTAssertEqual(settings.keepBackups, 7)
        XCTAssertFalse(settings.defaultAuto)
        XCTAssertEqual(settings.cacheTTLMinutes, 19)
        XCTAssertEqual(settings.lastRouterID, "remembered")
        let encoded = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertEqual(restored.chunkSize, 300)
        XCTAssertEqual(restored.keepBackups, 7)
        let contradictory = try JSONDecoder().decode(AppSettings.self,
            from: Data(#"{"chunkSize":300,"maxDomainsPerList":100}"#.utf8))
        XCTAssertEqual(contradictory.chunkSize, 100)
        XCTAssertEqual(FqdnLimits.effective(chunkSize: .max, verificationLimit: .min), 1)
    }

    func testManualImportHardLimitForBoundarySizesAndLegacySettings() {
        for count in [300, 301, 601] {
            let source = spec()
            let data = SourceData(spec: source, entries: (0..<count).map { "d\($0).example.org" },
                fromCache: false, fetchedAt: Date(), skipped: [], duplicates: 0, subnetsV4: [], subnetsV6: [])
            var reserved = Set<String>()
            let plan = Planner.planImport(groups: [:], data: data, chunkSize: 1000,
                                           removeStale: true, reservedIDs: &reserved)
            XCTAssertEqual(plan.createdGroups.count, (count + 299) / 300)
            XCTAssertEqual(plan.addCount, count)
            XCTAssertTrue(plan.adds.values.allSatisfy { $0.count <= 300 })
        }
    }

    func testHTTPMirrorRejectsPartialContentAndAcceptsCompleteAliases() async throws {
        let source = spec()
        defer { try? FileManager.default.removeItem(at: source.cacheFile) }
        let data = try await SourceLoader.load(source, ttlMinutes: 0, forceRefresh: true,
            requireFreshComplete: true, httpTransport: { request in
                let text = request.url!.path == "/first" ? "first.example.org INVALID-CONTENT" : "0.0.0.0 first.example.org second.example.org # aliases"
                return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        XCTAssertEqual(data.entries, ["first.example.org", "second.example.org"])
        XCTAssertFalse(data.fromCache)
        XCTAssertTrue(data.skipped.isEmpty)
    }

    func testHTTPRejectsStatusAndInvalidUTF8() async {
        for status in [403, 503, 200] {
            do {
                _ = try await SourceLoader.fetch("https://example.invalid/list", httpTransport: { request in
                    (Data([0xff]), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                })
                XCTFail("Status \(status) / invalid UTF-8 must fail")
            } catch { XCTAssertTrue(error is TransportError) }
        }
    }

    func testCancellationInterruptsHTTPAndDoesNotFallBackToCache() async throws {
        let source = spec()
        try "cached.example.org".write(to: source.cacheFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source.cacheFile) }
        let started = expectation(description: "HTTP started")
        let cancelled = expectation(description: "HTTP cancelled")
        let task = Task {
            try await SourceLoader.load(source, ttlMinutes: 0, forceRefresh: true, httpTransport: { _ in
                started.fulfill()
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { cancelled.fulfill(); throw error }
                throw TransportError("Should never finish")
            })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled download must not return cached data") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [cancelled], timeout: 2)
    }

    @MainActor
    func testBatchHasBoundedConcurrencyAndKeepsSuccessfulSources() async throws {
        let sources = (0..<8).map { spec("batch-\($0)") }
        var active = 0, peak = 0
        var completed: [String] = [], successful: [String] = []
        try await SourceDownloadBatch.load(sources, loader: { spec in
            active += 1; peak = max(peak, active)
            defer { active -= 1 }
            try await Task.sleep(nanoseconds: 20_000_000)
            if spec.key == "batch-2" { throw TransportError("Fixture failure") }
            return SourceData(spec: spec, entries: ["example.org"], fromCache: false,
                fetchedAt: Date(), skipped: [], duplicates: 0, subnetsV4: [], subnetsV6: [])
        }, onComplete: { outcome in
            completed.append(outcome.spec.key)
            if case .success = outcome.result { successful.append(outcome.spec.key) }
        })
        XCTAssertEqual(peak, 3)
        XCTAssertEqual(active, 0)
        XCTAssertEqual(Set(completed), Set(sources.map(\.key)))
        XCTAssertEqual(successful.count, 7)
    }

    @MainActor
    func testCancellingBatchStopsActiveRequestsAndDoesNotStartQueuedSources() async {
        let sources = (0..<9).map { spec("cancel-batch-\($0)") }
        var started = 0, cancelled = 0
        let task = Task {
            try await SourceDownloadBatch.load(sources, loader: { _ in
                started += 1
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { cancelled += 1; throw error }
                throw TransportError("Should not finish")
            }, onComplete: { _ in XCTFail("No request should complete") })
        }
        for _ in 0..<100 where started < 3 { await Task.yield() }
        XCTAssertEqual(started, 3)
        task.cancel()
        do { try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(started, 3)
        XCTAssertEqual(cancelled, 3)
    }
}
