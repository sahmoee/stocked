import XCTest

@testable import Stocked

final class CookLaterPlanningTests: XCTestCase {
  func testIngredientNameRemovesLeadingAmountAndUnit() {
    XCTAssertEqual(
      CookLaterPlanningEngine.ingredientName("2 cups shredded cheddar"), "shredded cheddar")
    XCTAssertEqual(CookLaterPlanningEngine.ingredientName("1 lb chicken breast"), "chicken breast")
  }

  func testMissingIngredientsUsesBoundaryAwareFoodMatching() {
    let meal = PlannedMeal(
      dayIndex: 1,
      title: "Tacos",
      servings: 4,
      ingredients: ["1 lb ground beef", "cheddar cheese", "tortillas"],
      mealType: "Dinner"
    )
    let missing = CookLaterPlanningEngine.missingIngredients(
      for: meal,
      inventoryNames: ["Ground beef", "Cheddar chips", "Flour tortillas"]
    )
    XCTAssertEqual(missing, ["cheddar cheese"])
  }

  func testGroceryCandidatesDeduplicateAndPreserveMealSource() {
    let first = PlannedMeal(
      dayIndex: 1,
      title: "Chicken Bowls",
      servings: 4,
      ingredients: ["rice", "avocado"],
      mealType: "Dinner"
    )
    let second = PlannedMeal(
      dayIndex: 2,
      title: "Tacos",
      servings: 4,
      ingredients: ["avocados", "tortillas"],
      mealType: "Dinner"
    )
    let candidates = CookLaterPlanningEngine.groceryCandidates(
      meals: [first, second],
      inventoryNames: ["rice"],
      groceryNames: []
    )
    XCTAssertEqual(candidates.map(\.name), ["avocado", "tortillas"])
    XCTAssertEqual(candidates.first?.mealTitle, "Chicken Bowls")
  }

  func testSuggestionsOnlyFillEmptyDinnerDays() {
    let existing = PlannedMeal(
      dayIndex: 0,
      title: "Existing Dinner",
      servings: 2,
      ingredients: [],
      mealType: "Dinner"
    )
    let suggestions = CookLaterPlanningEngine.suggestedMeals(
      catalog: Array(StarterMeals.all.prefix(3)),
      meals: [existing],
      householdSize: 3
    )
    XCTAssertFalse(suggestions.contains { $0.dayIndex == 0 })
    XCTAssertTrue(suggestions.allSatisfy { $0.servings == 3 })
  }

  func testFreezerIngredientCreatesThawTaskBeforeMeal() {
    let meal = PlannedMeal(
      dayIndex: 3,
      title: "Chicken Dinner",
      servings: 4,
      ingredients: ["chicken breast", "rice"],
      mealType: "Dinner"
    )
    let chicken = LocalInventoryItem(name: "Chicken breasts", zone: "Freezer")
    let tasks = CookLaterPlanningEngine.prepTasks(meals: [meal], inventory: [chicken])
    let thaw = tasks.first { $0.id.hasPrefix("thaw-") }
    XCTAssertEqual(thaw?.dayIndex, 2)
    XCTAssertTrue(thaw?.title.localizedCaseInsensitiveContains("chicken") == true)
  }
  func testCrossCheckDetectsOverAllocatedIngredient() {
    let first = PlannedMeal(
      dayIndex: 1,
      title: "Jerk Chicken",
      servings: 4,
      ingredients: ["1 lb chicken thighs"],
      mealType: "Dinner"
    )
    let second = PlannedMeal(
      dayIndex: 3,
      title: "Chicken Tacos",
      servings: 4,
      ingredients: ["1 lb chicken thighs"],
      mealType: "Dinner"
    )
    var chicken = LocalInventoryItem(name: "Chicken thighs", zone: "Fridge")
    chicken.sizeAmount = 1
    chicken.sizeUnit = "lb"

    let checks = CookLaterCrossCheckEngine.checks(
      for: first,
      allMeals: [first, second],
      inventory: [chicken]
    )

    XCTAssertEqual(checks.first?.state, .runningLow)
    XCTAssertEqual(checks.first?.competingMeals, ["Chicken Tacos"])
  }

  func testShoppingNeedsCombineShortagesAcrossMeals() {
    let first = PlannedMeal(
      dayIndex: 1,
      title: "Jerk Chicken",
      servings: 4,
      ingredients: ["1 lb chicken thighs"],
      mealType: "Dinner"
    )
    let second = PlannedMeal(
      dayIndex: 3,
      title: "Chicken Tacos",
      servings: 4,
      ingredients: ["1 lb chicken thighs"],
      mealType: "Dinner"
    )
    var chicken = LocalInventoryItem(name: "Chicken thighs", zone: "Fridge")
    chicken.sizeAmount = 1
    chicken.sizeUnit = "lb"

    let needs = CookLaterCrossCheckEngine.shoppingNeeds(
      meals: [first, second],
      inventory: [chicken],
      existingGrocery: []
    )

    XCTAssertEqual(needs.count, 1)
    XCTAssertEqual(needs.first?.unit, "lb")
    XCTAssertEqual(try XCTUnwrap(needs.first).amount, 1, accuracy: 0.01)
    XCTAssertEqual(needs.first?.mealTitles, ["Chicken Tacos", "Jerk Chicken"])
  }

  func testSubstitutionMarksOptionAlreadyAvailable() {
    let halfAndHalf = LocalInventoryItem(name: "Half & Half", zone: "Fridge")
    let options = CookLaterCrossCheckEngine.substitutions(
      for: "heavy cream",
      inventory: [halfAndHalf]
    )

    XCTAssertTrue(options.contains { $0.substitution.title == "Half & Half" && $0.isAvailable })
  }

  func testPrepIntelligenceCreatesThawAndChopActions() {
    let meal = PlannedMeal(
      dayIndex: 2,
      title: "Jerk Chicken and Rice",
      servings: 4,
      ingredients: ["1 lb chicken thighs", "1 onion", "1 bell pepper", "2 cups rice"],
      mealType: "Dinner"
    )
    let chicken = LocalInventoryItem(name: "Chicken thighs", zone: "Freezer")

    let actions = CookLaterCrossCheckEngine.prepActions(meals: [meal], inventory: [chicken])

    XCTAssertTrue(actions.contains { $0.id.hasPrefix("thaw-") && $0.dayIndex == 1 })
    XCTAssertTrue(actions.contains { $0.id.hasPrefix("chop-") })
  }

}
