import XCTest
@testable import Stocked

/// Repeatable micro-budgets for the pure transforms used by recipe cards, search,
/// ingestion, and quantity parsing. These deliberately avoid network, disk, and UI
/// work so a regression points at application code instead of simulator variance.
final class PerformanceBudgetTests: XCTestCase {
    private struct AsyncReadFixture: Codable, Equatable, Sendable {
        let values: [Int]
    }

    func testFoodMatchingHotPath() {
        let inventory = [
            "H-E-B organic whole milk", "Great Value canned tomatoes", "green onions",
            "garbanzo beans", "plain Greek yoghurt", "boneless chicken breast",
        ]
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for _ in 0..<1_000 {
                for name in inventory {
                    _ = FoodNameMatcher.matches(name, "organic canned tomato").score
                }
            }
        }
    }

    func testMeasureParserHotPath() {
        let lines = [
            "1 1/2 cups all-purpose flour", "⅜ tsp kosher salt", "2-3 cloves garlic",
            "1,5 kg potatoes", "4 fl oz heavy cream", "pepper to taste",
        ]
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for _ in 0..<1_000 {
                for line in lines { _ = MeasureParser.parse(line) }
            }
        }
    }

    func testRecipeStoreResultLimitsCannotBecomeUnbounded() {
        XCTAssertEqual(RecipeStore.boundedResultLimit(-1, maximum: 100), 0)
        XCTAssertEqual(RecipeStore.boundedResultLimit(30, maximum: 100), 30)
        XCTAssertEqual(RecipeStore.boundedResultLimit(Int.max, maximum: 100), 100)
        XCTAssertEqual(RecipeStore.boundedResultLimit(30, maximum: -1), 0)
    }

    func testRecipeStoreSamplingBudgetAndImageContract() {
        XCTAssertEqual(RecipeStore.sampleWindowSpan(for: 0), 512)
        XCTAssertEqual(RecipeStore.sampleWindowSpan(for: 30), 512)
        XCTAssertEqual(RecipeStore.sampleWindowSpan(for: 200), 3_200)
        XCTAssertEqual(RecipeStore.sampleWindowSpan(for: Int.max), 4_096)

        XCTAssertTrue(RecipeStore.isValidRemoteImageURL("https://images.example.com/recipe"))
        XCTAssertTrue(RecipeStore.isValidRemoteImageURL("http://cdn.example.com/recipe.jpg"))
        XCTAssertFalse(RecipeStore.isValidRemoteImageURL(""))
        XCTAssertFalse(RecipeStore.isValidRemoteImageURL("recipe.jpg"))
        XCTAssertFalse(RecipeStore.isValidRemoteImageURL("file:///tmp/recipe.jpg"))
        XCTAssertFalse(RecipeStore.isValidRemoteImageURL("data:image/png;base64,AA=="))
    }

    func testLocalDatabaseAsyncReadAfterExplicitFlush() async {
        let db = LocalDatabase.shared
        let key = "performance_async_read_\(UUID().uuidString)"
        let fixture = AsyncReadFixture(values: Array(0..<256))
        defer { db.delete(key: key) }

        db.save(fixture, key: key)
        await db.flush()

        let loaded = await db.loadAsync(AsyncReadFixture.self, key: key)
        XCTAssertEqual(loaded, fixture)
    }

    func testLocalDatabaseAsyncArrayReadAfterExplicitFlush() async {
        let db = LocalDatabase.shared
        let key = "performance_async_array_read_\(UUID().uuidString)"
        let fixture = (0..<256).map { AsyncReadFixture(values: [$0]) }
        defer { db.delete(key: key) }

        db.save(fixture, key: key)
        await db.flush()

        let loaded = await db.loadArrayAsync(AsyncReadFixture.self, key: key)
        XCTAssertEqual(loaded, fixture)
    }

    override func tearDown() {
        FoodNameMatcher.purgeCaches()
        super.tearDown()
    }
}
