// FeatureEngineTests.swift — Launch readiness 3.2: the eight pure engines behind the new
// features, tested. Every one is `nonisolated` and pure, so no host app state is needed.
//
// SplitMath is first and heaviest: it's money math, and wrong money math is the worst kind of
// wrong. MeasureParser is second: six parsers were collapsed into it, so it now carries every
// call site's expectations at once.

import XCTest
@testable import Stocked

final class FeatureEngineTests: XCTestCase {

    // MARK: - SplitMath (shared costs)

    private func expense(_ label: String, _ amount: Double, paidBy: String,
                         sharedWith: [String] = []) -> SharedExpense {
        SharedExpense(label: label, amount: amount, paidBy: paidBy, sharedWith: sharedWith)
    }

    func testBalancesEvenSplit() {
        let people = ["A", "B"]
        let net = SplitMath.balances([expense("Groceries", 100, paidBy: "A")], people: people)
        // A paid 100, owes 50 → +50. B owes 50.
        XCTAssertEqual(net["A"] ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(net["B"] ?? 0, -50, accuracy: 0.001)
    }

    func testBalancesAlwaysSumToZero() {
        let people = ["A", "B", "C"]
        let expenses = [
            expense("One", 90, paidBy: "A"),
            expense("Two", 45.55, paidBy: "B", sharedWith: ["B", "C"]),
            expense("Three", 12.99, paidBy: "C", sharedWith: ["A"]),
        ]
        let total = SplitMath.balances(expenses, people: people).values.reduce(0, +)
        XCTAssertEqual(total, 0, accuracy: 0.001, "money must never appear or vanish in the split")
    }

    func testSettlementsClearAllDebts() {
        let people = ["A", "B", "C"]
        let expenses = [
            expense("Costco", 120, paidBy: "A"),
            expense("H-E-B", 60, paidBy: "B"),
        ]
        let transfers = SplitMath.settlements(expenses, people: people)
        // Replay the transfers over the balances; everyone must land on zero.
        var net = SplitMath.balances(expenses, people: people)
        for t in transfers {
            net[t.from, default: 0] += t.amount
            net[t.to, default: 0] -= t.amount
        }
        for (person, balance) in net {
            XCTAssertEqual(balance, 0, accuracy: 0.01, "\(person) not settled")
        }
        XCTAssertLessThanOrEqual(transfers.count, people.count - 1,
                                 "greedy settle-up must not exceed n-1 transfers")
    }

    func testSettleUpEmptyLedgerProducesNoTransfers() {
        XCTAssertTrue(SplitMath.settlements([], people: ["A", "B"]).isEmpty)
    }

    func testTargetedSplitOnlyChargesParticipants() {
        let people = ["A", "B", "C"]
        let net = SplitMath.balances([expense("Beer", 30, paidBy: "A", sharedWith: ["A", "B"])],
                                     people: people)
        XCTAssertEqual(net["C"] ?? -1, 0, accuracy: 0.001, "C wasn't part of the split")
        XCTAssertEqual(net["A"] ?? 0, 15, accuracy: 0.001)
        XCTAssertEqual(net["B"] ?? 0, -15, accuracy: 0.001)
    }

    // MARK: - MeasureParser (the unified parser)

    func testParsesPlainAmountUnitName() {
        let m = MeasureParser.parse("2 cups flour")
        XCTAssertEqual(m.amount ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(m.unit, "cup")
        XCTAssertEqual(m.name, "flour")
    }

    func testParsesMixedNumber() {
        // The old ParsedQuantity regex could NOT read this — the headline fix.
        let m = MeasureParser.parse("1 1/2 cups sugar")
        XCTAssertEqual(m.amount ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(m.unit, "cup")
    }

    func testParsesUnicodeFractionsIncludingEighths() {
        XCTAssertEqual(MeasureParser.parse("½ tsp salt").amount ?? 0, 0.5, accuracy: 0.001)
        // ⅜ was previously known to only ONE of the six parsers.
        XCTAssertEqual(MeasureParser.parse("⅜ cup milk").amount ?? 0, 0.375, accuracy: 0.001)
        XCTAssertEqual(MeasureParser.parse("1½ cups broth").amount ?? 0, 1.5, accuracy: 0.001)
    }

    func testParsesTwoTokenUnit() {
        let m = MeasureParser.parse("4 fl oz cream")
        XCTAssertEqual(m.unit, "fl oz")
        XCTAssertEqual(m.name, "cream")
    }

    func testRangeTakesLowerBound() {
        XCTAssertEqual(MeasureParser.parse("2-3 cloves garlic").amount ?? 0, 2, accuracy: 0.001)
    }

    func testEuropeanDecimalComma() {
        XCTAssertEqual(MeasureParser.parse("1,5 kg potatoes").amount ?? 0, 1.5, accuracy: 0.001)
    }

    func testNoAmountYieldsNilNotZero() {
        let m = MeasureParser.parse("salt to taste")
        XCTAssertNil(m.amount)
        XCTAssertEqual(m.unit, "")
    }

    func testCupIsLegalUSCupEverywhere() {
        // The 240-vs-236.588 disagreement is what this guards against.
        XCTAssertEqual(MeasureParser.baseValue(amount: 1, unit: "cup") ?? 0, 236.588, accuracy: 0.01)
    }

    func testConvertWithinFamily() {
        XCTAssertEqual(MeasureParser.convert(1000, from: "g", to: "kg") ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(MeasureParser.convert(3, from: "tsp", to: "tbsp") ?? 0, 1, accuracy: 0.01)
        XCTAssertNil(MeasureParser.convert(1, from: "cup", to: "g"),
                     "cross-family needs a density — must refuse, not guess")
    }

    // MARK: - ReadinessCalculator (emergency pantry)

    private func item(_ name: String, qty: Int = 1, zone: StorageCategory = .pantry,
                      sizeAmount: Double? = nil, sizeUnit: String? = nil) -> LocalInventoryItem {
        var i = LocalInventoryItem(name: name)
        i.quantity = qty
        i.storageCategory = zone
        i.sizeAmount = sizeAmount
        i.sizeUnit = sizeUnit
        return i
    }

    func testEmptyPantryIsZeroDays() {
        let r = ReadinessCalculator.assess(items: [], people: 2)
        XCTAssertEqual(r.days, 0, accuracy: 0.001)
    }

    func testMorePeopleMeansFewerDays() {
        let items = [item("rice", qty: 4), item("water", qty: 12, sizeAmount: 1, sizeUnit: "l")]
        let solo = ReadinessCalculator.assess(items: items, people: 1)
        let family = ReadinessCalculator.assess(items: items, people: 4)
        XCTAssertGreaterThan(solo.days, family.days)
    }

    func testFridgeFoodDoesNotCountAsShelfStable() {
        let r = ReadinessCalculator.assess(items: [item("milk", zone: .fridge)], people: 1)
        XCTAssertEqual(r.totalCalories, 0, accuracy: 0.001,
                       "readiness counts only pantry/staples — the fridge dies with the power")
    }

    func testWaterVolumeParsing() {
        let items = [item("water", qty: 2, sizeAmount: 1, sizeUnit: "gal")]
        let liters = ReadinessCalculator.waterLiters(in: items)
        XCTAssertEqual(liters, 2 * 3.785, accuracy: 0.01)
    }

    func testMissingStaplesFlagsCanOpener() {
        let missing = ReadinessCalculator.missing(from: [item("rice"), item("water")])
        XCTAssertTrue(missing.contains { $0.lowercased().contains("can opener") },
                      "the one everyone forgets must be flagged")
    }

    // MARK: - TimelinePlanner (cook together)

    func testMinutesExtraction() {
        XCTAssertEqual(TimelinePlanner.minutes(in: "Bake for 25 minutes"), 25)
        XCTAssertEqual(TimelinePlanner.minutes(in: "Simmer 1 hour"), 60)
        XCTAssertEqual(TimelinePlanner.minutes(in: "Rest 1 hour 10 minutes"), 70)
        XCTAssertEqual(TimelinePlanner.minutes(in: "Chop the onions"), 5, "no time → 5 min active default")
    }

    func testStepsScheduleBackwardFromServe() {
        let recipe = TimelineRecipe(title: "Roast", steps: ["Season 5 minutes", "Roast 60 minutes"])
        let plan = TimelinePlanner.plan([recipe])
        // First step must start 65 minutes before serve; last ends at serve.
        XCTAssertEqual(plan.first?.startOffset, 65)
        XCTAssertEqual(TimelinePlanner.totalMinutes([recipe]), 65)
    }

    func testTwoRecipesInterleaveByStartTime() {
        let long = TimelineRecipe(title: "Turkey", steps: ["Roast 120 minutes"])
        let short = TimelineRecipe(title: "Beans", steps: ["Boil 10 minutes"])
        let plan = TimelinePlanner.plan([long, short])
        XCTAssertEqual(plan.first?.recipe, "Turkey", "the longest lead time must come first")
        XCTAssertEqual(plan.last?.recipe, "Beans")
    }

    // MARK: - EventMath (dinner parties)

    func testScaleRoundsUpToWholeMultiples() {
        let dish = EventDish(title: "Lasagna", baseServings: 4)
        XCTAssertEqual(EventMath.scale(dish: dish, headcount: 9), 3,
                       "9 people need 3 batches of a serves-4 dish — you can't cook 2.25 lasagnas")
    }

    func testAllergyConflictDetected() {
        let dish = EventDish(title: "Pad Thai", baseServings: 4, ingredients: ["rice noodles", "peanuts", "egg"])
        let guest = EventGuest(name: "Sam", allergies: ["peanut"])
        let conflicts = EventMath.conflicts(dishes: [dish], guests: [guest])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.guest, "Sam")
    }

    func testVeganDietConflictDetected() {
        let dish = EventDish(title: "Alfredo", baseServings: 4, ingredients: ["pasta", "heavy cream", "parmesan"])
        let guest = EventGuest(name: "Riley", diet: "Vegan")
        XCTAssertFalse(EventMath.conflicts(dishes: [dish], guests: [guest]).isEmpty)
    }

    func testShoppingListMultipliesSharedIngredients() {
        let a = EventDish(title: "A", baseServings: 4, ingredients: ["onion"])
        let b = EventDish(title: "B", baseServings: 4, ingredients: ["onion"])
        let list = EventMath.shoppingList(dishes: [a, b], headcount: 4)
        XCTAssertEqual(list.count, 1, "same ingredient across dishes consolidates to one line")
        XCTAssertTrue(list[0].contains("×2"), "…with the multiplier visible")
    }

    // MARK: - StoreRouting (store layout learning)

    func testLearnedOrderSortsList() {
        var layout = StoreLayout(store: "H-E-B")
        layout.learn(order: ["bananas", "milk", "ice cream"])   // produce → dairy → frozen
        let sorted = StoreRouting.sort(["ice cream", "bananas", "milk"], layout: layout)
        XCTAssertEqual(sorted, ["bananas", "milk", "ice cream"])
    }

    func testUnknownItemsSinkToEndInStableOrder() {
        var layout = StoreLayout(store: "H-E-B")
        layout.learn(order: ["bananas", "milk"])
        let sorted = StoreRouting.sort(["mystery1", "milk", "mystery2", "bananas"], layout: layout)
        XCTAssertEqual(sorted, ["bananas", "milk", "mystery1", "mystery2"])
    }

    func testConfidenceGrowsWithTrips() {
        var layout = StoreLayout(store: "H-E-B")
        let items = ["bananas", "milk"]
        XCTAssertEqual(StoreRouting.confidence(items, layout: layout), 0, accuracy: 0.001)
        layout.learn(order: items)
        let one = StoreRouting.confidence(items, layout: layout)
        layout.learn(order: items)
        layout.learn(order: items)
        XCTAssertGreaterThan(StoreRouting.confidence(items, layout: layout), one)
    }

    // MARK: - HarvestMath (garden)

    func testTotalsGroupCaseInsensitively() {
        let entries = [
            HarvestEntry(crop: "Tomato", amount: 2),
            HarvestEntry(crop: "tomato", amount: 3),
        ]
        let totals = HarvestMath.totals(entries)
        XCTAssertEqual(totals.count, 1)
        XCTAssertEqual(totals[0].amount, 5, accuracy: 0.001)
    }

    func testFreshDaysShorterForGreensThanRoots() {
        XCTAssertLessThan(HarvestMath.freshDays(for: "basil"),
                          HarvestMath.freshDays(for: "potato"),
                          "fresh-picked greens turn far faster than storage crops")
    }

    // MARK: - TakeoutMath (eating out)

    func testSummaryTotalsAndAverage() {
        let entries = [
            TakeoutEntry(place: "Thai", cost: 30),
            TakeoutEntry(place: "Pizza", cost: 20),
        ]
        let s = TakeoutMath.summary(entries)
        XCTAssertEqual(s.total, 50, accuracy: 0.001)
        XCTAssertEqual(s.perMeal, 25, accuracy: 0.001)
    }

    func testFavoritesRankByRating() {
        var good = TakeoutEntry(place: "Great Thai", cost: 30); good.rating = 5
        var ok = TakeoutEntry(place: "Meh Pizza", cost: 20); ok.rating = 2
        let favs = TakeoutMath.favorites([good, ok])
        XCTAssertEqual(favs.first?.place, "Great Thai")
    }

    func testBusiestWeekdayNeedsAtLeastTwoVisits() {
        XCTAssertNil(TakeoutMath.busiestWeekday([TakeoutEntry(place: "Once", cost: 10)]),
                     "one data point is noise, not a habit")
    }

    // MARK: - Upgrade-migration decode safety (build-65 crash regression)
    //
    // The build-65 launch crash was an infinite recursion set off when the feature stores loaded
    // OLD rows (saved before household-sync fields existed) with updatedAt == 0, which triggered a
    // stamping pass that re-entered its own didSet. These tests lock the trigger condition: a row
    // saved by the pre-sync build must decode with updatedAt == 0 (proving the fields are optional
    // in practice) — that's the exact input that must be handled without crashing.

    /// Strip the sync fields from an encoded row to mimic pre-sync persisted JSON, then decode.
    private func migrated<T: Codable>(_ value: T, as type: T.Type) throws -> T {
        var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        dict.removeValue(forKey: "updatedAt")
        dict.removeValue(forKey: "lastWriterID")
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testLeftoverMigratesFromPreSyncData() throws {
        let old = LeftoverEntry(title: "Chili", portions: 3, cookedAt: Date(),
                                storage: "Fridge", expiresAt: Date())
        let m = try migrated(old, as: LeftoverEntry.self)
        XCTAssertEqual(m.updatedAt, 0, "pre-sync rows must decode with updatedAt 0 — the crash trigger, handled")
        XCTAssertEqual(m.lastWriterID, "")
        XCTAssertEqual(m.title, "Chili")
        XCTAssertEqual(m.portions, 3)
    }

    func testSharedExpenseMigratesFromPreSyncData() throws {
        let old = SharedExpense(label: "Costco", amount: 80, paidBy: "A")
        let m = try migrated(old, as: SharedExpense.self)
        XCTAssertEqual(m.updatedAt, 0)
        XCTAssertEqual(m.amount, 80, accuracy: 0.001, "money survives the migration intact")
        XCTAssertEqual(m.paidBy, "A")
    }

    /// `stamped` must always move updatedAt off zero — that non-zero value is what lets the store's
    /// re-entrancy guard treat the follow-up didSet as a no-op instead of recursing.
    func testStampedAlwaysSetsNonZeroTimestamp() {
        let a = LeftoverEntry(title: "X", portions: 1, cookedAt: Date(),
                              storage: "Fridge", expiresAt: Date())
        XCTAssertEqual(a.updatedAt, 0)
        let s = FeatureSync.stamped(a)
        XCTAssertGreaterThan(s.updatedAt, 0)
        XCTAssertEqual(s.id, a.id, "stamping never changes identity")
    }
}
