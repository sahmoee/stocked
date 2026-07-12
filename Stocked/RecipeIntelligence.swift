import Foundation

// ─────────────────────────────────────────────────────────────────────
// Build 251 — Online recipe intelligence + onboarding seed.
//
// Pure, nonisolated helpers that let the Discover section and the online
// browser behave like the rest of the app: tell the user what they can
// cook ("Ready" / "2 missing"), flag what they've already saved, warn on
// allergens, and rank by what they actually open — plus a small starter-
// staples list so a brand-new kitchen lights up the Cook catalog and the
// Discover "can I make this?" badges immediately.
// ─────────────────────────────────────────────────────────────────────

// MARK: - Online recipe → pantry match

enum OnlineRecipeMatch {
    /// (have, total) over an online recipe's ingredient names, using the same loose,
    /// two-way name match the rest of the app uses for inventory. `inStock` is the
    /// caller's set of lowercased in-stock item names (GuestDataStore.inStockNameSet).
    nonisolated static func stockMatch(_ recipe: OnlineRecipe, inStock: Set<String>) -> (have: Int, total: Int) {
        let names = RecipeIngredients.names(recipe.ingredients)
            .map { IngredientSynonyms.canonical($0) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return (0, 0) }
        var have = 0
        for n in names where inStock.contains(where: { $0.contains(n) || n.contains($0) }) { have += 1 }
        return (have, names.count)
    }

    /// A short status for a Discover/browser card: nil when there's nothing in the
    /// pantry yet (so we don't show a discouraging "all missing" on an empty kitchen).
    nonisolated enum Status: Equatable, Sendable {
        case ready                 // everything on hand
        case missing(Int)          // n ingredients short
        case unknown               // no pantry signal — show nothing
    }

    nonisolated static func status(_ recipe: OnlineRecipe, inStock: Set<String>) -> Status {
        // No inventory at all → no honest badge to show.
        guard !inStock.isEmpty else { return .unknown }
        let m = stockMatch(recipe, inStock: inStock)
        guard m.total > 0 else { return .unknown }
        if m.have >= m.total { return .ready }
        // Only surface a missing count when the user is genuinely close-ish; a recipe
        // they have none of isn't useful as a "2 missing" nudge, so cap the signal.
        let missing = m.total - m.have
        return .missing(missing)
    }
}

// MARK: - Saved-state + allergen helpers for online recipes

enum OnlineRecipeFacts {
    /// True when an online recipe is already in the user's saved collection, matched by
    /// normalized title — mirrors the cookCatalog dedupe so users don't re-import.
    nonisolated static func isSaved(_ recipe: OnlineRecipe, savedTitles: Set<String>) -> Bool {
        savedTitles.contains(normalizedTitle(recipe.title))
    }

    nonisolated static func normalizedTitle(_ t: String) -> String {
        t.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `instructions` contains actual cooking steps — not empty, and not
    /// one of the placeholder "go to the source" strings some feeds (e.g. Edamam)
    /// produce when they don't license step text. Used so the detail view can show
    /// an honest empty-state instead of rendering a bare URL as if it were a step.
    nonisolated static func hasRealInstructions(_ instructions: String) -> Bool {
        let s = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        let lower = s.lowercased()
        // Legacy/placeholder patterns that are really just a source pointer.
        if lower.hasPrefix("full instructions at the source") { return false }
        if lower == "see full recipe at source." { return false }
        if lower.hasPrefix("see full recipe at source") { return false }
        // A lone URL is not instructions.
        if (lower.hasPrefix("http://") || lower.hasPrefix("https://")),
           !s.contains(" ") { return false }
        return true
    }

    /// Allergens (from the user's profile) that this online recipe appears to contain.
    /// Returns the matched allergen words so the UI can show "Contains: peanuts, milk".
    nonisolated static func allergenHits(_ recipe: OnlineRecipe, allergens: [String]) -> [String] {
        let active = allergens.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { $0.count > 1 }
        guard !active.isEmpty else { return [] }
        let names = RecipeIngredients.names(recipe.ingredients).map { $0.lowercased() }
        let haystack = (names + [recipe.title.lowercased()])
        var hits: Set<String> = []
        for a in active where haystack.contains(where: { $0.contains(a) || a.contains($0) }) {
            hits.insert(a)
        }
        return Array(hits).sorted()
    }
}

// MARK: - Interest-based ranking (#6)

// Lightweight, persisted tally of which categories/areas the user opens from the online
// surfaces. Discover uses it to float matching recipes up — so "Popular right now"
// reflects this user, not a fixed category mix. Decays gently so old taste fades.
@MainActor
final class RecipeInterest {
    static let shared = RecipeInterest()
    private init() { load() }

    private let key = "stocked.onlineRecipeInterest_v1"
    // term (lowercased category or area) → weight
    private(set) var weights: [String: Double] = [:]

    func record(category: String, area: String) {
        bump(category); bump(area)
        save()
    }

    private func bump(_ raw: String) {
        let t = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard t.count > 1 else { return }
        // Gentle decay on every record so the profile tracks recent taste.
        for k in weights.keys { weights[k]? *= 0.98 }
        weights[t, default: 0] += 1
        // Keep the table small.
        if weights.count > 40 {
            let survivors = weights.sorted { $0.value > $1.value }.prefix(40)
            weights = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
        }
    }

    /// Additive interest score for one recipe (0 when we know nothing about the user).
    func score(category: String, area: String) -> Double {
        let c = category.lowercased().trimmingCharacters(in: .whitespaces)
        let a = area.lowercased().trimmingCharacters(in: .whitespaces)
        return (weights[c] ?? 0) + (weights[a] ?? 0)
    }

    private func load() {
        if let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] {
            weights = raw
        }
    }
    private func save() {
        UserDefaults.standard.set(weights, forKey: key)
    }
}

// MARK: - Starter staples (empty-state onboarding seed, App #3)

enum StarterStaples {
    /// A small, broadly-useful set of pantry/fridge basics. Adding these makes the Cook
    /// catalog's starter meals match (so Cook Now / Cook Later populate) and lights up the
    /// Discover "can I make this?" badges. Names match how StarterMeals + the matcher expect
    /// them. Each is created at a healthy level with no hard expiry (staples keep).
    struct Seed { let name: String; let zone: String }

    static let all: [Seed] = [
        Seed(name: "Eggs",        zone: "Fridge"),
        Seed(name: "Milk",        zone: "Fridge"),
        Seed(name: "Butter",      zone: "Fridge"),
        Seed(name: "Cheese",      zone: "Fridge"),
        Seed(name: "Chicken Breast", zone: "Fridge"),
        Seed(name: "Garlic",      zone: "Pantry"),
        Seed(name: "Onion",       zone: "Pantry"),
        Seed(name: "Pasta",       zone: "Pantry"),
        Seed(name: "Rice",        zone: "Pantry"),
        Seed(name: "Bread",       zone: "Pantry"),
        Seed(name: "Olive Oil",   zone: "Staples"),
        Seed(name: "Salt",        zone: "Staples"),
        Seed(name: "Black Pepper", zone: "Staples"),
        Seed(name: "Tomatoes",    zone: "Pantry"),
        Seed(name: "Soy Sauce",   zone: "Staples"),
    ]
}
