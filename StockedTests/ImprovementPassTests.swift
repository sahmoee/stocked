// ImprovementPassTests.swift — Guards added in the improvement pass:
// release metadata consistency, ingredient fingerprints, the three static regexes that are
// built with `try!`, and the force-unwrapped retailer URLs. Each test forces the static to load,
// so a typo fails CI instead of crashing the app on first use.
import XCTest
@testable import Stocked

final class ReleaseConsistencyTests: XCTestCase {

    @MainActor func testExactlyOneLatestChangelogVersion() {
        XCTAssertEqual(StockedChangelog.versions.filter(\.isLatest).count, 1,
                       "AppChangelog must have exactly one isLatest: true version")
    }

    @MainActor func testLatestChangelogVersionIsListedFirst() {
        XCTAssertEqual(StockedChangelog.versions.first?.isLatest, true,
                       "New changelog versions go at the top of StockedChangelog.versions")
    }

    @MainActor func testChangeCountMatchesLatestEntries() {
        guard let latest = StockedChangelog.versions.first(where: \.isLatest) else {
            return XCTFail("No latest changelog version")
        }
        XCTAssertEqual(BuildConfig.changeCount, latest.entries.count,
                       "BuildConfig.changeCount must equal the latest changelog version's entry count")
    }

    @MainActor func testChangelogVersionsAreUnique() {
        let versions = StockedChangelog.versions.map(\.version)
        XCTAssertEqual(versions.count, Set(versions).count, "Duplicate changelog version strings")
    }
}

final class IngredientFingerprintTests: XCTestCase {

    func testFingerprintIsOrderIndependent() {
        XCTAssertEqual(IngredientMatcher.ingredientFingerprint(["chicken breast", "fettuccine", "parmesan"]),
                       IngredientMatcher.ingredientFingerprint(["parmesan", "chicken breast", "fettuccine"]))
    }

    func testDifferentIngredientSetsDiffer() {
        XCTAssertNotEqual(IngredientMatcher.ingredientFingerprint(["rice", "beans"]),
                          IngredientMatcher.ingredientFingerprint(["rice", "lentils"]))
    }
}

final class StaticPatternTests: XCTestCase {

    func testFinderDurationParsesCommonTimes() {
        XCTAssertEqual(FinderDuration.minutes("20 minutes"), 20)
        XCTAssertEqual(FinderDuration.minutes("1 hour"), 60)
        XCTAssertEqual(FinderDuration.minutes("1 hour 30 minutes"), 90)
        XCTAssertNil(FinderDuration.minutes("10-15 minutes"))
    }

    func testCookingTimerDetectsDurations() {
        XCTAssertEqual(CookingTimerPolicy.detectSeconds(in: "Bake for 25 minutes"), 1_500)
        XCTAssertEqual(CookingTimerPolicy.detectSeconds(in: "Simmer 1 hour and 30 minutes"), 5_400)
        XCTAssertEqual(CookingTimerPolicy.detectSeconds(in: "Cook 10 to 12 minutes"), 720)
        XCTAssertNil(CookingTimerPolicy.detectSeconds(in: "Season to taste"))
    }

    func testQuantityParserHandlesHyphenatedPacks() {
        XCTAssertNil(QuantityParser.parse("2 6-pack sparkling water").validationMessage)
    }
}

final class RetailerCatalogTests: XCTestCase {

    func testEveryRetailerLoadsWithHTTPSLocator() {
        let retailers = GroceryKnowledgeBase.retailers
        XCTAssertFalse(retailers.isEmpty)
        for retailer in retailers {
            XCTAssertEqual(retailer.officialLocatorURL.scheme, "https", retailer.name)
        }
    }

    func testRetailerIDsAreUnique() {
        let ids = GroceryKnowledgeBase.retailers.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }
}
