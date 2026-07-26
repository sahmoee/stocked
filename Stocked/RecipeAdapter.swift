// RecipeAdapter.swift
// ─────────────────────────────────────────────────────────────────────────────
// Converts every recipe shape in the app into the ONE shape the readiness
// classifier understands.
//
// WHY THIS FILE EXISTS
// `CookNowEngine` is typed on `UserRecipe` at every level — `recipes:
// [UserRecipe]`, `classify(_ recipe: UserRecipe)`, `ClassifiedRecipe.recipe:
// UserRecipe`. There was no conversion from `OnlineRecipe` anywhere in the
// codebase, so `cookCatalog` could only ever be `userRecipes + StarterMeals`.
//
// The consequence: the thousands of recipes in the Recipes tab were structurally
// incapable of receiving a readiness tier, substitution resolution, allergen
// exclusion, or reservation demotion. They got a naive missing-count badge
// instead, and Cook Now scored a handful of authored starter meals. The two tabs
// could not agree because they were not looking at the same recipes — and no
// amount of unifying the MATCHER fixes that.
//
// WHY AN ADAPTER RATHER THAN A PROTOCOL
// The obvious fix is to generalise the engine over a `ClassifiableRecipe`
// protocol. That means changing `ClassifiedRecipe.recipe`'s type, which is read
// as `.recipe.title` / `.recipe.ingredients` / `.recipe.dishRole` / `.recipe.id`
// across roughly twenty view files. It is the cleaner long-term design and it is
// also a refactor of the app's central engine touching every Cook surface at
// once.
//
// Adapting at the boundary reaches the same outcome — online and generated
// recipes flow through the real classifier — with an additive change and zero
// downstream churn. Nothing that consumes `ClassifiedRecipe` needs to know.
//
// STABLE IDENTITY
// `UserRecipe()` mints a fresh UUID on every construction. If adapted recipes
// were built that way, `ClassifiedRecipe.id` would change on every
// recomputation, breaking SwiftUI identity (rows animating as insert+delete on
// every inventory edit) and any id-keyed cache. So ids here are derived
// deterministically from the source recipe's own identifier: the same online
// recipe always adapts to the same UUID.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import CryptoKit

nonisolated enum RecipeAdapter {

    // MARK: - Deterministic identity

    /// A stable UUID derived from a namespace and a source key. Same inputs
    /// always produce the same UUID, in this process and the next.
    static func stableID(namespace: String, key: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(namespace):\(key)".utf8))
        var bytes = Array(digest.prefix(16))
        // Stamp RFC-4122 version 4 / variant bits so the value is a well-formed
        // UUID rather than 16 arbitrary bytes.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2],  bytes[3],
                           bytes[4], bytes[5], bytes[6],  bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Ingredient conversion

    /// Turn an amount + name pair into a structured `RecipeIngredient`, marking
    /// optional lines so the shared coverage rule can exclude them.
    ///
    /// This logic previously existed twice, copy-pasted into
    /// `saveGeneratedRecipe` and `importOnlineRecipe`. Both now call here.
    static func ingredient(amount rawAmount: String, name rawName: String) -> RecipeIngredient {
        let amount = rawAmount.trimmingCharacters(in: .whitespaces)
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let full = "\(amount) \(name)".trimmingCharacters(in: .whitespaces)
        let pq = ParsedQuantity.parse(full)
        let resolved = pq.baseName.isEmpty ? name : pq.baseName
        return RecipeIngredient(
            name: resolved,
            amount: amount,
            isOptional: KitchenAvailability.isOptionalLine(full),
            quantity: pq.amount > 0 ? pq.amount : nil,
            unit: pq.canonicalUnit.isEmpty ? nil : pq.canonicalUnit
        )
    }

    // MARK: - OnlineRecipe

    /// Adapt a Discover/browser recipe into the classifier's shape.
    ///
    /// - Parameter persistentID: pass an existing id when saving into the user's
    ///   collection (so the saved copy keeps its own identity). Omit it for the
    ///   read-only classification pool, where the derived stable id is wanted.
    static func userRecipe(from recipe: OnlineRecipe, persistentID: UUID? = nil) -> UserRecipe {
        var out = UserRecipe(title: recipe.title)
        out.id = persistentID ?? stableID(namespace: "online", key: "\(recipe.source)|\(recipe.id)")
        out.ingredients = recipe.ingredientLines.map { ingredient(amount: $0.measure, name: $0.ingredient) }
        out.instructions = recipe.instructions
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        out.imageURL = recipe.imageURL
        out.cuisine = recipe.area
        out.notes = [recipe.area, recipe.category].filter { !$0.isEmpty }.joined(separator: " · ")
        out.tags = [recipe.category, recipe.area, recipe.source].filter { !$0.isEmpty }
        return out
    }

    // MARK: - GeneratedRecipe

    /// Adapt an AI-generated or Surprise Me recipe into the classifier's shape.
    ///
    /// This also retires a stale-data bug: `availableMeals` counted generated
    /// recipes by reading `GeneratedRecipe.missingIngredients`, a list frozen at
    /// the moment of generation. Once adapted, generated recipes are classified
    /// against LIVE inventory like everything else, so their readiness updates
    /// when the kitchen changes.
    static func userRecipe(from recipe: GeneratedRecipe, persistentID: UUID? = nil) -> UserRecipe {
        var out = UserRecipe(title: recipe.title)
        out.id = persistentID ?? stableID(namespace: "generated", key: recipe.id.uuidString)
        out.cookTime = recipe.cookTime
        out.servings = recipe.servings
        out.difficulty = recipe.difficulty
        out.notes = recipe.tips
        out.ingredients = recipe.ingredients.map { ingredient(amount: $0.amount, name: $0.name) }
        out.instructions = recipe.steps
        out.imageURL = recipe.imageURL
        out.imageData = recipe.imageData
        out.isFavorited = recipe.isFavorited
        out.tags = recipe.mealCategory.isEmpty ? [] : [recipe.mealCategory]
        return out
    }

    // MARK: - Pools

    // MARK: - Cheap pre-screen

    /// Words that carry no food identity, so they never count as overlap.
    private static let screenStopwords: Set<String> = [
        "cup", "cups", "tablespoon", "tablespoons", "teaspoon", "teaspoons",
        "tbsp", "tsp", "ounce", "ounces", "pound", "pounds", "gram", "grams",
        "kilogram", "litre", "liter", "millilitre", "milliliter", "pinch",
        "large", "small", "medium", "fresh", "freshly", "chopped", "sliced",
        "diced", "minced", "ground", "optional", "taste", "garnish", "needed",
        "and", "the", "for", "with", "into", "plus", "about", "packed",
    ]

    /// Lowercased content words of a string, for coarse set-overlap scoring.
    static func screenTokens(_ text: String) -> Set<String> {
        var out: Set<String> = []
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            let w = String(raw)
            guard w.count > 2, !screenStopwords.contains(w) else { continue }
            out.insert(w)
        }
        return out
    }

    /// Content words across the available inventory — the haystack for scoring.
    static func availableTokens(in items: [LocalInventoryItem]) -> Set<String> {
        var out: Set<String> = []
        for item in KitchenAvailability.availableItems(in: items) {
            out.formUnion(screenTokens(item.name))
        }
        return out
    }

    // MARK: - Pools

    /// Adapt a Discover pool for classification, dropping anything whose title
    /// already exists in the user's own collection so a saved recipe and its
    /// online origin do not both appear in Cook Now.
    ///
    /// WHY THERE IS A CHEAP PRE-SCREEN AND A CAP
    /// The precise classifier is expensive: for every ingredient of every recipe
    /// it token-scores against every available inventory item. A thousand-recipe
    /// Discover cache times an average ingredient list times a real pantry is
    /// hundreds of thousands of scored comparisons, and `CookNowCompute.run` is
    /// called synchronously from view code on the main actor. Handing it the
    /// whole cache would hang the Cook tab.
    ///
    /// So recipes are first ranked by plain set overlap between their ingredient
    /// words and the pantry's words — hashing, not scoring, so it is cheap — and
    /// only the top `limit` go to the classifier. There is no recall loss where
    /// it matters: the cap trims the LEAST makeable end, and anything close to
    /// ready ranks at the top. Nothing is filtered out by a score floor.
    static func classificationPool(online: [OnlineRecipe],
                                   excludingTitles savedTitles: Set<String>,
                                   availableTokens: Set<String>,
                                   limit: Int = 120) -> [UserRecipe] {
        guard !online.isEmpty, limit > 0 else { return [] }

        var seen = savedTitles
        var scored: [(score: Double, recipe: OnlineRecipe)] = []
        scored.reserveCapacity(online.count)

        for r in online {
            let key = OnlineRecipeFacts.normalizedTitle(r.title)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            let lines = r.ingredientLines
            // A recipe with no ingredient lines cannot be classified honestly —
            // it would read as "ready" because nothing is missing.
            guard !lines.isEmpty else { continue }
            seen.insert(key)

            var matched = 0
            var counted = 0
            for line in lines {
                let tokens = screenTokens(line.ingredient)
                guard !tokens.isEmpty else { continue }
                counted += 1
                if !tokens.isDisjoint(with: availableTokens) { matched += 1 }
            }
            guard counted > 0 else { continue }
            scored.append((Double(matched) / Double(counted), r))
        }

        // Most makeable first, so the cap trims what the user cannot cook anyway.
        scored.sort { $0.score > $1.score }

        var out: [UserRecipe] = []
        out.reserveCapacity(min(limit, scored.count))
        for entry in scored.prefix(limit) {
            let adapted = userRecipe(from: entry.recipe)
            guard !adapted.ingredients.isEmpty else { continue }
            out.append(adapted)
        }
        return out
    }
}
