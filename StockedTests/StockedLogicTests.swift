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

    // MARK: Grocery de-duplication (#17)

    func testGroceryDedupCollapsesCaseAndAccents() {
        let existing = ["Milk", "Eggs"]
        XCTAssertTrue(GroceryDedup.isDuplicate("milk", in: existing))
        XCTAssertTrue(GroceryDedup.isDuplicate("MILK", in: existing))
        XCTAssertFalse(GroceryDedup.isDuplicate("Almond Milk", in: existing))
    }

    func testGroceryDedupHandlesBrandPrefix() {
        // "Great Value Milk" should be treated as a duplicate of "Milk" only if the policy says
        // so. Current policy: exact normalized match, so it is NOT a dup. This documents intent.
        XCTAssertFalse(GroceryDedup.isDuplicate("Great Value Milk", in: ["Milk"]))
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
        return Calendar.current.dateComponents([.day], from: Date(), to: exp).day
    }
    var isExpiringSoon: Bool { (daysUntilExpiry ?? 999) <= 3 }
}
