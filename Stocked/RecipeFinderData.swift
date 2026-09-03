import Foundation

nonisolated struct FinderHit: Identifiable, Sendable {
  var record: FinderRecord
  var recipe: UserRecipe
  var databaseEntry: RecipeDatabaseEntry?
  var publisherRatingCount: Int?
  var id: String { record.id }
}

nonisolated enum FinderData {
  // Only a complete explicit total, or BOTH prep and cook durations, can establish total time.
  static func minutes(_ value: String) -> Int? {
    FinderDuration.minutes(value)
  }

  static func recipe(_ entry: RecipeDatabaseEntry, parseAmounts: Bool = false) -> UserRecipe {
    var r = UserRecipe(title: entry.title)
    r.id = entry.id
    r.description = entry.description
    r.cuisine = entry.cuisine
    r.tags = entry.tags
    r.categories = [entry.category]
    r.prepTime = entry.prepTime
    r.cookTime = entry.cookTime
    r.ingredients = entry.ingredients.map { line in
      guard parseAmounts else { return RecipeIngredient(name: line, amount: "") }
      var ingredient = RecipeAdapter.ingredient(amount: "", name: line)
      let parsed = ParsedQuantity.parse(line)
      if parsed.amount > 0 { ingredient.amount = parsed.display }
      return ingredient
    }
    r.instructions = entry.steps
    r.imageURL = entry.imageURL
    r.sourceURL = entry.sourceURL
    r.sourceName = entry.sourceName
    r.servings = Int(entry.servings) ?? 4
    return r
  }

  static func record(
    _ recipe: UserRecipe, entry: RecipeDatabaseEntry?, history: [LocalPastMeal],
    inventory: [LocalInventoryItem], filters: FinderFilters
  ) -> FinderRecord {
    let norm = FinderQuery.normalize
    let metadata = recipe.tags + (recipe.categories ?? [])
    let tags = Set(
      metadata.flatMap { value in
        ([value] + value.components(separatedBy: CharacterSet(charactersIn: ",;/|")))
          .map { norm($0).replacingOccurrences(of: "-", with: " ") }
      })
    let cuisine = RecipeTaxonomy.resolvedCuisine(
      recipe.cuisine, title: recipe.title, keywords: metadata)
    let cuisineLabels = Set(
      [cuisine, RecipeTaxonomy.parentCuisine(cuisine)].compactMap { $0 }.map(norm))
    var r = FinderRecord(
      id: recipe.id.uuidString, title: recipe.title,
      searchText: norm(
        ([recipe.title, recipe.description, recipe.cuisine] + metadata
          + recipe.ingredients.map(\.name)).joined(separator: " ")))
    r.sortTitle = norm(recipe.title)
    if let entry, let total = minutes(entry.totalTime) {
      r.totalMinutes = total
    } else if let prep = minutes(recipe.prepTime), let cook = minutes(recipe.cookTime) {
      r.totalMinutes = prep + cook
    }
    r.addedAt = entry == nil ? recipe.dateCreated : nil
    r.cookCount = recipe.cookCount
    r.lastCooked = recipe.lastCooked
    let meals = history.filter { $0.recipeId == recipe.id || norm($0.title) == norm(recipe.title) }
    r.cookCount = max(r.cookCount, meals.count)
    let ratings = meals.map(\.rating).filter { (1...5).contains($0) }
    r.rating = entry?.rating
    if let rating = r.rating, !(1...5).contains(rating) { r.rating = nil }
    if !ratings.isEmpty {
      r.rating = Double(ratings.reduce(0, +)) / Double(ratings.count)
      r.ratingCount = ratings.count
    }
    let dates = meals.compactMap { meal -> Date? in
      if let date = ISO8601DateFormatter().date(from: meal.date) { return date }
      let formatter = DateFormatter()
      formatter.dateStyle = .short
      formatter.timeStyle = .none
      return formatter.date(from: meal.date)
    }
    if let latest = dates.max(), latest > (r.lastCooked ?? .distantPast) { r.lastCooked = latest }
    for category in [FinderCategory.meal, .cuisine, .mood] {
      for choice in category.options where !choice.isNeutral && !choice.isDiscovery {
        let label = norm(choice.label).replacingOccurrences(of: "-", with: " ")
        if tags.contains(label) || (category == .cuisine && cuisineLabels.contains(label)) {
          r.facets[category, default: []].insert(choice)
        }
      }
    }
    let aliases: [(String, FinderCategory, FinderChoice)] = [
      ("main dish", .meal, .dinner), ("main course", .meal, .dinner), ("beverage", .meal, .drink),
      ("side", .meal, .sideDish), ("comfort food", .mood, .comfort), ("cajun", .cuisine, .cajun),
      ("creole", .cuisine, .cajun), ("latin american", .cuisine, .latin),
      ("barbecue", .mood, .grilled),
      ("kid friendly", .mood, .familyFriendly), ("light and fresh", .mood, .lightFresh),
    ]
    for (label, category, choice) in aliases
    where tags.contains(label) || norm(recipe.cuisine) == label {
      r.facets[category, default: []].insert(choice)
    }
    let groups: [FinderChoice: [String]] = [
      .chicken: ["chicken"], .beef: ["beef", "steak"], .pork: ["pork", "bacon", "ham"],
      .turkey: ["turkey"],
      .fish: ["fish", "salmon", "tuna", "cod", "tilapia", "trout"], .shrimp: ["shrimp", "prawn"],
      .seafood: [
        "fish", "salmon", "tuna", "cod", "shrimp", "prawn", "crab", "lobster", "clam", "mussel",
        "scallop",
      ],
      .pasta: ["pasta", "spaghetti", "penne", "macaroni", "noodle", "linguine"], .rice: ["rice"],
      .vegetables: [
        "vegetable", "carrot", "broccoli", "spinach", "zucchini", "cabbage", "cauliflower",
        "eggplant", "potato", "tomato", "kale", "pea",
      ],
      .beans: ["bean", "lentil", "chickpea"], .eggs: ["egg"], .tofu: ["tofu"],
    ]
    for (choice, names) in groups
    where filters.active(.ingredient).contains(choice)
      && recipe.ingredients.contains(where: { ingredient in
        names.contains { FoodNameMatcher.containsPhrase($0, in: ingredient.name) }
      })
    { r.facets[.ingredient, default: []].insert(choice) }
    // Only explicit tags, never absence-of-meat/allergen text guesses. These options
    // express dietary metadata, NOT guarantees concerning cross-contamination.
    for choice in FinderCategory.diet.options where tags.contains(norm(choice.label)) {
      r.facets[.diet, default: []].insert(choice)
    }
    if r.facets[.diet, default: []].contains(.vegan) {
      r.facets[.diet, default: []].formUnion([.vegetarian, .pescatarian])
    }
    if r.facets[.diet, default: []].contains(.vegetarian) {
      r.facets[.diet, default: []].insert(.pescatarian)
    }
    if filters.usesInventory {
      let coverage = coverage(recipe.ingredients, inventory: inventory)
      r.required = coverage.required
      r.have = coverage.have
      r.uncertain = coverage.uncertain
    }
    return r
  }

  /// Consume a per-recipe quantity pool, so two lines cannot spend the same stock twice.
  /// Unknown amounts may count as present for 70% coverage, but never as fully ready.
  static func coverage(_ ingredients: [RecipeIngredient], inventory: [LocalInventoryItem]) -> (
    required: Int, have: Int, uncertain: Int
  ) {
    let now = Date()
    let items = KitchenAvailability.availableItems(in: inventory).filter {
      $0.quantity > 0 && ($0.expirationDate == nil || $0.expirationDate! >= now)
    }
    let stock = items.map { item -> FinderQuantityPool.Stock in
      let owned = ReservationEngine.ownedBase(of: item)
      return .init(family: owned.family, amount: owned.base)
    }
    var needs: [FinderQuantityPool.Need] = []
    for ingredient in ingredients where !ingredient.isOptional {
      let indices = items.indices.filter {
        KitchenAvailability.nameMatches(ingredient.name, items[$0].name)
      }
      guard let amount = ingredient.quantity, amount > 0 else {
        needs.append(.init(family: nil, amount: nil, matchingStock: indices))
        continue
      }
      let unit = ingredient.unit ?? ""
      let family: String
      let needed: Double
      if let f = UnitMath.family(of: unit) {
        family = f == .mass ? "weight" : "volume"
        needed = UnitMath.convert(amount, from: unit, to: f == .mass ? "g" : "ml") ?? amount
      } else if ["", "count", "each", "piece", "pieces"].contains(unit.lowercased()) {
        family = "count"
        needed = amount
      } else {
        needs.append(.init(family: nil, amount: amount, matchingStock: indices))
        continue
      }
      needs.append(.init(family: family, amount: needed, matchingStock: indices))
    }
    return FinderQuantityPool.coverage(stock: stock, needs: needs)
  }
}

nonisolated struct FinderResponse: Sendable {
  var hits: [FinderHit]
  var count: Int
  var catalogueUnavailable: Bool
  var alternatives: [FinderAlternative] = []
  var source: FinderResultSource = .database
  var matchedIdentities: Set<String> = []
}

enum FinderService {
  nonisolated static func webQuery(
    _ web: [WebRecipe], filters: FinderFilters, saved: [UserRecipe], history: [LocalPastMeal],
    inventory: [LocalInventoryItem], allergens: [String]
  ) throws -> FinderResponse {
    var hits: [FinderHit] = []
    var seen = Set<String>()
    let rules = DietaryGuard.Rules(allergens: allergens, dislikes: [])
    let cuisineCounts = Dictionary(grouping: saved, by: { FinderQuery.normalize($0.cuisine) })
      .mapValues { $0.reduce(0) { $0 + $1.cookCount } }
    for page in web {
      try Task.checkCancellation()
      let key = FinderWebPolicy.identity(page.sourceURL)
      guard seen.insert(key).inserted else { continue }
      let entry = RecipeDatabaseEntry(
        id: page.id, title: page.title, description: page.description,
        sourceURL: page.sourceURL, sourceName: page.sourceName, prepTime: page.prepTime,
        cookTime: page.cookTime, totalTime: page.totalTime, servings: page.servings,
        category: page.category, cuisine: page.cuisine, tags: page.tags,
        ingredients: page.ingredients, steps: page.steps.map(\.text), imageURL: page.imageURL,
        rating: page.rating)
      let existing = saved.first { FinderWebPolicy.identity($0.sourceURL ?? "") == key }
      let recipe = existing ?? FinderData.recipe(entry, parseAmounts: true)
      // Web cards always show inventory facts; this does not change eligibility
      // or rank unless the actual selected kitchen/sort rule asks for it.
      var coverageFilters = filters
      coverageFilters.sort = .readyToCook
      var record = FinderData.record(
        recipe, entry: entry, history: history, inventory: inventory, filters: coverageFilters)
      record.id = key
      record.cuisineCookCount = cuisineCounts[FinderQuery.normalize(recipe.cuisine), default: 0]
      record.hasAllergenConflict = !DietaryGuard.allergenHits(
        ingredientLines: recipe.ingredients.map(\.name), title: recipe.title, rules: rules
      ).isEmpty
      let publisherCount = record.ratingCount == nil ? page.ratingCount : nil
      if record.ratingCount == nil { record.ratingCount = page.ratingCount }
      guard FinderQuery.matches(record, filters: filters) else { continue }
      hits.append(
        FinderHit(
          record: record, recipe: recipe, databaseEntry: existing == nil ? entry : nil,
          publisherRatingCount: publisherCount))
    }
    hits.sort { FinderQuery.ordered($0.record, before: $1.record, filters: filters) }
    return FinderResponse(
      hits: hits, count: hits.count, catalogueUnavailable: false, source: .web,
      matchedIdentities: Set(hits.map(\.id)))
  }

  /// One globally sorted result set. Local/saved records win same-source ties;
  /// publisher attribution remains on every card, never a separate result section.
  nonisolated static func merge(
    local: FinderResponse, web: FinderResponse, filters: FinderFilters, limit: Int
  ) -> FinderResponse {
    var byID = Dictionary(web.hits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for hit in local.hits { byID[hit.id] = hit }
    let ordered = byID.values.sorted {
      FinderQuery.ordered($0.record, before: $1.record, filters: filters)
    }
    let count = FinderWebPolicy.mergedCount(
      localCount: local.count,
      localIdentities: local.matchedIdentities, webIdentities: web.matchedIdentities)
    return FinderResponse(
      hits: Array(ordered.prefix(max(1, limit))), count: count,
      catalogueUnavailable: local.catalogueUnavailable,
      alternatives: count == 0 ? local.alternatives : [],
      matchedIdentities: local.matchedIdentities.union(web.matchedIdentities))
  }

  /// No full-corpus model cache. The caller cancels obsolete work and publishes only
  /// the latest snapshot. Saved data wins deduplication; source documents stay intact.
  nonisolated static func query(
    filters: FinderFilters, saved: [UserRecipe], history: [LocalPastMeal],
    inventory: [LocalInventoryItem], allergens: [String], limit: Int,
    onProgress: (@Sendable (FinderResponse) async -> Void)? = nil
  ) async throws -> FinderResponse {
    var hits: [FinderHit] = []
    var count = 0
    var seen = Set<String>()
    var matched = Set<String>()
    var lastPreview = Date.distantPast
    var alternatives = FinderQuery.alternatives(for: filters)
    let rules = DietaryGuard.Rules(allergens: allergens, dislikes: [])
    let historyByTitle = Dictionary(grouping: history, by: { FinderQuery.normalize($0.title) })
    let cuisineCounts = Dictionary(grouping: saved, by: { FinderQuery.normalize($0.cuisine) })
      .mapValues { $0.reduce(0) { $0 + $1.cookCount } }
    func consume(_ recipe: UserRecipe, entry: RecipeDatabaseEntry?) {
      let key = FinderWebPolicy.recipeIdentity(sourceURL: recipe.sourceURL, id: recipe.id)
      guard seen.insert(key).inserted else { return }
      var record = FinderData.record(
        recipe, entry: entry,
        history: historyByTitle[FinderQuery.normalize(recipe.title), default: []],
        inventory: inventory, filters: filters)
      record.id = key
      record.hasAllergenConflict = !DietaryGuard.allergenHits(
        ingredientLines: recipe.ingredients.map(\.name), title: recipe.title, rules: rules
      ).isEmpty
      record.cuisineCookCount = cuisineCounts[FinderQuery.normalize(recipe.cuisine), default: 0]
      // Preview alternatives in this same bounded pass, with identical dietary,
      // allergen, inventory and search rules. Nothing is applied automatically.
      let exact = FinderQuery.matches(record, filters: filters)
      for index in alternatives.indices
      where exact || FinderQuery.matches(record, filters: alternatives[index].filters) {
        alternatives[index].count += 1
      }
      guard exact else { return }
      matched.insert(key)
      count += 1
      hits.append(FinderHit(record: record, recipe: recipe, databaseEntry: entry))
    }
    func trim() {
      hits.sort { FinderQuery.ordered($0.record, before: $1.record, filters: filters) }
      if hits.count > limit { hits.removeLast(hits.count - limit) }
    }
    func publish() async throws {
      try Task.checkCancellation()
      guard let onProgress, count > 0, Date().timeIntervalSince(lastPreview) >= 0.2 else { return }
      trim()
      lastPreview = Date()
      await onProgress(
        FinderResponse(
          hits: hits, count: count, catalogueUnavailable: false, matchedIdentities: matched))
    }
    for (index, recipe) in saved.enumerated() {
      try Task.checkCancellation()
      consume(recipe, entry: nil)
      if index % 128 == 0 { try await publish() }
    }
    trim()
    try await publish()
    let local = await RecipeDatabase.shared.all()
    for (index, entry) in local.enumerated() {
      try Task.checkCancellation()
      consume(FinderData.recipe(entry, parseAmounts: filters.usesInventory), entry: entry)
      if index % 128 == 0 { try await publish() }
    }
    trim()
    var cursor: Int64 = 0
    var unavailable = false
    do {
      while true {
        try Task.checkCancellation()
        let page = try await RecipeDatabaseManager.cataloguePage(after: cursor)
        for entry in page.entries {
          try Task.checkCancellation()
          consume(FinderData.recipe(entry, parseAmounts: filters.usesInventory), entry: entry)
        }
        trim()
        cursor = page.cursor
        try await publish()
        if page.done { break }
        await Task.yield()
      }
    } catch is CancellationError { throw CancellationError() } catch { unavailable = true }
    cursor = 0
    do {
      while true {
        try Task.checkCancellation()
        let page = try await RecipeStore.shared.finderPage(after: cursor)
        for entry in page.entries {
          try Task.checkCancellation()
          consume(FinderData.recipe(entry, parseAmounts: filters.usesInventory), entry: entry)
        }
        trim()
        cursor = page.cursor
        try await publish()
        if page.done { break }
        await Task.yield()
      }
    } catch is CancellationError { throw CancellationError() } catch { unavailable = true }
    if unavailable && count == 0 { throw CocoaError(.fileReadUnknown) }
    return FinderResponse(
      hits: hits, count: count, catalogueUnavailable: unavailable,
      alternatives: count == 0 ? Array(alternatives.filter { $0.count > 0 }.prefix(1)) : [],
      matchedIdentities: matched)
  }
}
