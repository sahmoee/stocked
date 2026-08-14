// CookLaterCommandCenterView.swift
// Refines the unified Cook Later planner into the Plan / Shop / Prep command center.
// All entry points still write to GuestDataStore.plannedMeals and Grocery.

import SwiftUI

// MARK: - Workspace domain

nonisolated enum CookLaterWorkspaceMode: String, CaseIterable, Identifiable, Sendable {
  case plan = "Plan"
  case shop = "Shop"
  case prep = "Prep"

  var id: String { rawValue }
  var icon: String {
    switch self {
    case .plan: return "calendar"
    case .shop: return "cart"
    case .prep: return "checklist"
    }
  }
}

nonisolated enum CookLaterIngredientState: String, Sendable, Equatable {
  case onHand
  case runningLow
  case needed

  var title: String {
    switch self {
    case .onHand: return "On Hand"
    case .runningLow: return "Running Low"
    case .needed: return "Needed"
    }
  }
}

nonisolated struct CookLaterParsedIngredient: Sendable, Equatable {
  let raw: String
  let name: String
  let amount: Double
  let unit: String
  let family: String
  let baseAmount: Double

  var displayAmount: String {
    guard amount > 0 else { return "" }
    let number = amount.rounded(toPlaces: 2).clean
    return unit.isEmpty ? number : "\(number) \(unit)"
  }
}

nonisolated struct CookLaterIngredientCheck: Identifiable, Sendable, Equatable {
  let id: String
  let raw: String
  let name: String
  let requestedDisplay: String
  let availableDisplay: String
  let shortageDisplay: String
  let state: CookLaterIngredientState
  let matchingInventoryIDs: [UUID]
  let competingMeals: [String]
}

nonisolated struct CookLaterShoppingNeed: Identifiable, Sendable, Equatable {
  let id: String
  let name: String
  let amount: Double
  let unit: String
  let sizeText: String
  let mealTitles: [String]
  let shortageReason: String

  var displayAmount: String {
    let value = max(1, amount).rounded(toPlaces: 2).clean
    return unit.isEmpty ? value : "\(value) \(unit)"
  }
}

nonisolated struct CookLaterSubstitution: Identifiable, Sendable, Equatable {
  let id: String
  let title: String
  let detail: String
  let ingredientNames: [String]
}

nonisolated struct CookLaterSubstitutionAvailability: Identifiable, Sendable, Equatable {
  let substitution: CookLaterSubstitution
  let isAvailable: Bool
  var id: String { substitution.id }
}

nonisolated struct CookLaterPrepAction: Identifiable, Sendable, Equatable {
  let id: String
  let title: String
  let detail: String
  let dayIndex: Int
  let mealID: UUID
  let systemImage: String
}

nonisolated enum CookLaterCrossCheckEngine {
  private nonisolated struct UnitDescriptor: Sendable {
    let family: String
    let canonical: String
    let factor: Double
  }

  private static let unitAliases: [String: UnitDescriptor] = [
    "tsp": .init(family: "volume", canonical: "tsp", factor: 4.92892),
    "teaspoon": .init(family: "volume", canonical: "tsp", factor: 4.92892),
    "teaspoons": .init(family: "volume", canonical: "tsp", factor: 4.92892),
    "tbsp": .init(family: "volume", canonical: "tbsp", factor: 14.7868),
    "tablespoon": .init(family: "volume", canonical: "tbsp", factor: 14.7868),
    "tablespoons": .init(family: "volume", canonical: "tbsp", factor: 14.7868),
    "cup": .init(family: "volume", canonical: "cup", factor: 236.588),
    "cups": .init(family: "volume", canonical: "cup", factor: 236.588),
    "ml": .init(family: "volume", canonical: "ml", factor: 1),
    "milliliter": .init(family: "volume", canonical: "ml", factor: 1),
    "milliliters": .init(family: "volume", canonical: "ml", factor: 1),
    "l": .init(family: "volume", canonical: "L", factor: 1000),
    "liter": .init(family: "volume", canonical: "L", factor: 1000),
    "liters": .init(family: "volume", canonical: "L", factor: 1000),
    "fl oz": .init(family: "volume", canonical: "fl oz", factor: 29.5735),
    "floz": .init(family: "volume", canonical: "fl oz", factor: 29.5735),
    "oz": .init(family: "weight", canonical: "oz", factor: 28.3495),
    "ounce": .init(family: "weight", canonical: "oz", factor: 28.3495),
    "ounces": .init(family: "weight", canonical: "oz", factor: 28.3495),
    "lb": .init(family: "weight", canonical: "lb", factor: 453.592),
    "lbs": .init(family: "weight", canonical: "lb", factor: 453.592),
    "pound": .init(family: "weight", canonical: "lb", factor: 453.592),
    "pounds": .init(family: "weight", canonical: "lb", factor: 453.592),
    "g": .init(family: "weight", canonical: "g", factor: 1),
    "gram": .init(family: "weight", canonical: "g", factor: 1),
    "grams": .init(family: "weight", canonical: "g", factor: 1),
    "kg": .init(family: "weight", canonical: "kg", factor: 1000),
    "kilogram": .init(family: "weight", canonical: "kg", factor: 1000),
    "kilograms": .init(family: "weight", canonical: "kg", factor: 1000),
    "can": .init(family: "count", canonical: "can", factor: 1),
    "cans": .init(family: "count", canonical: "can", factor: 1),
    "piece": .init(family: "count", canonical: "piece", factor: 1),
    "pieces": .init(family: "count", canonical: "piece", factor: 1),
    "count": .init(family: "count", canonical: "count", factor: 1),
    "clove": .init(family: "count", canonical: "clove", factor: 1),
    "cloves": .init(family: "count", canonical: "clove", factor: 1),
    "bunch": .init(family: "count", canonical: "bunch", factor: 1),
    "bunches": .init(family: "count", canonical: "bunch", factor: 1),
  ]

  private static let substitutions: [String: [CookLaterSubstitution]] = [
    "heavy cream": [
      .init(
        id: "heavy-half", title: "Half & Half", detail: "Use a 1:1 swap.",
        ingredientNames: ["half and half", "half & half"]),
      .init(
        id: "heavy-milk-butter", title: "Milk + Butter",
        detail: "Use ¾ cup milk plus ¼ cup melted butter per cup.",
        ingredientNames: ["milk", "butter"]),
      .init(
        id: "heavy-evap", title: "Evaporated Milk", detail: "Use a 1:1 swap.",
        ingredientNames: ["evaporated milk"]),
    ],
    "buttermilk": [
      .init(
        id: "buttermilk-lemon", title: "Milk + Lemon",
        detail: "Add 1 tablespoon lemon juice per cup of milk and rest 5 minutes.",
        ingredientNames: ["milk", "lemon"]),
      .init(
        id: "buttermilk-yogurt", title: "Plain Yogurt + Water",
        detail: "Thin plain yogurt until pourable.", ingredientNames: ["plain yogurt", "water"]),
    ],
    "egg": [
      .init(
        id: "egg-flax", title: "Flax Egg",
        detail: "Mix 1 tablespoon ground flax with 3 tablespoons water per egg.",
        ingredientNames: ["ground flax", "water"]),
      .init(
        id: "egg-applesauce", title: "Applesauce",
        detail: "Use ¼ cup unsweetened applesauce per egg for baking.",
        ingredientNames: ["applesauce"]),
    ],
    "butter": [
      .init(
        id: "butter-oil", title: "Neutral Oil",
        detail: "Use about ¾ as much oil as butter for most cooking.",
        ingredientNames: ["vegetable oil"]),
      .init(
        id: "butter-olive", title: "Olive Oil", detail: "Use for sautéing and savory dishes.",
        ingredientNames: ["olive oil"]),
    ],
    "sour cream": [
      .init(
        id: "sour-yogurt", title: "Plain Greek Yogurt", detail: "Use a 1:1 swap.",
        ingredientNames: ["greek yogurt", "plain yogurt"])
    ],
    "fresh thyme": [
      .init(
        id: "thyme-dried", title: "Dried Thyme", detail: "Use about one-third as much dried thyme.",
        ingredientNames: ["dried thyme", "thyme"])
    ],
    "scallion": [
      .init(
        id: "scallion-onion", title: "Green Onion or Chives",
        detail: "Use the same amount and adjust to taste.",
        ingredientNames: ["green onion", "chives"])
    ],
  ]

  static func parse(_ raw: String) -> CookLaterParsedIngredient {
    let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else {
      return .init(raw: raw, name: "", amount: 0, unit: "", family: "count", baseAmount: 0)
    }

    let tokens = clean.split(separator: " ").map(String.init)
    var amount = 1.0
    var consumed = 0

    if let first = tokens.first, let parsed = parseNumber(first) {
      amount = parsed
      consumed = 1
      if tokens.count > 1, let fraction = parseFraction(tokens[1]), !tokens[0].contains("/") {
        amount += fraction
        consumed = 2
      }
    }

    let remaining = Array(tokens.dropFirst(consumed))
    var unitDescriptor: UnitDescriptor?
    var unitTokenCount = 0
    if remaining.count >= 2 {
      let pair = "\(remaining[0].lowercased()) \(remaining[1].lowercased())"
      if let descriptor = unitAliases[pair] {
        unitDescriptor = descriptor
        unitTokenCount = 2
      }
    }
    if unitDescriptor == nil, let first = remaining.first {
      let normalized = first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",."))
      if let descriptor = unitAliases[normalized] {
        unitDescriptor = descriptor
        unitTokenCount = 1
      }
    }

    var nameTokens = Array(remaining.dropFirst(unitTokenCount))
    while let first = nameTokens.first?.lowercased(), ["of", "a", "an"].contains(first) {
      nameTokens.removeFirst()
    }
    let rawName = nameTokens.joined(separator: " ")
    let name = rawName.isEmpty ? CookLaterPlanningEngine.ingredientName(clean) : rawName
    let descriptor = unitDescriptor ?? .init(family: "count", canonical: "", factor: 1)
    return .init(
      raw: raw,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      amount: max(0, amount),
      unit: descriptor.canonical,
      family: descriptor.family,
      baseAmount: max(0, amount * descriptor.factor)
    )
  }

  static func checks(
    for meal: PlannedMeal, allMeals: [PlannedMeal], inventory: [LocalInventoryItem]
  ) -> [CookLaterIngredientCheck] {
    meal.ingredients.enumerated().map { index, raw in
      let parsed = parse(raw)
      let matches = matchingInventory(for: parsed.name, inventory: inventory)
      let available = availableBase(for: parsed, matches: matches)
      let totalDemand =
        allMeals
        .filter { !$0.isCooked && !$0.isBuilding }
        .flatMap(\.ingredients)
        .map(parse)
        .filter {
          FoodNameMatcher.matches($0.name, parsed.name).score >= 0.80 && compatible($0, parsed)
        }
        .reduce(0) { $0 + $1.baseAmount }
      let shortage = max(0, totalDemand - available)
      let directShortage = max(0, parsed.baseAmount - available)
      let competing = allMeals.filter { other in
        other.id != meal.id && !other.isCooked
          && other.ingredients.contains { ingredient in
            let otherParsed = parse(ingredient)
            return FoodNameMatcher.matches(otherParsed.name, parsed.name).score >= 0.80
              && compatible(otherParsed, parsed)
          }
      }.map(\.title)

      let state: CookLaterIngredientState
      if matches.isEmpty || directShortage >= parsed.baseAmount - 0.001 {
        state = .needed
      } else if shortage > 0.001 || matches.contains(where: \.isLow) {
        state = .runningLow
      } else {
        state = .onHand
      }

      return CookLaterIngredientCheck(
        id: "\(meal.id.uuidString)-\(index)-\(FoodNameMatcher.normalized(parsed.name))",
        raw: raw,
        name: parsed.name,
        requestedDisplay: parsed.displayAmount,
        availableDisplay: display(base: available, parsed: parsed),
        shortageDisplay: display(base: max(directShortage, shortage), parsed: parsed),
        state: state,
        matchingInventoryIDs: matches.map(\.id),
        competingMeals: Array(Set(competing)).sorted()
      )
    }
  }

  static func shoppingNeeds(
    meals: [PlannedMeal], inventory: [LocalInventoryItem], existingGrocery: [LocalGroceryItem]
  ) -> [CookLaterShoppingNeed] {
    struct Bucket {
      var name: String
      var parsed: CookLaterParsedIngredient
      var demand: Double
      var meals: Set<String>
    }

    var buckets: [String: Bucket] = [:]
    for meal in meals where !meal.isCooked && !meal.isBuilding {
      for raw in meal.ingredients {
        let parsed = parse(raw)
        guard !parsed.name.isEmpty else { continue }
        let key = "\(FoodNameMatcher.normalized(parsed.name))|\(parsed.family)"
        if var bucket = buckets[key] {
          bucket.demand += parsed.baseAmount
          bucket.meals.insert(meal.title)
          buckets[key] = bucket
        } else {
          buckets[key] = Bucket(
            name: parsed.name, parsed: parsed, demand: parsed.baseAmount, meals: [meal.title])
        }
      }
    }

    return buckets.compactMap { key, bucket in
      let matches = matchingInventory(for: bucket.name, inventory: inventory)
      let available = availableBase(for: bucket.parsed, matches: matches)
      let shortageBase = max(0, bucket.demand - available)
      guard shortageBase > 0.001 else { return nil }
      let alreadyListed = existingGrocery.contains {
        FoodNameMatcher.matches($0.name, bucket.name).score >= 0.82
      }
      guard !alreadyListed else { return nil }
      let amount =
        bucket.parsed.baseAmount > 0
        ? shortageBase / max(0.0001, bucket.parsed.baseAmount / max(0.0001, bucket.parsed.amount))
        : 1
      let mealTitles = bucket.meals.sorted()
      return CookLaterShoppingNeed(
        id: key,
        name: bucket.name,
        amount: max(1, amount),
        unit: bucket.parsed.unit,
        sizeText: bucket.parsed.unit.isEmpty
          ? "" : "\(max(1, amount).rounded(toPlaces: 2).clean) \(bucket.parsed.unit)",
        mealTitles: mealTitles,
        shortageReason: mealTitles.count == 1
          ? "For \(mealTitles[0])" : "Across \(mealTitles.count) planned meals"
      )
    }
    .sorted { lhs, rhs in
      if lhs.mealTitles.count == rhs.mealTitles.count { return lhs.name < rhs.name }
      return lhs.mealTitles.count > rhs.mealTitles.count
    }
  }

  static func substitutions(for ingredientName: String, inventory: [LocalInventoryItem])
    -> [CookLaterSubstitutionAvailability]
  {
    let normalized = FoodNameMatcher.normalized(ingredientName)
    let key = substitutions.keys
      .sorted { $0.count > $1.count }
      .first { FoodNameMatcher.matches($0, normalized).score >= 0.78 }
    guard let key, let options = substitutions[key] else { return [] }
    return options.map { option in
      let haveAll = option.ingredientNames.allSatisfy { needed in
        inventory.contains {
          $0.effectiveLevel > 0 && FoodNameMatcher.matches($0.name, needed).score >= 0.75
        }
      }
      return CookLaterSubstitutionAvailability(substitution: option, isAvailable: haveAll)
    }
  }

  static func allocationSummary(for item: LocalInventoryItem, meals: [PlannedMeal]) -> (
    available: String, planned: String, unallocated: String, mealTitles: [String]
  ) {
    let relevant = meals.filter { meal in
      !meal.isCooked
        && meal.ingredients.contains {
          FoodNameMatcher.matches(parse($0).name, item.name).score >= 0.78
        }
    }
    let availableCount = max(0, Double(item.quantity) * max(0, item.effectiveLevel))
    let demand = relevant.flatMap(\.ingredients).map(parse).filter {
      FoodNameMatcher.matches($0.name, item.name).score >= 0.78
    }.reduce(0) { $0 + ($1.family == "count" ? max(1, $1.amount) : 1) }
    return (
      available: inventoryDisplay(item),
      planned: demand.rounded(toPlaces: 1).clean,
      unallocated: max(0, availableCount - demand).rounded(toPlaces: 1).clean,
      mealTitles: relevant.map(\.title)
    )
  }

  static func prepActions(meals: [PlannedMeal], inventory: [LocalInventoryItem])
    -> [CookLaterPrepAction]
  {
    var actions: [CookLaterPrepAction] = []
    for meal in meals where !meal.isCooked && !meal.isBuilding {
      let parsed = meal.ingredients.map(parse)
      let freezerItems = inventory.filter { item in
        item.zone == "Freezer" && item.effectiveLevel > 0
          && parsed.contains { FoodNameMatcher.matches($0.name, item.name).score >= 0.75 }
      }
      for item in freezerItems {
        let day = max(0, meal.dayIndex - 1)
        actions.append(
          .init(
            id: "thaw-\(meal.id.uuidString)-\(item.id.uuidString)",
            title: "Thaw \(item.name.displayNormalized)",
            detail: "Move freezer → fridge for \(meal.title)",
            dayIndex: day,
            mealID: meal.id,
            systemImage: "snowflake"
          ))
      }

      let title = meal.title.lowercased()
      let protein = parsed.first { ingredient in
        ["chicken", "beef", "pork", "steak", "fish", "salmon", "shrimp", "turkey", "tofu"].contains
        { FoodNameMatcher.containsPhrase($0, in: ingredient.name) }
      }
      if let protein,
        title.contains("jerk") || title.contains("marinat") || meal.ingredients.count >= 6
      {
        actions.append(
          .init(
            id: "marinate-\(meal.id.uuidString)",
            title: "Marinate \(protein.name.displayNormalized)",
            detail:
              "10 min · for \(CookLaterPlanningEngine.dayLabel(meal.dayIndex)) \(meal.mealType.lowercased())",
            dayIndex: max(0, meal.dayIndex - 1),
            mealID: meal.id,
            systemImage: "drop.fill"
          ))
      }

      let chopNames = parsed.filter { ingredient in
        ["onion", "pepper", "scallion", "carrot", "celery", "garlic", "herb"].contains {
          FoodNameMatcher.containsPhrase($0, in: ingredient.name)
        }
      }.map(\.name)
      if !chopNames.isEmpty {
        let preview = chopNames.prefix(2).map(\.displayNormalized).joined(separator: " + ")
        actions.append(
          .init(
            id: "chop-\(meal.id.uuidString)",
            title: "Chop \(preview)",
            detail: "15 min · used in \(meal.title)",
            dayIndex: max(0, meal.dayIndex - 1),
            mealID: meal.id,
            systemImage: "takeoutbag.and.cup.and.straw.fill"
          ))
      }

      if title.contains("rice") || title.contains("grain") || title.contains("bean") {
        actions.append(
          .init(
            id: "batch-\(meal.id.uuidString)",
            title: "Cook the base for \(meal.title)",
            detail: "Batch ahead and refrigerate safely",
            dayIndex: max(0, meal.dayIndex - 1),
            mealID: meal.id,
            systemImage: "flame.fill"
          ))
      }
    }

    var seen = Set<String>()
    return actions.filter { seen.insert($0.id).inserted }.sorted {
      if $0.dayIndex == $1.dayIndex { return $0.title < $1.title }
      return $0.dayIndex < $1.dayIndex
    }
  }

  private static func matchingInventory(for name: String, inventory: [LocalInventoryItem])
    -> [LocalInventoryItem]
  {
    inventory.filter {
      $0.effectiveLevel > 0 && FoodNameMatcher.matches(name, $0.name).score >= 0.72
    }
  }

  private static func compatible(_ lhs: CookLaterParsedIngredient, _ rhs: CookLaterParsedIngredient)
    -> Bool
  {
    lhs.family == rhs.family || lhs.unit.isEmpty || rhs.unit.isEmpty
  }

  private static func availableBase(
    for parsed: CookLaterParsedIngredient, matches: [LocalInventoryItem]
  ) -> Double {
    matches.reduce(0) { partial, item in
      let level = max(0, min(1, item.effectiveLevel))
      if let amount = item.sizeAmount, let unit = item.sizeUnit,
        let descriptor = unitAliases[
          unit.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)],
        descriptor.family == parsed.family
      {
        return partial + Double(max(1, item.quantity)) * amount * descriptor.factor * level
      }
      if parsed.family == "count" {
        return partial + Double(max(1, item.quantity)) * level
      }
      // Presence is useful even when packaging is unstructured. Treat one matching
      // package as one requested unit instead of incorrectly claiming zero stock.
      return partial + max(parsed.baseAmount, 1) * level
    }
  }

  private static func display(base: Double, parsed: CookLaterParsedIngredient) -> String {
    guard base > 0 else { return "0" }
    let perUnit = parsed.amount > 0 ? parsed.baseAmount / parsed.amount : 1
    let converted = base / max(0.0001, perUnit)
    let number = converted.rounded(toPlaces: 2).clean
    return parsed.unit.isEmpty ? number : "\(number) \(parsed.unit)"
  }

  private static func inventoryDisplay(_ item: LocalInventoryItem) -> String {
    if let amount = item.sizeAmount, let unit = item.sizeUnit {
      let total = Double(max(1, item.quantity)) * amount * max(0, item.effectiveLevel)
      return "\(total.rounded(toPlaces: 1).clean) \(unit)"
    }
    return
      "\((Double(max(1, item.quantity)) * max(0, item.effectiveLevel)).rounded(toPlaces: 1).clean) \(item.containerType)"
  }

  private static func parseNumber(_ token: String) -> Double? {
    let cleaned = token.replacingOccurrences(of: ",", with: ".")
    if let fraction = parseFraction(cleaned) { return fraction }
    let vulgar: [Character: Double] = [
      "¼": 0.25, "½": 0.5, "¾": 0.75, "⅓": 1.0 / 3.0, "⅔": 2.0 / 3.0, "⅛": 0.125, "⅜": 0.375,
      "⅝": 0.625, "⅞": 0.875,
    ]
    if cleaned.count == 1, let char = cleaned.first, let value = vulgar[char] { return value }
    return Double(cleaned)
  }

  private static func parseFraction(_ token: String) -> Double? {
    let parts = token.split(separator: "/")
    guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]),
      denominator != 0
    else { return nil }
    return numerator / denominator
  }
}

// MARK: - Command center

private enum CookLaterCommandSheet: Identifiable {
  case addMeal(day: Int, mealType: String)
  case editor(CookLaterPlanDraft)
  case recipePicker(day: Int, title: String, recipes: [UserRecipe])
  case onlinePicker(day: Int)
  case mealDetail(UUID)
  case calendar
  case substitutions(CookLaterShoppingNeed)
  case suggestions(title: String, items: [CookLaterSuggestedMeal])

  var id: String {
    switch self {
    case .addMeal(let day, let type): return "add-\(day)-\(type)"
    case .editor(let draft): return "editor-\(draft.id.uuidString)"
    case .recipePicker(let day, let title, _): return "recipes-\(day)-\(title)"
    case .onlinePicker(let day): return "online-\(day)"
    case .mealDetail(let id): return "meal-\(id.uuidString)"
    case .calendar: return "calendar"
    case .substitutions(let need): return "sub-\(need.id)"
    case .suggestions(let title, let items):
      return "suggestions-\(title)-\(items.map { $0.id.uuidString }.joined(separator: ","))"
    }
  }
}

struct CookLaterCommandCenterView: View {
  @Environment(AppSession.self) private var session

  let context: CookLaterContext?
  var onPlanCompleted: (() -> Void)?

  @State private var selectedMode: CookLaterWorkspaceMode = .plan
  @State private var selectedDay: Int
  @State private var activeSheet: CookLaterCommandSheet?
  @State private var completedPrepKeys: Set<String> = []
  /// #11 — the meal awaiting a "what did this use?" confirm.
  @State private var cookedMeal: PlannedMeal? = nil
  @State private var shoppingOverrides: [String: Double] = [:]
  @State private var toast: String?
  @State private var webManager = WebRecipeManager.shared

  init(context: CookLaterContext?, onPlanCompleted: (() -> Void)?) {
    self.context = context
    self.onPlanCompleted = onPlanCompleted
    _selectedDay = State(initialValue: min(max(0, context?.suggestedDay ?? 0), 6))
  }

  private var store: GuestDataStore { session.guestStore }
  private var householdSize: Int { max(1, store.cookingProfile.householdSize) }
  private var activeMeals: [PlannedMeal] {
    store.plannedMeals.filter { !$0.isBuilding && (0..<7).contains($0.dayIndex) }
  }
  private var upcomingMeals: [PlannedMeal] { activeMeals.filter { !$0.isCooked } }
  private var shoppingNeeds: [CookLaterShoppingNeed] {
    CookLaterCrossCheckEngine.shoppingNeeds(
      meals: upcomingMeals, inventory: store.inventoryItems, existingGrocery: store.groceryItems)
  }
  private var prepActions: [CookLaterPrepAction] {
    CookLaterCrossCheckEngine.prepActions(meals: upcomingMeals, inventory: store.inventoryItems)
  }
  private var stockedMealCount: Int {
    upcomingMeals.filter { meal in
      CookLaterCrossCheckEngine.checks(
        for: meal, allMeals: upcomingMeals, inventory: store.inventoryItems
      ).allSatisfy { $0.state == .onHand }
    }.count
  }
  private var conflictCount: Int {
    upcomingMeals.reduce(0) { partial, meal in
      partial
        + CookLaterCrossCheckEngine.checks(
          for: meal, allMeals: upcomingMeals, inventory: store.inventoryItems
        )
        .filter { !$0.competingMeals.isEmpty && $0.state != .onHand }.count
    }
  }
  private var readinessPercent: Int {
    guard !upcomingMeals.isEmpty else { return 0 }
    let stockedWeight = Double(stockedMealCount) / Double(upcomingMeals.count)
    let shoppingPenalty = min(0.35, Double(shoppingNeeds.count) * 0.035)
    let prepPenalty = min(
      0.2, Double(prepActions.filter { !completedPrepKeys.contains($0.id) }.count) * 0.02)
    return Int(max(0, min(1, stockedWeight + 0.45 - shoppingPenalty - prepPenalty)) * 100)
  }

  var body: some View {
    StockedShell(
      showBack: true,
      titleText: "Cook Later",
      trailingIcon: "calendar",
      trailingLabel: "Calendar",
      onTrailing: { activeSheet = .calendar }
    ) {
      VStack(alignment: .leading, spacing: 18) {
        weekHeader
        if let context { contextualEntry(context) }
        modePicker
        Group {
          switch selectedMode {
          case .plan: planWorkspace
          case .shop: shopWorkspace
          case .prep: prepWorkspace
          }
        }
        Spacer(minLength: 24)
      }
      .padding(.top, 2)
    }
    // #11 — close the loop between "I cooked this" and what's actually left in the pantry.
    .sheet(item: $cookedMeal) { meal in
      CookCompletionSheet(meal: meal).environment(session)
    }
    .sheet(item: $activeSheet) { sheet in
      switch sheet {
      case .addMeal(let day, let mealType):
        CookLaterAddMealSourceSheet(
          dayIndex: day,
          mealType: mealType,
          recentMeals: recentMealRecipes,
          onSelectSource: handleAddSource
        )
        .environment(session)
      case .editor(let draft):
        CookLaterCommandEditorSheet(draft: draft) { save($0) }
          .environment(session)
      case .recipePicker(let day, let title, let recipes):
        CookLaterCommandRecipePicker(title: title, dayIndex: day, recipes: recipes) { recipe in
          activeSheet = .editor(draft(for: recipe, day: day))
        }
        .environment(session)
      case .onlinePicker(let day):
        CookLaterWebRecipePicker(dayIndex: day, recipes: webManager.recipes) { recipe in
          activeSheet = .editor(
            CookLaterPlanDraft(
              dayIndex: day,
              title: recipe.title,
              mealType: "Dinner",
              servings: max(householdSize, parsedServings(recipe.servings)),
              ingredients: recipe.ingredients
            ))
        }
        .environment(session)
      case .mealDetail(let id):
        if let meal = activeMeals.first(where: { $0.id == id }) {
          CookLaterMealDetailSheet(
            meal: meal,
            allMeals: upcomingMeals,
            inventory: store.inventoryItems,
            onSave: save,
            onAddMissing: addChecksToGrocery
          )
          .environment(session)
        }
      case .calendar:
        CookLaterMonthCalendarSheet(
          meals: activeMeals,
          prepActions: prepActions,
          shoppingNeeds: shoppingNeeds,
          selectedDay: selectedDay
        ) { day in
          selectedDay = day
          selectedMode = .plan
          activeSheet = nil
        }
        .environment(session)
      case .substitutions(let need):
        CookLaterSubstitutionSheet(
          need: need,
          options: CookLaterCrossCheckEngine.substitutions(
            for: need.name, inventory: store.inventoryItems)
        ) { option in
          applySubstitution(option, replacing: need)
        }
        .environment(session)
      case .suggestions(let title, let items):
        CookLaterCommandSuggestionsSheet(title: title, suggestions: items) { selected in
          applySuggestions(selected)
        }
        .environment(session)
      }
    }
    .overlay(alignment: .bottom) {
      if let toast {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.stockedGreen)
          Text(toast).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.stockedWhite)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Color.stockedCharcoal, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .onAppear {
      completedPrepKeys = CookLaterPrepCompletionStore.load()
      webManager.loadIfNeeded()
      routeInitialContext()
    }
  }

  // MARK: Header and navigation

  private var weekHeader: some View {
    HStack(spacing: 12) {
      Button {
        selectedDay = max(0, selectedDay - 1)
      } label: {
        Image(systemName: "chevron.left")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(session.themeTextColor)
          .frame(width: 34, height: 34)
          .background(session.themeCardColor, in: Circle())
      }
      .buttonStyle(.plain)
      .disabled(selectedDay == 0)
      .opacity(selectedDay == 0 ? 0.35 : 1)

      VStack(alignment: .leading, spacing: 2) {
        Text("\(CookLaterPlanningEngine.dateLabel(0)) – \(CookLaterPlanningEngine.dateLabel(6))")
          .font(.system(size: 15.5, weight: .bold, design: .serif))
          .foregroundStyle(session.themeTextColor)
        Text("Plan it. Shop for it. Prep it. Cook it.")
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(session.themeTextColor.opacity(0.48))
      }
      Spacer()
      Button {
        selectedDay = min(6, selectedDay + 1)
      } label: {
        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(session.themeTextColor)
          .frame(width: 34, height: 34)
          .background(session.themeCardColor, in: Circle())
      }
      .buttonStyle(.plain)
      .disabled(selectedDay == 6)
      .opacity(selectedDay == 6 ? 0.35 : 1)
    }
    .padding(.horizontal, CookStyle.screenHPad)
  }

  private var modePicker: some View {
    HStack(spacing: 4) {
      ForEach(CookLaterWorkspaceMode.allCases) { mode in
        Button {
          withAnimation(.snappy(duration: 0.22)) { selectedMode = mode }
          HapticManager.select()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: mode.icon).font(.system(size: 12, weight: .semibold))
            Text(mode.rawValue).font(.system(size: 13.5, weight: .semibold))
          }
          .foregroundStyle(
            selectedMode == mode ? Color.stockedWhite : session.themeTextColor.opacity(0.58)
          )
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
          .background(selectedMode == mode ? Color.stockedCharcoal : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(4)
    .background(session.themeCardColor, in: Capsule())
    .padding(.horizontal, CookStyle.screenHPad)
  }

  // MARK: Context entry

  @ViewBuilder private func contextualEntry(_ context: CookLaterContext) -> some View {
    if context.source == .inventory, let item = matchingContextInventory(context.title) {
      inventoryAllocationCard(item)
    } else {
      let presentation = contextPresentation(context)
      VStack(alignment: .leading, spacing: 11) {
        HStack(spacing: 11) {
          ZStack {
            Circle().fill(presentation.tint.opacity(0.14)).frame(width: 40, height: 40)
            Image(systemName: presentation.icon).font(.system(size: 16, weight: .semibold))
              .foregroundStyle(presentation.tint)
          }
          VStack(alignment: .leading, spacing: 2) {
            Text(presentation.eyebrow.uppercased()).font(.system(size: 9.5, weight: .bold))
              .tracking(0.7).foregroundStyle(presentation.tint)
            Text(presentation.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(
              session.themeTextColor
            ).lineLimit(1)
            Text(presentation.detail).font(.system(size: 11.5)).foregroundStyle(
              session.themeTextColor.opacity(0.48)
            ).lineLimit(2)
          }
          Spacer()
        }
        Button {
          if let focus = context.focusMealTitle,
            let meal = activeMeals.first(where: {
              FoodNameMatcher.matches($0.title, focus).score >= 0.80
            })
          {
            activeSheet = .mealDetail(meal.id)
          } else {
            activeSheet = .editor(
              CookLaterPlanDraft(context: context, householdSize: householdSize))
          }
        } label: {
          Label(
            context.focusMealTitle == nil ? "Plan this" : "Open planned meal",
            systemImage: "calendar.badge.plus"
          )
          .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.stockedWhite)
          .frame(maxWidth: .infinity).padding(.vertical, 11)
          .background(Color.stockedCharcoal, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
      }
      .padding(14)
      .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: CookStyle.cardCorner))
      .overlay(
        RoundedRectangle(cornerRadius: CookStyle.cardCorner).stroke(
          presentation.tint.opacity(0.18), lineWidth: 1)
      )
      .padding(.horizontal, CookStyle.screenHPad)
    }
  }

  private func inventoryAllocationCard(_ item: LocalInventoryItem) -> some View {
    let allocation = CookLaterCrossCheckEngine.allocationSummary(for: item, meals: upcomingMeals)
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        AsyncFoodImage(name: item.name, url: nil, size: 54)
          .clipShape(RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 3) {
          Text(item.name.displayNormalized).font(.system(size: 17, weight: .bold, design: .serif))
            .foregroundStyle(session.themeTextColor)
          Text("\(allocation.available) available")
            .font(.system(size: 11.5)).foregroundStyle(session.themeTextColor.opacity(0.48))
          Text("\(allocation.planned) planned · \(allocation.unallocated) unallocated")
            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.stockedGreen)
        }
        Spacer()
      }
      if !allocation.mealTitles.isEmpty {
        Text("Already reserved for \(allocation.mealTitles.joined(separator: ", ")).")
          .font(.system(size: 11.5)).foregroundStyle(session.themeTextColor.opacity(0.5))
      }
      Button {
        openRecipesUsing(item.name)
      } label: {
        Text("Plan with this ingredient")
          .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.stockedWhite)
          .frame(maxWidth: .infinity).padding(.vertical, 12)
          .background(Color.stockedCharcoal, in: RoundedRectangle(cornerRadius: 12))
      }
      .buttonStyle(.plain)
      HStack(spacing: 8) {
        contextQuickButton("Add to meal", icon: "calendar.badge.plus") {
          activeSheet = .editor(
            CookLaterPlanDraft(
              dayIndex: selectedDay, servings: householdSize, ingredients: [item.name]))
        }
        contextQuickButton("Grocery", icon: "cart.badge.plus") {
          store.addToGroceryIfMissing(item.name, recommended: false)
          showToast("Added \(item.name.displayNormalized) to Grocery")
        }
        contextQuickButton("Recipes", icon: "book.closed") { openRecipesUsing(item.name) }
      }
    }
    .padding(14)
    .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: CookStyle.cardCorner))
    .overlay(
      RoundedRectangle(cornerRadius: CookStyle.cardCorner).stroke(
        Color.stockedGreen.opacity(0.22), lineWidth: 1)
    )
    .padding(.horizontal, CookStyle.screenHPad)
  }

  private func contextQuickButton(_ title: String, icon: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      VStack(spacing: 5) {
        Image(systemName: icon).font(.system(size: 13, weight: .semibold))
        Text(title).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
      }
      .foregroundStyle(session.themeTextColor)
      .frame(maxWidth: .infinity).padding(.vertical, 9)
      .background(session.themeTextColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
  }

  // MARK: Plan

  private var planWorkspace: some View {
    VStack(alignment: .leading, spacing: 18) {
      readinessCard
      smartPlanRail
      weekPlan
      unscheduledRecipes
      planningInsights
    }
  }

  private var readinessCard: some View {
    Button {
      selectedMode = shoppingNeeds.isEmpty ? .prep : .shop
    } label: {
      HStack(spacing: 16) {
        ZStack {
          Circle().stroke(session.themeTextColor.opacity(0.08), lineWidth: 8)
          Circle().trim(from: 0, to: CGFloat(readinessPercent) / 100)
            .stroke(
              readinessPercent >= 75 ? Color.stockedGreen : Color.stockedGold,
              style: StrokeStyle(lineWidth: 8, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
          Text("\(readinessPercent)%")
            .font(.system(size: 17, weight: .bold, design: .serif)).foregroundStyle(
              session.themeTextColor)
        }
        .frame(width: 72, height: 72)
        VStack(alignment: .leading, spacing: 5) {
          Text("Week Readiness").font(.system(size: 17, weight: .bold, design: .serif))
            .foregroundStyle(session.themeTextColor)
          readinessLine("\(upcomingMeals.count) meals planned", tint: Color.stockedGreen)
          readinessLine(
            "\(shoppingNeeds.count) groceries needed",
            tint: shoppingNeeds.isEmpty ? Color.stockedGreen : Color.stockedError)
          readinessLine(
            "\(prepActions.filter { !completedPrepKeys.contains($0.id) }.count) prep tasks",
            tint: Color.stockedGold)
          readinessLine(
            "\(conflictCount) conflicts",
            tint: conflictCount == 0 ? Color.stockedGreen : Color.orange)
        }
        Spacer()
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(
          session.themeTextColor.opacity(0.3))
      }
      .padding(16)
      .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: CookStyle.cardCorner))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, CookStyle.screenHPad)
  }

  private func readinessLine(_ text: String, tint: Color) -> some View {
    HStack(spacing: 6) {
      Circle().fill(tint).frame(width: 5, height: 5)
      Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(
        session.themeTextColor.opacity(0.58))
    }
  }

  private var smartPlanRail: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionHeader("Plan smarter", trailing: "Nothing changes until confirmed")
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          smartAction("Fill empty days", icon: "wand.and.stars", tint: Color.stockedGold) {
            fillEmptyDays()
          }
          smartAction("Use something up", icon: "flame.fill", tint: Color.orange) {
            useSomethingUp()
          }
          smartAction("Based on inventory", icon: "shippingbox.fill", tint: Color.stockedGreen) {
            openInventoryBasedRecipes()
          }
          smartAction("From my recipes", icon: "bookmark.fill", tint: Color.stockedInfo) {
            openMyRecipes(day: selectedDay)
          }
          smartAction(
            "Repeat favorites", icon: "arrow.counterclockwise", tint: Color.stockedCharcoal
          ) { repeatFavorites() }
        }
        .padding(.horizontal, CookStyle.screenHPad)
        .stockedScrollTargetLayout()
      }
      .stockedHorizontalSnap()
    }
  }

  private func smartAction(_ title: String, icon: String, tint: Color, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 10) {
        ZStack {
          Circle().fill(tint.opacity(0.15)).frame(width: 38, height: 38)
          Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
        }
        Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(
          session.themeTextColor
        ).lineLimit(2)
      }
      .padding(13).frame(width: 138, height: 104, alignment: .leading)
      .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain)
  }

  private var weekPlan: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionHeader("The week", trailing: "Tap a meal for ingredient check")
      LazyVStack(spacing: 10) {
        ForEach(0..<7, id: \.self) { day in weekDayCard(day) }
      }
      .padding(.horizontal, CookStyle.screenHPad)
    }
  }

  private func weekDayCard(_ day: Int) -> some View {
    let meals = activeMeals.filter { $0.dayIndex == day }.sorted {
      mealOrder($0.mealType) < mealOrder($1.mealType)
    }
    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 1) {
          Text(day == 0 ? "TODAY" : CookLaterPlanningEngine.dayLabel(day).uppercased())
            .font(.system(size: 10, weight: .bold)).tracking(0.8)
            .foregroundStyle(
              day == selectedDay ? Color.stockedGold : session.themeTextColor.opacity(0.45))
          Text(CookLaterPlanningEngine.dateLabel(day))
            .font(.system(size: 15, weight: .bold, design: .serif)).foregroundStyle(
              session.themeTextColor)
        }
        Spacer()
        Menu {
          ForEach(CookLaterPlanningEngine.mealTypes, id: \.self) { type in
            Button("Plan \(type)") { activeSheet = .addMeal(day: day, mealType: type) }
          }
        } label: {
          Label("Plan", systemImage: "plus")
            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.stockedGold)
        }
      }
      if meals.isEmpty {
        Button {
          activeSheet = .addMeal(day: day, mealType: "Dinner")
        } label: {
          HStack {
            Image(systemName: "plus.circle")
            Text("Plan a meal").font(.system(size: 12.5, weight: .semibold))
            Spacer()
          }
          .foregroundStyle(session.themeTextColor.opacity(0.45))
          .padding(12).background(
            session.themeTextColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
      } else {
        ForEach(meals) { meal in mealPlanRow(meal) }
      }
    }
    .padding(14)
    .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: CookStyle.cardCorner))
    .overlay(
      RoundedRectangle(cornerRadius: CookStyle.cardCorner).stroke(
        day == selectedDay ? Color.stockedGold.opacity(0.32) : Color.clear, lineWidth: 1)
    )
    .onTapGesture { selectedDay = day }
  }

  private func mealPlanRow(_ meal: PlannedMeal) -> some View {
    let checks = CookLaterCrossCheckEngine.checks(
      for: meal, allMeals: upcomingMeals, inventory: store.inventoryItems)
    let onHand = checks.filter { $0.state == .onHand }.count
    let missing = checks.filter { $0.state == .needed }.count
    let low = checks.filter { $0.state == .runningLow }.count
    return Button {
      activeSheet = .mealDetail(meal.id)
    } label: {
      HStack(spacing: 11) {
        AsyncFoodImage(name: meal.title, url: nil, size: 52)
          .clipShape(RoundedRectangle(cornerRadius: 11))
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(meal.mealType).font(.system(size: 9.5, weight: .bold)).tracking(0.5)
              .foregroundStyle(Color.stockedGold)
            if meal.isCooked {
              Text("COOKED").font(.system(size: 8.5, weight: .bold)).foregroundStyle(
                Color.stockedGreen)
            }
          }
          Text(meal.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(
            session.themeTextColor
          ).lineLimit(1)
          Text(
            "\(onHand)/\(checks.count) on hand\(missing > 0 ? " · \(missing) needed" : "")\(low > 0 ? " · \(low) low" : "")"
          )
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(
            missing == 0 && low == 0 ? Color.stockedGreen : session.themeTextColor.opacity(0.48))
        }
        Spacer()
        Image(systemName: meal.isCooked ? "checkmark.circle.fill" : "chevron.right")
          .font(.system(size: meal.isCooked ? 17 : 11, weight: .bold))
          .foregroundStyle(
            meal.isCooked ? Color.stockedGreen : session.themeTextColor.opacity(0.28))
      }
      .padding(9)
      .background(session.themeTextColor.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button(meal.isCooked ? "Mark not cooked" : "Mark cooked", systemImage: "checkmark.circle") {
        toggleCooked(meal)
      }
      Menu("Move to day") {
        ForEach(0..<7, id: \.self) { day in
          Button(CookLaterPlanningEngine.dayLabel(day)) { move(meal, to: day) }
        }
      }
      Button("Remove", systemImage: "trash", role: .destructive) { remove(meal) }
    }
  }

  private var unscheduledRecipes: some View {
    let planned = Set(upcomingMeals.map { FoodNameMatcher.normalized($0.title) })
    let recipes = store.cookCatalog.filter {
      !planned.contains(FoodNameMatcher.normalized($0.title))
    }.prefix(8)
    return VStack(alignment: .leading, spacing: 10) {
      sectionHeader(
        "Ideas not on the calendar",
        trailing: "Drop into \(CookLaterPlanningEngine.dayLabel(selectedDay))")
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(Array(recipes)) { recipe in
            Button {
              activeSheet = .editor(draft(for: recipe, day: selectedDay))
            } label: {
              VStack(alignment: .leading, spacing: 8) {
                AsyncFoodImage(name: recipe.title, url: recipe.imageURL, size: 140)
                  .frame(width: 140, height: 78).clipped().clipShape(
                    RoundedRectangle(cornerRadius: 11))
                Text(recipe.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(
                  session.themeTextColor
                ).lineLimit(2)
                let match = store.stockMatch(for: recipe)
                Text(
                  match.total == 0 ? "Review ingredients" : "\(match.have)/\(match.total) stocked"
                )
                .font(.system(size: 10)).foregroundStyle(
                  match.total > 0 && match.have == match.total
                    ? Color.stockedGreen : session.themeTextColor.opacity(0.45))
              }
              .padding(10).frame(width: 160, height: 154, alignment: .topLeading)
              .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, CookStyle.screenHPad)
        .stockedScrollTargetLayout()
      }
      .stockedHorizontalSnap()
    }
  }

  private var planningInsights: some View {
    let expiringUsed = Set(
      upcomingMeals.flatMap(\.ingredients).compactMap { ingredient in
        store.expiringSoonItems.first {
          FoodNameMatcher.matches(CookLaterCrossCheckEngine.parse(ingredient).name, $0.name).score
            >= 0.72
        }?.name
      }
    ).count
    let shared = sharedIngredientCount
    return VStack(alignment: .leading, spacing: 10) {
      sectionHeader("Planning impact", trailing: "Live from your kitchen")
      VStack(spacing: 8) {
        insightRow(
          "Inventory allocation",
          value: conflictCount == 0
            ? "No overuse conflicts detected"
            : "\(conflictCount) ingredient conflict\(conflictCount == 1 ? "" : "s") need attention",
          icon: "shippingbox.fill", tint: conflictCount == 0 ? Color.stockedGreen : Color.orange)
        insightRow(
          "Ingredient reuse",
          value: shared == 0
            ? "Plan another meal to reuse ingredients"
            : "\(shared) ingredient\(shared == 1 ? "" : "s") shared across meals",
          icon: "arrow.triangle.2.circlepath", tint: Color.stockedGreen)
        insightRow(
          "Waste prevention",
          value: expiringUsed == 0
            ? "No expiring food assigned yet"
            : "\(expiringUsed) expiring item\(expiringUsed == 1 ? "" : "s") included",
          icon: "clock.badge.checkmark", tint: Color.orange)
      }
      .padding(.horizontal, CookStyle.screenHPad)
    }
  }

  // MARK: Shop

  private var shopWorkspace: some View {
    VStack(alignment: .leading, spacing: 18) {
      shoppingOverview
      if shoppingNeeds.isEmpty {
        CookEmptyState(
          icon: "checkmark.circle.fill", title: "The week is covered",
          message: "Inventory already covers the ingredients in the current plan.",
          ctaTitle: "Review Plan"
        ) {
          selectedMode = .plan
        }
      } else {
        VStack(alignment: .leading, spacing: 10) {
          sectionHeader("Need to buy", trailing: "Quantities are combined across meals")
          LazyVStack(spacing: 9) {
            ForEach(shoppingNeeds) { need in shoppingNeedRow(need) }
          }
          .padding(.horizontal, CookStyle.screenHPad)
        }
      }
      shopConflictCard
    }
  }

  private var shoppingOverview: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Shopping Overview").font(.system(size: 18, weight: .bold, design: .serif))
            .foregroundStyle(session.themeTextColor)
          Text(
            "\(shoppingNeeds.count) items needed across \(Set(shoppingNeeds.flatMap(\.mealTitles)).count) planned meals"
          )
          .font(.system(size: 11.5)).foregroundStyle(session.themeTextColor.opacity(0.48))
        }
        Spacer()
        Button {
          addAllShoppingNeeds()
        } label: {
          Label("Add All", systemImage: "cart.badge.plus")
            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.stockedWhite)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.stockedCharcoal, in: Capsule())
        }
        .buttonStyle(.plain).disabled(shoppingNeeds.isEmpty).opacity(
          shoppingNeeds.isEmpty ? 0.4 : 1)
      }
      if !shoppingNeeds.isEmpty {
        Text(
          "Stocked combines shortages, avoids duplicate grocery rows, and keeps every meal that needs the item attached."
        )
        .font(.system(size: 11.5)).foregroundStyle(session.themeTextColor.opacity(0.5)).fixedSize(
          horizontal: false, vertical: true)
      }
    }
    .padding(15)
    .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: CookStyle.cardCorner))
    .padding(.horizontal, CookStyle.screenHPad)
  }

  private func shoppingNeedRow(_ need: CookLaterShoppingNeed) -> some View {
    let amount = shoppingOverrides[need.id] ?? need.amount
    let substitutions = CookLaterCrossCheckEngine.substitutions(
      for: need.name, inventory: store.inventoryItems)
    return VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 11) {
        AsyncFoodImage(name: need.name, url: nil, size: 46).clipShape(
          RoundedRectangle(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 2) {
          Text(need.name.displayNormalized).font(.system(size: 14, weight: .semibold))
            .foregroundStyle(session.themeTextColor)
          Text(need.shortageReason).font(.system(size: 10.5)).foregroundStyle(
            session.themeTextColor.opacity(0.45)
          ).lineLimit(1)
          if !need.sizeText.isEmpty {
            Text("Short by about \(need.sizeText)").font(.system(size: 10.5, weight: .medium))
              .foregroundStyle(Color.stockedError)
          }
        }
        Spacer()
        HStack(spacing: 10) {
          Button {
            shoppingOverrides[need.id] = max(1, amount - 1)
          } label: {
            Image(systemName: "minus").frame(width: 26, height: 26).background(
              session.themeTextColor.opacity(0.06), in: Circle())
          }
          Text(amount.rounded(toPlaces: 1).clean).font(.system(size: 12.5, weight: .semibold))
            .frame(minWidth: 20)
          Button {
            shoppingOverrides[need.id] = amount + 1
          } label: {
            Image(systemName: "plus").frame(width: 26, height: 26).background(
              session.themeTextColor.opacity(0.06), in: Circle())
          }
        }
        .font(.system(size: 10, weight: .bold)).foregroundStyle(session.themeTextColor)
        .buttonStyle(.plain)
      }
      if !substitutions.isEmpty {
        Button {
          activeSheet = .substitutions(need)
        } label: {
          HStack {
            Image(
              systemName: substitutions.contains(where: \.isAvailable)
                ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
            Text(
              substitutions.contains(where: \.isAvailable)
                ? "You already have a possible substitute" : "Find a substitute"
            )
            .font(.system(size: 11.5, weight: .semibold))
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
          }
          .foregroundStyle(
            substitutions.contains(where: \.isAvailable) ? Color.stockedGreen : Color.stockedGold)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(13)
    .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 14))
  }

  private var shopConflictCard: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 10) {
        Image(
          systemName: conflictCount == 0 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
        )
        .font(.system(size: 17, weight: .semibold)).foregroundStyle(
          conflictCount == 0 ? Color.stockedGreen : Color.orange)
        VStack(alignment: .leading, spacing: 2) {
          Text(
            conflictCount == 0
              ? "No quantity conflicts"
              : "\(conflictCount) planning conflict\(conflictCount == 1 ? "" : "s")"
          )
          .font(.system(size: 14, weight: .semibold)).foregroundStyle(session.themeTextColor)
          Text(
            conflictCount == 0
              ? "Planned meals do not over-allocate what is currently on hand."
              : "One or more ingredients are promised to multiple meals beyond the amount available."
          )
          .font(.system(size: 11.5)).foregroundStyle(session.themeTextColor.opacity(0.48))
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(14).background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 14))
    .padding(.horizontal, CookStyle.screenHPad)
  }

  // MARK: Prep

  private var prepWorkspace: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Upcoming Prep").font(.system(size: 18, weight: .bold, design: .serif))
          .foregroundStyle(session.themeTextColor)
        Text(
          "Auto-generated from meal dates, freezer items, and ingredients that can be prepared together."
        )
        .font(.system(size: 11.5)).foregroundStyle(session.themeTextColor.opacity(0.48)).fixedSize(
          horizontal: false, vertical: true)
      }
      .padding(.horizontal, CookStyle.screenHPad)

      if prepActions.isEmpty {
        CookEmptyState(
          icon: "checklist", title: "Nothing to prep yet",
          message:
            "Add meals and Stocked will create thawing, chopping, marinating, and batch-prep actions.",
          ctaTitle: "Plan a Meal"
        ) {
          selectedMode = .plan
          activeSheet = .addMeal(day: selectedDay, mealType: "Dinner")
        }
      } else {
        ForEach(Array(Dictionary(grouping: prepActions, by: \.dayIndex).keys.sorted()), id: \.self)
        { day in
          VStack(alignment: .leading, spacing: 9) {
            sectionHeader(
              CookLaterPlanningEngine.dayLabel(day),
              trailing: CookLaterPlanningEngine.dateLabel(day))
            VStack(spacing: 8) {
              ForEach(prepActions.filter { $0.dayIndex == day }) { action in prepActionRow(action) }
            }
            .padding(.horizontal, CookStyle.screenHPad)
          }
        }
      }
    }
  }

  private func prepActionRow(_ action: CookLaterPrepAction) -> some View {
    let done = completedPrepKeys.contains(action.id)
    return HStack(spacing: 11) {
      ZStack {
        Circle().fill(done ? Color.stockedGreen.opacity(0.14) : Color.stockedGold.opacity(0.14))
          .frame(width: 42, height: 42)
        Image(systemName: done ? "checkmark" : action.systemImage).font(
          .system(size: 15, weight: .semibold)
        ).foregroundStyle(done ? Color.stockedGreen : Color.stockedGold)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(action.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(
          session.themeTextColor
        ).strikethrough(done)
        Text(action.detail).font(.system(size: 10.5)).foregroundStyle(
          session.themeTextColor.opacity(0.46)
        ).lineLimit(2)
      }
      Spacer()
      Button(done ? "Undo" : "Start") {
        togglePrep(action)
      }
      .font(.system(size: 11, weight: .semibold)).foregroundStyle(
        done ? session.themeTextColor.opacity(0.5) : Color.stockedCharcoal
      )
      .padding(.horizontal, 11).padding(.vertical, 7)
      .background(
        done ? session.themeTextColor.opacity(0.06) : Color.stockedGold.opacity(0.18), in: Capsule()
      )
      .buttonStyle(.plain)
    }
    .padding(13).background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 14))
  }

  // MARK: Shared rows

  private func sectionHeader(_ title: String, trailing: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).font(.system(size: 16.5, weight: .bold, design: .serif)).foregroundStyle(
        session.themeTextColor)
      Spacer()
      Text(trailing).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(
        session.themeTextColor.opacity(0.4)
      ).lineLimit(1)
    }
    .padding(.horizontal, CookStyle.screenHPad)
  }

  private func insightRow(_ title: String, value: String, icon: String, tint: Color) -> some View {
    HStack(spacing: 11) {
      Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
        .frame(width: 27)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(
          session.themeTextColor)
        Text(value).font(.system(size: 10.5)).foregroundStyle(session.themeTextColor.opacity(0.46))
      }
      Spacer()
    }
    .padding(13).background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 14))
  }

  // MARK: Actions

  private var recentMealRecipes: [UserRecipe] {
    let titles = store.plannedMeals.filter(\.isCooked).reversed().map(\.title)
    let matches = titles.compactMap { title in
      store.cookCatalog.first { FoodNameMatcher.matches($0.title, title).score >= 0.86 }
    }
    var seen = Set<UUID>()
    return matches.filter { seen.insert($0.id).inserted }.prefix(5).map { $0 }
  }

  private var sharedIngredientCount: Int {
    var counts: [String: Int] = [:]
    for name in upcomingMeals.flatMap(\.ingredients).map({
      CookLaterCrossCheckEngine.parse($0).name
    }).filter({ !$0.isEmpty }) {
      counts[FoodNameMatcher.normalized(name), default: 0] += 1
    }
    return counts.values.filter { $0 > 1 }.count
  }

  private func routeInitialContext() {
    guard let context else { return }
    if let focus = context.focusMealTitle,
      let meal = activeMeals.first(where: { FoodNameMatcher.matches($0.title, focus).score >= 0.80 }
      )
    {
      selectedDay = meal.dayIndex
    }
    if context.source == .grocery { selectedMode = .shop }
  }

  private func handleAddSource(_ source: CookLaterAddSource, day: Int, mealType: String) {
    switch source {
    case .myRecipes:
      openMyRecipes(day: day)
    case .inventory:
      openInventoryBasedRecipes(day: day)
    case .useSomethingUp:
      useSomethingUp(day: day)
    case .online:
      activeSheet = .onlinePicker(day: day)
    case .custom:
      activeSheet = .editor(
        CookLaterPlanDraft(dayIndex: day, mealType: mealType, servings: householdSize))
    case .recent(let recipe):
      activeSheet = .editor(draft(for: recipe, day: day, mealType: mealType))
    }
  }

  private func draft(for recipe: UserRecipe, day: Int, mealType: String = "Dinner")
    -> CookLaterPlanDraft
  {
    CookLaterPlanDraft(
      dayIndex: day,
      title: recipe.title,
      mealType: mealType,
      servings: max(householdSize, recipe.servings),
      ingredients: recipe.ingredients.map { ingredient in
        let amount = ingredient.amount.trimmingCharacters(in: .whitespacesAndNewlines)
        return amount.isEmpty ? ingredient.name : "\(amount) \(ingredient.name)"
      }
    )
  }

  private func save(_ draft: CookLaterPlanDraft) {
    let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    let ingredients = draft.ingredients.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    var meal = PlannedMeal(
      id: draft.replacingMealID ?? UUID(),
      dayIndex: min(max(0, draft.dayIndex), 6),
      title: title,
      servings: max(1, draft.servings),
      ingredients: ingredients,
      mealType: draft.mealType,
      isCooked: false,
      isBuilding: false,
      updatedAt: Date().timeIntervalSince1970 * 1000,
      lastWriterID: ""
    )
    if let id = draft.replacingMealID,
      let index = store.plannedMeals.firstIndex(where: { $0.id == id })
    {
      meal.isCooked = store.plannedMeals[index].isCooked
      store.plannedMeals[index] = meal
      showToast("Updated \(title)")
    } else {
      store.plannedMeals.append(meal)
      showToast("Added \(title) to \(CookLaterPlanningEngine.dayLabel(meal.dayIndex))")
    }
    selectedDay = meal.dayIndex
    if draft.addMissingToGrocery {
      let checks = CookLaterCrossCheckEngine.checks(
        for: meal, allMeals: upcomingMeals, inventory: store.inventoryItems)
      addChecksToGrocery(checks.filter { $0.state != .onHand }, meal.title)
    }
    onPlanCompleted?()
    HapticManager.success()
  }

  private func addChecksToGrocery(_ checks: [CookLaterIngredientCheck], _ mealTitle: String) {
    for check in checks where check.state != .onHand {
      store.addToGroceryIfMissing(check.name, recommended: true, recipeSource: mealTitle)
    }
    selectedMode = .shop
    showToast(
      "Added \(checks.filter { $0.state != .onHand }.count) shortage\(checks.filter { $0.state != .onHand }.count == 1 ? "" : "s") to Grocery"
    )
  }

  private func addAllShoppingNeeds() {
    var list = store.groceryItems
    for need in shoppingNeeds {
      let amount = shoppingOverrides[need.id] ?? need.amount
      let key = FoodNameMatcher.normalized(need.name)
      if let index = list.firstIndex(where: { FoodNameMatcher.normalized($0.name) == key }) {
        list[index].quantity = max(list[index].quantity, Int(amount.rounded(.up)))
        if list[index].sizeText.isEmpty { list[index].sizeText = need.sizeText }
        if list[index].recipeSource.isEmpty {
          list[index].recipeSource = need.mealTitles.joined(separator: ", ")
        }
      } else {
        var item = LocalGroceryItem(
          name: need.name,
          isChecked: false,
          isRecommended: true,
          recipeSource: need.mealTitles.joined(separator: ", ")
        )
        item.quantity = max(1, Int(amount.rounded(.up)))
        item.sizeText = need.sizeText
        list.append(item)
      }
    }
    store.groceryItems = list
    showToast("Added the week’s shortages to Grocery")
    HapticManager.success()
  }

  private func applySubstitution(
    _ option: CookLaterSubstitution, replacing need: CookLaterShoppingNeed
  ) {
    let replacement = option.ingredientNames.joined(separator: " + ")
    var meals = store.plannedMeals
    var changed = 0
    for mealIndex in meals.indices where !meals[mealIndex].isCooked {
      var mealChanged = false
      for ingredientIndex in meals[mealIndex].ingredients.indices {
        let current = CookLaterCrossCheckEngine.parse(meals[mealIndex].ingredients[ingredientIndex])
          .name
        if FoodNameMatcher.matches(current, need.name).score >= 0.78 {
          meals[mealIndex].ingredients[ingredientIndex] = replacement
          mealChanged = true
        }
      }
      if mealChanged {
        meals[mealIndex].updatedAt = Date().timeIntervalSince1970 * 1000
        changed += 1
      }
    }
    guard changed > 0 else { return }
    store.plannedMeals = meals
    showToast("Applied \(option.title) to \(changed) planned meal\(changed == 1 ? "" : "s")")
  }

  private func fillEmptyDays() {
    let suggestions = CookLaterPlanningEngine.suggestedMeals(
      catalog: store.cookCatalog.filter(isCompleteRecipe),
      meals: activeMeals,
      householdSize: householdSize
    )
    guard !suggestions.isEmpty else {
      showToast("Every dinner slot already has a plan")
      return
    }
    activeSheet = .suggestions(title: "Fill Empty Dinner Days", items: suggestions)
  }

  private func applySuggestions(_ suggestions: [CookLaterSuggestedMeal]) {
    guard !suggestions.isEmpty else { return }
    var meals = store.plannedMeals
    let now = Date().timeIntervalSince1970 * 1000
    for suggestion in suggestions {
      meals.append(
        PlannedMeal(
          dayIndex: suggestion.dayIndex,
          title: suggestion.title,
          servings: suggestion.servings,
          ingredients: suggestion.ingredients,
          mealType: suggestion.mealType,
          updatedAt: now
        ))
    }
    store.plannedMeals = meals
    activeSheet = nil
    showToast("Added \(suggestions.count) meal\(suggestions.count == 1 ? "" : "s") to the week")
    onPlanCompleted?()
    HapticManager.success()
  }

  private func useSomethingUp(day: Int? = nil) {
    let targetDay = day ?? selectedDay
    let recipes = store.recipesUsingExpiringItems(
      within: KitchenThresholds.expiringSoonDays, limit: 12)
    if !recipes.isEmpty {
      activeSheet = .recipePicker(day: targetDay, title: "Use Something Up", recipes: recipes)
    } else if let item = store.expiringSoonItems.first {
      activeSheet = .editor(
        CookLaterPlanDraft(dayIndex: targetDay, servings: householdSize, ingredients: [item.name]))
    } else {
      showToast("Nothing is expiring soon")
    }
  }

  private func openInventoryBasedRecipes(day: Int? = nil) {
    let targetDay = day ?? selectedDay
    let recipes = store.cookCatalog.filter(isCompleteRecipe).sorted { lhs, rhs in
      let lm = store.stockMatch(for: lhs)
      let rm = store.stockMatch(for: rhs)
      let l = lm.total == 0 ? 0 : Double(lm.have) / Double(lm.total)
      let r = rm.total == 0 ? 0 : Double(rm.have) / Double(rm.total)
      return l == r ? lhs.title < rhs.title : l > r
    }
    activeSheet = .recipePicker(
      day: targetDay, title: "Based on Inventory", recipes: Array(recipes.prefix(30)))
  }

  private func isCompleteRecipe(_ recipe: UserRecipe) -> Bool {
    let title = OnlineRecipeFacts.normalizedTitle(recipe.title)
    let generic: Set<String> = ["dinner", "lunch", "breakfast", "meal", "recipe", "food"]
    return !generic.contains(title) && recipe.ingredients.count >= 3 &&
      OnlineRecipeFacts.hasRealInstructions(recipe.instructions.joined(separator: "\n"))
  }

  private func openMyRecipes(day: Int) {
    activeSheet = .recipePicker(
      day: day, title: "From My Recipes",
      recipes: store.userRecipes.isEmpty ? store.cookCatalog : store.userRecipes)
  }

  private func openRecipesUsing(_ ingredient: String) {
    let recipes = store.cookCatalog.filter { recipe in
      recipe.ingredients.contains { FoodNameMatcher.matches($0.name, ingredient).score >= 0.72 }
    }
    if recipes.isEmpty {
      activeSheet = .editor(
        CookLaterPlanDraft(
          dayIndex: selectedDay, servings: householdSize, ingredients: [ingredient]))
    } else {
      activeSheet = .recipePicker(
        day: selectedDay, title: "Plan with \(ingredient.displayNormalized)", recipes: recipes)
    }
  }

  private func repeatFavorites() {
    let recipes = store.cookCatalog.filter { $0.isFavorited || $0.cookCount > 0 }
    guard !recipes.isEmpty else {
      showToast("Cook or favorite recipes first")
      return
    }
    activeSheet = .recipePicker(day: selectedDay, title: "Household Favorites", recipes: recipes)
  }

  private func toggleCooked(_ meal: PlannedMeal) {
    guard let index = store.plannedMeals.firstIndex(where: { $0.id == meal.id }) else { return }
    store.plannedMeals[index].isCooked.toggle()
    // Improvement #11 — this path never touched inventory, so cooking from Cook Later left the
    // ingredients on the shelf indefinitely. Offer the deductions (and leftovers) in one step.
    if store.plannedMeals[index].isCooked {
      if CookConsumption.hasProposals(for: meal, store: store) {
        cookedMeal = meal
      } else {
        store.addLeftover(named: meal.title, servings: meal.servings)
      }
    }
    HapticManager.success()
  }

  private func move(_ meal: PlannedMeal, to day: Int) {
    guard let index = store.plannedMeals.firstIndex(where: { $0.id == meal.id }) else { return }
    store.plannedMeals[index].dayIndex = day
    store.plannedMeals[index].updatedAt = Date().timeIntervalSince1970 * 1000
    selectedDay = day
    showToast("Moved \(meal.title) to \(CookLaterPlanningEngine.dayLabel(day))")
  }

  private func remove(_ meal: PlannedMeal) {
    store.plannedMeals.removeAll { $0.id == meal.id }
    completedPrepKeys = completedPrepKeys.filter { !$0.contains(meal.id.uuidString) }
    CookLaterPrepCompletionStore.save(completedPrepKeys)
    showToast("Removed \(meal.title)")
  }

  private func togglePrep(_ action: CookLaterPrepAction) {
    if completedPrepKeys.contains(action.id) {
      completedPrepKeys.remove(action.id)
    } else {
      completedPrepKeys.insert(action.id)
    }
    CookLaterPrepCompletionStore.save(completedPrepKeys)
    HapticManager.select()
  }

  private func matchingContextInventory(_ name: String) -> LocalInventoryItem? {
    store.inventoryItems.max { lhs, rhs in
      FoodNameMatcher.matches(name, lhs.name).score < FoodNameMatcher.matches(name, rhs.name).score
    }.flatMap { FoodNameMatcher.matches(name, $0.name).score >= 0.72 ? $0 : nil }
  }

  private func contextPresentation(_ context: CookLaterContext) -> (
    eyebrow: String, title: String, detail: String, icon: String, tint: Color
  ) {
    switch context.source {
    case .inventory:
      return (
        "From Inventory", context.title, context.detail, "shippingbox.fill", Color.stockedGreen
      )
    case .recipe:
      return ("From Recipes", context.title, context.detail, "book.closed.fill", Color.stockedGold)
    case .grocery:
      return ("From Grocery", context.title, context.detail, "cart.fill", Color.stockedInfo)
    case .notification:
      return (
        "Weekly reminder", "Review the household plan", "Check readiness, shortages, and prep.",
        "bell.badge.fill", Color.orange
      )
    case .cook:
      return (
        "Cook Later", "Plan the next meal", "Choose a day and keep the week moving.", "calendar",
        Color.stockedGold
      )
    }
  }

  private func mealOrder(_ type: String) -> Int {
    CookLaterPlanningEngine.mealTypes.firstIndex(of: type) ?? 99
  }

  private func parsedServings(_ raw: String) -> Int {
    raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first ?? householdSize
  }

  private func showToast(_ message: String) {
    withAnimation { toast = message }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      withAnimation { if toast == message { toast = nil } }
    }
  }
}

// MARK: - Add meal source sheet

private enum CookLaterAddSource {
  case myRecipes
  case inventory
  case useSomethingUp
  case online
  case custom
  case recent(UserRecipe)
}

private struct CookLaterAddMealSourceSheet: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  let dayIndex: Int
  let mealType: String
  let recentMeals: [UserRecipe]
  let onSelectSource: (CookLaterAddSource, Int, String) -> Void

  var body: some View {
    NavigationStack {
      ZStack {
        session.themeBgColor.ignoresSafeArea()
        ScrollView(showsIndicators: false) {
          VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 3) {
              Text("Plan \(mealType)").font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
              Text(
                "\(CookLaterPlanningEngine.dayLabel(dayIndex)), \(CookLaterPlanningEngine.dateLabel(dayIndex))"
              )
              .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.48))
            }
            .frame(maxWidth: .infinity)

            Text("Choose a meal").font(.system(size: 15, weight: .bold, design: .serif))
              .foregroundStyle(session.themeTextColor)
            sourceRow(
              "From My Recipes", detail: "Use your saved recipes", icon: "bookmark.fill",
              tint: Color.stockedGold, source: .myRecipes)
            sourceRow(
              "Based on My Inventory", detail: "See what you can make", icon: "shippingbox.fill",
              tint: Color.stockedGreen, source: .inventory)
            sourceRow(
              "Use Something Up", detail: "Pick ingredients to build a meal", icon: "flame.fill",
              tint: Color.orange, source: .useSomethingUp)
            sourceRow(
              "Online Suggestions", detail: "Discover complete cached recipes",
              icon: "lightbulb.fill", tint: Color.stockedInfo, source: .online)
            sourceRow(
              "Add My Own Meal", detail: "Create a custom meal", icon: "plus.circle.fill",
              tint: Color.stockedGold, source: .custom)

            if !recentMeals.isEmpty {
              Text("Recent Meals").font(.system(size: 15, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor).padding(.top, 8)
              ForEach(recentMeals) { recipe in
                Button {
                  dismiss()
                  Task { @MainActor in onSelectSource(.recent(recipe), dayIndex, mealType) }
                } label: {
                  HStack(spacing: 11) {
                    AsyncFoodImage(name: recipe.title, url: recipe.imageURL, size: 48).clipShape(
                      RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                      Text(recipe.title).font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                      Text(
                        recipe.lastCooked.map {
                          "Cooked \($0.formatted(date: .abbreviated, time: .omitted))"
                        } ?? "Cook again"
                      )
                      .font(.system(size: 10.5)).foregroundStyle(
                        session.themeTextColor.opacity(0.46))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                      .foregroundStyle(session.themeTextColor.opacity(0.28))
                  }
                  .padding(12).background(
                    session.themeCardColor, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
              }
            }
          }
          .padding(20).padding(.bottom, 24)
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }.foregroundStyle(Color.stockedGold)
        }
      }
    }
    .presentationDetents([.large])
  }

  private func sourceRow(
    _ title: String, detail: String, icon: String, tint: Color, source: CookLaterAddSource
  ) -> some View {
    Button {
      dismiss()
      Task { @MainActor in onSelectSource(source, dayIndex, mealType) }
    } label: {
      HStack(spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.13)).frame(width: 42, height: 42)
          Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(
            session.themeTextColor)
          Text(detail).font(.system(size: 10.5)).foregroundStyle(
            session.themeTextColor.opacity(0.46))
        }
        Spacer()
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(
          session.themeTextColor.opacity(0.28))
      }
      .padding(12).background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Editor

private struct CookLaterCommandEditorSheet: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State var draft: CookLaterPlanDraft
  let onSave: (CookLaterPlanDraft) -> Void
  @State private var ingredientText = ""

  var body: some View {
    NavigationStack {
      ZStack {
        session.themeBgColor.ignoresSafeArea()
        ScrollView(showsIndicators: false) {
          VStack(alignment: .leading, spacing: 16) {
            TextField("Meal name", text: $draft.title)
              .font(.system(size: 18, weight: .semibold, design: .serif)).padding(14)
              .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 13))
            Picker("Day", selection: $draft.dayIndex) {
              ForEach(0..<7, id: \.self) { day in
                Text(
                  "\(CookLaterPlanningEngine.dayLabel(day)) · \(CookLaterPlanningEngine.dateLabel(day))"
                ).tag(day)
              }
            }
            .pickerStyle(.menu).tint(Color.stockedGold)
            Picker("Meal", selection: $draft.mealType) {
              ForEach(CookLaterPlanningEngine.mealTypes, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            Stepper("Servings: \(draft.servings)", value: $draft.servings, in: 1...24)
              .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(session.themeTextColor)
              .padding(13).background(
                session.themeCardColor, in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 9) {
              Text("Ingredients").font(.system(size: 15, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
              ForEach(Array(draft.ingredients.enumerated()), id: \.offset) { index, ingredient in
                HStack {
                  Text(ingredient).font(.system(size: 12.5)).foregroundStyle(session.themeTextColor)
                  Spacer()
                  Button {
                    draft.ingredients.remove(at: index)
                  } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(
                      session.themeTextColor.opacity(0.28))
                  }
                }
                .padding(11).background(
                  session.themeCardColor, in: RoundedRectangle(cornerRadius: 11))
              }
              HStack {
                TextField("e.g. 2 cups rice", text: $ingredientText)
                Button("Add") {
                  let value = ingredientText.trimmingCharacters(in: .whitespacesAndNewlines)
                  guard !value.isEmpty else { return }
                  draft.ingredients.append(value)
                  ingredientText = ""
                }
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.stockedGold)
              }
              .padding(12).background(
                session.themeCardColor, in: RoundedRectangle(cornerRadius: 12))
            }
            Toggle("Add shortages to Grocery after saving", isOn: $draft.addMissingToGrocery)
              .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(session.themeTextColor)
              .tint(Color.stockedGold)
              .padding(13).background(
                session.themeCardColor, in: RoundedRectangle(cornerRadius: 13))
          }
          .padding(20).padding(.bottom, 28)
        }
      }
      .navigationTitle(draft.replacingMealID == nil ? "Plan Meal" : "Edit Meal")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }.foregroundStyle(Color.stockedGold)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Save") {
            onSave(draft)
            dismiss()
          }
          .fontWeight(.semibold).foregroundStyle(Color.stockedGold)
          .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .presentationDetents([.large])
  }
}

// MARK: - Recipe pickers

private struct CookLaterCommandRecipePicker: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  let title: String
  let dayIndex: Int
  let recipes: [UserRecipe]
  let onSelect: (UserRecipe) -> Void
  @State private var searchText = ""

  private var filtered: [UserRecipe] {
    let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return recipes }
    return recipes.filter { recipe in
      recipe.title.localizedCaseInsensitiveContains(q)
        || recipe.ingredients.contains { $0.name.localizedCaseInsensitiveContains(q) }
    }
  }

  var body: some View {
    NavigationStack {
      ZStack {
        session.themeBgColor.ignoresSafeArea()
        ScrollView(showsIndicators: false) {
          LazyVStack(spacing: 9) {
            ForEach(filtered) { recipe in
              Button {
                dismiss()
                Task { @MainActor in onSelect(recipe) }
              } label: {
                HStack(spacing: 11) {
                  UniformRecipeIcon(size: 52)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(recipe.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(
                      session.themeTextColor
                    ).lineLimit(1)
                    let match = session.guestStore.stockMatch(for: recipe)
                    Text("\(match.have) of \(match.total) ingredients stocked")
                      .font(.system(size: 10.5)).foregroundStyle(
                        match.total > 0 && match.have == match.total
                          ? Color.stockedGreen : session.themeTextColor.opacity(0.46))
                  }
                  Spacer()
                  Image(systemName: "calendar.badge.plus").foregroundStyle(Color.stockedGold)
                }
                .padding(12).background(
                  session.themeCardColor, in: RoundedRectangle(cornerRadius: 14))
              }
              .buttonStyle(.plain)
            }
          }
          .padding(20).padding(.bottom, 24)
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, prompt: "Search recipes or ingredients")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }.foregroundStyle(Color.stockedGold)
        }
      }
    }
    .presentationDetents([.large])
  }
}

private struct CookLaterWebRecipePicker: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  let dayIndex: Int
  let recipes: [WebRecipe]
  let onSelect: (WebRecipe) -> Void
  @State private var searchText = ""

  private var filtered: [WebRecipe] {
    let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return recipes }
    return recipes.filter {
      $0.title.localizedCaseInsensitiveContains(q)
        || $0.ingredients.contains { $0.localizedCaseInsensitiveContains(q) }
    }
  }

  var body: some View {
    NavigationStack {
      ZStack {
        session.themeBgColor.ignoresSafeArea()
        if filtered.isEmpty {
          ContentUnavailableView(
            "No complete online recipes cached", systemImage: "wifi.slash",
            description: Text("Open Recipes once to refresh qualified sources, then return here.")
          )
          .foregroundStyle(session.themeTextColor)
        } else {
          ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 9) {
              ForEach(filtered.prefix(80)) { recipe in
                Button {
                  dismiss()
                  Task { @MainActor in onSelect(recipe) }
                } label: {
                  HStack(spacing: 11) {
                    AsyncFoodImage(name: recipe.title, url: recipe.imageURL, size: 52).clipShape(
                      RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                      Text(recipe.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(
                        session.themeTextColor
                      ).lineLimit(1)
                      Text("\(recipe.sourceName) · \(recipe.ingredients.count) ingredients")
                        .font(.system(size: 10.5)).foregroundStyle(
                          session.themeTextColor.opacity(0.46))
                    }
                    Spacer()
                    Image(systemName: "calendar.badge.plus").foregroundStyle(Color.stockedGold)
                  }
                  .padding(12).background(
                    session.themeCardColor, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
              }
            }
            .padding(20).padding(.bottom, 24)
          }
        }
      }
      .navigationTitle("Online Suggestions")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, prompt: "Search complete recipes")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }.foregroundStyle(Color.stockedGold)
        }
      }
    }
    .presentationDetents([.large])
  }
}

// MARK: - Meal details and ingredient check

private struct CookLaterMealDetailSheet: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  let meal: PlannedMeal
  let allMeals: [PlannedMeal]
  let inventory: [LocalInventoryItem]
  let onSave: (CookLaterPlanDraft) -> Void
  let onAddMissing: ([CookLaterIngredientCheck], String) -> Void
  @State private var servings: Int
  @State private var editorDraft: CookLaterPlanDraft?

  init(
    meal: PlannedMeal,
    allMeals: [PlannedMeal],
    inventory: [LocalInventoryItem],
    onSave: @escaping (CookLaterPlanDraft) -> Void,
    onAddMissing: @escaping ([CookLaterIngredientCheck], String) -> Void
  ) {
    self.meal = meal
    self.allMeals = allMeals
    self.inventory = inventory
    self.onSave = onSave
    self.onAddMissing = onAddMissing
    _servings = State(initialValue: meal.servings)
  }

  private var checks: [CookLaterIngredientCheck] {
    CookLaterCrossCheckEngine.checks(for: meal, allMeals: allMeals, inventory: inventory)
  }
  private var missing: [CookLaterIngredientCheck] { checks.filter { $0.state != .onHand } }

  var body: some View {
    NavigationStack {
      ZStack {
        session.themeBgColor.ignoresSafeArea()
        ScrollView(showsIndicators: false) {
          VStack(alignment: .leading, spacing: 16) {
            AsyncFoodImage(name: meal.title, url: nil, size: 420)
              .frame(maxWidth: .infinity).frame(height: 190).clipped().clipShape(
                RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 3) {
              Text(meal.title).font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
              Text(
                "\(CookLaterPlanningEngine.dayLabel(meal.dayIndex)), \(CookLaterPlanningEngine.dateLabel(meal.dayIndex)) · \(meal.mealType)"
              )
              .font(.system(size: 11.5)).foregroundStyle(session.themeTextColor.opacity(0.48))
            }

            HStack {
              Text("Servings").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(
                session.themeTextColor)
              Spacer()
              Button {
                servings = max(1, servings - 1)
              } label: {
                Image(systemName: "minus").frame(width: 28, height: 28).background(
                  session.themeCardColor, in: Circle())
              }
              Text("\(servings)").font(.system(size: 13.5, weight: .semibold)).frame(width: 28)
              Button {
                servings = min(24, servings + 1)
              } label: {
                Image(systemName: "plus").frame(width: 28, height: 28).background(
                  session.themeCardColor, in: Circle())
              }
            }
            .foregroundStyle(session.themeTextColor).buttonStyle(.plain)

            Text("Ingredient Check").font(.system(size: 17, weight: .bold, design: .serif))
              .foregroundStyle(session.themeTextColor)
            HStack(spacing: 8) {
              stateSummary(.onHand, count: checks.filter { $0.state == .onHand }.count)
              stateSummary(.needed, count: checks.filter { $0.state == .needed }.count)
              stateSummary(.runningLow, count: checks.filter { $0.state == .runningLow }.count)
            }

            LazyVStack(spacing: 8) {
              ForEach(checks) { check in ingredientCheckRow(check) }
            }

            let conflicts = checks.filter { !$0.competingMeals.isEmpty && $0.state != .onHand }
            if !conflicts.isEmpty {
              VStack(alignment: .leading, spacing: 7) {
                Label("Planning Impact", systemImage: "exclamationmark.triangle.fill")
                  .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.orange)
                ForEach(conflicts) { check in
                  Text(
                    "You also planned \(check.competingMeals.joined(separator: ", ")) with \(check.name.displayNormalized)."
                  )
                  .font(.system(size: 11.5)).foregroundStyle(session.themeTextColor.opacity(0.55))
                }
              }
              .padding(13).background(
                Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
            }

            Button {
              editorDraft = CookLaterPlanDraft(meal: meal)
            } label: {
              Text("Adjust Quantity or Ingredients")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(session.themeTextColor)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .overlay(
                  RoundedRectangle(cornerRadius: 12).stroke(session.themeTextColor.opacity(0.18)))
            }
            .buttonStyle(.plain)
            Button {
              onAddMissing(missing, meal.title)
              dismiss()
            } label: {
              Text(missing.isEmpty ? "No Shortages to Add" : "Add Shortages to Grocery List")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(session.themeTextColor)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .overlay(
                  RoundedRectangle(cornerRadius: 12).stroke(session.themeTextColor.opacity(0.18)))
            }
            .buttonStyle(.plain).disabled(missing.isEmpty).opacity(missing.isEmpty ? 0.45 : 1)
            Button {
              var draft = CookLaterPlanDraft(meal: meal)
              draft.servings = servings
              onSave(draft)
              dismiss()
            } label: {
              Text("Save Meal Plan")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.stockedWhite)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Color.stockedCharcoal, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
          }
          .padding(20).padding(.bottom, 28)
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close") { dismiss() }.foregroundStyle(Color.stockedGold)
        }
      }
    }
    .sheet(item: $editorDraft) { draft in
      CookLaterCommandEditorSheet(draft: draft) { saved in
        onSave(saved)
        dismiss()
      }
      .environment(session)
    }
    .presentationDetents([.large])
  }

  private func stateSummary(_ state: CookLaterIngredientState, count: Int) -> some View {
    let tint: Color =
      state == .onHand
      ? Color.stockedGreen : state == .needed ? Color.stockedError : Color.stockedGold
    return VStack(spacing: 2) {
      Text("\(count)").font(.system(size: 18, weight: .bold, design: .serif)).foregroundStyle(tint)
      Text(state.title).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(
        session.themeTextColor.opacity(0.52))
    }
    .frame(maxWidth: .infinity).padding(.vertical, 10)
    .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.18)))
  }

  private func ingredientCheckRow(_ check: CookLaterIngredientCheck) -> some View {
    let tint: Color =
      check.state == .onHand
      ? Color.stockedGreen : check.state == .needed ? Color.stockedError : Color.stockedGold
    return HStack(spacing: 10) {
      ZStack {
        Circle().fill(tint.opacity(0.12)).frame(width: 36, height: 36)
        Image(
          systemName: check.state == .onHand
            ? "checkmark" : check.state == .needed ? "cart.badge.plus" : "exclamationmark"
        )
        .font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(check.name.displayNormalized).font(.system(size: 13.5, weight: .semibold))
          .foregroundStyle(session.themeTextColor)
        Text(
          check.requestedDisplay.isEmpty
            ? check.state.title : "Need \(check.requestedDisplay) · have \(check.availableDisplay)"
        )
        .font(.system(size: 10.5)).foregroundStyle(session.themeTextColor.opacity(0.46))
      }
      Spacer()
      Text(check.state.title).font(.system(size: 9.5, weight: .bold)).foregroundStyle(tint)
    }
    .padding(11).background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 12))
  }
}

// MARK: - Substitutions

private struct CookLaterSubstitutionSheet: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  let need: CookLaterShoppingNeed
  let options: [CookLaterSubstitutionAvailability]
  let onApply: (CookLaterSubstitution) -> Void

  var body: some View {
    NavigationStack {
      ZStack {
        session.themeBgColor.ignoresSafeArea()
        ScrollView(showsIndicators: false) {
          VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
              Text(need.name.displayNormalized).font(
                .system(size: 20, weight: .bold, design: .serif)
              ).foregroundStyle(session.themeTextColor)
              Text("Missing · \(need.shortageReason)").font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.stockedError)
            }
            Text("Find a substitute").font(.system(size: 15.5, weight: .bold, design: .serif))
              .foregroundStyle(session.themeTextColor)
            if options.isEmpty {
              ContentUnavailableView(
                "No trusted substitute saved", systemImage: "arrow.triangle.2.circlepath",
                description: Text("Keep the original ingredient or edit the meal manually."))
            } else {
              ForEach(options) { availability in
                let option = availability.substitution
                let have = availability.isAvailable
                Button {
                  onApply(option)
                  dismiss()
                } label: {
                  HStack(spacing: 11) {
                    ZStack {
                      RoundedRectangle(cornerRadius: 9).fill(
                        (have ? Color.stockedGreen : Color.stockedGold).opacity(0.12)
                      ).frame(width: 42, height: 42)
                      Image(
                        systemName: have ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
                      )
                      .font(.system(size: 15, weight: .semibold)).foregroundStyle(
                        have ? Color.stockedGreen : Color.stockedGold)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                      Text(option.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(
                        session.themeTextColor)
                      Text(option.detail).font(.system(size: 10.5)).foregroundStyle(
                        session.themeTextColor.opacity(0.48)
                      ).fixedSize(horizontal: false, vertical: true)
                      if have {
                        Text("You already have this!").font(.system(size: 10, weight: .bold))
                          .foregroundStyle(Color.stockedGreen)
                      }
                    }
                    Spacer()
                    Text("Use").font(.system(size: 11, weight: .semibold)).foregroundStyle(
                      session.themeTextColor
                    )
                    .padding(.horizontal, 10).padding(.vertical, 6).background(
                      session.themeTextColor.opacity(0.06), in: Capsule())
                  }
                  .padding(12).background(
                    session.themeCardColor, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
              }
            }
          }
          .padding(20).padding(.bottom, 24)
        }
      }
      .navigationTitle("Substitutions")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }.foregroundStyle(Color.stockedGold)
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

// MARK: - Smart-plan confirmation

private struct CookLaterCommandSuggestionsSheet: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  let title: String
  let suggestions: [CookLaterSuggestedMeal]
  let onApply: ([CookLaterSuggestedMeal]) -> Void
  @State private var selectedIDs: Set<UUID>

  init(
    title: String, suggestions: [CookLaterSuggestedMeal],
    onApply: @escaping ([CookLaterSuggestedMeal]) -> Void
  ) {
    self.title = title
    self.suggestions = suggestions
    self.onApply = onApply
    _selectedIDs = State(initialValue: Set(suggestions.map(\.id)))
  }

  var body: some View {
    NavigationStack {
      ZStack {
        session.themeBgColor.ignoresSafeArea()
        VStack(spacing: 0) {
          ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 9) {
              Text("Review the proposed week. Nothing changes until you confirm.")
                .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                .padding(.bottom, 4)
              ForEach(suggestions) { suggestion in
                Button {
                  if selectedIDs.contains(suggestion.id) {
                    selectedIDs.remove(suggestion.id)
                  } else {
                    selectedIDs.insert(suggestion.id)
                  }
                } label: {
                  HStack(spacing: 11) {
                    Image(
                      systemName: selectedIDs.contains(suggestion.id)
                        ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.system(size: 19)).foregroundStyle(
                      selectedIDs.contains(suggestion.id)
                        ? Color.stockedGreen : session.themeTextColor.opacity(0.28))
                    VStack(alignment: .leading, spacing: 2) {
                      Text(suggestion.title).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                      Text(
                        "\(CookLaterPlanningEngine.dayLabel(suggestion.dayIndex)) · \(suggestion.mealType) · \(suggestion.servings) servings"
                      )
                      .font(.system(size: 10.5)).foregroundStyle(
                        session.themeTextColor.opacity(0.46))
                    }
                    Spacer()
                  }
                  .padding(13).background(
                    session.themeCardColor, in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.plain)
              }
            }
            .padding(20)
          }
          Button {
            onApply(suggestions.filter { selectedIDs.contains($0.id) })
            dismiss()
          } label: {
            Text("Apply \(selectedIDs.count) Meal\(selectedIDs.count == 1 ? "" : "s")")
              .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.stockedWhite)
              .frame(maxWidth: .infinity).padding(.vertical, 13)
              .background(
                selectedIDs.isEmpty ? Color.stockedCharcoal.opacity(0.35) : Color.stockedCharcoal,
                in: RoundedRectangle(cornerRadius: 13))
          }
          .buttonStyle(.plain).disabled(selectedIDs.isEmpty).padding(20)
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }.foregroundStyle(Color.stockedGold)
        }
      }
    }
    .presentationDetents([.large])
  }
}

// MARK: - Month calendar

private struct CookLaterMonthCalendarSheet: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  let meals: [PlannedMeal]
  let prepActions: [CookLaterPrepAction]
  let shoppingNeeds: [CookLaterShoppingNeed]
  let selectedDay: Int
  let onSelectDay: (Int) -> Void
  @State private var monthOffset = 0

  private var calendar: Calendar { Calendar.current }
  private var monthDate: Date {
    calendar.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
  }
  private var monthTitle: String { monthDate.formatted(.dateTime.month(.wide).year()) }
  private var days: [Date?] {
    guard let interval = calendar.dateInterval(of: .month, for: monthDate),
      let range = calendar.range(of: .day, in: .month, for: monthDate)
    else { return [] }
    let firstWeekday = calendar.component(.weekday, from: interval.start)
    let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
    var result = [Date?](repeating: nil, count: leading)
    for day in range {
      result.append(calendar.date(bySetting: .day, value: day, of: interval.start))
    }
    while result.count % 7 != 0 { result.append(nil) }
    return result
  }

  var body: some View {
    NavigationStack {
      ZStack {
        session.themeBgColor.ignoresSafeArea()
        ScrollView(showsIndicators: false) {
          VStack(alignment: .leading, spacing: 18) {
            HStack {
              Button {
                monthOffset -= 1
              } label: {
                Image(systemName: "chevron.left")
              }
              Spacer()
              Text(monthTitle).font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
              Spacer()
              Button {
                monthOffset += 1
              } label: {
                Image(systemName: "chevron.right")
              }
            }
            .font(.system(size: 13, weight: .bold)).foregroundStyle(session.themeTextColor)

            let symbols = calendar.shortWeekdaySymbols
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 10) {
              ForEach(symbols, id: \.self) { symbol in
                Text(String(symbol.prefix(2))).font(.system(size: 9.5, weight: .bold))
                  .foregroundStyle(session.themeTextColor.opacity(0.42))
              }
              ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                calendarDay(date)
              }
            }

            HStack(spacing: 14) {
              legend("Planned", tint: Color.stockedGold)
              legend("Cooked", tint: Color.stockedGreen)
              legend("Prep", tint: Color.purple)
              legend("Shopping", tint: Color.stockedInfo)
            }
            .frame(maxWidth: .infinity)

            if let selectedDate = calendar.date(
              byAdding: .day, value: selectedDay, to: calendar.startOfDay(for: Date()))
            {
              let mealsForDay = meals.filter { $0.dayIndex == selectedDay }
              VStack(alignment: .leading, spacing: 9) {
                Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                  .font(.system(size: 16, weight: .bold, design: .serif)).foregroundStyle(
                    session.themeTextColor)
                if mealsForDay.isEmpty {
                  Text("No meals planned.").font(.system(size: 12)).foregroundStyle(
                    session.themeTextColor.opacity(0.48))
                } else {
                  ForEach(mealsForDay) { meal in
                    HStack(spacing: 10) {
                      AsyncFoodImage(name: meal.title, url: nil, size: 46).clipShape(
                        RoundedRectangle(cornerRadius: 10))
                      VStack(alignment: .leading, spacing: 2) {
                        Text(meal.mealType).font(.system(size: 9.5, weight: .bold)).foregroundStyle(
                          Color.stockedGold)
                        Text(meal.title).font(.system(size: 13.5, weight: .semibold))
                          .foregroundStyle(session.themeTextColor)
                        Text("\(meal.ingredients.count) ingredients").font(.system(size: 10.5))
                          .foregroundStyle(session.themeTextColor.opacity(0.46))
                      }
                      Spacer()
                    }
                    .padding(11).background(
                      session.themeCardColor, in: RoundedRectangle(cornerRadius: 13))
                  }
                }
              }
            }
          }
          .padding(20).padding(.bottom, 24)
        }
      }
      .navigationTitle("Cook Later")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }.foregroundStyle(Color.stockedGold)
        }
      }
    }
    .presentationDetents([.large])
  }

  @ViewBuilder private func calendarDay(_ date: Date?) -> some View {
    if let date {
      let horizonDay = calendar.dateComponents(
        [.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)
      ).day
      let inHorizon = horizonDay.map { (0..<7).contains($0) } ?? false
      let dayMeals = horizonDay.map { day in meals.filter { $0.dayIndex == day } } ?? []
      Button {
        if let horizonDay, inHorizon { onSelectDay(horizonDay) }
      } label: {
        VStack(spacing: 4) {
          Text("\(calendar.component(.day, from: date))")
            .font(.system(size: 12, weight: horizonDay == selectedDay ? .bold : .medium))
            .foregroundStyle(
              horizonDay == selectedDay
                ? Color.stockedWhite
                : inHorizon ? session.themeTextColor : session.themeTextColor.opacity(0.32)
            )
            .frame(width: 30, height: 30)
            .background(
              horizonDay == selectedDay ? Color.stockedCharcoal : Color.clear, in: Circle())
          HStack(spacing: 2) {
            if dayMeals.contains(where: { !$0.isCooked }) {
              Circle().fill(Color.stockedGold).frame(width: 4, height: 4)
            }
            if dayMeals.contains(where: \.isCooked) {
              Circle().fill(Color.stockedGreen).frame(width: 4, height: 4)
            }
            if let horizonDay, prepActions.contains(where: { $0.dayIndex == horizonDay }) {
              Circle().fill(Color.purple).frame(width: 4, height: 4)
            }
            if let horizonDay, horizonDay == 0, !shoppingNeeds.isEmpty {
              Circle().fill(Color.stockedInfo).frame(width: 4, height: 4)
            }
          }
          .frame(height: 5)
        }
      }
      .buttonStyle(.plain).disabled(!inHorizon)
    } else {
      Color.clear.frame(height: 39)
    }
  }

  private func legend(_ title: String, tint: Color) -> some View {
    HStack(spacing: 4) {
      Circle().fill(tint).frame(width: 5, height: 5)
      Text(title).font(.system(size: 9.5)).foregroundStyle(session.themeTextColor.opacity(0.48))
    }
  }
}
