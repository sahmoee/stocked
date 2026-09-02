// StockedLogicTests.swift — Unit tests for core, pure logic (#3).
//
// IMPORTANT: these must run in a **Unit Test Bundle target**, not the app target. In Xcode:
//   File ▸ New ▸ Target… ▸ Unit Testing Bundle ▸ name it "StockedTests" ▸ host app = Stocked.
// Then add this file to that test target's membership. (Running XCTest inside the app target
// fails because XCTest isn't linked there — which is why the old StockedTests.swift was empty.)
//
// These cover logic that doesn't need the live session: search folding, grocery de-duplication,
// and expiry-day math. Add more as the data layer gets more testable (see #8/#9 refactors).

import XCTest
@testable import Stocked

final class StockedLogicTests: XCTestCase {

    // MARK: Search normalization (#9)

    func testSearchFoldingIgnoresAccents() {
        XCTAssertTrue("Jalapeño".searchMatches("jalapeno"))
        XCTAssertTrue("jalapeno".searchMatches("Jalapeño"))
        XCTAssertTrue("Crème Fraîche".searchMatches("creme"))
    }

    func testSearchFoldingIsCaseInsensitive() {
        XCTAssertTrue("Whole Milk".searchMatches("MILK"))
        XCTAssertFalse("Whole Milk".searchMatches("almond"))
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue("anything".searchMatches(""))
    }

    // MARK: Recipe import

    @MainActor func testRecipeImportNormalizesBareAndTrackedURLs() {
        let normalized = RecipeImportCoordinator.normalizedURLString(
            from: "example.com/chili?utm_source=newsletter&v=42#ingredients")
        XCTAssertEqual(normalized, "https://example.com/chili?v=42")
    }

    @MainActor func testRecipeImportExtractsURLFromSharedText() {
        let normalized = RecipeImportCoordinator.normalizedURLString(
            from: "Try this recipe https://example.com/pasta?fbclid=abc")
        XCTAssertEqual(normalized, "https://example.com/pasta")
    }

    @MainActor func testMultiScreenshotMergeRemovesRepeatedLines() {
        let merged = RecipeTextParser.mergeOCRPages([
            "Chocolate Cake\nIngredients\n1 cup flour",
            "Chocolate Cake\nInstructions\n1. Mix well"
        ])
        XCTAssertEqual(merged.components(separatedBy: "Chocolate Cake").count - 1, 1)
        XCTAssertTrue(merged.contains("1 cup flour"))
        XCTAssertTrue(merged.contains("1. Mix well"))
    }

    func testRecipeSourceBalancingPreventsOneProviderFromFillingThePool() {
        func recipe(_ id: String, source: String) -> OnlineRecipe {
            OnlineRecipe(id: id, title: "Recipe \(id)", category: "Dinner", area: "",
                         instructions: "Prepare ingredients.\nCook until done.",
                         imageURL: "https://example.com/\(id).jpg",
                         ingredients: ["one", "two", "three"], measures: ["", "", ""],
                         source: source)
        }
        let mealDB = (0..<8).map { recipe("meal-\($0)", source: "TheMealDB Database") }
        let harvested = (0..<3).map { recipe("publisher-\($0)", source: "Publisher") }

        let result = RecipeSourceHub.balancedRecipes(mealDB + harvested, limit: 6)

        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(result.filter { RecipeSourceHub.canonicalSourceName($0.source) == "TheMealDB" }.count, 3)
        XCTAssertEqual(result.filter { $0.source == "Publisher" }.count, 3)
    }

    func testQATicketRequiresWorkerAndFolderSync() {
        var ticket = QATicket(number: "STK-TEST-1", title: "Sync test")
        XCTAssertFalse(ticket.isFullySynced)
        ticket.syncedAt = Date()
        XCTAssertFalse(ticket.isFullySynced)
        ticket.mirroredAt = Date()
        XCTAssertEqual(ticket.isFullySynced, !QACPanelSettings.isConfigured)
    }

    func testQATicketWithScreenshotRequiresImageUpload() {
        var ticket = QATicket(number: "STK-TEST-2", title: "Screenshot sync")
        ticket.syncedAt = Date()
        ticket.mirroredAt = Date()
        ticket.screenshotFile = "shot.jpg"
        XCTAssertFalse(ticket.isFullySynced)
        ticket.shotSyncedAt = Date()
        XCTAssertEqual(ticket.isFullySynced, !QACPanelSettings.isConfigured)
    }

    func testCurrentLayoutTicketsShipDeviceVerifiableResolutions() {
        let tickets = [
            QATicket(number: "STK-89-0088", title: "Ingredients"),
            QATicket(number: "STK-89-0089", title: "Button size"),
            QATicket(number: "STK-89-0090", title: "Percentage"),
        ]

        for ticket in tickets {
            let resolution = QATicketStore.shippedResolution(for: ticket)
            XCTAssertNotNil(resolution, "\(ticket.number) must become Fixed in the corrected build")
            XCTAssertFalse(resolution?.isEmpty ?? true)
        }
    }

    @MainActor
    func testEveryAppTextOptionUsesTheSingleMonotonicTypographyScale() {
        let scales = AppTextSize.allCases.map {
            StockedType.appTextScale(for: $0.rawValue)
        }

        XCTAssertEqual(scales.count, AppTextSize.allCases.count)
        XCTAssertTrue(zip(scales, scales.dropFirst()).allSatisfy(<))
    }

    @MainActor
    func testFontSizeDoesNotChangeControlPlacementPolicy() {
        let standard = StockedLayoutMetrics(
            width: 393,
            height: 852,
            isAccessibilityText: false,
            interfaceScale: 1,
            textScale: 1
        )
        let enlarged = StockedLayoutMetrics(
            width: 393,
            height: 852,
            isAccessibilityText: true,
            interfaceScale: 1,
            textScale: 2.2
        )

        let standardPrefersVertical = standard.prefersVerticalControls
        let enlargedPrefersVertical = enlarged.prefersVerticalControls
        let standardColumnCount = standard.gridColumns(minimum: 104).count
        let enlargedColumnCount = enlarged.gridColumns(minimum: 104).count
        let standardControlHeight = standard.minimumControlHeight
        let enlargedControlHeight = enlarged.minimumControlHeight

        XCTAssertEqual(standardPrefersVertical, enlargedPrefersVertical)
        XCTAssertEqual(standardColumnCount, enlargedColumnCount)
        XCTAssertGreaterThan(enlargedControlHeight, standardControlHeight)
    }

    // MARK: Grocery de-duplication (#17)

    @MainActor func testGroceryDedupCollapsesCaseAndAccents() {
        let existing = ["Milk", "Eggs"]
        XCTAssertTrue(GroceryDedup.isDuplicate("milk", in: existing))
        XCTAssertTrue(GroceryDedup.isDuplicate("MILK", in: existing))
        XCTAssertFalse(GroceryDedup.isDuplicate("Almond Milk", in: existing))
    }

    @MainActor func testGroceryDedupHandlesBrandPrefix() {
        // "Great Value Milk" should be treated as a duplicate of "Milk" only if the policy says
        // Brand prefixes are deliberately ignored so the same underlying ingredient
        // cannot create duplicate shopping rows.
        XCTAssertTrue(GroceryDedup.isDuplicate("Great Value Milk", in: ["Milk"]))
    }

    // MARK: Expiry math (#16 / inventory)

    func testDaysUntilExpiry() {
        let cal = Calendar.current
        let inThreeDays = cal.date(byAdding: .day, value: 3, to: Date())!
        let item = TestExpiry(expirationDate: inThreeDays)
        XCTAssertEqual(item.daysUntilExpiry, 3)
        XCTAssertTrue(item.isExpiringSoon)
    }

    func testNoExpiryIsNotExpiringSoon() {
        let item = TestExpiry(expirationDate: nil)
        XCTAssertNil(item.daysUntilExpiry)
        XCTAssertFalse(item.isExpiringSoon)
    }
}

// A tiny stand-in mirroring the inventory expiry helpers, so the test doesn't need the full
// LocalInventoryItem (which carries many unrelated fields). If you prefer, delete this and test
// LocalInventoryItem directly.
private struct TestExpiry {
    var expirationDate: Date?
    var daysUntilExpiry: Int? {
        guard let exp = expirationDate else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: exp)).day
    }
    var isExpiringSoon: Bool { (daysUntilExpiry ?? 999) <= 3 }
}
