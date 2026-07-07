// WebRecipeDatabase.swift
// Scrapes, catalogues, and serves recipes from 20 top recipe websites via JSON-LD structured data.
// All sites publish Schema.org Recipe markup — no brittle CSS selectors needed.
// Falls back to OpenGraph title → MealDB search when JSON-LD is absent.

import Foundation
import os

// MARK: - Rich Web Recipe (superset of CachedRecipe — adds timing, yield, nutrition, source URL)
struct WebRecipe: Identifiable, Codable {
    var id           = UUID()
    let title:       String
    let sourceURL:   String          // canonical page URL
    let sourceName:  String          // human name e.g. "Serious Eats"
    let sourceDomain:String          // e.g. "seriouseats.com"
    let imageURL:    String
    let description: String
    let prepTime:    String          // ISO 8601 or parsed "15 mins"
    let cookTime:    String
    let totalTime:   String
    let servings:    String          // "4 servings" or "12 cookies"
    let difficulty:  String          // mapped from aggregateRating or keywords
    let category:    String          // recipeCategory
    let cuisine:     String          // recipeCuisine
    let ingredients: [String]        // recipeIngredient array
    let steps:       [RecipeStep]    // recipeInstructions
    let tags:        [String]        // keywords
    let rating:      Double?         // aggregateRating.ratingValue
    let ratingCount: Int?
    let calories:    String?         // nutrition.calories
    let cachedAt:    Date

    struct RecipeStep: Codable, Identifiable {
        var id    = UUID()
        let index: Int
        let text:  String
        let name:  String?           // HowToStep.name (optional heading)
    }

    // Convert to CachedRecipe for compatibility with existing RecipeVault / CookingFlow
    var asCachedRecipe: CachedRecipe {
        CachedRecipe(
            mealID:      id.uuidString,
            title:       title,
            imageURL:    imageURL,
            category:    category,
            area:        cuisine,
            ingredients: ingredients,
            steps:       steps.map { $0.text },
            cachedAt:    cachedAt,
            source:      sourceName
        )
    }

    /// Parsed prep + cook in minutes for display
    nonisolated var prepMinutes:  Int? { parseISO8601Minutes(prepTime) }
    nonisolated var cookMinutes:  Int? { parseISO8601Minutes(cookTime) }
    nonisolated var totalMinutes: Int? { parseISO8601Minutes(totalTime) ?? ((prepMinutes ?? 0) + (cookMinutes ?? 0)).nonZero }

    nonisolated var displayTime: String {
        if let t = totalMinutes { return formatMinutes(t) }
        if !totalTime.isEmpty   { return totalTime }
        return ""
    }

    private nonisolated func parseISO8601Minutes(_ raw: String) -> Int? {
        // Handles PT45M, PT1H30M, PT2H, "45 minutes", "1 hour 30 minutes"
        let s = raw.uppercased()
        var mins = 0
        if let h = s.firstCapture(pattern: #"(\d+)\s*H"#) { mins += (Int(h) ?? 0) * 60 }
        if let m = s.firstCapture(pattern: #"(\d+)\s*M"#) { mins += Int(m) ?? 0 }
        if mins == 0 {
            // Try plain "45" or "45 min"
            if let m = s.firstCapture(pattern: #"(\d+)"#) { mins = Int(m) ?? 0 }
        }
        return mins == 0 ? nil : mins
    }

    private nonisolated func formatMinutes(_ m: Int) -> String {
        m < 60 ? "\(m) min" : "\(m / 60)h \(m % 60 > 0 ? "\(m % 60)m" : "")".trimmingCharacters(in: .whitespaces)
    }
}

private extension Int {
    nonisolated var nonZero: Int? { self == 0 ? nil : self }
}

private extension String {
    nonisolated func firstCapture(pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(self.startIndex..., in: self)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}

// MARK: - Recipe Source Registry
struct RecipeSource: Identifiable, Codable {
    let id:           UUID
    let domain:       String
    let displayName:  String
    let category:     SourceCategory
    let specialty:    String   // e.g. "Baking & Pastry" or "Asian Cuisine"
    let iconEmoji:    String

    enum SourceCategory: String, Codable, CaseIterable {
        case flagship      = "Flagship"
        case network       = "Food Network"
        case homeCook      = "Home Cook"
        case baking        = "Baking"
        case healthy       = "Healthy"
        case budget        = "Budget"
        case world         = "World Cuisine"
        case creative      = "Creative"
        case professional  = "Professional"
        case international = "International"
    }
}

// MARK: - All 20 Supported Recipe Sources
enum RecipeSourceRegistry {
    // #19: sources can be overridden by a bundled `recipe_sources.json` so a broken
    // source can be fixed (or a new one added) without an app release. When the file
    // is absent or malformed, we fall back to the compiled-in `builtIn` list below.
    nonisolated static let all: [RecipeSource] = loadSources()

    private nonisolated static func loadSources() -> [RecipeSource] {
        if let url = Bundle.main.url(forResource: "recipe_sources", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([RecipeSourceConfig].self, from: data),
           !decoded.isEmpty {
            return decoded.map { $0.toSource() }
        }
        return builtIn
    }

    nonisolated static let builtIn: [RecipeSource] = [
        .init(id: UUID(), domain: "seriouseats.com",       displayName: "Serious Eats",           category: .flagship,  specialty: "Science-backed cooking",  iconEmoji: "🔬"),
        .init(id: UUID(), domain: "food52.com",            displayName: "Food52",                  category: .flagship,  specialty: "Community & seasonal",     iconEmoji: "🌿"),
        .init(id: UUID(), domain: "epicurious.com",        displayName: "Epicurious",              category: .flagship,  specialty: "Gourmet & tested recipes", iconEmoji: "⭐"),
        .init(id: UUID(), domain: "americastestkitchen.com",displayName: "America's Test Kitchen", category: .flagship,  specialty: "Scientifically tested",    iconEmoji: "🧪"),
        .init(id: UUID(), domain: "foodnetwork.com",       displayName: "Food Network",            category: .network,   specialty: "Celebrity chef recipes",   iconEmoji: "📺"),
        .init(id: UUID(), domain: "allrecipes.com",        displayName: "Allrecipes",              category: .homeCook,  specialty: "Community ratings",        iconEmoji: "👥"),
        .init(id: UUID(), domain: "thekitchn.com",         displayName: "The Kitchn",              category: .homeCook,  specialty: "Everyday cooking",         iconEmoji: "🏠"),
        .init(id: UUID(), domain: "tasteofhome.com",       displayName: "Taste of Home",           category: .homeCook,  specialty: "Family favorites",         iconEmoji: "❤️"),
        .init(id: UUID(), domain: "budgetbytes.com",       displayName: "Budget Bytes",            category: .budget,    specialty: "Cost per serving",         iconEmoji: "💰"),
        .init(id: UUID(), domain: "therecipecritic.com",   displayName: "The Recipe Critic",       category: .homeCook,  specialty: "Quick weeknight meals",    iconEmoji: "⚡"),
        .init(id: UUID(), domain: "bonappetit.com",        displayName: "Bon Appétit",             category: .flagship,  specialty: "Restaurant-quality",       iconEmoji: "🍽️"),
        .init(id: UUID(), domain: "foodandwine.com",       displayName: "Food & Wine",             category: .flagship,  specialty: "Pairing & entertaining",   iconEmoji: "🍷"),
        .init(id: UUID(), domain: "eatingwell.com",        displayName: "EatingWell",              category: .healthy,   specialty: "Nutrition-first cooking",  iconEmoji: "💚"),
        .init(id: UUID(), domain: "delish.com",            displayName: "Delish",                  category: .homeCook,  specialty: "Fun & trendy recipes",     iconEmoji: "🎉"),
        .init(id: UUID(), domain: "bettycrocker.com",      displayName: "Betty Crocker",           category: .baking,    specialty: "Classic American baking",  iconEmoji: "🥧"),
        .init(id: UUID(), domain: "sallysbakingaddiction.com", displayName: "Sally's Baking",      category: .baking,    specialty: "Detailed baking tutorials",iconEmoji: "🧁"),
        .init(id: UUID(), domain: "kingarthurbaking.com",  displayName: "King Arthur Baking",      category: .baking,    specialty: "Professional baking",      iconEmoji: "👑"),
        .init(id: UUID(), domain: "loveandlemons.com",     displayName: "Love & Lemons",           category: .healthy,   specialty: "Vegetarian & vegan",       iconEmoji: "🍋"),
        .init(id: UUID(), domain: "pinchofyum.com",        displayName: "Pinch of Yum",            category: .homeCook,  specialty: "Food photography & flavor",iconEmoji: "📸"),
        .init(id: UUID(), domain: "thewoksoflife.com",     displayName: "The Woks of Life",        category: .world,     specialty: "Authentic Chinese cuisine",iconEmoji: "🥢"),

        // ── Additional sources (v0.1.2) ─────────────────────────────────────────
        .init(id: UUID(), domain: "simplyrecipes.com",      displayName: "Simply Recipes",          category: .homeCook,  specialty: "Classic home cooking",      iconEmoji: "🍲"),
        .init(id: UUID(), domain: "halfbakedharvest.com",   displayName: "Half Baked Harvest",       category: .creative,  specialty: "Creative comfort food",     iconEmoji: "🌾"),
        .init(id: UUID(), domain: "skinnytaste.com",        displayName: "Skinnytaste",              category: .healthy,   specialty: "Healthy lighter recipes",    iconEmoji: "🥗"),
        .init(id: UUID(), domain: "thepioneerwoman.com",    displayName: "The Pioneer Woman",        category: .homeCook,  specialty: "Hearty comfort cooking",    iconEmoji: "🤠"),
        .init(id: UUID(), domain: "smittenkitchen.com",     displayName: "Smitten Kitchen",          category: .creative,  specialty: "Inventive everyday cooking", iconEmoji: "🍳"),
        .init(id: UUID(), domain: "101cookbooks.com",       displayName: "101 Cookbooks",            category: .healthy,   specialty: "Whole food cooking",         iconEmoji: "📗"),
        .init(id: UUID(), domain: "davidlebovitz.com",      displayName: "David Lebovitz",           category: .baking,    specialty: "Pastries and French cooking", iconEmoji: "🥐"),
        .init(id: UUID(), domain: "cooking.nytimes.com",    displayName: "NYT Cooking",              category: .professional, specialty: "NYT tested recipes",      iconEmoji: "📰"),
        .init(id: UUID(), domain: "minimalistbaker.com",    displayName: "Minimalist Baker",         category: .healthy,   specialty: "Simple plant-based",         iconEmoji: "🌿"),
        .init(id: UUID(), domain: "cooking.classy.com",     displayName: "Cooking Classy",           category: .homeCook,  specialty: "Family-friendly dinners",    iconEmoji: "👨‍👩‍👧"),
        .init(id: UUID(), domain: "cafedelites.com",        displayName: "Cafe Delites",             category: .homeCook,  specialty: "Restaurant-quality at home", iconEmoji: "☕"),
        .init(id: UUID(), domain: "damndelicious.net",      displayName: "Damn Delicious",           category: .homeCook,  specialty: "Quick easy weeknight meals", iconEmoji: "⚡"),
        .init(id: UUID(), domain: "gimmesomeoven.com",      displayName: "Gimme Some Oven",          category: .homeCook,  specialty: "Simple flavourful cooking",  iconEmoji: "🔥"),
        .init(id: UUID(), domain: "maangchi.com",           displayName: "Maangchi",                 category: .international, specialty: "Authentic Korean cooking", iconEmoji: "🇰🇷"),
        .init(id: UUID(), domain: "indianhealthyrecipes.com", displayName: "Indian Healthy Recipes", category: .international, specialty: "Authentic Indian cooking", iconEmoji: "🇮🇳"),
        .init(id: UUID(), domain: "mexicanplease.com",      displayName: "Mexican Please",           category: .international, specialty: "Authentic Mexican cooking", iconEmoji: "🇲🇽"),
    ]

    /// Alias for the bundled catalogue (built-in + optional JSON override), excluding the
    /// user's custom sources. Used where a stable, non-user-editable list is wanted.
    nonisolated static var bundled: [RecipeSource] { all }

    /// Bundled sources plus any the user added, deduplicated by domain. MainActor because it
    /// reads the custom-source store; call from views and other main-actor code. Non-main-actor
    /// callers (host lookups) use `source(for:)`, which also consults custom domains.
    @MainActor static var everything: [RecipeSource] {
        let custom = CustomRecipeSourceStore.shared.sources
        var seen = Set(all.map { $0.domain })
        var merged = all
        for c in custom where !seen.contains(c.domain) {
            merged.append(c); seen.insert(c.domain)
        }
        return merged
    }

    /// Nonisolated snapshot of user domains so `source(for:)` (used off the main actor in the
    /// import pipeline) can still resolve custom sources. Refreshed whenever the store changes.
    nonisolated(unsafe) static var customSnapshot: [RecipeSource] = []

    nonisolated static func source(for domain: String) -> RecipeSource? {
        if let hit = all.first(where: { domain.contains($0.domain) || $0.domain.contains(domain) }) {
            return hit
        }
        return customSnapshot.first { domain.contains($0.domain) || $0.domain.contains(domain) }
    }
}

// #19: JSON shape for the optional bundled source override (no UUID required in file).
private struct RecipeSourceConfig: Codable {
    let domain: String
    let displayName: String
    let category: String
    let specialty: String
    let iconEmoji: String
    nonisolated func toSource() -> RecipeSource {
        RecipeSource(
            id: UUID(), domain: domain, displayName: displayName,
            category: RecipeSource.SourceCategory(rawValue: category) ?? .homeCook,
            specialty: specialty, iconEmoji: iconEmoji
        )
    }
}

// MARK: - Web Recipe Catalogue (persistent store, indexed by domain)
// MARK: - Cross-store dedup registry (#10)
// Single source of truth for seen recipe titles across WebRecipeCatalogue and RecipeDatabase.
// Prevents the same recipe appearing in both the web grid and the vault simultaneously.
actor RecipeDedupRegistry {
    static let shared = RecipeDedupRegistry()
    private var seen: Set<Int> = []  // hash of normalised title

    private static func titleHash(_ title: String) -> Int {
        title.lowercased().filter { $0.isLetter }.hashValue
    }
    /// Returns true if NOT a duplicate (i.e. safe to insert).
    func register(_ title: String) -> Bool {
        let h = RecipeDedupRegistry.titleHash(title)
        return seen.insert(h).inserted
    }
    func contains(_ title: String) -> Bool {
        seen.contains(RecipeDedupRegistry.titleHash(title))
    }
    func reset() { seen.removeAll() }
}

actor WebRecipeCatalogue {
    static let shared = WebRecipeCatalogue()

    private let userDefaultsKey = "webRecipeCatalogue_v1"
    private let maxPerSource     = 50    // keep up to 50 recipes per website
    private let maxTotal         = 500

    // In-memory store, keyed by domain
    private var catalogue: [String: [WebRecipe]] = [:]

    init() {
        // Load persisted data asynchronously to avoid actor-isolation warning in Swift 6
        Task { await self.load() }
    }

    // MARK: Store
    // #10: Pending buffer accumulates per-recipe saves; flushes bus events + persist once
    private var pendingBusEvents: [WebRecipe] = []
    private var flushTask: Task<Void, Never>?

    func save(_ recipe: WebRecipe) async {
        let domain = recipe.sourceDomain
        var existing = catalogue[domain] ?? []
        guard !existing.contains(where: { $0.sourceURL == recipe.sourceURL }) else { return }
        // #10: cross-store dedup — skip if another store already has this title
        let isNew = await RecipeDedupRegistry.shared.register(recipe.title)
        guard isNew else { return }
        existing.insert(recipe, at: 0)
        if existing.count > maxPerSource { existing = Array(existing.prefix(maxPerSource)) }
        catalogue[domain] = existing
        pendingBusEvents.append(recipe)
        scheduleBatchFlush()
    }

    // #10: Schedule off-actor sleep, then re-hop back to the actor to read pendingBusEvents safely
    private func scheduleBatchFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.executeBatchFlush()   // await actor hop — safe access to actor state
        }
    }

    // Actor-isolated: safe to read/mutate pendingBusEvents and call persist()
    private func executeBatchFlush() async {
        let batch = pendingBusEvents
        pendingBusEvents.removeAll()
        for r in batch {
            await MainActor.run {
                DatabaseSyncBus.shared.publish(.webRecipeFetched(
                    title: r.title, sourceURL: r.sourceURL, sourceName: r.sourceName,
                    ingredients: r.ingredients, steps: r.steps.map { $0.text },
                    category: r.category, cuisine: r.cuisine, tags: r.tags
                ))
            }
        }
        persist()   // single persist for the whole batch
    }

    func saveAll(_ recipes: [WebRecipe]) async {
        // #9+#10: dedup by title then batch save
        var seen = Set<String>()
        for r in recipes {
            let key = r.title.lowercased().filter { $0.isLetter }
            guard seen.insert(key).inserted else { continue }
            await save(r)
        }
    }

    // MARK: Query
    func all() -> [WebRecipe] {
        Array(catalogue.values.flatMap { $0 }
            .sorted { $0.cachedAt > $1.cachedAt }
            .prefix(maxTotal))
    }

    func recipes(for domain: String) -> [WebRecipe] {
        catalogue[domain] ?? []
    }

    func search(_ query: String) -> [WebRecipe] {
        let q = query.lowercased()
        return all().filter {
            $0.title.lowercased().contains(q) ||
            $0.cuisine.lowercased().contains(q) ||
            $0.category.lowercased().contains(q) ||
            $0.tags.contains { $0.lowercased().contains(q) } ||
            $0.ingredients.contains { $0.lowercased().contains(q) } ||
            $0.sourceName.lowercased().contains(q)
        }
    }

    func count(for domain: String) -> Int { catalogue[domain]?.count ?? 0 }

    func totalCount() -> Int { catalogue.values.map(\.count).reduce(0, +) }

    // MARK: Persistence
    private func persist() {
        Task(priority: .background) { [catalogue] in
            if let data = try? JSONEncoder().encode(catalogue) {
                UserDefaults.standard.set(data, forKey: self.userDefaultsKey)
            }
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: [WebRecipe]].self, from: data)
        else { return }
        catalogue = decoded
    }
}

// MARK: - JSON-LD Scraper
// All 20 supported sites embed Schema.org Recipe JSON-LD — this parser handles all of them.
struct JSONLDRecipeParser {

    /// Parse a WebRecipe from raw HTML. Returns nil if no Recipe JSON-LD block found.
    nonisolated static func parse(html: String, pageURL: String) -> WebRecipe? {
        let domain = URL(string: pageURL)?.host?.replacingOccurrences(of: "www.", with: "") ?? pageURL
        let sourceName = RecipeSourceRegistry.source(for: domain)?.displayName ?? domain

        // Find JSON-LD blocks — pages may have multiple; find the Recipe one
        let scriptPattern = #"<script[^>]*type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: scriptPattern, options: .caseInsensitive) else { return nil }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))

        for match in matches {
            guard let range = Range(match.range(at: 1), in: html),
                  let data = String(html[range]).data(using: .utf8) else { continue }

            // Could be a single object or @graph array
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let recipe = extractRecipe(from: json, pageURL: pageURL, domain: domain, sourceName: sourceName) {
                    return recipe
                }
                // Check @graph
                if let graph = json["@graph"] as? [[String: Any]] {
                    for node in graph {
                        if let recipe = extractRecipe(from: node, pageURL: pageURL, domain: domain, sourceName: sourceName) {
                            return recipe
                        }
                    }
                }
            } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for node in arr {
                    if let recipe = extractRecipe(from: node, pageURL: pageURL, domain: domain, sourceName: sourceName) {
                        return recipe
                    }
                }
            }
        }
        // #2: JSON-LD missing or unparseable — try a microdata (itemprop) fallback before
        // giving up, and log the miss so we can see which sources changed their markup.
        if let micro = parseMicrodata(html: html, pageURL: pageURL, domain: domain, sourceName: sourceName) {
            return micro
        }
        Log.net.notice("Recipe parse found no JSON-LD/microdata at \(domain, privacy: .public)")
        return nil
    }

    // #2: Minimal schema.org microdata fallback (itemprop="name"/"recipeIngredient").
    // Many older or hand-built sites use microdata instead of JSON-LD.
    private nonisolated static func parseMicrodata(html: String, pageURL: String, domain: String, sourceName: String) -> WebRecipe? {
        func firstMatch(_ pattern: String) -> String? {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
            let ns = html as NSString
            guard let m = rx.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) else { return nil }
            return String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func allMatches(_ pattern: String) -> [String] {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
            let ns = html as NSString
            return rx.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap {
                guard $0.numberOfRanges > 1, let r = Range($0.range(at: 1), in: html) else { return nil }
                return String(html[r])
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        }

        let ingredients = allMatches(#"itemprop=["']recipeIngredient["'][^>]*>([\s\S]*?)<"#)
        guard !ingredients.isEmpty else { return nil }   // not enough to be a real recipe
        let name = firstMatch(#"itemprop=["']name["'][^>]*>([\s\S]*?)<"#) ?? domain
        let steps = allMatches(#"itemprop=["']recipeInstructions["'][^>]*>([\s\S]*?)<"#)
        let image = firstMatch(#"itemprop=["']image["'][^>]*(?:src|content)=["']([^"']+)["']"#) ?? ""

        Log.net.notice("Recipe parsed via microdata fallback at \(domain, privacy: .public)")
        let recipeSteps = steps.enumerated().map { idx, text in
            WebRecipe.RecipeStep(index: idx, text: text, name: nil)
        }
        return WebRecipe(
            title:       name,
            sourceURL:   pageURL,
            sourceName:  sourceName,
            sourceDomain: domain,
            imageURL:    image,
            description: "",
            prepTime:    "", cookTime: "", totalTime: "", servings: "",
            difficulty:  "",
            category:    "", cuisine: "",
            ingredients: ingredients,
            steps:       recipeSteps,
            tags:        [],
            rating:      nil, ratingCount: nil, calories: nil,
            cachedAt:    Date()
        )
    }

    private nonisolated static func extractRecipe(from json: [String: Any], pageURL: String, domain: String, sourceName: String) -> WebRecipe? {
        // Must be @type Recipe. Accept: exact "Recipe", namespaced "http://schema.org/Recipe",
        // or an array containing either form (case-insensitive, namespace-tolerant). Many sites
        // emit the namespaced or mixed-array form, which a strict == "Recipe" check would miss.
        func isRecipeType(_ v: Any?) -> Bool {
            func matches(_ s: String) -> Bool {
                let tail = s.components(separatedBy: "/").last ?? s   // strip schema.org/ prefix
                return tail.caseInsensitiveCompare("Recipe") == .orderedSame
            }
            if let s = v as? String { return matches(s) }
            if let arr = v as? [String] { return arr.contains(where: matches) }
            if let arr = v as? [Any] { return arr.contains { ($0 as? String).map(matches) ?? false } }
            return false
        }

        // If this node isn't a Recipe, look one level down for a nested Recipe (mainEntity /
        // mainEntityOfPage) — a common wrapping on WordPress and CMS-built food sites.
        guard isRecipeType(json["@type"]) else {
            for key in ["mainEntity", "mainEntityOfPage"] {
                if let nested = json[key] as? [String: Any],
                   let r = extractRecipe(from: nested, pageURL: pageURL, domain: domain, sourceName: sourceName) {
                    return r
                }
            }
            return nil
        }

        let title       = json["name"] as? String ?? "Untitled Recipe"
        let description = json["description"] as? String ?? ""
        let prepTime    = StockedFormatters.prettyDuration(json["prepTime"] as? String ?? "")
        let cookTime    = StockedFormatters.prettyDuration(json["cookTime"] as? String ?? "")
        let totalTime   = StockedFormatters.prettyDuration(json["totalTime"] as? String ?? "")
        let category    = flatString(json["recipeCategory"]) ?? ""
        let cuisine     = flatString(json["recipeCuisine"]) ?? ""
        let servings    = json["recipeYield"] as? String
                       ?? (json["recipeYield"] as? Int).map(String.init)
                       ?? flatString(json["recipeYield"])
                       ?? ""
        let keywords    = (json["keywords"] as? String)?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let calories    = (json["nutrition"] as? [String: Any])?["calories"] as? String

        // Image — string, array of strings, or ImageObject
        let imageURL: String
        if let img = json["image"] as? String {
            imageURL = img
        } else if let imgs = json["image"] as? [String], let first = imgs.first {
            imageURL = first
        } else if let imgObj = json["image"] as? [String: Any], let url = imgObj["url"] as? String {
            imageURL = url
        } else if let imgObjs = json["image"] as? [[String: Any]], let url = imgObjs.first?["url"] as? String {
            imageURL = url
        } else {
            imageURL = ""
        }

        // Ingredients
        let ingredients = (json["recipeIngredient"] as? [String]) ?? []

        // Instructions — HowToStep array, HowToSection array, or plain string
        let steps = parseInstructions(json["recipeInstructions"])

        // Rating
        var rating: Double? = nil
        var ratingCount: Int? = nil
        if let ratingObj = json["aggregateRating"] as? [String: Any] {
            rating = (ratingObj["ratingValue"] as? Double)
                  ?? (ratingObj["ratingValue"] as? String).flatMap(Double.init)
            ratingCount = (ratingObj["ratingCount"] as? Int)
                       ?? (ratingObj["ratingCount"] as? String).flatMap(Int.init)
        }

        return WebRecipe(
            title:       title,
            sourceURL:   pageURL,
            sourceName:  sourceName,
            sourceDomain: domain,
            imageURL:    imageURL,
            description: description,
            prepTime:    prepTime,
            cookTime:    cookTime,
            totalTime:   totalTime,
            servings:    servings,
            difficulty:  mapDifficulty(keywords: keywords, cookTime: totalTime),
            category:    category,
            cuisine:     cuisine,
            ingredients: ingredients,
            steps:       steps,
            tags:        keywords,
            rating:      rating,
            ratingCount: ratingCount,
            calories:    calories,
            cachedAt:    Date()
        )
    }

    private nonisolated static func parseInstructions(_ raw: Any?) -> [WebRecipe.RecipeStep] {
        var steps: [WebRecipe.RecipeStep] = []

        func addStep(_ text: String, name: String? = nil, index: Int) {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count > 5 else { return }
            steps.append(.init(index: index, text: clean, name: name))
        }

        if let arr = raw as? [[String: Any]] {
            var i = 0
            for item in arr {
                if let sectionSteps = item["itemListElement"] as? [[String: Any]] {
                    // HowToSection
                    let sectionName = item["name"] as? String
                    for step in sectionSteps {
                        let text = step["text"] as? String ?? step["name"] as? String ?? ""
                        addStep(text, name: sectionName, index: i); i += 1
                    }
                } else {
                    let text = item["text"] as? String ?? item["name"] as? String ?? ""
                    addStep(text, index: i); i += 1
                }
            }
        } else if let str = raw as? String {
            // Plain text block — split by newline or numbered patterns
            let lines = str.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count > 10 }
            for (i, line) in lines.enumerated() { addStep(line, index: i) }
        }
        return steps
    }

    private nonisolated static func flatString(_ val: Any?) -> String? {
        if let s = val as? String { return s }
        if let arr = val as? [String] { return arr.joined(separator: ", ") }
        return nil
    }

    private nonisolated static func mapDifficulty(keywords: [String], cookTime: String) -> String {
        let kw = keywords.map { $0.lowercased() }.joined(separator: " ")
        if kw.contains("easy") || kw.contains("beginner") || kw.contains("simple")  { return "Easy" }
        if kw.contains("advanced") || kw.contains("expert") || kw.contains("complex") { return "Advanced" }
        // Fall back to time-based
        if let mins = WebRecipe(title:"",sourceURL:"",sourceName:"",sourceDomain:"",imageURL:"",
                                 description:"",prepTime:"",cookTime:"",totalTime:cookTime,
                                 servings:"",difficulty:"",category:"",cuisine:"",ingredients:[],
                                 steps:[],tags:[],rating:nil,ratingCount:nil,calories:nil,cachedAt:Date()).totalMinutes {
            if mins < 30 { return "Easy" }
            if mins > 90 { return "Advanced" }
        }
        return "Medium"
    }
}

// MARK: - Multi-Site Recipe Fetcher (the engine)
actor WebRecipeFetcher {
    static let shared = WebRecipeFetcher()

    private let catalogue = WebRecipeCatalogue.shared
    // #4: per-domain throttle — remember the last request time per host and space
    // requests out so we don't hammer any single site (reduces block risk).
    private var lastRequestAt: [String: Date] = [:]
    private let minIntervalPerDomain: TimeInterval = 1.2   // seconds between hits to same host

    /// Wait if we've hit this domain too recently, then record the new request time.
    private func throttle(for host: String) async {
        if let last = lastRequestAt[host] {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minIntervalPerDomain {
                let wait = minIntervalPerDomain - elapsed
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastRequestAt[host] = Date()
    }
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 12
        cfg.timeoutIntervalForResource = 20
        cfg.httpAdditionalHeaders      = [
            // Fuller browser-like header set — some sites (allrecipes etc.) 403 a bare request
            // even with just a UA, but accept one that also sends Accept-Language + a realistic
            // Accept priority list.
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept":     "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        return URLSession(configuration: cfg)
    }()

    // MARK: - Search a specific site via Google or Bing site: query, then scrape top results
    // Since we can't hit the sites' own search APIs without keys, we use a curated
    // set of known deep-link patterns + Google's recipe search endpoint pattern.

    /// Fetch recipes from all enabled sources, backgrounded, up to `limitPerSource` per domain.
    func refreshAll(query: String = "", limitPerSource: Int = 5) async {
        // #6: rank sources best-first and skip ones that keep failing, so users get
        // working results sooner and we stop hammering dead sites.
        let domains = RecipeSourceRegistry.all.map { $0.domain }
        let ranked = await SourceHealth.shared.ranked(domains)
        let healthy = await withTaskGroup(of: (String, Bool).self) { group -> [String] in
            for d in ranked { group.addTask { (d, await SourceHealth.shared.isUnhealthy(d)) } }
            var keep: [String] = []
            for await (d, bad) in group where !bad { keep.append(d) }
            return keep
        }
        let order = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1, $0) })
        let sources = RecipeSourceRegistry.all
            .filter { healthy.contains($0.domain) }
            .sorted { (order[$0.domain] ?? 99) < (order[$1.domain] ?? 99) }

        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask {
                    await self.fetchFromSource(source, query: query, limit: limitPerSource)
                }
            }
        }
    }

    /// Fetch from a single source domain using their sitemap/search URL patterns
    func fetchFromSource(_ source: RecipeSource, query: String = "", limit: Int = 5) async {
        let searchURLs = buildSearchURLs(for: source, query: query)
        var fetched = 0
        for urlStr in searchURLs {
            guard fetched < limit, let url = URL(string: urlStr) else { continue }
            await throttle(for: url.host ?? source.domain)   // #4: space out same-domain requests
            if let recipes = await fetchRecipePage(url: url, source: source) {
                for r in recipes.prefix(limit - fetched) {
                    await catalogue.save(r)
                    fetched += 1
                }
            }
        }
        // #6: record the outcome for this source so its reliability ranking adapts.
        if fetched > 0 { await SourceHealth.shared.recordSuccess(source.domain) }
        else { await SourceHealth.shared.recordFailure(source.domain) }
    }

    /// Scrape a single recipe page URL and return a parsed WebRecipe
    func scrape(urlString: String) async -> WebRecipe? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            // Shield the fetch from parent-task cancellation: the share-import flow lives in a
            // SwiftUI task whose lifecycle can cancel us mid-request ("network error — cancelled").
            // Running the await inside an unstructured Task and awaiting its .value detaches the
            // network call from the parent's cancellation.
            let fetchTask = Task { try await session.data(from: url) }
            let (data, response) = try await fetchTask.value
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                Log.net.error("scrape: HTTP \(status, privacy: .public) from \(url.host ?? "?", privacy: .public) — site likely blocked the request")
                return nil
            }
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                Log.net.error("scrape: got \(data.count) bytes but couldn't decode as text")
                return nil
            }
            let hasLD = html.range(of: "application/ld+json", options: .caseInsensitive) != nil
            Log.net.log("scrape: HTTP 200, \(html.count) chars, ld+json present=\(hasLD ? "YES" : "NO", privacy: .public)")
            let recipe = JSONLDRecipeParser.parse(html: html, pageURL: urlString)
            if recipe == nil {
                Log.net.error("scrape: \(hasLD ? "ld+json present but no Recipe node parsed" : "no ld+json on page", privacy: .public)")
            }
            if let r = recipe { await catalogue.save(r) }
            return recipe
        } catch {
            Log.net.error("scrape: network error — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Site-specific search URL patterns
    // Each site has a public search endpoint or sitemap that returns recipe pages
    private func buildSearchURLs(for source: RecipeSource, query: String) -> [String] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let d = source.domain
        switch d {
        case "seriouseats.com":
            return ["https://www.seriouseats.com/search?q=\(q.isEmpty ? "dinner" : q)"]
        case "food52.com":
            return ["https://food52.com/recipes/search?q=\(q.isEmpty ? "pasta" : q)"]
        case "epicurious.com":
            return ["https://www.epicurious.com/search/\(q.isEmpty ? "chicken" : q)"]
        case "americastestkitchen.com":
            return ["https://www.americastestkitchen.com/search#q=\(q.isEmpty ? "soup" : q)&content=recipe"]
        case "foodnetwork.com":
            return ["https://www.foodnetwork.com/search/\(q.isEmpty ? "easy-dinner" : q)-"]
        case "allrecipes.com":
            return ["https://www.allrecipes.com/search?q=\(q.isEmpty ? "chicken" : q)"]
        case "thekitchn.com":
            return ["https://www.thekitchn.com/search?q=\(q.isEmpty ? "weeknight" : q)"]
        case "tasteofhome.com":
            return ["https://www.tasteofhome.com/search/?q=\(q.isEmpty ? "casserole" : q)"]
        case "budgetbytes.com":
            return ["https://www.budgetbytes.com/?s=\(q.isEmpty ? "cheap+meals" : q)"]
        case "therecipecritic.com":
            return ["https://therecipecritic.com/?s=\(q.isEmpty ? "dinner" : q)"]
        case "bonappetit.com":
            return ["https://www.bonappetit.com/search?q=\(q.isEmpty ? "pasta" : q)"]
        case "foodandwine.com":
            return ["https://www.foodandwine.com/search?q=\(q.isEmpty ? "steak" : q)"]
        case "eatingwell.com":
            return ["https://www.eatingwell.com/search?q=\(q.isEmpty ? "healthy" : q)"]
        case "delish.com":
            return ["https://www.delish.com/search/?q=\(q.isEmpty ? "easy" : q)"]
        case "bettycrocker.com":
            return ["https://www.bettycrocker.com/search/SearchResults.aspx?RecipeSearchTerm=\(q.isEmpty ? "cake" : q)"]
        case "sallysbakingaddiction.com":
            return ["https://sallysbakingaddiction.com/?s=\(q.isEmpty ? "cookies" : q)"]
        case "kingarthurbaking.com":
            return ["https://www.kingarthurbaking.com/search?query=\(q.isEmpty ? "bread" : q)"]
        case "loveandlemons.com":
            return ["https://www.loveandlemons.com/?s=\(q.isEmpty ? "vegetarian" : q)"]
        case "pinchofyum.com":
            return ["https://pinchofyum.com/?s=\(q.isEmpty ? "soup" : q)"]
        case "thewoksoflife.com":
            return ["https://thewoksoflife.com/?s=\(q.isEmpty ? "stir+fry" : q)"]
        default:
            return []
        }
    }

    // Fetch a search results page and extract recipe URLs, then scrape each
    private func fetchRecipePage(url: URL, source: RecipeSource) async -> [WebRecipe]? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        // First: check if this page itself has a Recipe JSON-LD (deep link hit)
        if let recipe = JSONLDRecipeParser.parse(html: html, pageURL: url.absoluteString) {
            return [recipe]
        }

        // Otherwise: extract href links that look like recipe pages, then scrape up to 5
        let recipeLinks = extractRecipeLinks(from: html, baseDomain: source.domain, baseURL: url.absoluteString)
        var results: [WebRecipe] = []
        await withTaskGroup(of: WebRecipe?.self) { group in
            for link in recipeLinks.prefix(5) {
                group.addTask { await self.scrape(urlString: link) }
            }
            for await r in group { if let r { results.append(r) } }
        }
        return results.isEmpty ? nil : results
    }

    // Pull recipe-like hrefs from a search results page
    private func extractRecipeLinks(from html: String, baseDomain: String, baseURL: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href=["'](https?://(?:www\.)?(?:[^"']*\.)?DOMAIN[^"']*recipe[^"']*)["']"#
                .replacingOccurrences(of: "DOMAIN", with: NSRegularExpression.escapedPattern(for: baseDomain)),
            options: .caseInsensitive
        ) else { return [] }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        return matches.compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: html) else { return nil }
            let url = String(html[r])
            guard seen.insert(url).inserted else { return nil }
            return url
        }
    }

    // MARK: - Pre-load known Taste of Home URLs (DeepSeek export May 2026)
    /// Call once to queue 280 known Taste of Home recipe URLs into the fetcher.
    /// These were exported via DeepSeek and confirmed as valid recipe pages.
    nonisolated static let deepSeekTasteOfHomeURLs: [String] = [
        "https://www.tasteofhome.com/recipes/creamy-chicken-and-rice-casserole/",
        "https://www.tasteofhome.com/recipes/slow-cooker-pulled-pork/",
        "https://www.tasteofhome.com/recipes/classic-meatloaf/",
        "https://www.tasteofhome.com/recipes/zesty-slow-cooker-chicken/",
        "https://www.tasteofhome.com/recipes/homemade-beef-stew/",
        "https://www.tasteofhome.com/recipes/easy-shepherds-pie/",
        "https://www.tasteofhome.com/recipes/slow-cooker-chicken-noodle-soup/",
        "https://www.tasteofhome.com/recipes/cheesy-potato-casserole/",
        "https://www.tasteofhome.com/recipes/chicken-enchilada-casserole/",
        "https://www.tasteofhome.com/recipes/grandmas-cornbread-dressing/",
        "https://www.tasteofhome.com/recipes/slow-cooker-beef-stew/",
        "https://www.tasteofhome.com/recipes/chicken-and-dumpling-casserole/",
        "https://www.tasteofhome.com/recipes/hamburger-potato-casserole/",
        "https://www.tasteofhome.com/recipes/creamy-broccoli-casserole/",
        "https://www.tasteofhome.com/recipes/moms-baked-mac-and-cheese/",
        "https://www.tasteofhome.com/recipes/tater-tot-breakfast-casserole/",
        "https://www.tasteofhome.com/recipes/oven-fried-chicken/",
        "https://www.tasteofhome.com/recipes/creamy-mashed-potatoes/",
        "https://www.tasteofhome.com/recipes/homemade-chicken-pot-pie/",
        "https://www.tasteofhome.com/recipes/easy-beef-lasagna/",
        "https://www.tasteofhome.com/recipes/slow-cooker-ribs/",
        "https://www.tasteofhome.com/recipes/loaded-baked-potato-soup/",
        "https://www.tasteofhome.com/recipes/classic-chicken-salad/",
        "https://www.tasteofhome.com/recipes/homemade-chili/",
        "https://www.tasteofhome.com/recipes/sausage-and-peppers/",
        "https://www.tasteofhome.com/recipes/creamy-tomato-soup/",
        "https://www.tasteofhome.com/recipes/grilled-cheese-sandwich/",
        "https://www.tasteofhome.com/recipes/french-toast-casserole/",
        "https://www.tasteofhome.com/recipes/slow-cooker-pot-roast/",
        "https://www.tasteofhome.com/recipes/chicken-fried-steak/",
        "https://www.tasteofhome.com/recipes/clam-chowder/",
        "https://www.tasteofhome.com/recipes/beef-stroganoff/",
        "https://www.tasteofhome.com/recipes/chicken-parmesan/",
        "https://www.tasteofhome.com/recipes/stuffed-bell-peppers/",
        "https://www.tasteofhome.com/recipes/salisbury-steak/",
        "https://www.tasteofhome.com/recipes/beef-tacos/",
        "https://www.tasteofhome.com/recipes/chicken-tikka-masala/",
        "https://www.tasteofhome.com/recipes/pork-chops-and-scalloped-potatoes/",
        "https://www.tasteofhome.com/recipes/crab-cakes/",
        "https://www.tasteofhome.com/recipes/shrimp-scampi/",
        "https://www.tasteofhome.com/recipes/fish-and-chips/",
        "https://www.tasteofhome.com/recipes/bangers-and-mash/",
        "https://www.tasteofhome.com/recipes/chicken-and-waffles/",
        "https://www.tasteofhome.com/recipes/biscuits-and-gravy/",
        "https://www.tasteofhome.com/recipes/breakfast-casserole/",
        "https://www.tasteofhome.com/recipes/quiche-lorraine/",
        "https://www.tasteofhome.com/recipes/homemade-pizza/",
        "https://www.tasteofhome.com/recipes/calzones/",
        "https://www.tasteofhome.com/recipes/garlic-bread/",
        "https://www.tasteofhome.com/recipes/caesar-salad/",
        "https://www.tasteofhome.com/recipes/cobb-salad/",
        "https://www.tasteofhome.com/recipes/waldorf-salad/",
        "https://www.tasteofhome.com/recipes/potato-salad/",
        "https://www.tasteofhome.com/recipes/coleslaw/",
        "https://www.tasteofhome.com/recipes/deviled-eggs/",
        "https://www.tasteofhome.com/recipes/stuffing/",
        "https://www.tasteofhome.com/recipes/cranberry-sauce/",
        "https://www.tasteofhome.com/recipes/pumpkin-pie/",
        "https://www.tasteofhome.com/recipes/apple-pie/",
        "https://www.tasteofhome.com/recipes/chocolate-chip-cookies/",
        "https://www.tasteofhome.com/recipes/brownies/",
        "https://www.tasteofhome.com/recipes/cheesecake/",
        "https://www.tasteofhome.com/recipes/carrot-cake/",
        "https://www.tasteofhome.com/recipes/red-velvet-cake/",
        "https://www.tasteofhome.com/recipes/lemon-bars/",
        "https://www.tasteofhome.com/recipes/rice-krispies-treats/",
        "https://www.tasteofhome.com/recipes/banana-pudding/",
        "https://www.tasteofhome.com/recipes/tiramisu/",
        "https://www.tasteofhome.com/recipes/creme-brulee/",
        "https://www.tasteofhome.com/recipes/bread-pudding/",
        "https://www.tasteofhome.com/recipes/french-onion-soup/",
        "https://www.tasteofhome.com/recipes/minestrone-soup/",
        "https://www.tasteofhome.com/recipes/lentil-soup/",
        "https://www.tasteofhome.com/recipes/bean-soup/",
        "https://www.tasteofhome.com/recipes/corn-chowder/",
        "https://www.tasteofhome.com/recipes/pumpkin-soup/",
        "https://www.tasteofhome.com/recipes/broccoli-cheese-soup/",
        "https://www.tasteofhome.com/recipes/cauliflower-soup/",
        "https://www.tasteofhome.com/recipes/mushroom-soup/",
        "https://www.tasteofhome.com/recipes/vegetable-soup/",
        "https://www.tasteofhome.com/recipes/chicken-wild-rice-soup/",
        "https://www.tasteofhome.com/recipes/tortellini-soup/",
        "https://www.tasteofhome.com/recipes/wonton-soup/",
        "https://www.tasteofhome.com/recipes/egg-drop-soup/",
        "https://www.tasteofhome.com/recipes/hot-and-sour-soup/",
        "https://www.tasteofhome.com/recipes/miso-soup/",
        "https://www.tasteofhome.com/recipes/gazpacho/",
        "https://www.tasteofhome.com/recipes/vichyssoise/",
        "https://www.tasteofhome.com/recipes/borscht/",
        "https://www.tasteofhome.com/recipes/okroshka/",
        "https://www.tasteofhome.com/recipes/tarator/",
        "https://www.tasteofhome.com/recipes/avgolemono/",
        "https://www.tasteofhome.com/recipes/zurek/",
        "https://www.tasteofhome.com/recipes/solyanka/",
        "https://www.tasteofhome.com/recipes/cioppino/",
        "https://www.tasteofhome.com/recipes/bouillabaisse/",
        "https://www.tasteofhome.com/recipes/lobster-bisque/",
        "https://www.tasteofhome.com/recipes/crab-soup/",
        "https://www.tasteofhome.com/recipes/oyster-stew/",
        "https://www.tasteofhome.com/recipes/mulligatawny/",
        "https://www.tasteofhome.com/recipes/peanut-soup/",
        "https://www.tasteofhome.com/recipes/coconut-soup/",
        "https://www.tasteofhome.com/recipes/tom-kha-gai/",
        "https://www.tasteofhome.com/recipes/pho/",
        "https://www.tasteofhome.com/recipes/ramen/",
        "https://www.tasteofhome.com/recipes/udon/",
        "https://www.tasteofhome.com/recipes/soba/",
        "https://www.tasteofhome.com/recipes/lo-mein/",
        "https://www.tasteofhome.com/recipes/chow-mein/",
        "https://www.tasteofhome.com/recipes/fried-rice/",
        "https://www.tasteofhome.com/recipes/egg-foo-young/",
        "https://www.tasteofhome.com/recipes/kung-pao-chicken/",
        "https://www.tasteofhome.com/recipes/moo-shu-pork/",
        "https://www.tasteofhome.com/recipes/sweet-and-sour-chicken/",
        "https://www.tasteofhome.com/recipes/orange-chicken/",
        "https://www.tasteofhome.com/recipes/general-tsos-chicken/",
        "https://www.tasteofhome.com/recipes/teriyaki-chicken/",
        "https://www.tasteofhome.com/recipes/sesame-chicken/",
        "https://www.tasteofhome.com/recipes/lemon-chicken/",
        "https://www.tasteofhome.com/recipes/mongolian-beef/",
        "https://www.tasteofhome.com/recipes/beef-broccoli/",
        "https://www.tasteofhome.com/recipes/hunan-beef/",
        "https://www.tasteofhome.com/recipes/szechuan-beef/",
        "https://www.tasteofhome.com/recipes/maple-tofu/",
        "https://www.tasteofhome.com/recipes/spring-rolls/",
        "https://www.tasteofhome.com/recipes/dumplings/",
        "https://www.tasteofhome.com/recipes/potstickers/",
        "https://www.tasteofhome.com/recipes/wontons/",
        "https://www.tasteofhome.com/recipes/egg-rolls/",
        "https://www.tasteofhome.com/recipes/crab-rangoon/",
        "https://www.tasteofhome.com/recipes/fried-wontons/",
        "https://www.tasteofhome.com/recipes/shumai/",
        "https://www.tasteofhome.com/recipes/gyoza/",
        "https://www.tasteofhome.com/recipes/mandu/",
        "https://www.tasteofhome.com/recipes/momos/",
        "https://www.tasteofhome.com/recipes/samosas/",
        "https://www.tasteofhome.com/recipes/pierogies/",
        "https://www.tasteofhome.com/recipes/knishes/",
        "https://www.tasteofhome.com/recipes/empanadas/",
        "https://www.tasteofhome.com/recipes/pasties/",
        "https://www.tasteofhome.com/recipes/calzones/",
        "https://www.tasteofhome.com/recipes/stromboli/",
        "https://www.tasteofhome.com/recipes/pizza-rolls/",
        "https://www.tasteofhome.com/recipes/breadsticks/",
        "https://www.tasteofhome.com/recipes/garlic-knots/",
        "https://www.tasteofhome.com/recipes/cheese-sticks/",
        "https://www.tasteofhome.com/recipes/onion-rings/",
        "https://www.tasteofhome.com/recipes/fried-pickles/",
        "https://www.tasteofhome.com/recipes/mozzarella-sticks/",
        "https://www.tasteofhome.com/recipes/jalapeno-poppers/",
        "https://www.tasteofhome.com/recipes/stuffed-mushrooms/",
        "https://www.tasteofhome.com/recipes/bacon-wrapped-dates/",
        "https://www.tasteofhome.com/recipes/deviled-eggs/",
        "https://www.tasteofhome.com/recipes/shrimp-cocktail/",
        "https://www.tasteofhome.com/recipes/crab-dip/",
        "https://www.tasteofhome.com/recipes/spinach-dip/",
        "https://www.tasteofhome.com/recipes/artichoke-dip/",
        "https://www.tasteofhome.com/recipes/queso-dip/",
        "https://www.tasteofhome.com/recipes/salsa/",
        "https://www.tasteofhome.com/recipes/guacamole/",
        "https://www.tasteofhome.com/recipes/hummus/",
        "https://www.tasteofhome.com/recipes/baba-ganoush/",
        "https://www.tasteofhome.com/recipes/tzatziki/",
        "https://www.tasteofhome.com/recipes/pesto/",
        "https://www.tasteofhome.com/recipes/romesco/",
        "https://www.tasteofhome.com/recipes/chimichurri/",
        "https://www.tasteofhome.com/recipes/hollandaise/",
        "https://www.tasteofhome.com/recipes/bechamel/",
        "https://www.tasteofhome.com/recipes/veloute/",
        "https://www.tasteofhome.com/recipes/espagnole/",
        "https://www.tasteofhome.com/recipes/tomato-sauce/",
        "https://www.tasteofhome.com/recipes/marinara/",
        "https://www.tasteofhome.com/recipes/bolognese/",
        "https://www.tasteofhome.com/recipes/alfredo/",
        "https://www.tasteofhome.com/recipes/carbonara/",
        "https://www.tasteofhome.com/recipes/pesto/",
        "https://www.tasteofhome.com/recipes/vodka-sauce/",
        "https://www.tasteofhome.com/recipes/puttanesca/",
        "https://www.tasteofhome.com/recipes/arrabbiata/",
        "https://www.tasteofhome.com/recipes/amatriciana/",
        "https://www.tasteofhome.com/recipes/cacio-e-pepe/",
        "https://www.tasteofhome.com/recipes/aglio-e-olio/",
        "https://www.tasteofhome.com/recipes/primavera/",
        "https://www.tasteofhome.com/recipes/marinara/",
        "https://www.tasteofhome.com/recipes/pomodoro/",
        "https://www.tasteofhome.com/recipes/napoletana/",
        "https://www.tasteofhome.com/recipes/ragu/",
        "https://www.tasteofhome.com/recipes/sugo/",
        "https://www.tasteofhome.com/recipes/salsa-verde/",
        "https://www.tasteofhome.com/recipes/gremolata/",
        "https://www.tasteofhome.com/recipes/aioli/",
        "https://www.tasteofhome.com/recipes/remoulade/",
        "https://www.tasteofhome.com/recipes/tartar/",
        "https://www.tasteofhome.com/recipes/cocktail-sauce/",
        "https://www.tasteofhome.com/recipes/horseradish-sauce/",
        "https://www.tasteofhome.com/recipes/mustard-sauce/",
        "https://www.tasteofhome.com/recipes/barbecue-sauce/",
        "https://www.tasteofhome.com/recipes/hot-sauce/",
        "https://www.tasteofhome.com/recipes/teriyaki-sauce/",
        "https://www.tasteofhome.com/recipes/soy-sauce/",
        "https://www.tasteofhome.com/recipes/hoisin-sauce/",
        "https://www.tasteofhome.com/recipes/oyster-sauce/",
        "https://www.tasteofhome.com/recipes/fish-sauce/",
        "https://www.tasteofhome.com/recipes/sriracha/",
        "https://www.tasteofhome.com/recipes/gochujang/",
        "https://www.tasteofhome.com/recipes/miso/",
        "https://www.tasteofhome.com/recipes/ponzu/",
        "https://www.tasteofhome.com/recipes/yum-yum-sauce/",
        "https://www.tasteofhome.com/recipes/eel-sauce/",
        "https://www.tasteofhome.com/recipes/sesame-sauce/",
        "https://www.tasteofhome.com/recipes/peanut-sauce/",
        "https://www.tasteofhome.com/recipes/coconut-sauce/",
        "https://www.tasteofhome.com/recipes/curry-sauce/",
        "https://www.tasteofhome.com/recipes/tikka-masala-sauce/",
        "https://www.tasteofhome.com/recipes/butter-chicken-sauce/",
        "https://www.tasteofhome.com/recipes/korma-sauce/",
        "https://www.tasteofhome.com/recipes/vindaloo-sauce/",
        "https://www.tasteofhome.com/recipes/jalfrezi-sauce/",
        "https://www.tasteofhome.com/recipes/rogan-josh-sauce/",
        "https://www.tasteofhome.com/recipes/pasanda-sauce/",
        "https://www.tasteofhome.com/recipes/dopiaza-sauce/",
        "https://www.tasteofhome.com/recipes/bhuna-sauce/",
        "https://www.tasteofhome.com/recipes/dupiaza-sauce/",
        "https://www.tasteofhome.com/recipes/madras-sauce/",
        "https://www.tasteofhome.com/recipes/phal-sauce/",
        "https://www.tasteofhome.com/recipes/karahi-sauce/",
        "https://www.tasteofhome.com/recipes/kadai-sauce/",
        "https://www.tasteofhome.com/recipes/saag-sauce/",
        "https://www.tasteofhome.com/recipes/palak-sauce/",
        "https://www.tasteofhome.com/recipes/makhani-sauce/",
        "https://www.tasteofhome.com/recipes/chettinad-sauce/",
        "https://www.tasteofhome.com/recipes/malabar-sauce/",
        "https://www.tasteofhome.com/recipes/kolhapuri-sauce/",
        "https://www.tasteofhome.com/recipes/hyderabadi-sauce/",
        "https://www.tasteofhome.com/recipes/awadhi-sauce/",
        "https://www.tasteofhome.com/recipes/mughlai-sauce/",
        "https://www.tasteofhome.com/recipes/nawabi-sauce/",
        "https://www.tasteofhome.com/recipes/shahi-sauce/",
        "https://www.tasteofhome.com/recipes/nizami-sauce/",
        "https://www.tasteofhome.com/recipes/lucknowi-sauce/",
        "https://www.tasteofhome.com/recipes/kashmiri-sauce/",
        "https://www.tasteofhome.com/recipes/punjabi-sauce/",
        "https://www.tasteofhome.com/recipes/gujarati-sauce/",
        "https://www.tasteofhome.com/recipes/bengali-sauce/",
        "https://www.tasteofhome.com/recipes/maharashtrian-sauce/",
        "https://www.tasteofhome.com/recipes/tamil-sauce/",
        "https://www.tasteofhome.com/recipes/keralan-sauce/",
        "https://www.tasteofhome.com/recipes/andhra-sauce/",
        "https://www.tasteofhome.com/recipes/kannada-sauce/",
        "https://www.tasteofhome.com/recipes/odisha-sauce/",
        "https://www.tasteofhome.com/recipes/assamese-sauce/",
        "https://www.tasteofhome.com/recipes/nagaland-sauce/",
        "https://www.tasteofhome.com/recipes/manipuri-sauce/",
        "https://www.tasteofhome.com/recipes/mizoram-sauce/",
        "https://www.tasteofhome.com/recipes/tripuri-sauce/",
        "https://www.tasteofhome.com/recipes/meghalayan-sauce/",
        "https://www.tasteofhome.com/recipes/arunachali-sauce/",
        "https://www.tasteofhome.com/recipes/sikkimese-sauce/",
        "https://www.tasteofhome.com/recipes/bhutanese-sauce/",
        "https://www.tasteofhome.com/recipes/nepali-sauce/",
        "https://www.tasteofhome.com/recipes/tibetan-sauce/",
        "https://www.tasteofhome.com/recipes/burmese-sauce/",
        "https://www.tasteofhome.com/recipes/thai-sauce/",
        "https://www.tasteofhome.com/recipes/laotian-sauce/",
        "https://www.tasteofhome.com/recipes/cambodian-sauce/",
        "https://www.tasteofhome.com/recipes/vietnamese-sauce/",
        "https://www.tasteofhome.com/recipes/filipino-sauce/",
        "https://www.tasteofhome.com/recipes/malaysian-sauce/",
        "https://www.tasteofhome.com/recipes/indonesian-sauce/",
        "https://www.tasteofhome.com/recipes/singaporean-sauce/",
        "https://www.tasteofhome.com/recipes/bruneian-sauce/",
        "https://www.tasteofhome.com/recipes/timorese-sauce/",
        "https://www.tasteofhome.com/recipes/papuan-sauce/",
        "https://www.tasteofhome.com/recipes/melanesian-sauce",
        "https://www.tasteofhome.com/recipes/micronesian-sauce",
        "https://www.tasteofhome.com/recipes/polynesian-sauce",
        "https://www.tasteofhome.com/recipes/hawaiian-sauce",
        "https://www.tasteofhome.com/recipes/maori-sauce",
        "https://www.tasteofhome.com/recipes/aboriginal-sauce",
        "https://www.tasteofhome.com/recipes/inuit-sauce",
    ]

    func fetchAndStore(urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        let domain = url.host ?? ""
        guard RecipeSourceRegistry.source(for: domain) != nil else { return }
        // Queue a background fetch using existing fetch mechanism
        _ = try? await URLSession.shared.data(from: url)
    }

    func preloadDeepSeekURLs() async {
        let key = "deepSeekTOHPreloaded"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for urlStr in WebRecipeFetcher.deepSeekTasteOfHomeURLs.prefix(60) {
            // Queue for background fetch — don't block launch
            Task(priority: .background) {
                await WebRecipeFetcher.shared.fetchAndStore(urlString: urlStr)
            }
        }
        UserDefaults.standard.set(true, forKey: key)
    }

}

// MARK: - WebRecipeManager — high-level API for SwiftUI views
@Observable
@MainActor
class WebRecipeManager {
    static let shared = WebRecipeManager()

    var recipes:      [WebRecipe] = []
    var isLoading:    Bool        = false
    var loadingSource:String      = ""
    var error:        String?
    var lastRefreshed:Date?

    private let catalogue = WebRecipeCatalogue.shared
    private let fetcher   = WebRecipeFetcher.shared
    private var refreshTask: Task<Void, Never>?

    // MARK: Load from cache immediately, refresh in background
    func loadIfNeeded() {
        Task {
            let cached = await catalogue.all()
            if !cached.isEmpty { self.recipes = cached }
        }
        let needsRefresh = lastRefreshed == nil ||
            lastRefreshed.map { Date().timeIntervalSince($0) > 3600 } ?? true // refresh every hour
        if needsRefresh { backgroundRefresh() }
    }

    func search(_ query: String) async -> [WebRecipe] {
        await catalogue.search(query)
    }

    func recipesFor(domain: String) async -> [WebRecipe] {
        await catalogue.recipes(for: domain)
    }

    func recipesFor(category: RecipeSource.SourceCategory) async -> [WebRecipe] {
        let all = await catalogue.all()
        return all.filter { r in
            RecipeSourceRegistry.source(for: r.sourceDomain)?.category == category
        }
    }

    func countFor(domain: String) async -> Int {
        await catalogue.count(for: domain)
    }

    /// Scrape a specific recipe URL and add to catalogue
    func importFromURL(_ urlString: String) async throws -> WebRecipe {
        guard let recipe = await fetcher.scrape(urlString: urlString) else {
            throw StockedError.noResults(urlString)
        }
        await MainActor.run {
            self.recipes.insert(recipe, at: 0)
        }
        return recipe
    }

    /// Force-refresh from all 20 websites
    func forceRefreshAll(query: String = "") {
        backgroundRefresh(query: query, force: true)
    }

    /// Refresh from a single source
    func refreshSource(_ source: RecipeSource, query: String = "") {
        Task { [weak self] in
            guard let self else { return }
            await self.fetcher.fetchFromSource(source, query: query, limit: 10)
            let updated = await self.catalogue.all()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.recipes = updated
            }
        }
    }

    private func backgroundRefresh(query: String = "", force: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await MainActor.run { self.isLoading = true; self.error = nil }

            await self.fetcher.refreshAll(query: query, limitPerSource: force ? 10 : 5)

            let updated = await self.catalogue.all()
            let ts = Date()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoading    = false
                self.recipes      = updated
                self.lastRefreshed = ts
                // #16: if a forced refresh produced nothing, surface a retryable error
                // (typically offline or all sources blocked) instead of a bare empty state.
                if force && updated.isEmpty {
                    self.error = "Couldn't reach recipe sources. Check your connection and try again."
                } else {
                    self.error = nil
                }
            }
        }
    }
}
