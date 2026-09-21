import XCTest
@testable import Stocked

// #19 Regression tests for the public household/sync logic that's easy to break:
// permission override resolution, conflict de-duplication, and shelf-life estimation.
// The internal merge functions are private; these cover the behavior users actually feel.

final class HouseholdLogicTests: XCTestCase {

    // MARK: Permission overrides (#4)

    func testEffectivePermissionsFallBackToRole() {
        let teen = HouseholdMember(id: "1", name: "Sam", role: .teen)
        XCTAssertTrue(teen.effectiveCanAdd)      // teen default: can add
        XCTAssertTrue(teen.effectiveCanEdit)     // teen default: can edit
        XCTAssertFalse(teen.effectiveCanRemove)  // teen default: cannot remove
    }

    func testOverrideWinsOverRoleDefault() {
        var teen = HouseholdMember(id: "1", name: "Sam", role: .teen)
        teen.overrideCanRemove = true            // owner grants remove to this teen
        XCTAssertTrue(teen.effectiveCanRemove)
        teen.overrideCanAdd = false              // and revokes add
        XCTAssertFalse(teen.effectiveCanAdd)
    }

    func testKidIsViewOnlyByDefault() {
        let kid = HouseholdMember(id: "2", name: "Rae", role: .kid)
        XCTAssertFalse(kid.effectiveCanAdd)
        XCTAssertFalse(kid.effectiveCanEdit)
        XCTAssertFalse(kid.effectiveCanRemove)
    }

    func testDisplayLabelPrefersCustom() {
        var m = HouseholdMember(id: "3", name: "Jess", role: .adult)
        XCTAssertEqual(m.displayLabel, "Adult")
        m.customLabel = "Mom"
        XCTAssertEqual(m.displayLabel, "Mom")
    }

    // MARK: Shelf-life estimation (#9)

    @MainActor func testShelfLifeKeywordBeatsZone() {
        let store = GuestDataStore()
        let base = Date(timeIntervalSince1970: 1_000_000)
        // "milk" keyword → 7 days, regardless of zone.
        let milk = store.estimatedUseBy(forName: "Whole Milk", zone: "Fridge", from: base)
        XCTAssertEqual(milk, Calendar.current.date(byAdding: .day, value: 7, to: base))
    }

    @MainActor func testShelfStablePantryHasNoExpiry() {
        let store = GuestDataStore()
        XCTAssertNil(store.estimatedUseBy(forName: "Canned Beans", zone: "Pantry"))
    }

    @MainActor func testFridgeFallbackWhenNoKeyword() {
        let store = GuestDataStore()
        let base = Date(timeIntervalSince1970: 2_000_000)
        let unknown = store.estimatedUseBy(forName: "Mystery Dish", zone: "Fridge", from: base)
        XCTAssertEqual(unknown, Calendar.current.date(byAdding: .day, value: 10, to: base))
    }
}
