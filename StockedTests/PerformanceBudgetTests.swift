import XCTest
@testable import Stocked

/// Repeatable micro-budgets for the pure transforms used by recipe cards, search,
/// ingestion, and quantity parsing. These deliberately avoid network, disk, and UI
/// work so a regression points at application code instead of simulator variance.
final class PerformanceBudgetTests: XCTestCase {
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

    override func tearDown() {
        FoodNameMatcher.purgeCaches()
        super.tearDown()
    }
}
