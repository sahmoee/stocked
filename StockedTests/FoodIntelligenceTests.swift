import XCTest
@testable import Stocked

final class FoodIntelligenceTests: XCTestCase {
    @MainActor
    func testEquipmentServiceCanBeReleasedBetweenPresentations() {
        weak var released: EquipmentAvailabilityService?
        for _ in 0..<20 {
            autoreleasepool {
                let service = EquipmentAvailabilityService()
                released = service
                XCTAssertNotNil(released)
            }
            XCTAssertNil(released)
        }
    }

    func testZoneClassifierDoesNotTreatSnackNamesAsDairy() {
        XCTAssertEqual(ZoneClassifier.classify("Cheddar chips"), .pantry)
        XCTAssertEqual(ZoneClassifier.classify("Cheese crackers"), .pantry)
    }

    func testCayennePepperIsAStapleNotFreshProduce() {
        XCTAssertEqual(ZoneClassifier.classify("Cayenne pepper"), .staples)
    }

    func testPhraseMatcherUsesTokenBoundaries() {
        XCTAssertFalse(FoodNameMatcher.containsPhrase("ham", in: "graham crackers"))
        XCTAssertTrue(FoodNameMatcher.containsPhrase("ham", in: "smoked ham"))
    }

    func testMatcherRecognizesPluralAndBrandNoise() {
        XCTAssertGreaterThan(FoodNameMatcher.matches("Great Value canned tomatoes", "tomato cans").score, 0.45)
    }

    func testZoneConsensusRequiresReviewForStrongColdConflict() {
        let decision = ZoneDecisionEngine.decide(name: "Cheddar chips", aiZone: .fridge, aiConfidence: 0.9)
        XCTAssertTrue(decision.needsConfirmation)
        XCTAssertEqual(decision.zone, .pantry)
    }

    func testShelfLifePrefersPersonalHistory() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let estimate = ShelfLifeEstimator.estimate(name: "Milk", zone: .fridge, from: base,
                                                   learnedDays: 4, crowdDays: 8, aiDays: 9)
        XCTAssertEqual(estimate.date, Calendar.current.date(byAdding: .day, value: 4, to: base))
        XCTAssertEqual(estimate.evidence?.source, "Your history")
    }

    func testOpenedShelfLifeIsShorter() {
        let closed = ShelfLifeEstimator.estimate(name: "Yogurt", zone: .fridge, opened: false)
        let opened = ShelfLifeEstimator.estimate(name: "Yogurt", zone: .fridge, opened: true)
        XCTAssertLessThan(opened.evidence?.days ?? 999, closed.evidence?.days ?? 0)
    }

    func testOpenedPantryTinUsesItsOpenedClock() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        // A sealed pantry tin has no estimate; once opened it keeps five days.
        XCTAssertNil(ShelfLifeEstimator.estimate(name: "Diced tomatoes", zone: .pantry, from: base).date)
        let opened = ShelfLifeEstimator.estimate(name: "Diced tomatoes", zone: .pantry, from: base, opened: true)
        XCTAssertEqual(opened.date, Calendar.current.date(byAdding: .day, value: 5, to: base))
        XCTAssertEqual(opened.evidence?.source, "Opened shelf-life table")
        // Freezing stops the clock, so frozen items keep the sealed rule.
        let frozen = ShelfLifeEstimator.estimate(name: "Chicken broth", zone: .freezer, from: base, opened: true)
        XCTAssertNotEqual(frozen.evidence?.source, "Opened shelf-life table")
    }

    func testPackKnowledgePrefersSpecificNames() {
        XCTAssertEqual(PackKnowledge.facts(for: "Tomato paste")?.openedDays, 7)
        XCTAssertEqual(PackKnowledge.facts(for: "Cream cheese")?.openedDays, 10)
        XCTAssertEqual(PackKnowledge.facts(for: "Coconut milk")?.freezesOpen, true)
        XCTAssertNil(PackKnowledge.facts(for: "Dish soap"))
    }

    func testPackFractionConvertsUnits() throws {
        let tin = try XCTUnwrap(PackKnowledge.facts(for: "Diced tomatoes"))
        XCTAssertEqual(try XCTUnwrap(PackKnowledge.fractionUsed(amount: 7.25, unit: "oz", of: tin)), 0.5, accuracy: 0.001)
        XCTAssertEqual(PackKnowledge.fractionUsed(amount: 1, unit: "can", of: tin), 1)
        // 1 cup of broth from a 32 fl oz carton is a quarter.
        XCTAssertEqual(try XCTUnwrap(PackKnowledge.fractionUsed(amount: 1, unit: "cup", packSize: 32, packUnit: "fl oz")), 0.25, accuracy: 0.001)
        // 500 g from a 1 lb pack is the whole pack, never more.
        XCTAssertEqual(PackKnowledge.fractionUsed(amount: 500, unit: "g", packSize: 1, packUnit: "lb"), 1)
        // Counts and weights can't be compared.
        XCTAssertNil(PackKnowledge.fractionUsed(amount: 2, unit: "", packSize: 2, packUnit: "lb"))
        XCTAssertNil(PackKnowledge.fractionUsed(amount: 0, unit: "oz", of: tin))
    }
}
