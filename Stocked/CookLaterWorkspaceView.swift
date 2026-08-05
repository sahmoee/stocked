// CookLaterWorkspaceView.swift
// One planning workspace for the next seven days. Inventory, Recipes, and Grocery
// open this same surface with context instead of creating parallel planning flows.

import SwiftUI

// MARK: - Context passed from Inventory / Recipes / Grocery

nonisolated enum CookLaterEntrySource: String, Sendable, Equatable {
  case cook
  case inventory
  case recipe
  case grocery
  case notification
}

nonisolated struct CookLaterContext: Identifiable, Sendable, Equatable {
  let id: UUID
  let source: CookLaterEntrySource
  var title: String
  var ingredients: [String]
  var detail: String
  var suggestedDay: Int
  var mealType: String
  var servings: Int
  var imageURL: String?
  var focusMealTitle: String?

  nonisolated init(
    id: UUID = UUID(),
    source: CookLaterEntrySource,
    title: String = "",
    ingredients: [String] = [],
    detail: String = "",
    suggestedDay: Int = 0,
    mealType: String = "Dinner",
    servings: Int = 2,
    imageURL: String? = nil,
    focusMealTitle: String? = nil
  ) {
    self.id = id
    self.source = source
    self.title = title
    self.ingredients = ingredients
    self.detail = detail
    self.suggestedDay = min(max(0, suggestedDay), 6)
    self.mealType = mealType
    self.servings = max(1, servings)
    self.imageURL = imageURL
    self.focusMealTitle = focusMealTitle
  }

  nonisolated static func direct(day: Int = 0, source: CookLaterEntrySource = .cook)
    -> CookLaterContext
  {
    CookLaterContext(source: source, suggestedDay: day)
  }

  nonisolated static func inventory(name: String, day: Int = 0, servings: Int = 2)
    -> CookLaterContext
  {
    CookLaterContext(
      source: .inventory,
      title: name,
      ingredients: name.isEmpty ? [] : [name],
      detail: name.isEmpty
        ? "Choose a meal for this day." : "Build a future meal around an item you already have.",
      suggestedDay: day,
      servings: servings
    )
  }

  nonisolated static func recipe(
    title: String,
    ingredients: [String],
    servings: Int,
    imageURL: String? = nil,
    suggestedDay: Int = 1
  ) -> CookLaterContext {
    CookLaterContext(
      source: .recipe,
      title: title,
      ingredients: ingredients,
      detail: "Choose when this recipe belongs in your week.",
      suggestedDay: suggestedDay,
      servings: servings,
      imageURL: imageURL
    )
  }

  nonisolated static func grocery(name: String, recipeSource: String) -> CookLaterContext {
    CookLaterContext(
      source: .grocery,
      title: recipeSource.isEmpty ? name : recipeSource,
      ingredients: recipeSource.isEmpty ? [name] : [],
      detail: recipeSource.isEmpty
        ? "Plan a meal that explains why this item belongs on the list."
        : "This grocery item was added for \(recipeSource).",
      suggestedDay: 0,
      focusMealTitle: recipeSource.isEmpty ? nil : recipeSource
    )
  }
}

// MARK: - Pure planning helpers

nonisolated struct CookLaterPrepTask: Identifiable, Sendable, Equatable {
  let id: String
  let title: String
  let subtitle: String
  let mealID: UUID
  let dayIndex: Int
}

nonisolated struct CookLaterGroceryCandidate: Identifiable, Sendable, Equatable {
  let id: String
  let name: String
  let mealTitle: String
}

nonisolated struct CookLaterSuggestedMeal: Identifiable, Sendable, Equatable {
  let id: UUID
  let dayIndex: Int
  let title: String
  let ingredients: [String]
  let mealType: String
  let servings: Int
}

nonisolated enum CookLaterPlanningEngine {
  static let mealTypes = RecipeTaxonomy.categories.filter { ["Breakfast", "Lunch", "Dinner", "Snack"].contains($0) }

  static func dayLabel(_ index: Int, short: Bool = false) -> String {
    guard (0..<7).contains(index) else { return "Later" }
    if index == 0 { return "Today" }
    if index == 1 { return short ? "Tmrw" : "Tomorrow" }
    let calendar = Calendar.current
    let date = calendar.date(byAdding: .day, value: index, to: Date()) ?? Date()
    let formatter = DateFormatter()
    formatter.dateFormat = short ? "EEE" : "EEEE"
    return formatter.string(from: date)
  }

  static func dateLabel(_ index: Int) -> String {
    let calendar = Calendar.current
    let date = calendar.date(byAdding: .day, value: index, to: Date()) ?? Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter.string(from: date)
  }

  static func ingredientName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    // Amounts are useful in the recipe, but matching and grocery grouping need the food name.
    let tokens = trimmed.split(separator: " ").map(String.init)
    var index = 0
    while index < tokens.count {
      let token = tokens[index].lowercased()
      let numeric = token.range(of: #"^[0-9¼½¾⅓⅔⅛⅜⅝⅞./-]+$"#, options: .regularExpression) != nil
      let units: Set<String> = [
        "cup", "cups", "tbsp", "tablespoon", "tablespoons", "tsp", "teaspoon", "teaspoons", "oz",
        "ounce", "ounces", "lb", "lbs", "pound", "pounds", "g", "kg", "ml", "l", "can", "cans",
        "clove", "cloves",
      ]
      if numeric || units.contains(token) { index += 1 } else { break }
    }
    let result = tokens.dropFirst(index).joined(separator: " ")
    return result.isEmpty ? trimmed : result
  }

  static func isIngredient(_ raw: String, availableIn inventoryNames: [String]) -> Bool {
    let name = ingredientName(raw)
    guard !name.isEmpty else { return false }
    return inventoryNames.contains { FoodNameMatcher.matches(name, $0).score >= 0.72 }
  }

  static func missingIngredients(for meal: PlannedMeal, inventoryNames: [String]) -> [String] {
    meal.ingredients.compactMap { raw in
      let name = ingredientName(raw)
      guard !name.isEmpty, !isIngredient(name, availableIn: inventoryNames) else { return nil }
      return name
    }
  }

  static func groceryCandidates(
    meals: [PlannedMeal], inventoryNames: [String], groceryNames: [String]
  ) -> [CookLaterGroceryCandidate] {
    var seen = Set<String>()
    var candidates: [CookLaterGroceryCandidate] = []
    for meal in meals where !meal.isCooked && !meal.isBuilding && (0..<7).contains(meal.dayIndex) {
      for ingredient in missingIngredients(for: meal, inventoryNames: inventoryNames) {
        let key = FoodNameMatcher.normalized(ingredient)
        guard !key.isEmpty,
          !seen.contains(key),
          !groceryNames.contains(where: { FoodNameMatcher.matches(ingredient, $0).score >= 0.80 })
        else { continue }
        seen.insert(key)
        candidates.append(
          CookLaterGroceryCandidate(
            id: "\(meal.id.uuidString)-\(key)",
            name: ingredient,
            mealTitle: meal.title
          ))
      }
    }
    return candidates
  }

  static func prepTasks(meals: [PlannedMeal], inventory: [LocalInventoryItem])
    -> [CookLaterPrepTask]
  {
    var tasks: [CookLaterPrepTask] = []
    for meal in meals where !meal.isCooked && !meal.isBuilding && (0..<7).contains(meal.dayIndex) {
      let freezerMatches = inventory.filter { item in
        guard item.zone == "Freezer", item.effectiveLevel > 0 else { return false }
        return meal.ingredients.contains {
          FoodNameMatcher.matches(ingredientName($0), item.name).score >= 0.72
        }
      }
      for item in freezerMatches {
        let when = max(0, meal.dayIndex - 1)
        tasks.append(
          CookLaterPrepTask(
            id: "thaw-\(meal.id.uuidString)-\(FoodNameMatcher.normalized(item.name))",
            title: "Move \(item.name.displayNormalized) to the fridge",
            subtitle: "\(dayLabel(when)) · for \(meal.title)",
            mealID: meal.id,
            dayIndex: when
          ))
      }

      if meal.ingredients.count >= 4 {
        let when = max(0, meal.dayIndex - 1)
        tasks.append(
          CookLaterPrepTask(
            id: "prep-\(meal.id.uuidString)",
            title: "Chop and measure for \(meal.title)",
            subtitle: "\(dayLabel(when)) · prep ahead",
            mealID: meal.id,
            dayIndex: when
          ))
      } else {
        tasks.append(
          CookLaterPrepTask(
            id: "review-\(meal.id.uuidString)",
            title: "Set out ingredients for \(meal.title)",
            subtitle: "\(dayLabel(meal.dayIndex))",
            mealID: meal.id,
            dayIndex: meal.dayIndex
          ))
      }
    }
    return tasks.sorted {
      if $0.dayIndex == $1.dayIndex { return $0.title < $1.title }
      return $0.dayIndex < $1.dayIndex
    }
  }

  static func suggestedMeals(
    catalog: [UserRecipe],
    meals: [PlannedMeal],
    householdSize: Int,
    onlyEmptyDinnerDays: Bool = true,
    limit: Int = 7
  ) -> [CookLaterSuggestedMeal] {
    let occupiedDays = Set(
      meals.filter { !$0.isCooked && $0.mealType == "Dinner" && (0..<7).contains($0.dayIndex) }.map(
        \.dayIndex))
    let plannedTitles = Set(meals.map { FoodNameMatcher.normalized($0.title) })
    let recipes = catalog.filter { !plannedTitles.contains(FoodNameMatcher.normalized($0.title)) }
    var result: [CookLaterSuggestedMeal] = []
    var recipeIndex = 0
    for day in 0..<7 where !onlyEmptyDinnerDays || !occupiedDays.contains(day) {
      guard recipeIndex < recipes.count, result.count < limit else { break }
      let recipe = recipes[recipeIndex]
      recipeIndex += 1
      result.append(
        CookLaterSuggestedMeal(
          id: recipe.id,
          dayIndex: day,
          title: recipe.title,
          ingredients: recipe.ingredientNames,
          mealType: "Dinner",
          servings: max(1, householdSize > 0 ? householdSize : recipe.servings)
        ))
    }
    return result
  }
}

// MARK: - Workspace sheet payloads

nonisolated struct CookLaterPlanDraft: Identifiable, Sendable, Equatable {
  let id: UUID
  var replacingMealID: UUID?
  var dayIndex: Int
  var title: String
  var mealType: String
  var servings: Int
  var ingredients: [String]
  var addMissingToGrocery: Bool

  nonisolated init(
    id: UUID = UUID(),
    replacingMealID: UUID? = nil,
    dayIndex: Int,
    title: String = "",
    mealType: String = "Dinner",
    servings: Int = 2,
    ingredients: [String] = [],
    addMissingToGrocery: Bool = false
  ) {
    self.id = id
    self.replacingMealID = replacingMealID
    self.dayIndex = min(max(0, dayIndex), 6)
    self.title = title
    self.mealType = mealType
    self.servings = max(1, servings)
    self.ingredients = ingredients
    self.addMissingToGrocery = addMissingToGrocery
  }

  nonisolated init(meal: PlannedMeal) {
    self.init(
      replacingMealID: meal.id,
      dayIndex: meal.dayIndex,
      title: meal.title,
      mealType: meal.mealType,
      servings: meal.servings,
      ingredients: meal.ingredients
    )
  }

  nonisolated init(context: CookLaterContext, householdSize: Int) {
    self.init(
      dayIndex: context.suggestedDay,
      title: context.title,
      mealType: context.mealType,
      servings: context.servings > 0 ? context.servings : max(1, householdSize),
      ingredients: context.ingredients,
      addMissingToGrocery: false
    )
  }
}

// MARK: - Unified workspace

struct CookLaterWorkspaceView: View {
  let context: CookLaterContext?
  var onPlanCompleted: (() -> Void)?

  init(context: CookLaterContext? = nil, onPlanCompleted: (() -> Void)? = nil) {
    self.context = context
    self.onPlanCompleted = onPlanCompleted
  }

  var body: some View {
    CookLaterCommandCenterView(context: context, onPlanCompleted: onPlanCompleted)
  }
}

// MARK: - Local prep completion persistence

nonisolated enum CookLaterPrepCompletionStore {
  private static let key = "stocked.cookLater.completedPrep.v1"

  static func load() -> Set<String> {
    Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
  }

  static func save(_ keys: Set<String>) {
    UserDefaults.standard.set(Array(keys).sorted(), forKey: key)
  }
}
