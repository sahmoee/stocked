import XCTest
@testable import Stocked

final class FoodIntelligenceTests: XCTestCase {
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
        XCTAssertGreaterThan(FoodNameMatcher.score("Great Value canned tomatoes", "tomato cans"), 0.45)
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
}
