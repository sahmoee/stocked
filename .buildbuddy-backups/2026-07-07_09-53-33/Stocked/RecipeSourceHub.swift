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

    struct SourceListing: Identifiable {
        var id: String { name }
        let name: String
        let emoji: String
        let specialty: String
        let recipeCount: Int     // live recipes currently in the shared pool from this source
        let isLiveFeed: Bool     // a data feed (fetches recipes) vs a catalogue website
        let isCustom: Bool       // user-added
    }

    /// Every source the app knows, with live counts from the shared pool. Live feeds first
    /// (they have content now), then catalogue sites — bundled, extended, and custom — sorted
    /// by whether they currently have recipes, then by name.
    static func allSources(pool: [OnlineRecipe]) -> [SourceListing] {
        // Count recipes per normalized source name across the shared pool.
        var counts: [String: Int] = [:]
        for r in pool {
            let key = r.source.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            counts[key, default: 0] += 1
        }

        // Live feeds — always listed, even at zero (they fill in as fetches land).
        let feedMeta: [(name: String, emoji: String, specialty: String)] = [
            ("TheMealDB",          "🍽️", "Free worldwide recipe feed"),
            ("TheCocktailDB",      "🍹", "Drinks, cocktails, and mixers"),
            ("Spoonacular",        "🥄", "Full recipes with nutrition"),
            ("DummyJSON",          "📦", "Curated everyday recipes"),
            ("Wikibooks Cookbook", "📖", "Open-licensed cookbook"),
            ("Taste of Home",      "🏡", "Test-kitchen classics"),
            ("Edamam",             "🔎", "Recipe search aggregator"),
            ("Tasty",              "🎬", "Video-first favorites"),
            ("My Database",        "💾", "Recipes synced on this device"),
        ]
        var listings: [SourceListing] = feedMeta.map {
            SourceListing(name: $0.name, emoji: $0.emoji, specialty: $0.specialty,
                          recipeCount: counts[$0.name] ?? 0, isLiveFeed: true, isCustom: false)
        }
        let feedNames = Set(feedMeta.map { $0.name })

        // Catalogue websites — bundled + extended + custom, deduplicated by display name.
        var seen = feedNames
        for src in RecipeSourceRegistry.everything {
            guard !seen.contains(src.displayName) else { continue }
            seen.insert(src.displayName)
            let isCustom = CustomRecipeSourceStore.shared.sources.contains { $0.domain == src.domain }
            listings.append(SourceListing(
                name: src.displayName, emoji: src.iconEmoji, specialty: src.specialty,
                recipeCount: counts[src.displayName] ?? 0, isLiveFeed: false, isCustom: isCustom))
        }

        // Any source present in the pool that nothing above claimed (e.g. a site captured
        // during URL import) still gets a row — nothing in the pool is orphaned.
        for (name, count) in counts where !seen.contains(name) {
            seen.insert(name)
            listings.append(SourceListing(name: name, emoji: "🌐", specialty: "Imported recipes",
                                          recipeCount: count, isLiveFeed: false, isCustom: false))
        }

        return listings.sorted {
            if $0.isLiveFeed != $1.isLiveFeed { return $0.isLiveFeed }
            if ($0.recipeCount > 0) != ($1.recipeCount > 0) { return $0.recipeCount > 0 }
            return $0.name < $1.name
        }
    }

    /// Recipes from one source, out of the shared pool.
    static func recipes(from sourceName: String, pool: [OnlineRecipe]) -> [OnlineRecipe] {
        pool.filter { $0.source.caseInsensitiveCompare(sourceName) == .orderedSame }
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
        // upsertAll lives on the thread-safe RecipeDatabase actor; fire-and-forget so the
        // caller (often a UI update path) never blocks on persistence.
        Task { await RecipeDatabase.shared.upsertAll(entries) }
    }
}
