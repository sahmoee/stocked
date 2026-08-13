// RecipeDatabase.swift
// Stocked — Persistent local recipe database with bootstrap seed data, manual additions,
// online catalogue integration, and full-text search for predictive text / autofill.
//
// Architecture:
//   RecipeDatabaseEntry  — flat, searchable record stored on disk
//   RecipeDatabase       — actor-isolated singleton; thread-safe reads & writes
//   RecipeDatabaseManager— @Observable MainActor wrapper for SwiftUI
//
// Sources layered in priority order (highest → lowest):
//   1. User's own manually-added recipes (UserRecipe, converted on save)
//   2. Seeded from the DeepSeek JSON import (12 recipes, Taste of Home)
//   3. WebRecipeCatalogue entries (scraped from 20 sites, auto-merged hourly)
//   4. OfflineRecipeCache entries (TheMealDB, imported URLs)
//
// How predictive text works:
//   Call RecipeDatabaseManager.shared.suggestions(for:) from any TextField to get
//   ranked RecipeDatabaseEntry results. Selecting one calls autofill(entry:into:)
//   which populates an AddRecipeForm binding in one shot.

import Foundation
import Combine

// MARK: - RecipeDatabaseEntry
// Flat, serialisable record that every source maps into.
nonisolated struct RecipeDatabaseEntry: Identifiable, Codable, Hashable, Sendable {
    var id           = UUID()
    var title:       String
    var description: String
    var sourceURL:   String
    var sourceName:  String   = ""          // "Taste of Home", "TheMealDB", "Manual", etc.
    var prepTime:    String
    var cookTime:    String
    var totalTime:   String
    var servings:    String
    var category:    String
    var cuisine:     String
    var tags:        [String]
    var ingredients: [String]               // flat "amount unit name" strings
    var steps:       [String]
    var imageURL:    String   = ""
    var calories:    String   = ""
    var rating:      Double?
    var cachedAt:    Date    = Date()
    var openCount:   Int     = 0          // popularity tracking

    // Full-text index built once and reused for fast filtering
    var searchIndex: String {
        ([title, description, category, cuisine] + tags + ingredients + [sourceName])
            .joined(separator: " ").lowercased()
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// MARK: - AddRecipeForm
// A simple struct that the predictive field fills when a user selects a suggestion.
// Bind this in any View that has a recipe form.
nonisolated struct AddRecipeForm: Sendable {
    var title        = ""
    var description  = ""
    var prepTime     = ""
    var cookTime     = ""
    var totalTime    = ""
    var servings     = ""
    var cuisine      = ""
    var category     = ""
    var tags: [String] = []
    var ingredients: [String] = []
    var steps: [String] = []
    var imageURL     = ""
    var sourceURL    = ""
    var notes        = ""
    /// Raw text this form was parsed from (page text, OCR, or pasted recipe). Used to
    /// re-structure the import with AI and to power "Show original text". Empty for
    /// from-scratch entry.
    var originalText = ""

    mutating func fill(from entry: RecipeDatabaseEntry) {
        title       = entry.title
        description = entry.description
        prepTime    = entry.prepTime
        cookTime    = entry.cookTime
        totalTime   = entry.totalTime
        servings    = entry.servings
        cuisine     = entry.cuisine
        category    = entry.category
        tags        = entry.tags
        ingredients = entry.ingredients
        steps       = entry.steps
        imageURL    = entry.imageURL
        sourceURL   = entry.sourceURL
    }
}

// MARK: - RecipeDatabase (actor — thread-safe)
actor RecipeDatabase {
    static let shared = RecipeDatabase()

    private let storageKey       = "recipe_database_v3"
    private let legacyDefaultsKey = "recipeDatabase_v2"
    private let maxEntries       = 2000         // hard cap before LRU eviction
    private var entries: [RecipeDatabaseEntry] = []
    private var titleIndex: [String: UUID] = [:]   // lowercase title → id for dedup
    // #9 in-memory token index: search token → set of entry IDs. Rebuilt on load and
    // kept in sync on upsert/delete so search() doesn't scan the whole array each call.
    private var tokenIndex: [String: Set<UUID>] = [:]

    // Tokenize an entry's searchable text into lowercase word stems.
    private func tokens(for entry: RecipeDatabaseEntry) -> Set<String> {
        let text = ([entry.title, entry.description, entry.category, entry.cuisine]
                    + entry.tags + RecipeIngredients.names(entry.ingredients) + [entry.sourceName])
            .joined(separator: " ").lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
        let raw = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(raw.filter { $0.count >= 2 })
    }

    private func indexEntry(_ entry: RecipeDatabaseEntry) {
        for t in tokens(for: entry) { tokenIndex[t, default: []].insert(entry.id) }
    }
    private func unindexEntry(_ entry: RecipeDatabaseEntry) {
        for t in tokens(for: entry) { tokenIndex[t]?.remove(entry.id) }
    }
    private func rebuildTokenIndex() {
        tokenIndex = [:]
        for e in entries { indexEntry(e) }
    }

    init() {
        Task { await bootstrap() }
    }

    // MARK: Read
    func all() -> [RecipeDatabaseEntry] { entries }

    func search(_ query: String, limit: Int = 8) -> [RecipeDatabaseEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
        guard q.count >= 1 else { return [] }

        // #9: candidate set from the token index (prefix-match query against tokens),
        // avoiding a full-array scan. Fall back to all entries only if nothing indexed.
        var candidateIDs = Set<UUID>()
        for (token, ids) in tokenIndex where token.hasPrefix(q) || token.contains(q) {
            candidateIDs.formUnion(ids)
        }
        let candidates: [RecipeDatabaseEntry]
        if candidateIDs.isEmpty {
            candidates = entries.filter { $0.title.lowercased().contains(q) }
        } else {
            // Preserve database order while selecting candidates. Building a full UUID
            // dictionary on every keystroke allocated heavily and could trap on duplicate
            // IDs from a damaged/partially synced cache.
            candidates = entries.filter { candidateIDs.contains($0.id) }
        }

        // #14 + #10: rank by title relevance first, then quality/completeness.
        let ranked = candidates.sorted { a, b in
            let ra = FuzzyMatch.score(q, a.title.lowercased())
            let rb = FuzzyMatch.score(q, b.title.lowercased())
            if abs(ra - rb) > 0.0001 { return ra > rb }
            return qualityScore(a) > qualityScore(b)
        }
        return Array(ranked.prefix(limit))
    }

    /// Cached/derived quality score for ranking (#10).
    private func qualityScore(_ e: RecipeDatabaseEntry) -> Double {
        RecipeQuality.score(title: e.title, ingredients: e.ingredients,
                            steps: e.steps, imageURL: e.imageURL)
    }

    /// Snapshot ranked by quality — used by views that want "best first".
    func allRankedByQuality() -> [RecipeDatabaseEntry] {
        entries.sorted { qualityScore($0) > qualityScore($1) }
    }

    func entry(for title: String) -> RecipeDatabaseEntry? {
        entries.first { $0.title.lowercased() == title.lowercased() }
    }

    func count() -> Int { entries.count }

    func recordOpen(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].openCount += 1
    }

    // MARK: Write
    @discardableResult
    func upsert(_ entry: RecipeDatabaseEntry) -> Bool {
        let result = upsertNoPersist(entry)
        persist()
        return result
    }

    /// Core upsert that does NOT write to disk — used by upsertAll so a batch persists once
    /// instead of rewriting the entire recipe file per item (was O(N²) disk writes, the
    /// main driver of the runaway disk-write / CPU resource terminations).
    @discardableResult
    private func upsertNoPersist(_ entry: RecipeDatabaseEntry) -> Bool {
        // Retired sources are refused here rather than at each caller. Every ingestion
        // path in the app ends up in this method — the bundled-JSON importer, the web
        // catalogue merge, the offline cache merge, manual saves — so one guard closes
        // all of them, including any path added later. See RecipeSourceBlocklist.swift.
        guard !RecipeSourceBlocklist.isBlocked(entry) else { return false }

        let key = entry.title.lowercased()
        if let existing = titleIndex[key], let idx = entries.firstIndex(where: { $0.id == existing }) {
            // Overwrite only if the incoming entry has richer data
            let current = entries[idx]
            if entry.steps.count >= current.steps.count && entry.ingredients.count >= current.ingredients.count {
                unindexEntry(current)
                entries[idx] = entry
                titleIndex[key] = entry.id
                indexEntry(entry)
            }
            return false   // was duplicate
        }
        entries.insert(entry, at: 0)
        titleIndex[key] = entry.id
        indexEntry(entry)
        evictIfNeeded()
        return true   // new entry
    }

    @discardableResult
    func upsertAll(_ batch: [RecipeDatabaseEntry]) -> [RecipeDatabaseEntry] {
        guard !batch.isEmpty else { return [] }
        var changed = false
        var inserted: [RecipeDatabaseEntry] = []
        for e in batch {
            if upsertNoPersist(e) {
                changed = true
                inserted.append(e)
            }
        }
        // Persist ONCE for the whole batch (was once per item → O(N²) writes).
        if changed || !batch.isEmpty { persist() }
        return inserted
    }

    func delete(id: UUID) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            let removed = entries[idx]
            let key = removed.title.lowercased()
            unindexEntry(removed)
            entries.remove(at: idx)
            titleIndex.removeValue(forKey: key)
            persist()
        }
    }

    /// Removes every stored entry that came from a retired source, in one pass with one
    /// write. Returns how many went, so the caller can log it rather than guess.
    ///
    /// Deliberately not built out of `delete(id:)` in a loop: that method persists the
    /// whole file per call, which on a 2000-entry database is 2000 full rewrites for one
    /// sweep — the same O(N²) disk-write pattern that `upsertAll` exists to avoid.
    @discardableResult
    func purgeBlockedSources() -> Int {
        let kept = entries.filter { !RecipeSourceBlocklist.isBlocked($0) }
        let removed = entries.count - kept.count
        guard removed > 0 else { return 0 }
        entries = kept
        rebuildIndex()
        persist()
        return removed
    }

    // MARK: Import helpers — merge from other caches
    // Accepts already-converted entries — callers do the mapping outside the actor
    func mergeEntries(_ entries: [RecipeDatabaseEntry]) {
        upsertAll(entries)
    }

    // MARK: Persistence
    private func persist() {
        // Large recipe arrays do not belong in the preferences domain. LocalDatabase
        // coalesces and encodes this write on its utility queue, avoiding cfprefsd stalls.
        LocalDatabase.shared.save(entries, key: storageKey)
    }

    private func load() {
        if let decoded = LocalDatabase.shared.loadArray(RecipeDatabaseEntry.self, key: storageKey) {
            entries = decoded
            rebuildIndex()
            return
        }

        // One-time migration from builds that stored the full recipe database in UserDefaults.
        guard let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
              let decoded = try? JSONDecoder().decode([RecipeDatabaseEntry].self, from: data)
        else { return }
        entries = decoded
        rebuildIndex()
        LocalDatabase.shared.save(decoded, key: storageKey)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }

    private func rebuildIndex() {
        titleIndex = [:]
        for e in entries { titleIndex[e.title.lowercased()] = e.id }
        rebuildTokenIndex()   // #9 keep the search token index in sync
    }

    private func evictIfNeeded() {
        guard entries.count > maxEntries else { return }
        // Keep manual/user entries, evict oldest cached ones
        let manual = entries.filter { $0.sourceName == "Manual" || $0.sourceName == "My Recipes" }
        let auto   = entries.filter { $0.sourceName != "Manual" && $0.sourceName != "My Recipes" }
                            .sorted { $0.cachedAt > $1.cachedAt }
                            .prefix(maxEntries - manual.count)
        entries = manual + auto
        rebuildIndex()
    }

    // MARK: Seed / Bootstrap
    private func bootstrap() {
        load()
        guard entries.isEmpty else { return }   // already seeded
        let bootstrapDate = StockedFormatters.iso8601.date(from: "2026-05-31T00:00:00Z") ?? Date()
        let seed: [RecipeDatabaseEntry] = Self.seedRecipes(bootstrapDate: bootstrapDate)
        upsertAll(seed)
    }

    // MARK: - Seed Data (sourced from DeepSeek JSON import, Taste of Home)
    // To add more recipes manually: call await RecipeDatabase.shared.upsert(entry) from anywhere.
    static func seedRecipes(bootstrapDate: Date) -> [RecipeDatabaseEntry] {
        [
        RecipeDatabaseEntry(title: "French Onion Stew", description: "The ultimate mashup of French onion soup and pot roast. A beef chuck roast braises low and slow in a slow cooker with caramelized onions, rosemary, and beef broth, then finishes with spiral pasta and melted Monterey Jack cheese.", sourceURL: "https://www.tasteofhome.com/recipes/french-onion-stew/", sourceName: "Taste of Home", prepTime: "30 minutes", cookTime: "6 hours 45 minutes", totalTime: "7 hours 15 minutes", servings: "8", category: "beef", cuisine: "", tags: ["beef", "stew", "slow cooker", "onions", "soup-inspired", "pasta", "test kitchen"], ingredients: ["3 pounds boneless beef chuck roast, cut into 1-inch cubes", "1/2 teaspoon salt", "1/2 teaspoon black pepper", "2 tablespoons canola oil", "4 large sweet onions, thinly sliced", "2 tablespoons butter", "3 tablespoons all-purpose flour", "1/2 cup dry white wine or beef broth", "4 cups beef broth", "2 tablespoons Worcestershire sauce", "2 teaspoons minced fresh rosemary", "3 garlic cloves, minced", "2 cups uncooked spiral pasta", "1.5 cups shredded Monterey Jack or Gruyere cheese"], steps: ["Season beef with salt and pepper. In a large skillet, heat oil over medium-high heat; brown beef in batches. Transfer beef to a 5-qt. slow cooker. In the same skillet, melt butter over medium heat. Add onions; cook and stir until golden brown, 15–20 minutes. Stir in garlic and flour until combined; cook 1 minute. Gradually stir in wine, scraping up browned bits.", "Gradually add beef broth, Worcestershire sauce, and rosemary to the skillet. Bring to a boil; cook and stir for 2 minutes. Pour onion mixture over beef in the slow cooker. Cook, covered, on low until beef is tender, 6–7 hours.", "Skim fat from stew. Stir in pasta. Cook, covered, on high until pasta is tender, 20–25 minutes. Sprinkle with cheese; cover and let stand until cheese is melted, about 5 minutes."], cachedAt: bootstrapDate),

        RecipeDatabaseEntry(title: "Best Ever Potato Soup", description: "A velvety, ultra-creamy potato soup loaded with tender potato chunks, celery, and onions in a rich, buttery broth, finished with crispy bacon, cheddar cheese, and fresh green onions.", sourceURL: "https://www.tasteofhome.com/recipes/best-ever-potato-soup/", sourceName: "Taste of Home", prepTime: "20 minutes", cookTime: "20 minutes", totalTime: "40 minutes", servings: "8", category: "soup", cuisine: "", tags: ["soup", "potatoes", "bacon", "cheese", "comfort food", "quick meal", "test kitchen"], ingredients: ["3 cups cubed peeled potatoes", "1/2 cup diced celery", "1/2 cup finely chopped onion", "2.5 cups boiling water", "1/2 teaspoon salt", "5 tablespoons butter", "5 tablespoons all-purpose flour", "3.5 cups milk", "1/2 teaspoon pepper", "1 teaspoon chicken bouillon granules", "1 cup shredded cheddar cheese", "8 bacon strips, cooked and crumbled", "3 green onions, thinly sliced"], steps: ["In a large saucepan, combine potatoes, celery, onion, boiling water, and salt. Bring to a boil. Reduce heat; cover and simmer for 15 minutes or until vegetables are tender.", "Meanwhile, in another saucepan, melt butter. Stir in flour until smooth. Gradually add milk, pepper, and bouillon granules. Bring to a boil; cook and stir for 2 minutes or until thickened.", "Stir the white sauce into the potato mixture (do not drain the potatoes). Heat through. Ladle into bowls and top with shredded cheese, crumbled bacon, and green onions."], cachedAt: bootstrapDate),

        RecipeDatabaseEntry(title: "Slow-Cooker Beef Tips", description: "Tender cubes of beef sirloin slow-cooked in a rich, savory gravy made from mushroom soup, onion soup mix, and ginger ale. Absolutely incredible served over hot mashed potatoes or egg noodles.", sourceURL: "https://www.tasteofhome.com/recipes/slow-cooker-beef-tips/", sourceName: "Taste of Home", prepTime: "15 minutes", cookTime: "6 hours", totalTime: "6 hours 15 minutes", servings: "6", category: "beef", cuisine: "", tags: ["beef", "slow cooker", "gravy", "comfort food", "easy", "weeknight"], ingredients: ["2 pounds beef sirloin tips, cut into 1-inch cubes", "1 can (10.5 oz) condensed cream of mushroom soup, undiluted", "1 packet (1 oz) onion soup mix", "1 cup ginger ale or beef broth", "1/2 cup fresh sliced mushrooms (optional)", "4 cups cooked egg noodles or mashed potatoes", "2 tablespoons chopped fresh parsley (for garnish)"], steps: ["Place beef tips and mushrooms in a 3-qt. slow cooker. In a medium bowl, whisk together the cream of mushroom soup, onion soup mix, and ginger ale until smooth. Pour over the beef.", "Cover and cook on low for 6–7 hours or on high for 3–4 hours until the beef is melt-in-your-mouth tender.", "Stir the beef tips and gravy well. Spoon generously over hot cooked egg noodles or fluffy mashed potatoes, and garnish with chopped fresh parsley."], cachedAt: bootstrapDate),

        RecipeDatabaseEntry(title: "Classic Chicken Pot Pie", description: "A classic homemade chicken pot pie with a flaky, buttery double crust filled with tender chicken breasts, peas, carrots, and celery in a rich cream sauce.", sourceURL: "https://www.tasteofhome.com/recipes/favorite-chicken-pot-pie/", sourceName: "Taste of Home", prepTime: "30 minutes", cookTime: "35 minutes", totalTime: "1 hour 5 minutes", servings: "8", category: "chicken", cuisine: "", tags: ["chicken", "pot pie", "comfort food", "baking", "pie crust", "test kitchen"], ingredients: ["1 package (14.1 oz) refrigerated pie crusts (2 crusts)", "1/3 cup butter", "1/3 cup chopped onion", "1/3 cup all-purpose flour", "1/2 teaspoon salt", "1/4 teaspoon pepper", "1.75 cups chicken broth", "2/3 cup milk", "3 cups cooked shredded chicken", "2 cups frozen peas and carrots, thawed", "1/2 cup chopped celery"], steps: ["Preheat oven to 425°F. In a large saucepan, melt butter over medium heat. Add onion and celery; cook and stir until tender, about 5 minutes. Stir in flour, salt, and pepper until smooth. Gradually stir in chicken broth and milk.", "Bring the sauce to a boil; cook and stir for 2 minutes or until thickened. Stir in the shredded chicken, peas, and carrots. Remove from heat.", "Line a 9-inch pie plate with the bottom crust. Pour in the hot chicken filling. Top with the remaining pie crust; trim, seal, and flute the edges. Cut small slits in the top crust. Bake for 35–40 minutes or until the crust is golden brown and the filling is bubbly."], cachedAt: bootstrapDate),

        RecipeDatabaseEntry(title: "Best-Ever Macaroni and Cheese", description: "An incredibly rich, creamy, and cheesy baked macaroni and cheese featuring elbow macaroni blanketed in a smooth cheddar cheese roux sauce, topped with a golden, buttery breadcrumb crust.", sourceURL: "https://www.tasteofhome.com/recipes/best-ever-macaroni-and-cheese/", sourceName: "Taste of Home", prepTime: "20 minutes", cookTime: "30 minutes", totalTime: "50 minutes", servings: "8", category: "pasta", cuisine: "", tags: ["pasta", "cheese", "mac and cheese", "comfort food", "baked", "family favorite"], ingredients: ["2 cups uncooked elbow macaroni", "1/4 cup butter", "1/4 cup all-purpose flour", "1/2 teaspoon salt", "1/4 teaspoon pepper", "2 cups milk", "2 cups shredded sharp cheddar cheese", "2 tablespoons butter, melted", "1/2 cup dry bread crumbs"], steps: ["Preheat oven to 350°F. Cook macaroni according to package directions; drain. In a large saucepan, melt 1/4 cup butter over medium heat. Stir in flour, salt, and pepper until smooth. Gradually whisk in milk. Bring to a boil; cook and stir for 2 minutes or until thickened.", "Reduce heat to low; stir in shredded cheddar cheese until melted. Fold in the cooked macaroni. Transfer the mixture to a greased 2-qt. baking dish.", "In a small bowl, toss the bread crumbs with melted butter. Sprinkle evenly over the macaroni. Bake uncovered for 30 minutes or until bubbly and golden brown on top."], cachedAt: bootstrapDate),

        RecipeDatabaseEntry(title: "Hearty Beef Goulash", description: "An old-fashioned Midwestern classic, also known as American Goulash. Ground beef, onions, sweet bell peppers, and elbow macaroni are simmered together in a rich, seasoned tomato broth.", sourceURL: "https://www.tasteofhome.com/recipes/grandma-s-beef-goulash/", sourceName: "Taste of Home", prepTime: "15 minutes", cookTime: "30 minutes", totalTime: "45 minutes", servings: "6", category: "beef", cuisine: "", tags: ["beef", "ground beef", "pasta", "goulash", "one pot", "comfort food", "weeknight"], ingredients: ["1 pound ground beef", "1 large onion, chopped", "1 green bell pepper, chopped", "2 garlic cloves, minced", "2 cans (14.5 oz each) diced tomatoes, undrained", "1 can (15 oz) tomato sauce", "1 cup beef broth", "1 tablespoon Worcestershire sauce", "2 teaspoons paprika", "1 teaspoon Italian seasoning", "1/2 teaspoon salt", "1/4 teaspoon black pepper", "1.5 cups uncooked elbow macaroni"], steps: ["In a large Dutch oven over medium-high heat, cook ground beef, onion, and bell pepper until meat is no longer pink and vegetables are tender; drain any excess fat. Add garlic and cook 1 minute more.", "Stir in the diced tomatoes, tomato sauce, beef broth, Worcestershire sauce, paprika, Italian seasoning, salt, and pepper. Bring to a boil; reduce heat and simmer uncovered for 15 minutes.", "Stir in the uncooked macaroni. Cover and simmer over medium-low heat for 12–15 minutes, stirring occasionally, until the pasta is tender. Serve hot."], cachedAt: bootstrapDate),

        RecipeDatabaseEntry(title: "Flaky Chicken Dumpling Soup", description: "A comforting, creamy chicken soup packed with garden vegetables and loaded with light, fluffy scratch-made parsley drop dumplings that steam directly inside the savory broth.", sourceURL: "https://www.tasteofhome.com/recipes/homemade-chicken-and-dumplings/", sourceName: "Taste of Home", prepTime: "25 minutes", cookTime: "25 minutes", totalTime: "50 minutes", servings: "6", category: "chicken", cuisine: "", tags: ["chicken", "soup", "dumplings", "comfort food", "from scratch", "test kitchen"], ingredients: ["2 tablespoons butter", "1 medium onion, chopped", "3 carrots, sliced", "2 celery ribs, sliced", "6 cups chicken broth", "3 cups cooked chicken, shredded", "1/2 teaspoon dried basil", "1/4 teaspoon pepper", "2 cups all-purpose flour", "1 tablespoon baking powder", "1/2 teaspoon salt", "1 tablespoon minced fresh parsley", "1 cup milk", "3 tablespoons butter, melted"], steps: ["In a large Dutch oven, melt butter over medium heat. Add onion, carrots, and celery; cook and stir until crisp-tender, about 5 minutes. Add chicken broth, shredded chicken, basil, and pepper. Bring to a boil; reduce heat and simmer uncovered for 10 minutes.", "In a medium bowl, whisk together flour, baking powder, salt, and parsley. In a small bowl, combine milk and melted butter; stir into dry ingredients just until moistened (do not overmix).", "Drop dough by rounded tablespoons onto the simmering soup. Cover tightly and simmer without lifting the lid for 15 minutes, or until a toothpick inserted into a dumpling comes out clean. Serve hot."], cachedAt: bootstrapDate),

        RecipeDatabaseEntry(title: "Creamy Salisbury Steak", description: "Tender, seasoned ground beef patties seared golden brown and smothered in a rich, from-scratch brown onion and mushroom gravy. A nostalgic comfort classic.", sourceURL: "https://www.tasteofhome.com/recipes/flavorful-salisbury-steak/", sourceName: "Taste of Home", prepTime: "15 minutes", cookTime: "20 minutes", totalTime: "35 minutes", servings: "4", category: "beef", cuisine: "", tags: ["beef", "ground beef", "salisbury steak", "gravy", "comfort food", "quick meal", "weeknight"], ingredients: ["1 pound ground beef", "1/3 cup dry bread crumbs", "1 egg, lightly beaten", "2 tablespoons milk", "1/2 teaspoon onion powder", "1/2 teaspoon salt", "1/4 teaspoon pepper", "1 tablespoon olive oil", "1 small onion, thinly sliced", "1 cup sliced fresh mushrooms", "2 tablespoons all-purpose flour", "1.5 cups beef broth", "1 teaspoon Worcestershire sauce"], steps: ["In a large bowl, combine ground beef, bread crumbs, egg, milk, onion powder, salt, and pepper. Mix lightly but thoroughly; shape into 4 oval patties. In a large skillet, heat olive oil over medium-high heat. Brown patties on both sides; remove from skillet and keep warm.", "Add onion and mushrooms to the same skillet; cook and stir until tender, about 5 minutes. Stir in flour until combined. Gradually whisk in beef broth and Worcestershire sauce, scraping up any browned bits. Bring to a boil; cook and stir for 1–2 minutes until thickened.", "Return the patties to the skillet. Reduce heat; cover and simmer for 10 minutes or until beef patties are fully cooked through. Serve topped with the gravy."], cachedAt: bootstrapDate),

        RecipeDatabaseEntry(title: "Smoked Sausage Corn Chowder", description: "A thick, velvety, sweet corn chowder packed with smoky sliced kielbasa sausage, tender red potatoes, celery, and sweet onions. Cozy comfort in a bowl.", sourceURL: "https://www.tasteofhome.com/recipes/smoked-sausage-corn-chowder/", sourceName: "Taste of Home", prepTime: "15 minutes", cookTime: "25 minutes", totalTime: "40 minutes", servings: "6", category: "soup", cuisine: "", tags: ["soup", "chowder", "sausage", "corn", "potatoes", "comfort food", "quick meal"], ingredients: ["1 pound smoked kielbasa or sausage, sliced into rounds", "1 tablespoon butter", "1 medium sweet onion, chopped", "2 celery ribs, chopped", "3 cups diced unpeeled red potatoes", "2 cups chicken broth", "2 cans (14.75 oz each) cream-style corn", "2 cups half-and-half cream", "1/2 teaspoon salt", "1/4 teaspoon pepper"], steps: ["In a large Dutch oven, melt butter over medium-high heat. Add sliced sausage, onion, and celery; cook and stir until sausage is lightly browned and vegetables are tender, about 6–7 minutes.", "Add the diced red potatoes and chicken broth to the pot. Bring to a boil. Reduce heat; cover and simmer for 10–12 minutes or until potatoes are fork-tender.", "Stir in both cans of cream-style corn, half-and-half, salt, and pepper. Cook uncovered over medium-low heat until completely heated through, about 5 minutes (do not boil after adding cream). Serve hot."], cachedAt: bootstrapDate),

        RecipeDatabaseEntry(title: "Homemade Chicken Biscuit Pot Pie", description: "A delicious twist on pot pie. Creamy chicken filling topped with refrigerated flaky golden buttermilk biscuits instead of a traditional pie crust.", sourceURL: "https://www.tasteofhome.com/recipes/chicken-biscuit-pot-pie/", sourceName: "Taste of Home", prepTime: "20 minutes", cookTime: "20 minutes", totalTime: "40 minutes", servings: "6", category: "chicken", cuisine: "", tags: ["chicken", "pot pie", "biscuits", "casserole", "comfort food", "easy", "weeknight"], ingredients: ["1/4 cup butter", "1 small onion, chopped", "1 cup sliced fresh mushrooms", "1/4 cup all-purpose flour", "1.5 cups chicken broth", "3/4 cup milk", "3 cups cooked chicken, cubed", "2 cups frozen mixed vegetables, thawed", "1/2 teaspoon salt", "1/4 teaspoon pepper", "1 can (12 oz) refrigerated flaky buttermilk biscuits"], steps: ["Preheat oven to 400°F. In a large skillet or oven-safe pan, melt butter over medium heat. Add onion and mushrooms; cook and stir until tender, 5 minutes. Stir in flour until smooth. Gradually stir in chicken broth and milk.", "Bring to a boil; cook and stir for 2 minutes until thickened. Stir in chicken, vegetables, salt, and pepper. Heat through, then transfer to a greased 2-qt. baking dish.", "Arrange the uncooked biscuits on top of the hot chicken mixture. Bake for 18–22 minutes or until the biscuits are deep golden brown and cooked through, and filling is bubbling."], cachedAt: bootstrapDate),

        RecipeDatabaseEntry(title: "Classic Swiss Steak", description: "Budget-friendly beef round steak tenderized and braised slow and low in a robust tomato sauce with sliced onions and green bell peppers until completely melt-in-your-mouth tender.", sourceURL: "https://www.tasteofhome.com/recipes/easy-swiss-steak/", sourceName: "Taste of Home", prepTime: "15 minutes", cookTime: "1 hour 30 minutes", totalTime: "1 hour 45 minutes", servings: "6", category: "beef", cuisine: "", tags: ["beef", "swiss steak", "braised", "tomatoes", "peppers", "comfort food", "budget friendly"], ingredients: ["2 pounds beef top round steak, cut into single portions", "1/4 cup all-purpose flour", "1/2 teaspoon salt", "1/4 teaspoon pepper", "2 tablespoons canola oil", "1 large onion, sliced", "1 green bell pepper, sliced", "1 can (14.5 oz) diced tomatoes, undrained", "1 can (8 oz) tomato sauce", "1 teaspoon Worcestershire sauce"], steps: ["Combine flour, salt, and pepper in a shallow dish. Dredge beef portions in flour mixture. In a large heavy skillet or Dutch oven, heat oil over medium-high heat. Sear beef on both sides until browned; remove steak and drain any excess grease.", "Arrange sliced onions and green bell peppers over the bottom of the skillet. Place beef steaks back over the vegetables. Pour the undrained diced tomatoes, tomato sauce, and Worcestershire sauce completely over the beef.", "Bring to a boil; reduce heat to low. Cover tightly and simmer for 1.5 hours or until the round steak is incredibly tender. Serve steaks hot coated in the vegetable tomato sauce."], cachedAt: bootstrapDate),

        RecipeDatabaseEntry(title: "Creamy Chicken and Broccoli Casserole", description: "A comforting, classic baked pasta dish featuring medium conchiglie shells, tender cubed chicken, and fresh broccoli florets tossed in a rich, velvety cheddar cheese cream sauce.", sourceURL: "https://www.tasteofhome.com/recipes/chicken-broccoli-shell-casserole/", sourceName: "Taste of Home", prepTime: "20 minutes", cookTime: "25 minutes", totalTime: "45 minutes", servings: "6", category: "chicken", cuisine: "", tags: ["chicken", "casserole", "pasta", "broccoli", "cheese", "comfort food", "weeknight"], ingredients: ["2 cups uncooked medium pasta shells", "2 cups fresh broccoli florets", "2 tablespoons butter", "1 small onion, finely chopped", "2 tablespoons all-purpose flour", "1.5 cups milk", "1 can (10.5 oz) condensed cream of chicken soup, undiluted", "2 cups cooked chicken, cubed", "1.5 cups shredded cheddar cheese, divided", "1/4 teaspoon salt", "1/4 teaspoon pepper"], steps: ["Preheat oven to 350°F. Cook pasta according to package directions, adding broccoli during the last 3 minutes of boiling; drain and set aside.", "In a saucepan, melt butter over medium heat. Sauté onion until tender. Stir in flour until smooth. Gradually whisk in milk and cream of chicken soup. Bring to a boil; cook and stir for 2 minutes until thickened. Reduce heat; stir in 1 cup of cheddar cheese until melted.", "Stir chicken, salt, pepper, pasta, and broccoli into the cheese sauce. Transfer to a greased 2-qt. baking dish. Sprinkle remaining 1/2 cup cheese on top. Bake uncovered for 25 minutes or until bubbling."], cachedAt: bootstrapDate),
        ]
    }
}

// MARK: - RecipeDatabaseManager (@Observable, MainActor)
// The SwiftUI-facing object. Inject via .environment or use .shared.
@Observable
@MainActor
final class RecipeDatabaseManager {
    static let shared = RecipeDatabaseManager()

    private let db = RecipeDatabase.shared

    var totalCount: Int = 0

    /// Bumped whenever the writable pool gains rows outside the per-recipe add paths —
    /// today, the Mac-harvested cache landing via `ingestHarvested`. Views that hold a
    /// snapshot can observe this and reload so newly synced recipes appear without waiting
    /// for the screen to be dismissed and reopened.
    var recipesVersion: Int = 0

    init() {
        Task { await refreshCount() }
        // Merge other caches on launch
        Task(priority: .background) {
            await self.mergeAllSources()
        }
    }

    // MARK: Predictive Search
    /// Returns ranked suggestions for a partial recipe title / ingredient / tag.
    /// Call this from any TextField's onChange to power autocomplete.
    ///
    /// Queries the small writable store (user/web/seed recipes) first, then fills
    /// any remaining slots from the large read-only corpus (RecipeStore, FTS5).
    /// Corpus rows are fetched on demand — the 98k recipes are never all in memory.
    func suggestions(for query: String, limit: Int = 8) async -> [RecipeDatabaseEntry] {
        let primary = await db.search(query, limit: limit)
        if primary.count >= limit { return primary }

        let corpus = await RecipeStore.shared.search(query, limit: limit)
        guard !corpus.isEmpty else { return primary }

        // Merge, de-duplicating by normalized title so a dish present in both the
        // writable store and the corpus isn't shown twice (writable wins).
        var seen = Set(primary.map { RecipeStore.titleKey($0.title) })
        var merged = primary
        for entry in corpus {
            let key = RecipeStore.titleKey(entry.title)
            if seen.insert(key).inserted {
                merged.append(entry)
                if merged.count >= limit { break }
            }
        }
        return merged
    }

    /// Synchronous variant — fine for filtering a small in-memory snapshot.
    /// Load `snapshot` once on view appear; keep it fresh with a background task.
    func suggestions(for query: String, in snapshot: [RecipeDatabaseEntry], limit: Int = 8) -> [RecipeDatabaseEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 1 else { return [] }
        let byTitle    = snapshot.filter { $0.title.lowercased().hasPrefix(q) }
        let byAnywhere = snapshot.filter { entry in
            let idx = ([entry.title, entry.description, entry.category, entry.cuisine]
                + entry.tags + entry.ingredients + [entry.sourceName])
                .joined(separator: " ").lowercased()
            return !entry.title.lowercased().hasPrefix(q) && idx.contains(q)
        }
        return Array((byTitle + byAnywhere).prefix(limit))
    }

    // MARK: Snapshot for Views
    func loadSnapshot() async -> [RecipeDatabaseEntry] {
        await db.all()
    }

    // MARK: Corpus-backed reads (large read-only RecipeNLG store via RecipeStore)
    /// A random batch of presentable corpus recipes (image + steps) for Discover /
    /// offline seeding. Pulls only `limit` rows — never the whole corpus.
    func corpusPresentable(limit: Int = 30) async -> [RecipeDatabaseEntry] {
        await RecipeStore.shared.randomPresentable(limit: limit)
    }

    /// Highest-quality corpus recipes first.
    func corpusTopByQuality(limit: Int = 60) async -> [RecipeDatabaseEntry] {
        await RecipeStore.shared.topByQuality(limit: limit)
    }

    /// Direct corpus search (FTS5), bypassing the writable store. Useful for views
    /// that specifically want the broad catalogue.
    func corpusSearch(_ query: String, limit: Int = 20) async -> [RecipeDatabaseEntry] {
        await RecipeStore.shared.search(query, limit: limit)
    }

    // MARK: Add / Delete
    func add(entry: RecipeDatabaseEntry) async {
        await db.upsert(entry)
        await refreshCount()
    }

    /// Fold a batch of externally-sourced recipes (the Mac-harvested cache) into the pool,
    /// then refresh the count, bump the version token, and announce the change on the bus.
    /// Callers that used to reach through to `RecipeDatabase.shared.upsertAll` directly
    /// should use this so every surface — counts, Discover, search, planners — sees the new
    /// rows instead of only the actor's private store gaining them silently.
    @discardableResult
    func ingestHarvested(_ entries: [RecipeDatabaseEntry]) async -> [RecipeDatabaseEntry] {
        guard !entries.isEmpty else { return [] }
        let inserted = await db.upsertAll(entries)
        await refreshCount()
        recipesVersion &+= 1
        DatabaseSyncBus.shared.publish(.recipeDatabaseChanged(count: inserted.count))
        return inserted
    }

    /// Convert and save a UserRecipe into the database immediately.
    func save(userRecipe: UserRecipe) async {
        let entry = RecipeDatabaseEntry(
            title: userRecipe.title, description: userRecipe.description,
            sourceURL: "", sourceName: "My Recipes",
            prepTime: userRecipe.prepTime, cookTime: userRecipe.cookTime, totalTime: "",
            servings: String(userRecipe.servings), category: userRecipe.tags.first ?? "",
            cuisine: userRecipe.cuisine, tags: userRecipe.tags,
            ingredients: userRecipe.ingredients.map { "\($0.amount) \($0.name)" },
            steps: userRecipe.instructions, imageURL: userRecipe.imageURL ?? ""
        )
        await db.upsert(entry)
        await refreshCount()
    }

    func delete(id: UUID) async {
        await db.delete(id: id)
        await refreshCount()
    }

    /// Drops every entry from a retired source. Called by the launch sweep in
    /// `RecipePurge.run`; exposed here so a view can offer it too without reaching
    /// through to the actor.
    @discardableResult
    func purgeBlockedSources() async -> Int {
        let removed = await db.purgeBlockedSources()
        if removed > 0 { await refreshCount() }
        return removed
    }

    // MARK: Merge from all live caches
    func mergeAllSources() async {
        // Snapshot on MainActor, then convert away from it. These caches can contain hundreds
        // of rich rows; mapping every ingredient/step during launch used to compete with first paint.
        // 1. OfflineRecipeCache
        let offlineRaw = OfflineRecipeCache.shared.recipes
        let offlineEntries = await Task.detached(priority: .utility) {
            offlineRaw.map { r -> RecipeDatabaseEntry in
                RecipeDatabaseEntry(
                    title: r.title, description: r.description ?? "",
                    sourceURL: r.sourceURL ?? "", sourceName: r.source,
                    prepTime: r.prepTime ?? "", cookTime: r.cookTime ?? "", totalTime: "",
                    servings: r.servings ?? "", category: r.category, cuisine: r.area,
                    tags: r.tags, ingredients: r.ingredients, steps: r.steps,
                    imageURL: r.imageURL
                )
            }
        }.value
        await db.mergeEntries(offlineEntries)

        // 2. WebRecipeCatalogue
        let webRaw = await WebRecipeCatalogue.shared.all()
        let webEntries = await Task.detached(priority: .utility) {
            webRaw.map { r -> RecipeDatabaseEntry in
                RecipeDatabaseEntry(
                    title: r.title, description: r.description,
                    sourceURL: r.sourceURL, sourceName: r.sourceName,
                    prepTime: r.prepTime, cookTime: r.cookTime, totalTime: r.totalTime,
                    servings: r.servings, category: r.category, cuisine: r.cuisine,
                    tags: r.tags,
                    ingredients: r.ingredients,
                    steps: r.steps.map { $0.text },
                    imageURL: r.imageURL, calories: r.calories ?? "", rating: r.rating,
                    cachedAt: r.cachedAt
                )
            }
        }.value
        await db.mergeEntries(webEntries)

        // 3. Auto-discover and import any new bundled JSON files
        await BundleDataImporter.shared.importNewBundledFiles()

        await refreshCount()
        // Let open surfaces refresh after a full merge (launch and .fullSync both land here).
        recipesVersion &+= 1
        DatabaseSyncBus.shared.publish(.recipeDatabaseChanged(count: 0))
    }

    // MARK: Autofill helper
    /// Call this when the user taps a suggestion chip in any recipe form.
    /// Writes all known fields into the provided form binding in one shot.
    func autofill(from entry: RecipeDatabaseEntry, into form: inout AddRecipeForm) {
        form.fill(from: entry)
    }

    // MARK: - Popularity + Cache
    func recordOpen(id: UUID) async {
        await db.recordOpen(id: id)
    }

    func invalidateSearchCache() {
        // Clears any cached results so next search reflects updated popularity
    }

    // Memory warning — RecipeDatabase can rebuild from disk
    func handleMemoryWarning() {
        // The actor holds entries in memory; on severe pressure we can clear
        // and rely on disk persistence to rebuild. For now just log.
    }

    private func refreshCount() async {
        // Writable store (user/web/seed) + the large read-only corpus (RecipeStore).
        let writable = await db.count()
        let corpus   = await RecipeStore.shared.count()
        totalCount = writable + corpus
    }
    // MARK: - Bootstrap seed from DeepSeek/Taste of Home export (14 recipes, May 2026)
    func bootstrapSeedIfNeeded() async {
        let key = "recipeSeedV2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let seed: [RecipeDatabaseEntry] = [
        RecipeDatabaseEntry(
            title: "Creamy Chicken and Rice Casserole", description: "A comforting one-dish meal featuring tender chicken, creamy rice, and a blend of vegetables, all bak",
            sourceURL: "https://www.tasteofhome.com/recipes/creamy-chicken-and-rice-casserole/", sourceName: "Taste of Home",
            prepTime: "15 minutes", cookTime: "45 minutes", totalTime: "60 minutes",
            servings: "6", category: "Dinner", cuisine: "American",
            tags: ["chicken", "rice", "casserole", "comfort food", "easy dinner"],
            ingredients: ["1 can (10.75 oz) condensed cream of chicken soup, undiluted", "1 can (10.75 oz) condensed cream of mushroom soup, undiluted", "1 cup water", "1 cup uncooked long grain rice", "1 envelope onion soup mix", "4 boneless skinless chicken breast halves", "Paprika"],
            steps: ["In a large bowl, combine the soups, water, rice and soup mix. Pour into a greased 13x9-in. baking dish.", "Top with chicken; sprinkle with paprika.", "Cover and bake at 350° for 45 minutes or until rice is tender and chicken juices run clear."]
        ),
        RecipeDatabaseEntry(
            title: "Slow Cooker Pulled Pork", description: "Tender, flavorful pulled pork made effortlessly in the slow cooker. Perfect for sandwiches, tacos, o",
            sourceURL: "https://www.tasteofhome.com/recipes/slow-cooker-pulled-pork/", sourceName: "Taste of Home",
            prepTime: "15 minutes", cookTime: "8 hours", totalTime: "8 hours 15 minutes",
            servings: "12", category: "Dinner", cuisine: "American",
            tags: ["pork", "slow cooker", "bbq", "sandwiches", "comfort food"],
            ingredients: ["1 boneless pork shoulder roast (3 to 4 pounds)", "1 large onion, chopped", "1 cup beef broth", "2 tablespoons brown sugar", "1 tablespoon smoked paprika", "2 teaspoons garlic powder", "2 teaspoons onion powder", "1 teaspoon salt", "1/2 teaspoon black pepper", "1 bottle (18 oz) barbecue sauce"],
            steps: ["Cut roast in half; place in a 5-qt. slow cooker. Add onion and broth.", "Combine dry seasonings; rub over pork.", "Cover and cook on low for 8-10 hours or until meat is tender.", "Remove meat; shred with two forks. Skim fat from cooking juices; return meat to slow cooker. Stir in barbecue sauce and "]
        ),
        RecipeDatabaseEntry(
            title: "Classic Meatloaf", description: "A traditional meatloaf with a sweet and tangy glaze that makes it a family favorite. Moist, flavorfu",
            sourceURL: "https://www.tasteofhome.com/recipes/classic-meatloaf/", sourceName: "Taste of Home",
            prepTime: "15 minutes", cookTime: "1 hour 10 minutes", totalTime: "1 hour 25 minutes",
            servings: "8", category: "Dinner", cuisine: "American",
            tags: ["meatloaf", "beef", "pork", "comfort food", "family dinner"],
            ingredients: ["2 eggs, lightly beaten", "3/4 cup milk", "1/2 cup seasoned bread crumbs", "1/2 cup finely chopped onion", "1 teaspoon salt", "1/2 teaspoon rubbed sage", "1/2 teaspoon pepper", "1-1/2 pounds ground beef", "1/2 pound ground pork", "1/4 cup ketchup", "2 tablespoons brown sugar", "1 teaspoon ground mustard"],
            steps: ["Preheat oven to 350°. In a large bowl, combine eggs, milk, bread crumbs, onion, salt, sage and pepper. Crumble beef and ", "Shape into a loaf in a greased 11x7-in. baking dish. Bake, uncovered, for 60 minutes.", "In a small bowl, combine ketchup, brown sugar and mustard; spoon over meatloaf. Bake 10-15 minutes longer or until no pi"]
        ),
        RecipeDatabaseEntry(
            title: "Zesty Slow Cooker Chicken", description: "A tangy, flavorful chicken dish that cooks itself in the slow cooker. Great over rice or shredded fo",
            sourceURL: "https://www.tasteofhome.com/recipes/zesty-slow-cooker-chicken/", sourceName: "Taste of Home",
            prepTime: "10 minutes", cookTime: "3 hours", totalTime: "3 hours 10 minutes",
            servings: "6", category: "Dinner", cuisine: "American",
            tags: ["chicken", "slow cooker", "taco", "Mexican-inspired", "easy"],
            ingredients: ["6 boneless skinless chicken breast halves (4 ounces each)", "1 envelope taco seasoning", "1 can (10.75 oz) condensed cream of chicken soup, undiluted", "1 cup salsa"],
            steps: ["Place chicken in a 3-qt. slow cooker. Sprinkle with taco seasoning.", "In a small bowl, combine soup and salsa; pour over chicken.", "Cover and cook on low for 3-4 hours or until chicken is tender."]
        ),
        RecipeDatabaseEntry(
            title: "Homemade Beef Stew", description: "A rich, hearty beef stew loaded with tender meat, potatoes, carrots, and onions in a savory broth. P",
            sourceURL: "https://www.tasteofhome.com/recipes/homemade-beef-stew/", sourceName: "Taste of Home",
            prepTime: "20 minutes", cookTime: "1 hour 50 minutes", totalTime: "2 hours 10 minutes",
            servings: "8", category: "Dinner", cuisine: "American",
            tags: ["beef", "stew", "comfort food", "potatoes", "carrots", "hearty"],
            ingredients: ["2 pounds beef stew meat, cut into 1-inch cubes", "1/4 cup all-purpose flour", "1/2 teaspoon salt", "1/2 teaspoon pepper", "2 tablespoons canola oil", "1 can (14.5 oz) diced tomatoes, undrained", "1 large onion, chopped", "3 medium carrots, sliced", "2 celery ribs, chopped", "3 medium potatoes, peeled and cubed", "2 cups water", "2 teaspoons beef bouillon granules"],
            steps: ["In a large resealable bag, combine flour, salt and pepper. Add beef, a few pieces at a time, and shake to coat. In a Dut", "Add the remaining ingredients to the pot; bring to a boil.", "Reduce heat; cover and simmer for 1-1/2 to 2 hours or until meat and vegetables are tender."]
        ),
        RecipeDatabaseEntry(
            title: "Easy Shepherd's Pie", description: "A quick and easy version of the classic comfort food featuring a savory ground beef and vegetable fi",
            sourceURL: "https://www.tasteofhome.com/recipes/easy-shepherds-pie/", sourceName: "Taste of Home",
            prepTime: "15 minutes", cookTime: "30 minutes", totalTime: "45 minutes",
            servings: "6", category: "Dinner", cuisine: "American",
            tags: ["beef", "shepherd's pie", "potatoes", "casserole", "comfort food"],
            ingredients: ["1 pound ground beef", "1 small onion, chopped", "1 can (15.25 oz) whole kernel corn, drained", "1 can (14.5 oz) diced tomatoes, undrained", "1 can (8 oz) tomato sauce", "2 teaspoons chili powder", "1/2 teaspoon salt", "1/4 teaspoon pepper", "2 cups hot mashed potatoes (prepared with milk and butter)"],
            steps: ["In a large skillet, cook beef and onion over medium heat until meat is no longer pink; drain.", "Stir in the corn, tomatoes, tomato sauce, chili powder, salt and pepper. Bring to a boil.", "Spoon into a greased 1-1/2-qt. baking dish. Top with mashed potatoes. Bake, uncovered, at 350° for 25-30 minutes or unti"]
        ),
        RecipeDatabaseEntry(
            title: "Slow Cooker Chicken Noodle Soup", description: "A soothing, homemade chicken noodle soup made effortlessly in the slow cooker. Perfect for cold and ",
            sourceURL: "https://www.tasteofhome.com/recipes/slow-cooker-chicken-noodle-soup/", sourceName: "Taste of Home",
            prepTime: "20 minutes", cookTime: "5 hours", totalTime: "5 hours 20 minutes",
            servings: "8", category: "Dinner", cuisine: "American",
            tags: ["chicken", "soup", "noodles", "slow cooker", "comfort food"],
            ingredients: ["1 broiler/fryer chicken (3 to 4 pounds), cut up", "3 celery ribs, chopped", "3 medium carrots, chopped", "2 medium onions, chopped", "3 cups water", "4 teaspoons chicken bouillon granules", "1/2 teaspoon dried thyme", "1/2 teaspoon pepper", "1 bay leaf", "3 cups uncooked egg noodles"],
            steps: ["In a 5-qt. slow cooker, combine the chicken, celery, carrots, onions, water, bouillon, thyme, pepper and bay leaf.", "Cover and cook on low for 5-6 hours or until chicken is tender.", "Remove chicken and bay leaf. When cool enough to handle, remove meat from bones; discard bones and skin. Cut meat into b", "Cover and cook on high for 15-20 minutes or until noodles are tender."]
        ),
        RecipeDatabaseEntry(
            title: "Cheesy Potato Casserole", description: "A creamy, cheesy potato casserole that's perfect for holidays and family gatherings. Topped with a c",
            sourceURL: "https://www.tasteofhome.com/recipes/cheesy-potato-casserole/", sourceName: "Taste of Home",
            prepTime: "15 minutes", cookTime: "45 minutes", totalTime: "60 minutes",
            servings: "8", category: "Dinner", cuisine: "American",
            tags: ["potatoes", "casserole", "cheese", "side dish", "holiday", "comfort food"],
            ingredients: ["1 package (32 oz) frozen cubed hash brown potatoes, thawed", "1 can (10.75 oz) condensed cream of potato soup, undiluted", "2 cups shredded cheddar cheese", "1 cup sour cream", "1/2 cup butter, melted", "1/2 cup chopped onion", "1/2 teaspoon salt", "1/4 teaspoon pepper", "2 cups cornflakes, crushed", "1/4 cup butter, melted"],
            steps: ["Preheat oven to 350°. In a large bowl, combine the first eight ingredients.", "Transfer to a greased 13x9-in. baking dish.", "Combine cornflakes and butter; sprinkle over top.", "Bake, uncovered, 45-50 minutes or until heated through."]
        ),
        RecipeDatabaseEntry(
            title: "Chicken Enchilada Casserole", description: "All the flavor of chicken enchiladas in an easy layered casserole. Loaded with chicken, cheese, and ",
            sourceURL: "https://www.tasteofhome.com/recipes/chicken-enchilada-casserole/", sourceName: "Taste of Home",
            prepTime: "20 minutes", cookTime: "35 minutes", totalTime: "55 minutes",
            servings: "6", category: "Dinner", cuisine: "American",
            tags: ["chicken", "casserole", "enchiladas", "Mexican-inspired", "cheese"],
            ingredients: ["2 cups shredded cooked chicken", "1 can (10.75 oz) condensed cream of chicken soup, undiluted", "1 cup salsa", "1/2 cup sour cream", "1 teaspoon chili powder", "6 flour tortillas (6 inches), cut into 1-inch strips", "2 cups shredded Mexican cheese blend"],
            steps: ["Preheat oven to 350°. In a large bowl, mix chicken, soup, salsa, sour cream and chili powder.", "In a greased 11x7-in. baking dish, layer half of the tortilla strips, half of the chicken mixture and half of the cheese", "Bake, uncovered, 30-35 minutes or until bubbly. Let stand 5 minutes before serving."]
        ),
        RecipeDatabaseEntry(
            title: "Grandma's Cornbread Dressing", description: "A traditional Southern cornbread dressing passed down through generations. Perfect for Thanksgiving ",
            sourceURL: "https://www.tasteofhome.com/recipes/grandmas-cornbread-dressing/", sourceName: "Taste of Home",
            prepTime: "20 minutes", cookTime: "45 minutes", totalTime: "1 hour 5 minutes",
            servings: "12", category: "Dinner", cuisine: "American",
            tags: ["dressing", "cornbread", "Thanksgiving", "holiday", "southern"],
            ingredients: ["1 pan (8x8 in.) cornbread, crumbled", "4 slices day-old bread, crumbled", "4 eggs, lightly beaten", "1 large onion, chopped", "2 celery ribs, chopped", "1 teaspoon salt", "1 teaspoon rubbed sage", "1/2 teaspoon pepper", "2 to 3 cups chicken broth"],
            steps: ["Preheat oven to 350°. In a large bowl, combine cornbread and bread crumbs. Stir in eggs, onion, celery, salt, sage and p", "Stir in enough broth to reach desired moistness.", "Transfer to a greased 13x9-in. baking dish. Bake, uncovered, 45-50 minutes or until lightly browned."]
        ),
        RecipeDatabaseEntry(
            title: "Slow Cooker Beef Stew", description: "A set-it-and-forget-it beef stew that simmers all day, filling your home with wonderful aromas. Tend",
            sourceURL: "https://www.tasteofhome.com/recipes/slow-cooker-beef-stew/", sourceName: "Taste of Home",
            prepTime: "20 minutes", cookTime: "8 hours", totalTime: "8 hours 20 minutes",
            servings: "8", category: "Dinner", cuisine: "American",
            tags: ["beef", "stew", "slow cooker", "comfort food", "potatoes", "carrots"],
            ingredients: ["2 pounds beef stew meat, cut into 1-inch cubes", "1/3 cup all-purpose flour", "1/2 teaspoon salt", "1/2 teaspoon pepper", "2 tablespoons canola oil", "1 can (14.5 oz) diced tomatoes, undrained", "1 large onion, chopped", "3 medium carrots, sliced", "2 celery ribs, chopped", "3 medium potatoes, peeled and cubed", "2 cups water", "2 teaspoons beef bouillon granules"],
            steps: ["In a large resealable bag, combine flour, salt and pepper. Add beef, a few pieces at a time, and shake to coat. In a lar", "Add the remaining ingredients to slow cooker.", "Cover and cook on low for 8-10 hours or until meat and vegetables are tender. Discard bay leaf before serving."]
        ),
        RecipeDatabaseEntry(
            title: "Chicken and Dumpling Casserole", description: "All the comfort of chicken and dumplings in an easy casserole form. Topped with fluffy biscuits for ",
            sourceURL: "https://www.tasteofhome.com/recipes/chicken-and-dumpling-casserole/", sourceName: "Taste of Home",
            prepTime: "15 minutes", cookTime: "35 minutes", totalTime: "50 minutes",
            servings: "6", category: "Dinner", cuisine: "American",
            tags: ["chicken", "dumplings", "casserole", "comfort food", "biscuits"],
            ingredients: ["1/4 cup butter", "1/2 cup chopped onion", "1/2 cup chopped celery", "1/4 cup all-purpose flour", "1 teaspoon poultry seasoning", "1/2 teaspoon salt", "1/4 teaspoon pepper", "1-3/4 cups chicken broth", "2/3 cup milk", "3 cups cubed cooked chicken", "1 package (10 oz) frozen peas and carrots, thawed", "1 tube (16.3 oz) refrigerated buttermilk biscuits"],
            steps: ["Preheat oven to 350°. In a large saucepan, melt butter over medium heat. Add onion and celery; cook and stir until tende", "Transfer to a greased 11x7-in. baking dish.", "Arrange biscuits over top. Bake, uncovered, 25-30 minutes or until biscuits are golden brown and filling is bubbly."]
        ),
        RecipeDatabaseEntry(
            title: "Hamburger Potato Casserole", description: "A hearty, budget-friendly casserole with layers of seasoned ground beef, sliced potatoes, and creamy",
            sourceURL: "https://www.tasteofhome.com/recipes/hamburger-potato-casserole/", sourceName: "Taste of Home",
            prepTime: "20 minutes", cookTime: "60 minutes", totalTime: "1 hour 20 minutes",
            servings: "6", category: "Dinner", cuisine: "American",
            tags: ["beef", "potatoes", "casserole", "ground beef", "comfort food", "budget-friendly"],
            ingredients: ["1 pound ground beef", "1 small onion, chopped", "1 can (10.75 oz) condensed cream of mushroom soup, undiluted", "1/4 cup milk", "1/2 teaspoon salt", "1/4 teaspoon pepper", "4 medium potatoes, peeled and thinly sliced", "1 cup shredded cheddar cheese"],
            steps: ["Preheat oven to 350°. In a large skillet, cook beef and onion over medium heat until meat is no longer pink; drain.", "In a small bowl, combine the soup, milk, salt and pepper.", "In a greased 2-qt. baking dish, layer half of the potatoes, beef mixture and soup mixture. Repeat layers.", "Cover and bake for 50 minutes. Uncover; sprinkle with cheese. Bake 10-15 minutes longer or until potatoes are tender."]
        ),
        RecipeDatabaseEntry(
            title: "Creamy Broccoli Casserole", description: "A creamy, cheesy broccoli casserole that even picky eaters will love. Perfect as a side dish for hol",
            sourceURL: "https://www.tasteofhome.com/recipes/creamy-broccoli-casserole/", sourceName: "Taste of Home",
            prepTime: "15 minutes", cookTime: "25 minutes", totalTime: "40 minutes",
            servings: "6", category: "Dinner", cuisine: "American",
            tags: ["broccoli", "casserole", "cheese", "vegetable", "side dish", "comfort food"],
            ingredients: ["2 packages (10 oz each) frozen chopped broccoli, thawed", "1 can (10.75 oz) condensed cream of mushroom soup, undiluted", "1 cup mayonnaise", "1 cup shredded cheddar cheese", "2 eggs, lightly beaten", "1 small onion, chopped", "1/2 cup crushed butter-flavored crackers (about 12 crackers)"],
            steps: ["Preheat oven to 350°. In a large bowl, combine the broccoli, soup, mayonnaise, cheese, eggs and onion.", "Transfer to a greased 2-qt. baking dish.", "Sprinkle with crackers. Bake, uncovered, 25-30 minutes or until heated through."]
        )
        ]
        for entry in seed { await RecipeDatabase.shared.upsert(entry) }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Called when user searches online recipes — logs query and pre-seeds matching local results
    func handleSearch(query: String) async {
        guard query.count > 2 else { return }
        let results = await RecipeDatabase.shared.search(query)
        _ = results.prefix(5).map { $0.title }
    }

}
