import XCTest
@testable import Stocked

/// "Buy the missing amount" must carry the reservation engine's shortfall onto the list.
@MainActor
final class ShortageRepairTests: XCTestCase {
    func testShortageRepairPreservesAmountAndUnit() async throws {
        let store = GuestDataStore()
        let deadline = Date().addingTimeInterval(10)
        while !store.hasCompletedInitialHydration && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(store.hasCompletedInitialHydration, "Fixture setup requires completed local hydration")
        guard store.hasCompletedInitialHydration else { return }
        let previous = store.groceryItems
        defer {
            store.isApplyingHouseholdRemote = true
            store.groceryItems = previous
            store.flushPendingSaves()
            store.isApplyingHouseholdRemote = false
        }
        store.isApplyingHouseholdRemote = true
        store.groceryItems = [LocalGroceryItem(quantity: 1, name: "Eggs")]
        store.isApplyingHouseholdRemote = false

        store.addShortageToGrocery(conflict("chicken thighs", missing: 500, unit: "g"))
        store.addShortageToGrocery(conflict("eggs", missing: 3, unit: ""))

        let chicken = try XCTUnwrap(store.groceryItems.first { $0.name == "chicken thighs" })
        XCTAssertEqual(chicken.sizeText, "500 g", "Measured shortfall must reach the grocery row")
        XCTAssertEqual(chicken.recipeSource, "Tacos")
        let eggs = store.groceryItems.filter { GroceryDedup.isDuplicate("eggs", in: [$0.name]) }
        XCTAssertEqual(eggs.count, 1, "An existing matching row is updated, not duplicated")
        XCTAssertEqual(eggs.first?.quantity, 3, "Counted shortfall raises an insufficient row")
    }

    private func conflict(_ ingredient: String, missing: Double, unit: String) -> MealConflict {
        MealConflict(id: UUID().uuidString, mealID: UUID(), mealTitle: "Tacos", mealType: "Dinner",
                     dayIndex: 1, date: Date(), ingredient: ingredient, rawIngredient: ingredient,
                     missingAmount: missing, unit: unit, reason: .notInStock)
    }
}
