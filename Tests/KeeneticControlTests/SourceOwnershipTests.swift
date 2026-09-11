import XCTest
@testable import KeeneticControl

final class SourceOwnershipTests: XCTestCase {
    private func source(_ prefix: String, title: String = "Test source") -> CustomSource {
        CustomSource(title: title, descriptionPrefix: prefix, urls: ["https://example.invalid/list.txt"])
    }

    func testEqualPrefixesRemainOneStableConflictGroup() {
        let sources = [source("my list", title: "C"), source("MY_LIST", title: "A"),
                       source("my-list", title: "B"), source("separate", title: "D")]
        XCTAssertEqual(CustomSource.conflictingSourceTitles(sources.map(\.spec)), ["A / B / C"])
    }

    func testNumberedPrefixConflictsInBothCatalogOrders() {
        for part in ["my list 2", "MY_LIST:2", "my-list_02", "my list 1"] {
            let a = source("my list", title: "A"), b = source(part, title: "B")
            XCTAssertEqual(CustomSource.conflictingSourceTitles([a.spec, b.spec]), ["A / B"])
            XCTAssertEqual(CustomSource.conflictingSourceTitles([b.spec, a.spec]), ["A / B"])
            XCTAssertNotNil(Planner.sourceGroupNumber(description: part, spec: a.spec))
            XCTAssertThrowsError(try CustomSource.validate(a, existing: [b]))
            XCTAssertThrowsError(try CustomSource.validate(b, existing: [a]))
        }
    }

    func testConflictingPartsAreGroupedWithoutDuplicatePairs() {
        let sources = [source("example 2", title: "Part 2"), source("example", title: "Base"),
                       source("example 3", title: "Part 3")]
        XCTAssertEqual(CustomSource.conflictingSourceTitles(sources.map(\.spec)), ["Base / Part 2 / Part 3"])
    }

    func testSeparatorVariantsCannotHideOverlappingOwnership() {
        let a = source("my-list", title: "A"), b = source("my list 2", title: "B")
        let sharedDescription = "my-list 2"
        XCTAssertNotNil(Planner.sourceGroupNumber(description: sharedDescription, spec: a.spec))
        XCTAssertNotNil(Planner.sourceGroupNumber(description: sharedDescription, spec: b.spec))
        XCTAssertEqual(CustomSource.conflictingSourceTitles([a.spec, b.spec]), ["A / B"])
        XCTAssertThrowsError(try CustomSource.validate(a, existing: [b]))
        XCTAssertThrowsError(try CustomSource.validate(b, existing: [a]))
    }

    func testDistinctNamesWithSharedPrefixRemainValid() throws {
        for prefix in ["kinopub-alt", "kinopub2", "kinopub v2", "kinopub alternate 2"] {
            let candidate = source(prefix)
            XCTAssertTrue(CustomSource.conflictingSourceTitles(
                [SourceCatalog.spec(for: "kinopub")!, candidate.spec]).isEmpty)
            XCTAssertNoThrow(try CustomSource.validate(candidate, existing: []))
        }
        XCTAssertTrue(CustomSource.conflictingSourceTitles([
            source("my list 2").spec, source("my list 3").spec]).isEmpty)
    }

    func testNewSourceCannotClaimFuturePartOfBuiltInSource() {
        let candidate = source("KinoPub-2")
        XCTAssertThrowsError(try CustomSource.validate(candidate, existing: []))
        XCTAssertFalse(CustomSource.conflictingSourceTitles(SourceCatalog.all + [candidate.spec]).isEmpty)
    }

    func testEditorStillAllowsEditingSameSourceButRejectsRenamingIntoOtherPart() throws {
        var edited = source("my list")
        XCTAssertNoThrow(try CustomSource.validate(edited, existing: [edited]))
        let another = source("another", title: "Another")
        edited.descriptionPrefix = "another 2"
        XCTAssertThrowsError(try CustomSource.validate(edited, existing: [edited, another]))
    }
}
