import Foundation

nonisolated struct FinderHit: Identifiable, Sendable {
    var record: FinderRecord
    var recipe: UserRecipe
    var databaseEntry: RecipeDatabaseEntry?
    var id: String { record.id }
}

nonisolated enum FinderData {
    // Only a complete explicit total, or BOTH prep and cook durations, can establish total time.
    static func minutes(_ value: String) -> Int? {
        FinderDuration.minutes(value)
    }

    static func recipe(_ entry: RecipeDatabaseEntry, parseAmounts: Bool = false) -> UserRecipe {
        var r = UserRecipe(title: entry.title)
        r.id = entry.id; r.description = entry.description; r.cuisine = entry.cuisine
        r.tags = entry.tags; r.categories = [entry.category]
        r.prepTime = entry.prepTime; r.cookTime = entry.cookTime
        r.ingredients = entry.ingredients.map { line in
            guard parseAmounts else { return RecipeIngredient(name: line, amount: "") }
            var ingredient = RecipeAdapter.ingredient(amount: "", name: line)
            let parsed = ParsedQuantity.parse(line)
            if parsed.amount > 0 { ingredient.amount = parsed.display }
            return ingredient
        }
        r.instructions = entry.steps; r.imageURL = entry.imageURL
        r.sourceURL = entry.sourceURL; r.sourceName = entry.sourceName
        r.servings = Int(entry.servings) ?? 4
        return r
    }

    static func record(_ recipe: UserRecipe, entry: RecipeDatabaseEntry?, history: [LocalPastMeal], inventory: [LocalInventoryItem], filters: FinderFilters) -> FinderRecord {
        let norm = FinderQuery.normalize
        let metadata = recipe.tags + (recipe.categories ?? [])
        let tags = Set(metadata.flatMap { value in
            ([value] + value.components(separatedBy: CharacterSet(charactersIn: ",;/|")))
                .map { norm($0).replacingOccurrences(of: "-", with: " ") }
        })
        let cuisine = RecipeTaxonomy.resolvedCuisine(recipe.cuisine, title: recipe.title, keywords: metadata)
        let cuisineLabels = Set([cuisine, RecipeTaxonomy.parentCuisine(cuisine)].compactMap { $0 }.map(norm))
        var r = FinderRecord(id: recipe.id.uuidString, title: recipe.title,
            searchText: norm(([recipe.title, recipe.description, recipe.cuisine] + metadata + recipe.ingredients.map(\.name)).joined(separator: " ")))
        r.sortTitle = norm(recipe.title)
        if let entry, let total = minutes(entry.totalTime) { r.totalMinutes = total }
        else if let prep = minutes(recipe.prepTime), let cook = minutes(recipe.cookTime) { r.totalMinutes = prep + cook }
        r.addedAt = entry == nil ? recipe.dateCreated : nil
        r.cookCount = recipe.cookCount; r.lastCooked = recipe.lastCooked
        let meals = history.filter { $0.recipeId == recipe.id || norm($0.title) == norm(recipe.title) }
        r.cookCount = max(r.cookCount, meals.count)
        let ratings = meals.map(\.rating).filter { (1...5).contains($0) }
        r.rating = entry?.rating
        if let rating = r.rating, !(1...5).contains(rating) { r.rating = nil }
        if !ratings.isEmpty { r.rating = Double(ratings.reduce(0, +)) / Double(ratings.count); r.ratingCount = ratings.count }
        let dates = meals.compactMap { meal -> Date? in
            if let date = ISO8601DateFormatter().date(from: meal.date) { return date }
            let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .none
            return formatter.date(from: meal.date)
        }
        if let latest = dates.max(), latest > (r.lastCooked ?? .distantPast) { r.lastCooked = latest }
        for category in [FinderCategory.meal, .cuisine, .mood] {
            for choice in category.options where !choice.isNeutral && !choice.isDiscovery {
                let label = norm(choice.label).replacingOccurrences(of: "-", with: " ")
                if tags.contains(label) || (category == .cuisine && cuisineLabels.contains(label)) { r.facets[category, default: []].insert(choice) }
            }
        }
        let aliases: [(String, FinderCategory, FinderChoice)] = [
            ("main dish", .meal, .dinner), ("main course", .meal, .dinner), ("beverage", .meal, .drink),
            ("side", .meal, .sideDish), ("comfort food", .mood, .comfort), ("cajun", .cuisine, .cajun),
            ("creole", .cuisine, .cajun), ("latin american", .cuisine, .latin), ("barbecue", .mood, .grilled),
            ("kid friendly", .mood, .familyFriendly), ("light and fresh", .mood, .lightFresh)
        ]
        for (label, category, choice) in aliases where tags.contains(label) || norm(recipe.cuisine) == label { r.facets[category, default: []].insert(choice) }
        let groups: [FinderChoice: [String]] = [
            .chicken: ["chicken"], .beef: ["beef", "steak"], .pork: ["pork", "bacon", "ham"], .turkey: ["turkey"],
            .fish: ["fish", "salmon", "tuna", "cod", "tilapia", "trout"], .shrimp: ["shrimp", "prawn"],
            .seafood: ["fish", "salmon", "tuna", "cod", "shrimp", "prawn", "crab", "lobster", "clam", "mussel", "scallop"],
            .pasta: ["pasta", "spaghetti", "penne", "macaroni", "noodle", "linguine"], .rice: ["rice"],
            .vegetables: ["vegetable", "carrot", "broccoli", "spinach", "zucchini", "cabbage", "cauliflower", "eggplant", "potato", "tomato", "kale", "pea"],
            .beans: ["bean", "lentil", "chickpea"], .eggs: ["egg"], .tofu: ["tofu"]
        ]
        for (choice, names) in groups where filters.active(.ingredient).contains(choice) && recipe.ingredients.contains(where: { ingredient in names.contains { FoodNameMatcher.containsPhrase($0, in: ingredient.name) } }) { r.facets[.ingredient, default: []].insert(choice) }
        // Only explicit tags, never absence-of-meat/allergen text guesses. These options
        // express dietary metadata, NOT guarantees concerning cross-contamination.
        for choice in FinderCategory.diet.options where tags.contains(norm(choice.label)) { r.facets[.diet, default: []].insert(choice) }
        if r.facets[.diet, default: []].contains(.vegan) { r.facets[.diet, default: []].formUnion([.vegetarian, .pescatarian]) }
        if r.facets[.diet, default: []].contains(.vegetarian) { r.facets[.diet, default: []].insert(.pescatarian) }
        if filters.usesInventory {
            let coverage = coverage(recipe.ingredients, inventory: inventory)
            r.required = coverage.required; r.have = coverage.have; r.uncertain = coverage.uncertain
        }
        return r
    }

    /// Consume a per-recipe quantity pool, so two lines cannot spend the same stock twice.
    /// Unknown amounts may count as present for 70% coverage, but never as fully ready.
    static func coverage(_ ingredients: [RecipeIngredient], inventory: [LocalInventoryItem]) -> (required: Int, have: Int, uncertain: Int) {
        let now = Date()
        let items = KitchenAvailability.availableItems(in: inventory).filter { $0.quantity > 0 && ($0.expirationDate == nil || $0.expirationDate! >= now) }
        let stock = items.map { item -> FinderQuantityPool.Stock in
            let owned = ReservationEngine.ownedBase(of: item)
            return .init(family: owned.family, amount: owned.base)
        }
        var needs: [FinderQuantityPool.Need] = []
        for ingredient in ingredients where !ingredient.isOptional {
            let indices = items.indices.filter { KitchenAvailability.nameMatches(ingredient.name, items[$0].name) }
            guard let amount = ingredient.quantity, amount > 0 else {
                needs.append(.init(family: nil, amount: nil, matchingStock: indices)); continue
            }
            let unit = ingredient.unit ?? ""
            let family: String
            let needed: Double
            if let f = UnitMath.family(of: unit) {
                family = f == .mass ? "weight" : "volume"
                needed = UnitMath.convert(amount, from: unit, to: f == .mass ? "g" : "ml") ?? amount
            } else if ["", "count", "each", "piece", "pieces"].contains(unit.lowercased()) {
                family = "count"; needed = amount
            } else { needs.append(.init(family: nil, amount: amount, matchingStock: indices)); continue }
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
}

enum FinderService {
    /// No full-corpus model cache. The caller cancels obsolete work and publishes only
    /// the latest snapshot. Saved data wins deduplication; source documents stay intact.
    nonisolated static func query(filters: FinderFilters, saved: [UserRecipe], history: [LocalPastMeal], inventory: [LocalInventoryItem], allergens: [String], limit: Int) async throws -> FinderResponse {
        var hits: [FinderHit] = [], count = 0, seen = Set<String>()
        var alternatives = FinderQuery.alternatives(for: filters)
        let rules = DietaryGuard.Rules(allergens: allergens, dislikes: [])
        let historyByTitle = Dictionary(grouping: history, by: { FinderQuery.normalize($0.title) })
        let cuisineCounts = Dictionary(grouping: saved, by: { FinderQuery.normalize($0.cuisine) }).mapValues { $0.reduce(0) { $0 + $1.cookCount } }
        func consume(_ recipe: UserRecipe, entry: RecipeDatabaseEntry?) {
            let key = FinderQuery.normalize(recipe.sourceURL?.isEmpty == false ? recipe.sourceURL! : recipe.title)
            guard seen.insert(key).inserted else { return }
            var record = FinderData.record(recipe, entry: entry, history: historyByTitle[FinderQuery.normalize(recipe.title), default: []], inventory: inventory, filters: filters)
            record.hasAllergenConflict = !DietaryGuard.allergenHits(ingredientLines: recipe.ingredients.map(\.name), title: recipe.title, rules: rules).isEmpty
            record.cuisineCookCount = cuisineCounts[FinderQuery.normalize(recipe.cuisine), default: 0]
            // Preview alternatives in this same bounded pass, with identical dietary,
            // allergen, inventory and search rules. Nothing is applied automatically.
            let exact = FinderQuery.matches(record, filters: filters)
            for index in alternatives.indices where exact || FinderQuery.matches(record, filters: alternatives[index].filters) {
                alternatives[index].count += 1
            }
            guard exact else { return }
            count += 1; hits.append(FinderHit(record: record, recipe: recipe, databaseEntry: entry))
        }
        func trim() {
            hits.sort { FinderQuery.ordered($0.record, before: $1.record, filters: filters) }
            if hits.count > limit { hits.removeLast(hits.count - limit) }
        }
        for recipe in saved { try Task.checkCancellation(); consume(recipe, entry: nil) }
        trim()
        let local = await RecipeDatabase.shared.all()
        for entry in local { try Task.checkCancellation(); consume(FinderData.recipe(entry, parseAmounts: filters.usesInventory), entry: entry) }
        trim()
        var cursor: Int64 = 0, unavailable = false
        do {
            while true {
                try Task.checkCancellation()
                let page = try await RecipeStore.shared.finderPage(after: cursor)
                for entry in page.entries { try Task.checkCancellation(); consume(FinderData.recipe(entry, parseAmounts: filters.usesInventory), entry: entry) }
                trim(); cursor = page.cursor
                if page.done { break }
                await Task.yield()
            }
        } catch is CancellationError { throw CancellationError() }
        catch { unavailable = true }
        if unavailable && count == 0 { throw CocoaError(.fileReadUnknown) }
        return FinderResponse(hits: hits, count: count, catalogueUnavailable: unavailable,
            alternatives: count == 0 ? Array(alternatives.filter { $0.count > 0 }.prefix(1)) : [])
    }
}
