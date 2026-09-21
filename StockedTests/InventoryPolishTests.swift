import XCTest
@testable import Stocked

final class InventoryPolishTests: XCTestCase {
    func testItemNamesTrimLineBreaksAndWhitespace() {
        XCTAssertEqual(InventoryFormPolicy.normalizedName(" \n\t Milk \r\n"), "Milk")
        XCTAssertEqual(InventoryFormPolicy.normalizedName(" \n\t "), "")
        XCTAssertEqual(InventoryFormPolicy.normalizedName("Crème fraîche"), "Crème fraîche")
    }

    func testStorageSuggestionsCannotOverrideExplicitChoice() {
        XCTAssertEqual(InventoryFormPolicy.storageSelection(current: "Freezer", suggested: "Fridge", manuallySelected: true), "Freezer")
        XCTAssertEqual(InventoryFormPolicy.storageSelection(current: "Freezer", suggested: "Fridge", manuallySelected: false), "Fridge")
    }

    func testOpeningEmptyInventoryEditorDoesNotRestockIt() {
        XCTAssertEqual(InventoryFormPolicy.editableQuantity(0), 0)
        XCTAssertEqual(InventoryFormPolicy.editableQuantity(-3), 0)
        XCTAssertEqual(InventoryFormPolicy.editableQuantity(8), 8)
        XCTAssertEqual(InventoryFormPolicy.editableFillLevel(0), 0)
    }

    func testFillDraftRejectsNonFiniteAndOutOfRangeValues() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(InventoryFormPolicy.editableFillLevel(invalid), 0)
        }
        XCTAssertEqual(InventoryFormPolicy.editableFillLevel(-0.2), 0)
        XCTAssertEqual(InventoryFormPolicy.editableFillLevel(1.5), 1)
        XCTAssertEqual(InventoryFormPolicy.editableFillLevel(0.65), 0.65)
    }

    func testUntouchedDraftPreservesNewerHouseholdField() {
        XCTAssertEqual(InventoryFormPolicy.mergeDraft(live: 8, initial: 2, draft: 2), 8)
        XCTAssertEqual(InventoryFormPolicy.mergeDraft(live: 8, initial: 2, draft: 3), 3)
        XCTAssertEqual(InventoryFormPolicy.mergeDraft(live: "Freezer", initial: "Fridge", draft: "Fridge"), "Freezer")
        XCTAssertEqual(InventoryFormPolicy.mergeDraft(live: Optional("new"), initial: nil, draft: nil), "new")
    }

    func testLeftoverReminderUsesSuppliedCookedDate() {
        let cookedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fridge = LeftoverEntry.defaultExpiry(from: cookedAt, storage: "Fridge")
        let freezer = LeftoverEntry.defaultExpiry(from: cookedAt, storage: "Freezer")
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: cookedAt, to: fridge).day, 4)
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: cookedAt, to: freezer).day, 90)
        XCTAssertLessThan(fridge, Date(), "A historical cooked date must not receive a new clock starting today")
    }
}
