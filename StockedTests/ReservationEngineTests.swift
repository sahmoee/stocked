import XCTest

@testable import Stocked

/// RL-003…RL-006 — deterministic coverage of the pure reservation engine.
/// Every test injects a fixed `now`, so meal dates and expirations are stable.
final class ReservationEngineTests: XCTestCase {

  private let now = Date(timeIntervalSince1970: 1_760_000_000)  // fixed reference

  private func poundsItem(_ name: String, pounds: Double, quantity: Int = 1,
                          expiresInDays: Int? = nil) -> LocalInventoryItem {
    var item = LocalInventoryItem(name: name, zone: "Fridge")
    item.quantity = quantity
    item.sizeAmount = pounds
    item.sizeUnit = "lb"
    if let days = expiresInDays {
      item.expirationDate = now.addingTimeInterval(Double(days) * 86_400)
    }
    return item
  }

  private func meal(_ title: String, day: Int, ingredients: [String],
                    type: String = "Dinner") -> PlannedMeal {
    PlannedMeal(dayIndex: day, title: title, servings: 4,
                ingredients: ingredients, mealType: type)
  }

  // MARK: RL-003 — Total / Reserved / Available

  func testBreakdownTracksTotalReservedAvailable() {
    let chicken = poundsItem("Chicken thighs", pounds: 2)
    let dinner = meal("Jerk Chicken", day: 2, ingredients: ["1 lb chicken thighs"])

    let snap = ReservationEngine.compute(meals: [dinner], inventory: [chicken], now: now)
    let breakdown = snap.byItemID[chicken.id]

    XCTAssertNotNil(breakdown)
    XCTAssertEqual(breakdown?.totalOwned ?? 0, 2, accuracy: 0.01)
    XCTAssertEqual(breakdown?.reserved ?? 0, 1, accuracy: 0.01)
    XCTAssertEqual(breakdown?.available ?? 0, 1, accuracy: 0.01)
    XCTAssertEqual(breakdown?.unit, "lb")
    // Every reservation is labeled with its linked meal and day.
    XCTAssertEqual(breakdown?.claims.first?.mealTitle, "Jerk Chicken")
    XCTAssertEqual(breakdown?.claims.first?.dayIndex, 2)
    XCTAssertEqual(breakdown?.claims.first?.amount ?? 0, 1, accuracy: 0.01)
  }

  func testAvailableIsNeverNegative() {
    let chicken = poundsItem("Chicken thighs", pounds: 1)
    let dinner = meal("Chicken Feast", day: 1, ingredients: ["3 lb chicken thighs"])

    let snap = ReservationEngine.compute(meals: [dinner], inventory: [chicken], now: now)
    let breakdown = snap.byItemID[chicken.id]

    // The deficit surfaces as a conflict, not a negative Available.
    XCTAssertEqual(breakdown?.available ?? -1, 0, accuracy: 0.01)
    XCTAssertEqual(snap.conflicts.count, 1)
    XCTAssertEqual(snap.conflicts.first?.missingAmount ?? 0, 2, accuracy: 0.01)
    XCTAssertEqual(snap.conflicts.first?.unit, "lb")
  }

  func testCookedBuildingAndServedMealsHoldNoReservations() {
    let chicken = poundsItem("Chicken thighs", pounds: 2)
    var cooked = meal("Done Dinner", day: 0, ingredients: ["1 lb chicken thighs"])
    cooked.isCooked = true
    var building = meal("Draft", day: 1, ingredients: ["1 lb chicken thighs"])
    building.isBuilding = true
    var served = meal("Served", day: 1, ingredients: ["1 lb chicken thighs"])
    served.cookAheadStatus = .served

    let snap = ReservationEngine.compute(
      meals: [cooked, building, served], inventory: [chicken], now: now)

    XCTAssertTrue(snap.breakdowns.isEmpty)
    XCTAssertTrue(snap.conflicts.isEmpty)
  }

  // MARK: RL-005 — chronological conflicts

  func testOverAllocationFlagsTheLaterMeal() {
    let chicken = poundsItem("Chicken thighs", pounds: 1)
    let early = meal("Jerk Chicken", day: 1, ingredients: ["1 lb chicken thighs"])
    let late = meal("Chicken Tacos", day: 3, ingredients: ["1 lb chicken thighs"])

    // Input order deliberately reversed — chronology must win.
    let snap = ReservationEngine.compute(meals: [late, early], inventory: [chicken], now: now)

    XCTAssertEqual(snap.conflicts.count, 1)
    XCTAssertEqual(snap.conflicts.first?.mealTitle, "Chicken Tacos")
    XCTAssertEqual(snap.conflicts.first?.reason, .overAllocated)
    // The earlier meal keeps its claim untouched.
    let claims = snap.byItemID[chicken.id]?.claims ?? []
    XCTAssertEqual(claims.map(\.mealTitle), ["Jerk Chicken"])
  }

  func testConflictsOrderedEarliestAndMostUrgentFirst() {
    let lateConflict = meal("Later Meal", day: 5, ingredients: ["1 lb salmon"])
    let earlyConflict = meal("Sooner Meal", day: 2, ingredients: ["1 lb salmon"])

    let snap = ReservationEngine.compute(
      meals: [lateConflict, earlyConflict], inventory: [], now: now)

    XCTAssertEqual(snap.conflicts.map(\.mealTitle), ["Sooner Meal", "Later Meal"])
    XCTAssertEqual(snap.shortages.first?.firstAffectedMeal, "Sooner Meal")
    XCTAssertEqual(snap.shortages.first?.earliestDayIndex, 2)
  }

  func testExpirationBeforeMealDateCreatesShortage() {
    let chicken = poundsItem("Chicken thighs", pounds: 1, expiresInDays: 1)
    let soon = meal("Tonight", day: 0, ingredients: ["1 lb chicken thighs"])
    let far = meal("Next Week", day: 5, ingredients: ["1 lb chicken thighs"])

    // Alone, the far meal can't use chicken that dies on day 1.
    let farOnly = ReservationEngine.compute(meals: [far], inventory: [chicken], now: now)
    XCTAssertEqual(farOnly.conflicts.first?.reason, .expiresBeforeMeal)

    // The soon meal can — expiry is evaluated against each meal's own date.
    let soonOnly = ReservationEngine.compute(meals: [soon], inventory: [chicken], now: now)
    XCTAssertTrue(soonOnly.conflicts.isEmpty)
  }

  func testUnquantifiedInventoryReservesWithoutInventingConflicts() {
    // Item with no structured size: we know it exists, not how much.
    let beef = LocalInventoryItem(name: "Ground beef", zone: "Fridge")
    let dinner = meal("Tacos", day: 1, ingredients: ["1 lb ground beef"])

    let snap = ReservationEngine.compute(meals: [dinner], inventory: [beef], now: now)

    // No honest basis for a numeric shortage — but the item IS spoken for.
    XCTAssertTrue(snap.conflicts.isEmpty)
    let breakdown = snap.byItemID[beef.id]
    XCTAssertEqual(breakdown?.claims.count, 1)
    XCTAssertEqual(breakdown?.quantified, false)
  }

  // MARK: RL-004 — Cook Anyway consumption

  func testPendingConsumptionReducesProjectedAvailability() {
    let chicken = poundsItem("Chicken thighs", pounds: 1)
    let dinner = meal("Planned Dinner", day: 2, ingredients: ["1 lb chicken thighs"])
    let cookAnyway = ReservationPendingConsumption(
      ingredient: "chicken thighs", amount: 1, unit: "lb")

    let before = ReservationEngine.compute(meals: [dinner], inventory: [chicken], now: now)
    XCTAssertTrue(before.conflicts.isEmpty)

    let after = ReservationEngine.compute(
      meals: [dinner], inventory: [chicken],
      pendingConsumption: [cookAnyway], now: now)
    XCTAssertEqual(after.conflicts.count, 1)
    XCTAssertEqual(after.conflicts.first?.reason, .overAllocated)
  }

  func testUsesReservedMatchesLooseIngredientNames() {
    let chicken = poundsItem("Chicken thighs", pounds: 2)
    let dinner = meal("Jerk Chicken", day: 2, ingredients: ["1 lb chicken thighs"])
    let snap = ReservationEngine.compute(meals: [dinner], inventory: [chicken], now: now)

    // "chicken thighs" reserved ⇒ a recipe asking for plain "chicken" collides,
    // and unrelated ingredients don't.
    let hits = ReservationEngine.usesReserved(
      ingredientNames: ["chicken", "rice"], reservedNames: snap.reservedNames)
    XCTAssertEqual(hits, ["chicken"])
  }

  // MARK: RL-006 — idempotent recalculation

  func testRecomputationIsPureAndIdempotent() {
    let chicken = poundsItem("Chicken thighs", pounds: 2, expiresInDays: 6)
    let meals = [
      meal("Jerk Chicken", day: 1, ingredients: ["1 lb chicken thighs", "2 cups rice"]),
      meal("Chicken Tacos", day: 3, ingredients: ["1.5 lb chicken thighs"]),
    ]

    let first = ReservationEngine.compute(meals: meals, inventory: [chicken], now: now)
    let second = ReservationEngine.compute(meals: meals, inventory: [chicken], now: now)

    // Same inputs ⇒ byte-for-byte the same derived picture: no accumulation,
    // no duplicated claims or warnings, nothing physically deducted.
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.byItemID[chicken.id]?.claims.count, 2)
  }
}
