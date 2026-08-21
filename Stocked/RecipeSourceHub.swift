// RecipeSourceHub.swift — one place where every recipe source meets.
//
// Three jobs:
//   1. EXTENDED CATALOGUE — 30 additional recipe websites beyond the bundled list. The
//      registry's `bundled` and `everything` accessors merge these in, so filters, badges,
//      source counts, URL import, and the source lookup all see them automatically.
//   2. UNIFIED LISTING — `allSources(...)` builds the single list behind the new Sources
//      browser in Recipes: live data feeds (TheMealDB, TheCocktailDB, Spoonacular, DummyJSON,
//      Wikibooks, Taste of Home, …), every catalogue website (bundled + extended + the user's
//      custom ones), each with a live recipe count from the shared pool.
//   3. CROSS-SOURCE SYNC — `ingestIntoDatabase(_:)` writes presentable recipes fetched by the
//      Discover loader back into the on-device RecipeDatabase. That database already feeds
//      Discover's offline seed, search, the mood finder, and cook ranking — so once a recipe
//      arrives from ANY source, every area of the app can see it.
import Foundation

// MARK: - 30 additional catalogue sources

extension RecipeSourceRegistry {
    /// Thirty more recipe websites. Merged into `bundled` (and therefore `everything`),
    /// so they appear in the source picker, the Sources browser, and URL import support.
    nonisolated static let extended: [RecipeSource] = [
        RecipeSource(id: UUID(), domain: "bbcgoodfood.com",        displayName: "BBC Good Food",        category: .homeCook,      specialty: "Tested British classics",       iconEmoji: "🇬🇧"),
        RecipeSource(id: UUID(), domain: "delish.com",             displayName: "Delish",               category: .creative,      specialty: "Fun, bold crowd-pleasers",      iconEmoji: "🎉"),
        RecipeSource(id: UUID(), domain: "epicurious.com",         displayName: "Epicurious",           category: .professional,          specialty: "Test-kitchen expertise",        iconEmoji: "🎩"),
        RecipeSource(id: UUID(), domain: "food.com",               displayName: "Food.com",             category: .homeCook,      specialty: "Huge community archive",        iconEmoji: "🍲"),
        RecipeSource(id: UUID(), domain: "thekitchn.com",          displayName: "The Kitchn",           category: .homeCook,      specialty: "Everyday cooking know-how",     iconEmoji: "🏠"),
        RecipeSource(id: UUID(), domain: "smittenkitchen.com",     displayName: "Smitten Kitchen",      category: .homeCook,      specialty: "Fearless home baking",          iconEmoji: "🧁"),
        RecipeSource(id: UUID(), domain: "minimalistbaker.com",    displayName: "Minimalist Baker",     category: .healthy,       specialty: "10 ingredients or less",        iconEmoji: "🥄"),
        RecipeSource(id: UUID(), domain: "halfbakedharvest.com",   displayName: "Half Baked Harvest",   category: .creative,      specialty: "Cozy, layered flavors",         iconEmoji: "🌾"),
        RecipeSource(id: UUID(), domain: "damndelicious.net",      displayName: "Damn Delicious",       category: .homeCook,      specialty: "Quick weeknight wins",          iconEmoji: "⚡"),
        RecipeSource(id: UUID(), domain: "skinnytaste.com",        displayName: "Skinnytaste",          category: .healthy,       specialty: "Lightened-up favorites",        iconEmoji: "🥗"),
        RecipeSource(id: UUID(), domain: "budgetbytes.com",        displayName: "Budget Bytes",         category: .budget,        specialty: "Cost-per-serving recipes",      iconEmoji: "💰"),
        RecipeSource(id: UUID(), domain: "thewoksoflife.com",      displayName: "The Woks of Life",     category: .international, specialty: "Authentic Chinese cooking",     iconEmoji: "🥢"),
        RecipeSource(id: UUID(), domain: "maangchi.com",           displayName: "Maangchi",             category: .international, specialty: "Korean home cooking",           iconEmoji: "🇰🇷"),
        RecipeSource(id: UUID(), domain: "mexicanplease.com",      displayName: "Mexican Please",       category: .international, specialty: "Real-deal Mexican",             iconEmoji: "🌮"),
        RecipeSource(id: UUID(), domain: "vegrecipesofindia.com",  displayName: "Veg Recipes of India", category: .international, specialty: "Indian vegetarian depth",       iconEmoji: "🇮🇳"),
        RecipeSource(id: UUID(), domain: "thespruceeats.com",      displayName: "The Spruce Eats",      category: .homeCook,      specialty: "Technique-first guides",        iconEmoji: "🌿"),
        RecipeSource(id: UUID(), domain: "simplyrecipes.com",      displayName: "Simply Recipes",       category: .homeCook,      specialty: "Reliable family cooking",       iconEmoji: "🍋"),
        RecipeSource(id: UUID(), domain: "eatingwell.com",         displayName: "EatingWell",           category: .healthy,       specialty: "Dietitian-backed meals",        iconEmoji: "💚"),
        RecipeSource(id: UUID(), domain: "foodandwine.com",        displayName: "Food & Wine",          category: .professional,          specialty: "Restaurant-caliber dishes",     iconEmoji: "🍷"),
        RecipeSource(id: UUID(), domain: "bonappetit.com",         displayName: "Bon Appétit",          category: .professional,          specialty: "Modern test-kitchen hits",      iconEmoji: "👨‍🍳"),
        RecipeSource(id: UUID(), domain: "gimmesomeoven.com",      displayName: "Gimme Some Oven",      category: .homeCook,      specialty: "Feel-good favorites",           iconEmoji: "🔥"),
        RecipeSource(id: UUID(), domain: "pinchofyum.com",         displayName: "Pinch of Yum",         category: .creative,      specialty: "Photogenic comfort food",       iconEmoji: "📸"),
        RecipeSource(id: UUID(), domain: "loveandlemons.com",      displayName: "Love and Lemons",      category: .healthy,       specialty: "Vegetable-forward plates",      iconEmoji: "🍋"),
        RecipeSource(id: UUID(), domain: "davidlebovitz.com",      displayName: "David Lebovitz",       category: .professional,          specialty: "French pastry mastery",         iconEmoji: "🥐"),
        RecipeSource(id: UUID(), domain: "seriouseats.com",        displayName: "Serious Eats",         category: .professional,          specialty: "Science-driven cooking",        iconEmoji: "🔬"),
        RecipeSource(id: UUID(), domain: "101cookbooks.com",       displayName: "101 Cookbooks",        category: .healthy,       specialty: "Whole-food vegetarian",         iconEmoji: "📚"),
        RecipeSource(id: UUID(), domain: "themediterraneandish.com", displayName: "The Mediterranean Dish", category: .international, specialty: "Mediterranean staples",   iconEmoji: "🫒"),
        RecipeSource(id: UUID(), domain: "chinasichuanfood.com",   displayName: "China Sichuan Food",   category: .international, specialty: "Sichuan and beyond",            iconEmoji: "🌶️"),
        RecipeSource(id: UUID(), domain: "sallysbakingaddiction.com", displayName: "Sally's Baking",    category: .baking,      specialty: "Foolproof baking science",      iconEmoji: "🍪"),
        RecipeSource(id: UUID(), domain: "liquor.com",             displayName: "Liquor.com",           category: .creative,      specialty: "Classic and modern cocktails",  iconEmoji: "🍸"),
    ]
}

// MARK: - Unified source listing (for the Sources browser)

@MainActor
enum RecipeSourceHub {

    /// A source is only exposed as a browsable source when it can provide a real library,
    /// not a nearly-empty row. Five-or-fewer sources are treated as failed sources; 6–19 are
    /// kept as internal/import data but remain hidden until the source reaches twenty full recipes.
    // Six complete recipes is enough to make a useful source page. Requiring
    // twenty hid legitimate imported sites and made Sources look artificially
    // sparse even though their recipes were already available locally.
    nonisolated static let minimumVisibleRecipeCount = 6
    nonisolated static let hardRemovalThreshold = 5

    /// Normalizes aliases created by different fetch paths so one real provider does not get
    /// fragmented into several under-filled rows (for example TheMealDB, MealDB Search, and
    /// country-specific "Kitchen" aliases all belong to TheMealDB).
    nonisolated static func canonicalSourceName(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        if lower.contains("mealdb") || lower.hasSuffix(" kitchen") { return "TheMealDB" }
        if lower.contains("cocktaildb") { return "TheCocktailDB" }
        if lower.contains("dummyjson") { return "DummyJSON" }
        if lower.contains("wikibooks") { return "Wikibooks Cookbook" }
        if lower.contains("spoonacular") { return "Spoonacular" }
        if lower.contains("suggestic") { return "Suggestic" }
        if lower.contains("api ninjas") { return "API Ninjas" }
        if lower.contains("tasty") { return "Tasty" }
        if lower.contains("edamam") { return "Edamam" }
        return value.isEmpty ? "My Database" : value
    }

    /// A full recipe must contain a meaningful title, at least three ingredients, and actual
    /// cooking directions. Source counts use this stricter definition so users never open a
    /// source that claims twenty recipes but mostly contains links or incomplete stubs.
    nonisolated static func isFullRecipe(_ recipe: OnlineRecipe) -> Bool {
        RecipeQuality.hasMeaningfulTitle(recipe.title) &&
        recipe.ingredients.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count >= 3 &&
        OnlineRecipeFacts.hasRealInstructions(recipe.instructions)
    }

    /// Keeps a large provider from monopolizing Discover merely because it completed first.
    /// Network feeds, the Mac harvest, household recipes, and the local database all enter the
    /// same pool, so selection must be fair at this boundary rather than at individual call sites.
    /// Encounter order is retained within each source and sources are round-robined until `limit`.
    nonisolated static func balancedRecipes(_ recipes: [OnlineRecipe], limit: Int) -> [OnlineRecipe] {
        guard limit > 0 else { return [] }

        var sourceOrder: [String] = []
        var buckets: [String: [OnlineRecipe]] = [:]
        var seenRecipeKeys = Set<String>()
        for recipe in recipes {
            let source = canonicalSourceName(recipe.source)
            let titleKey = OnlineRecipeFacts.normalizedTitle(recipe.title)
            guard !titleKey.isEmpty else { continue }
            let uniqueKey = "\(source.lowercased())|\(titleKey)"
            guard seenRecipeKeys.insert(uniqueKey).inserted else { continue }
            if buckets[source] == nil { sourceOrder.append(source) }
            buckets[source, default: []].append(recipe)
        }

        var offsets = Dictionary(uniqueKeysWithValues: sourceOrder.map { ($0, 0) })
        var output: [OnlineRecipe] = []
        output.reserveCapacity(min(limit, recipes.count))
        while output.count < limit {
            var appended = false
            for source in sourceOrder where output.count < limit {
                let offset = offsets[source, default: 0]
                guard let bucket = buckets[source], offset < bucket.count else { continue }
                output.append(bucket[offset])
                offsets[source] = offset + 1
                appended = true
            }
            if !appended { break }
        }
        return output
    }

    struct SourceListing: Identifiable {
        var id: String { name }
        let name: String
        let emoji: String
        let specialty: String
        let recipeCount: Int     // live recipes currently in the shared pool from this source
        let isLiveFeed: Bool     // a data feed (fetches recipes) vs a catalogue website
        let isCustom: Bool       // user-added
    }

    /// Only sources that deliver a usable library appear. A source earns a row after twenty
    /// unique complete recipes exist in the merged pool. Smaller/failed sources remain hidden;
    /// the full catalogue can still power direct URL import without creating empty source pages.
    static func allSources(pool: [OnlineRecipe]) -> [SourceListing] {
        // Count recipes per normalized source name across the shared pool.
        var uniqueTitlesBySource: [String: Set<String>] = [:]
        for recipe in pool where isFullRecipe(recipe) {
            let source = canonicalSourceName(recipe.source)
            let titleKey = OnlineRecipeFacts.normalizedTitle(recipe.title)
            guard !source.isEmpty, !titleKey.isEmpty else { continue }
            uniqueTitlesBySource[source, default: []].insert(titleKey)
        }
        let counts = uniqueTitlesBySource.mapValues(\.count)

        // Known feed metadata (emoji + specialty) for nicer rows; keyed feeds are only
        // eligible when their credentials are configured.
        let feedMeta: [(name: String, emoji: String, specialty: String, eligible: Bool)] = [
            ("TheMealDB",          "🍽️", "Free worldwide recipe feed",    true),
            ("TheCocktailDB",      "🍹", "Drinks, cocktails, and mixers", true),
            ("IBA Official",       "🍸", "The official IBA cocktails",    true),
            ("Open Drinks",        "🧉", "Open-source community drinks",  true),
            ("DummyJSON",          "📦", "Curated everyday recipes",      true),
            ("Wikibooks Cookbook", "📖", "Open-licensed cookbook",        true),
            ("Taste of Home",      "🏡", "Test-kitchen classics",         true),
            
            ("My Database",        "💾", "Recipes synced on this device", true),
            ("Spoonacular",        "🥄", "Full recipes with nutrition",   SpoonacularClient.shared.isConfigured),
            ("Edamam",             "🔎", "Recipe search aggregator",      !BuildConfig.edamamAppID.isEmpty),
            ("Tasty",              "🎬", "Video-first favorites",         !BuildConfig.rapidAPIKey.isEmpty),
            ("API Ninjas",         "🥷", "Cocktails and recipes",         !BuildConfig.apiNinjasKey.isEmpty),
            ("Suggestic", "🍅", "Recipes with vegan and vegetarian filters", !BuildConfig.suggesticToken.isEmpty),
        ]
        let metaByName = Dictionary(keepingLastValues: feedMeta.map { ($0.name, $0) })

        var listings: [SourceListing] = []
        var seen = Set<String>()

        // Sources present in the pool — the only ones that get a row. Feed metadata and
        // catalogue metadata (bundled + extended + custom) dress up known names; unknown
        // names (e.g. sites captured by URL import) still appear with a globe.
        let catalogue = RecipeSourceRegistry.everything
        let customDomains = Set(CustomRecipeSourceStore.shared.sources.map { $0.domain })
        for (name, count) in counts where count > hardRemovalThreshold && count >= minimumVisibleRecipeCount {
            guard seen.insert(name).inserted else { continue }
            if let meta = metaByName[name] {
                guard meta.eligible else { continue }
                listings.append(SourceListing(name: name, emoji: meta.emoji, specialty: meta.specialty,
                                              recipeCount: count, isLiveFeed: true, isCustom: false))
            } else if let site = catalogue.first(where: { $0.displayName == name }) {
                listings.append(SourceListing(name: name, emoji: site.iconEmoji, specialty: site.specialty,
                                              recipeCount: count, isLiveFeed: false,
                                              isCustom: customDomains.contains(site.domain)))
            } else {
                listings.append(SourceListing(name: name, emoji: "🌐", specialty: "Imported recipes",
                                              recipeCount: count, isLiveFeed: false, isCustom: false))
            }
        }

        return listings.sorted {
            if $0.isLiveFeed != $1.isLiveFeed { return $0.isLiveFeed }
            if $0.recipeCount != $1.recipeCount { return $0.recipeCount > $1.recipeCount }
            return $0.name < $1.name
        }
    }

    /// Map on-device database entries into the shared pool model, so database-only recipes
    /// (ingested from any feed, or imported) count toward and appear under their source.
    static func poolEntries(from entries: [RecipeDatabaseEntry]) -> [OnlineRecipe] {
        entries
            .filter { !$0.steps.isEmpty }
            .map { e in
                OnlineRecipe(
                    id: "db-\(e.id.uuidString)",
                    title: e.title,
                    category: e.category,
                    area: e.cuisine,
                    instructions: e.steps.joined(separator: "\n"),
                    imageURL: e.imageURL,
                    ingredients: e.ingredients,
                    measures: Array(repeating: "", count: e.ingredients.count),
                    source: e.sourceName.isEmpty ? "My Database" : e.sourceName
                )
            }
    }

    /// Recipes from one source, out of the shared pool.
    static func recipes(from sourceName: String, pool: [OnlineRecipe]) -> [OnlineRecipe] {
        let canonical = canonicalSourceName(sourceName)
        return pool.filter {
            isFullRecipe($0) && canonicalSourceName($0.source).caseInsensitiveCompare(canonical) == .orderedSame
        }
    }

    /// Drink-detection for the Drinks section: TheCocktailDB recipes plus anything whose
    /// category reads as a beverage, from any source.
    static func drinks(pool: [OnlineRecipe]) -> [OnlineRecipe] {
        let drinkWords = ["cocktail", "drink", "beverage", "shake", "smoothie",
                          "coffee", "tea", "punch", "shot", "mocktail", "juice"]
        return pool.filter { r in
            if r.source == "TheCocktailDB" { return true }
            let c = r.category.lowercased()
            return drinkWords.contains { c.contains($0) }
        }
    }

    // MARK: - Cross-source sync

    /// Write presentable fetched recipes into the on-device RecipeDatabase, so recipes from
    /// EVERY feed become part of the one pool that powers Discover's offline seed, recipe
    /// search, the mood finder's database layer, and cook ranking. Bounded per call; the
    /// database's own dedup (upsert) prevents duplicates.
    static func ingestIntoDatabase(_ recipes: [OnlineRecipe]) {
        let presentable = recipes
            .filter { OnlineRecipeFacts.hasRealInstructions($0.instructions) }
            .prefix(40)
        guard !presentable.isEmpty else { return }
        let entries: [RecipeDatabaseEntry] = presentable.map { r in
            RecipeDatabaseEntry(
                title: r.title,
                description: "",
                sourceURL: "",
                sourceName: r.source,
                prepTime: "",
                cookTime: "",
                totalTime: "",
                servings: "",
                category: r.category,
                cuisine: r.area,
                tags: [r.category, r.area].filter { !$0.isEmpty },
                ingredients: r.ingredientLines.map { line in
                    line.measure.isEmpty ? line.ingredient : "\(line.measure) \(line.ingredient)"
                },
                steps: r.instructions
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty },
                imageURL: r.imageURL
            )
        }
        // Route through the manager so counts, the version token and the change bus all fire;
        // fire-and-forget so the caller (often a UI update path) never blocks on persistence.
        Task { await RecipeDatabaseManager.shared.ingestHarvested(entries) }
    }
}
