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

    /// Early history reused some version numbers across separate builds (4.21 is both Build 41
    /// and Build 77), so the version string alone isn't unique; each release — version plus
    /// build — must be, and the latest version must not appear twice.
    @MainActor func testChangelogReleasesAreUnique() {
        let releases = StockedChangelog.versions.map { "\($0.version)|\($0.buildDate)" }
        XCTAssertEqual(releases.count, Set(releases).count, "Duplicate changelog release (version + build)")
        guard let latest = StockedChangelog.versions.first(where: \.isLatest) else { return }
        XCTAssertEqual(StockedChangelog.versions.filter { $0.version == latest.version }.count, 1,
                       "The latest changelog version string is reused by an older entry")
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
