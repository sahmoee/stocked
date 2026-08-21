// RecipeSupport.swift
// Shared recipe utilities used across the database, online fetch, and results layers.
//
// Per architecture decision: ingredients stay as flat "amount unit name" strings in
// storage; this file parses them ON DEMAND (no data migration). It also centralizes
// quality scoring (#10), fuzzy de-duplication (#5/#12), and the canonical cuisine /
// category taxonomy (#20) so the DB, online results, and UI all agree.

import Foundation

// MARK: - On-demand ingredient parsing (#11)
// Turns a flat "2 cups all-purpose flour" string into {amount, unit, name} without
// changing how ingredients are stored. Reuses ParsedQuantity where possible.
// Named StockedParsedIngredient to avoid clashing with IngredientMatcher.ParsedIngredient.
struct StockedParsedIngredient: Sendable {
    let amount: Double      // 0 when unspecified
    let unit:   String      // "" when count/unspecified
    let name:   String      // ingredient name, lowercased & trimmed

    var isEmpty: Bool { amount == 0 && unit.isEmpty && name.isEmpty }
}

enum RecipeIngredients {
    /// Parse a single flat ingredient line on demand.
    nonisolated static func parse(_ line: String) -> StockedParsedIngredient {
        let pq = ParsedQuantity.parse(line)
        return StockedParsedIngredient(amount: pq.amount,
                                unit: pq.canonicalUnit,
                                name: pq.baseName.trimmingCharacters(in: .whitespaces))
    }

    /// Parse a whole recipe's ingredient list.
    nonisolated static func parseAll(_ lines: [String]) -> [StockedParsedIngredient] {
        lines.map(parse).filter { !$0.name.isEmpty }
    }

    /// Just the ingredient names (for matching against inventory / dedup).
    nonisolated static func names(_ lines: [String]) -> [String] {
        parseAll(lines).map(\.name)
    }
}

// MARK: - Quality scoring (#10)
// A 0…1 score used to rank recipes by completeness/quality rather than recency.
// nonisolated: pure scoring, called from the RecipeDatabase actor.
nonisolated enum RecipeQuality {
    /// Thin catalogue labels are categories, not dishes. Keep this check at the
    /// shared quality boundary so Discover, Sources, and Cook Now cannot drift
    /// into showing a literal "Dinner" or "Recipe" as something to cook.
    nonisolated static func hasMeaningfulTitle(_ title: String) -> Bool {
        let key = OnlineRecipeFacts.normalizedTitle(title)
        guard !key.isEmpty else { return false }
        let genericTitles: Set<String> = ["dinner", "lunch", "breakfast", "meal", "recipe", "food"]
        return !genericTitles.contains(key)
    }

    /// Score from the parts a recipe has: image, steps, sensible ingredient count, title.
    nonisolated static func score(title: String, ingredients: [String], steps: [String],
                      imageURL: String, baseScore: Double? = nil) -> Double {
        var s = baseScore ?? 0.4   // seed/importer score if provided, else neutral
        if !imageURL.isEmpty { s += 0.20 }
        if steps.count >= 3 { s += 0.20 } else if !steps.isEmpty { s += 0.08 }
        let n = ingredients.count
        if (3...20).contains(n) { s += 0.15 } else if n > 0 { s += 0.05 }
        if title.count >= 4 && !title.lowercased().contains("untitled") { s += 0.05 }
        return min(1.0, s)
    }

    /// Map a 0...1 quality score to a user-facing source badge, so thin recipes can be flagged.
    /// Pairs with SourceConfidence (the badge type). Verified when complete, Estimated when
    /// usable but thin, Needs review when too much is missing.
    nonisolated static func badge(for score: Double) -> SourceBadge {
        switch score {
        case 0.8...:    return .verified
        case 0.5..<0.8: return .estimated
        default:        return .needsReview
        }
    }
}

// MARK: - Fuzzy de-duplication (#5, #12)
// Treats near-identical titles (and high ingredient overlap) as the same dish.
enum RecipeDedup {
    /// A normalized key for exact-ish title matching.
    nonisolated static func key(_ title: String) -> String {
        title.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// True if two recipes are likely the same dish (fuzzy title, or strong overlap).
    nonisolated static func areSame(titleA: String, ingredientsA: [String],
                        titleB: String, ingredientsB: [String]) -> Bool {
        // Convenience overload — parses names on demand. Prefer areSameKeyed(...) inside
        // O(n²) dedup loops so ingredient strings aren't re-parsed on every comparison.
        areSameKeyed(keyA: key(titleA), namesA: Set(RecipeIngredients.names(ingredientsA)),
                     keyB: key(titleB), namesB: Set(RecipeIngredients.names(ingredientsB)))
    }

    /// Same comparison as areSame, but takes PRE-COMPUTED normalized title keys and name
    /// sets. This is the hot path: in a dedup of N recipes there are ~N²/2 comparisons, and
    /// re-parsing ingredient strings (RecipeIngredients.names) inside each one allocated
    /// millions of transient strings (the runaway-memory backtrace pointed straight here).
    /// Parsing once per recipe and reusing the result removes that entirely.
    nonisolated static func areSameKeyed(keyA: String, namesA: Set<String>,
                                         keyB: String, namesB: Set<String>) -> Bool {
        if keyA == keyB { return true }
        if FuzzyMatch.score(keyA, keyB) >= 0.85 { return true }
        guard !namesA.isEmpty, !namesB.isEmpty else { return false }
        let overlap = Double(namesA.intersection(namesB).count) / Double(min(namesA.count, namesB.count))
        return overlap >= 0.8 && FuzzyMatch.score(keyA, keyB) >= 0.6
    }

    /// De-duplicate a list, keeping the first occurrence of each dish.
    /// Each item's normalized title key and ingredient-name set are computed ONCE up front,
    /// then reused across all comparisons — so this is O(n²) comparisons but only O(n)
    /// string parsing, instead of O(n²) parsing (which was the memory blow-up).
    nonisolated static func dedupe<T>(_ items: [T],
                          title: (T) -> String,
                          ingredients: (T) -> [String]) -> [T] {
        var kept: [T] = []
        var keptKeys: [String] = []
        var keptNames: [Set<String>] = []
        for item in items {
            let k = key(title(item))
            let n = Set(RecipeIngredients.names(ingredients(item)))
            var dup = false
            for i in kept.indices {
                if areSameKeyed(keyA: keptKeys[i], namesA: keptNames[i], keyB: k, namesB: n) {
                    dup = true; break
                }
            }
            if !dup { kept.append(item); keptKeys.append(k); keptNames.append(n) }
        }
        return kept
    }
}

// MARK: - Canonical taxonomy (#20)
// One source of truth for cuisine/category names so DB, online, and filters agree.
enum RecipeTaxonomy {
    nonisolated static let cuisines: [String] = [
        "American","Southern","Cajun & Creole","Tex-Mex","BBQ","New England","Soul Food","Hawaiian",
        "Mexican","Italian","French","Spanish","Greek","Mediterranean","Middle Eastern","Indian",
        "Thai","Chinese","Japanese","Korean","Vietnamese","Filipino","Caribbean","African",
        "German","British","Irish","Eastern European","Latin American","Fusion","Moroccan","Turkish","Brazilian","Other"
    ]

    nonisolated static let categories: [String] = [
        "Breakfast","Brunch","Lunch","Dinner","Appetizer","Side","Salad","Soup",
        "Sandwich","Pasta","Seafood","Chicken","Beef","Pork","Vegetarian","Vegan",
        "Bread","Dessert","Snack","Beverage","Cocktail","Sauce & Condiment","Baked Goods","Other"
    ]

    /// Mood and occasion. Comfort, Healthy, Quick, One-Pot, Grilled, Baked, Slow-Cooker,
    /// Air-Fryer, Holiday, Party, Kid-Friendly, Budget, Meal-Prep, Leftovers.
    nonisolated static let styles: [String] = [
        "Comfort","Healthy","Quick","One-Pot","Grilled","Baked","Slow-Cooker",
        "Air-Fryer","Holiday","Party","Kid-Friendly","Budget","Meal-Prep","Leftovers"
    ]

    /// The parent a regional style rolls up to, so "Southern" and "Tex-Mex" both answer
    /// a filter for "American" without collapsing into it on the recipe card.
    nonisolated static func parentCuisine(_ cuisine: String) -> String? {
        switch canonicalCuisine(cuisine) {
        case "Southern", "Cajun & Creole", "Tex-Mex", "BBQ", "New England", "Soul Food", "Hawaiian":
            return "American"
        default:
            return nil
        }
    }

    /// Map a raw cuisine string (any case / synonym) to a canonical value.
    nonisolated static func canonicalCuisine(_ raw: String) -> String {
        let r = SearchNormalization.fold(raw)
        if r.isEmpty { return "Other" }
        if let direct = canonicalCuisineSingle(r) { return direct }

        let pieces = r
            .components(separatedBy: CharacterSet(charactersIn: "-/,&"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if pieces.count > 1 {
            var fallback: String?
            for piece in pieces.reversed() {
                if let hit = canonicalCuisineSingle(piece) {
                    if parentCuisine(hit) != nil { return hit }
                    fallback = fallback ?? hit
                }
            }
            if let fallback { return fallback }
        }

        if let fuzzy = cuisines.max(by: { FuzzyMatch.score(r, SearchNormalization.fold($0)) < FuzzyMatch.score(r, SearchNormalization.fold($1)) }),
           FuzzyMatch.score(r, SearchNormalization.fold(fuzzy)) >= 0.8 {
            return fuzzy
        }
        return "Other"
    }

    /// Map a raw category string to a canonical value.
    nonisolated static func canonicalCategory(_ raw: String) -> String {
        let r = SearchNormalization.fold(raw)
        if r.isEmpty { return "Other" }
        if let direct = canonicalCategorySingle(r) { return direct }

        let pieces = r
            .components(separatedBy: CharacterSet(charactersIn: "-/,&"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for piece in pieces where pieces.count > 1 {
            if let hit = canonicalCategorySingle(piece) { return hit }
        }

        if let fuzzy = categories.max(by: { FuzzyMatch.score(r, SearchNormalization.fold($0)) < FuzzyMatch.score(r, SearchNormalization.fold($1)) }),
           FuzzyMatch.score(r, SearchNormalization.fold(fuzzy)) >= 0.8 {
            return fuzzy
        }
        return "Other"
    }

    nonisolated static func canonicalStyle(_ raw: String) -> String? {
        let r = SearchNormalization.fold(raw)
        if r.isEmpty { return nil }
        if let hit = styles.first(where: { SearchNormalization.fold($0) == r }) { return hit }
        let synonyms: [String: String] = [
            "comfort food": "Comfort", "light": "Healthy", "healthy-ish": "Healthy",
            "fast": "Quick", "easy": "Quick", "weeknight": "Quick", "30 minute": "Quick", "30-minute": "Quick",
            "one pot": "One-Pot", "one pan": "One-Pot", "sheet pan": "One-Pot", "skillet": "One-Pot",
            "grill": "Grilled", "barbecue": "Grilled", "bbq": "Grilled", "roasted": "Baked", "oven": "Baked",
            "slow cooker": "Slow-Cooker", "crockpot": "Slow-Cooker", "crock pot": "Slow-Cooker",
            "air fryer": "Air-Fryer", "christmas": "Holiday", "thanksgiving": "Holiday", "easter": "Holiday",
            "game day": "Party", "potluck": "Party", "kids": "Kid-Friendly", "family": "Kid-Friendly",
            "cheap": "Budget", "meal prep": "Meal-Prep", "make ahead": "Meal-Prep", "leftover": "Leftovers"
        ]
        if let mapped = synonyms[r] { return mapped }
        if let fuzzy = styles.max(by: { FuzzyMatch.score(r, SearchNormalization.fold($0)) < FuzzyMatch.score(r, SearchNormalization.fold($1)) }),
           FuzzyMatch.score(r, SearchNormalization.fold(fuzzy)) >= 0.8 {
            return fuzzy
        }
        return nil
    }

    private nonisolated static func canonicalCuisineSingle(_ r: String) -> String? {
        if let hit = cuisines.first(where: { SearchNormalization.fold($0) == r }) { return hit }
        let synonyms: [String: String] = [
            "usa": "American", "u s a": "American", "us": "American", "u s": "American", "united states": "American",
            "states": "American", "america": "American", "american regional": "American",
            "south": "Southern", "southern food": "Southern", "southern us": "Southern", "southern usa": "Southern",
            "lowcountry": "Southern", "appalachian": "Southern", "soul": "Soul Food", "soulfood": "Soul Food",
            "cajun": "Cajun & Creole", "creole": "Cajun & Creole", "louisiana": "Cajun & Creole", "new orleans": "Cajun & Creole",
            "tex mex": "Tex-Mex", "texmex": "Tex-Mex", "southwestern": "Tex-Mex", "southwest": "Tex-Mex",
            "barbecue": "BBQ", "barbeque": "BBQ", "bbq": "BBQ", "smoked": "BBQ", "smokehouse": "BBQ",
            "new england": "New England", "hawaii": "Hawaiian", "aloha": "Hawaiian",
            "mexico": "Mexican", "italy": "Italian", "france": "French", "greece": "Greek", "spain": "Spanish",
            "china": "Chinese", "japan": "Japanese", "korea": "Korean", "vietnam": "Vietnamese", "viet": "Vietnamese",
            "philippines": "Filipino", "pinoy": "Filipino", "india": "Indian", "thailand": "Thai", "thai food": "Thai",
            "med": "Mediterranean", "levantine": "Middle Eastern", "levant": "Middle Eastern", "middle east": "Middle Eastern",
            "persian": "Middle Eastern", "israeli": "Middle Eastern", "lebanese": "Middle Eastern", "turkish": "Turkish", "turkey": "Turkish",
            "morocco": "Moroccan", "moroccan": "Moroccan", "brazil": "Brazilian", "brazilian": "Brazilian",
            "caribbean islands": "Caribbean", "jamaican": "Caribbean", "cuban": "Caribbean", "africa": "African", "ethiopian": "African",
            "britain": "British", "england": "British", "english": "British", "uk": "British", "u k": "British",
            "ireland": "Irish", "germany": "German", "polish": "Eastern European", "russian": "Eastern European", "hungarian": "Eastern European",
            "latin": "Latin American", "central american": "Latin American", "south american": "Latin American", "peruvian": "Latin American",
            "fusion cuisine": "Fusion", "global": "Fusion"
        ]
        return synonyms[r]
    }

    private nonisolated static func canonicalCategorySingle(_ r: String) -> String? {
        if let hit = categories.first(where: { SearchNormalization.fold($0) == r }) { return hit }
        let synonyms: [String: String] = [
            "morning": "Breakfast", "breakfasts": "Breakfast", "brunches": "Brunch",
            "main": "Dinner", "main course": "Dinner", "mains": "Dinner", "entree": "Dinner", "entrée": "Dinner", "supper": "Dinner",
            "starter": "Appetizer", "starters": "Appetizer", "appetizers": "Appetizer", "small plate": "Appetizer",
            "sides": "Side", "side dish": "Side", "soups": "Soup", "stew": "Soup", "stews": "Soup",
            "salads": "Salad", "sandwiches": "Sandwich", "burger": "Sandwich", "wrap": "Sandwich",
            "noodle": "Pasta", "noodles": "Pasta", "spaghetti": "Pasta", "macaroni": "Pasta",
            "fish": "Seafood", "shellfish": "Seafood", "shrimp": "Seafood", "prawn": "Seafood", "prawns": "Seafood",
            "poultry": "Chicken", "chickens": "Chicken", "steak": "Beef", "steaks": "Beef", "ground beef": "Beef",
            "pig": "Pork", "ham": "Pork", "bacon": "Pork", "plant based": "Vegan", "plant-based": "Vegan", "meatless": "Vegetarian",
            "veggie": "Vegetarian", "breads": "Bread", "loaf": "Bread", "baking": "Baked Goods", "baked goods": "Baked Goods",
            "sweet": "Dessert", "sweets": "Dessert", "desserts": "Dessert", "cake": "Dessert", "pie": "Dessert",
            "snacks": "Snack", "drink": "Beverage", "drinks": "Beverage", "cocktails": "Cocktail", "mocktail": "Cocktail",
            "sauce": "Sauce & Condiment", "sauces": "Sauce & Condiment", "condiment": "Sauce & Condiment", "condiments": "Sauce & Condiment", "dressing": "Sauce & Condiment"
        ]
        return synonyms[r]
    }
}

/// The cuisines, categories and styles that at least `minimum` recipes actually carry,
/// in taxonomy order, so a filter row never offers a dead end.
///
/// Regional cuisines roll up: a filter for "American" also matches recipes tagged
/// "Southern" or "Tex-Mex", via RecipeTaxonomy.parentCuisine.
enum RecipeFacets {
    nonisolated static func availableCuisines(in recipes: [UserRecipe], minimum: Int = 1) -> [String] {
        let counts = cuisineCounts(in: recipes)
        return RecipeTaxonomy.cuisines.filter { (counts[$0] ?? 0) >= minimum }
    }

    nonisolated static func availableCategories(in recipes: [UserRecipe], minimum: Int = 1) -> [String] {
        var counts: [String: Int] = [:]
        for recipe in recipes {
            for tag in recipe.tags {
                let category = RecipeTaxonomy.canonicalCategory(tag)
                if category != "Other" { counts[category, default: 0] += 1 }
            }
        }
        return RecipeTaxonomy.categories.filter { (counts[$0] ?? 0) >= minimum }
    }

    nonisolated static func availableStyles(in recipes: [UserRecipe], minimum: Int = 1) -> [String] {
        var counts: [String: Int] = [:]
        for recipe in recipes {
            for tag in recipe.tags {
                if let style = RecipeTaxonomy.canonicalStyle(tag) {
                    counts[style, default: 0] += 1
                }
            }
        }
        return RecipeTaxonomy.styles.filter { (counts[$0] ?? 0) >= minimum }
    }

    nonisolated static func matches(_ recipe: UserRecipe, cuisine: String) -> Bool {
        let target = RecipeTaxonomy.canonicalCuisine(cuisine)
        guard target != "Other" else { return false }
        let recipeCuisine = RecipeTaxonomy.canonicalCuisine(recipe.cuisine)
        if recipeCuisine == target { return true }
        if RecipeTaxonomy.parentCuisine(recipeCuisine) == target { return true }
        return recipe.tags.contains { tag in
            let tagCuisine = RecipeTaxonomy.canonicalCuisine(tag)
            return tagCuisine == target || RecipeTaxonomy.parentCuisine(tagCuisine) == target
        }
    }

    nonisolated static func count(cuisine: String, in recipes: [UserRecipe]) -> Int {
        cuisineCounts(in: recipes)[RecipeTaxonomy.canonicalCuisine(cuisine)] ?? 0
    }

    private nonisolated static func cuisineCounts(in recipes: [UserRecipe]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for recipe in recipes {
            let cuisine = RecipeTaxonomy.canonicalCuisine(recipe.cuisine)
            guard cuisine != "Other" else { continue }
            counts[cuisine, default: 0] += 1
            if let parent = RecipeTaxonomy.parentCuisine(cuisine) {
                counts[parent, default: 0] += 1
            }
        }
        return counts
    }
}

// MARK: - #14 Ingredient synonyms
// Normalize regional/alternate ingredient names so search and inventory-matching hit
// more recipes (scallion = green onion, cilantro = coriander, etc.).
enum IngredientSynonyms {
    nonisolated static let map: [String: String] = [
        "scallion": "green onion", "scallions": "green onion", "spring onion": "green onion",
        "cilantro": "coriander", "coriander leaves": "coriander",
        "aubergine": "eggplant", "courgette": "zucchini", "capsicum": "bell pepper",
        "rocket": "arugula", "beetroot": "beet", "mangetout": "snow peas",
        "garbanzo": "chickpea", "garbanzos": "chickpea", "chickpeas": "chickpea",
        "passata": "tomato sauce", "double cream": "heavy cream", "single cream": "light cream",
        "icing sugar": "powdered sugar", "caster sugar": "superfine sugar",
        "plain flour": "all-purpose flour", "bicarbonate of soda": "baking soda",
        "prawn": "shrimp", "prawns": "shrimp", "minced beef": "ground beef",
        "mince": "ground beef", "groundnut": "peanut", "maize": "corn",
        "stock cube": "bouillon", "soya": "soy", "yoghurt": "yogurt",
    ]

    /// Canonicalize a single ingredient name (returns it unchanged if no synonym).
    nonisolated static func canonical(_ name: String) -> String {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        return map[n] ?? n
    }

    /// Does a recipe ingredient list contain a given pantry item, allowing for synonyms?
    nonisolated static func contains(_ list: [String], item: String) -> Bool {
        let target = canonical(item)
        return RecipeIngredients.names(list).contains { canonical($0) == target }
    }
}

// MARK: - #12 Dietary tag inference
// Derive vegan / vegetarian / gluten-free / dairy-free flags locally from the ingredient
// list. Heuristic (errs toward NOT claiming a restrictive label if uncertain).
nonisolated struct DietaryFlags: Sendable, Equatable {
    var vegetarian = false
    var vegan      = false
    var glutenFree = false
    var dairyFree  = false

    var labels: [String] {
        var out: [String] = []
        if vegan { out.append("Vegan") } else if vegetarian { out.append("Vegetarian") }
        if glutenFree { out.append("Gluten-Free") }
        if dairyFree && !vegan { out.append("Dairy-Free") }
        return out
    }
}

nonisolated enum DietaryClassifier {
    // Expanded so that meat dishes are reliably detected. The previous short list let many
    // cuts/terms slip through (e.g. "chops", "mutton", "ribeye", "brisket", deli meats), which
    // caused meat recipes to be mislabeled vegan/vegetarian by absence.
    private static let meat = [
        // poultry
        "chicken","turkey","duck","goose","quail","poultry","drumstick","wing","thigh","breast meat",
        // red meat & game
        "beef","steak","ribeye","rib eye","sirloin","brisket","chuck","flank","skirt","tenderloin",
        "filet","fillet mignon","ground beef","mince","minced","pork","ham","bacon","pancetta",
        "prosciutto","lamb","mutton","chop","chops","veal","goat","venison","bison","buffalo",
        "rabbit","oxtail","tripe","liver","kidney","tongue","brisket",
        // processed / cured
        "sausage","salami","pepperoni","chorizo","bratwurst","hot dog","frankfurter","jerky",
        "spam","bologna","pastrami","corned beef","deli meat","cold cut","meatball","meatloaf",
        // seafood
        "fish","salmon","tuna","cod","tilapia","halibut","trout","bass","snapper","mackerel",
        "sardine","anchovy","herring","catfish","haddock","shrimp","prawn","crab","lobster",
        "scallop","clam","mussel","oyster","squid","calamari","octopus","crawfish","crayfish",
        "caviar","roe","eel","seafood","shellfish",
        // generic / byproducts that imply meat
        "meat","gelatin","lard","tallow","suet","broth","bone broth","stock","bouillon","dripping",
        "carnitas","barbacoa","pulled pork","ground turkey","ground chicken","stew meat"]
    private static let animalNonMeat = ["egg","eggs","milk","butter","cheese","cream","yogurt","yoghurt",
        "honey","ghee","mayonnaise","mayo","whey","casein","custard","lard","gelatin"]
    private static let dairy = ["milk","butter","cheese","cream","yogurt","yoghurt","ghee","whey",
        "casein","custard","ice cream","buttermilk","paneer","mozzarella","parmesan","cheddar",
        "ricotta","feta","gouda","brie","mascarpone","half-and-half","half and half"]
    private static let gluten = ["flour","wheat","bread","pasta","noodle","barley","rye","couscous",
        "cracker","breadcrumb","panko","soy sauce","beer","bulgur","semolina","farro","seitan",
        "tortilla","pita","bagel","cereal","cake","cookie","pastry","pretzel","crouton","matzo"]

    nonisolated static func flags(for ingredients: [String]) -> DietaryFlags {
        flags(for: ingredients, title: nil)
    }

    /// Optionally pass the recipe title so dishes named after meat are caught even when the
    /// ingredient list is sparse, garbled, or missing.
    nonisolated static func flags(for ingredients: [String], title: String?) -> DietaryFlags {
        let names = RecipeIngredients.names(ingredients).map { IngredientSynonyms.canonical($0) }
        let titleText = (title ?? "").lowercased()

        // If we have neither ingredients nor a title, we have NO evidence — claim nothing
        // restrictive (all flags false ⇒ no labels), rather than defaulting to "vegan".
        guard !names.isEmpty || !titleText.isEmpty else { return DietaryFlags() }

        func anyContains(_ keywords: [String]) -> Bool {
            if names.contains(where: { n in keywords.contains { n.contains($0) } }) { return true }
            // Also check the title (whole-string contains is fine for these distinctive words).
            return keywords.contains { titleText.contains($0) }
        }
        let hasMeat   = anyContains(meat)
        let hasAnimal = hasMeat || anyContains(animalNonMeat)
        let hasDairy  = anyContains(dairy)
        let hasGluten = anyContains(gluten)

        // Be conservative: only assert vegan/vegetarian when we actually parsed real ingredients
        // (positive evidence), not merely because a meat keyword happened to be absent. With only
        // a title and no ingredient list, we won't slap on a "Vegan" badge.
        let haveIngredientEvidence = !names.isEmpty
        return DietaryFlags(
            vegetarian: haveIngredientEvidence && !hasMeat,
            vegan: haveIngredientEvidence && !hasAnimal,
            glutenFree: haveIngredientEvidence && !hasGluten,
            dairyFree: haveIngredientEvidence && !hasDairy
        )
    }
}

// MARK: - #11 Recipe merge
// When two sources describe the same dish, merge them into the richer record: prefer a
// non-empty image, the longer step list, and the union of ingredients.
enum RecipeMerge {
    /// Merge B into A, returning the best of each field. Caller supplies getters/setters.
    nonisolated static func best(imageA: String, imageB: String) -> String {
        imageA.isEmpty ? imageB : imageA
    }
    nonisolated static func bestSteps(_ a: [String], _ b: [String]) -> [String] {
        b.count > a.count ? b : a
    }
    nonisolated static func unionIngredients(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set(RecipeIngredients.names(a).map { IngredientSynonyms.canonical($0) })
        var out = a
        for ing in b {
            let key = IngredientSynonyms.canonical(RecipeIngredients.parse(ing).name)
            if !key.isEmpty && !seen.contains(key) { out.append(ing); seen.insert(key) }
        }
        return out
    }
}



// MARK: - Recipe detail snapshots

/// Precomputed values used by recipe detail screens. Keeping these values in one immutable
/// snapshot prevents SwiftUI body updates (timers, steppers, image state) from repeatedly
/// reparsing every ingredient and instruction on the main actor.
nonisolated struct OnlineRecipeDetailSnapshot: Sendable, Equatable {
    let steps: [String]
    let coverage: RecipeCoverage
    let stockStatus: OnlineRecipeMatch.Status
    let dietLabels: [String]
    let allergenHits: [String]
    let hasRealInstructions: Bool

    static let empty = OnlineRecipeDetailSnapshot(
        steps: [],
        coverage: RecipeCoverage(have: 0, total: 0, missingNames: [], expiringUsed: []),
        stockStatus: .unknown,
        dietLabels: [],
        allergenHits: [],
        hasRealInstructions: false
    )
}

nonisolated struct RecipeOverviewIngredientState: Identifiable, Sendable, Equatable {
    let id: String
    let line: String
    let isInStock: Bool
}

nonisolated struct RecipeOverviewSnapshot: Sendable, Equatable {
    let rows: [RecipeOverviewIngredientState]
    let missingItems: [String]
    let estimatedTimerMinutes: Int?

    static let empty = RecipeOverviewSnapshot(rows: [], missingItems: [], estimatedTimerMinutes: nil)
}


nonisolated struct UserRecipeDetailMetrics: Sendable {
    let averageRating: Double?
    let ratingCount: Int
    let cost: RecipeCost.Estimate
    /// Nutrition per original recipe serving; the UI applies the live serving scale.
    let calories: Double?
    let protein: Double
    let carbs: Double
    let fat: Double

    static let empty = UserRecipeDetailMetrics(
        averageRating: nil, ratingCount: 0,
        cost: RecipeCost.Estimate(total: 0, pricedCount: 0, totalCount: 0),
        calories: nil, protein: 0, carbs: 0, fat: 0
    )
}

actor UserRecipeMetricsCache {
    static let shared = UserRecipeMetricsCache()
    private var cache: [String: UserRecipeDetailMetrics] = [:]

    func metrics(recipe: UserRecipe, pastMeals: [LocalPastMeal],
                 priceHistory: [PriceRecord]) -> UserRecipeDetailMetrics {
        let key = [recipe.id.uuidString, String(recipe.updatedAt), String(pastMeals.count),
                   String(priceHistory.count)].joined(separator: "|")
        if let cached = cache[key] { return cached }
        let titleKey = recipe.title.lowercased().trimmingCharacters(in: .whitespaces)
        let ratings = pastMeals.compactMap { meal -> Int? in
            let matches = meal.recipeId == recipe.id ||
                meal.title.lowercased().trimmingCharacters(in: .whitespaces) == titleKey
            return matches && meal.rating > 0 ? meal.rating : nil
        }
        let average = ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count)
        let servingCount = Double(max(1, recipe.servings))
        let calories = recipe.ingredients.compactMap { $0.nutrition?.calories }
        let result = UserRecipeDetailMetrics(
            averageRating: average, ratingCount: ratings.count,
            cost: RecipeCost.estimate(ingredients: recipe.ingredients.map(\.name), history: priceHistory),
            calories: calories.isEmpty ? nil : Double(calories.reduce(0, +)) / servingCount,
            protein: recipe.ingredients.compactMap { $0.nutrition?.protein }.reduce(0, +) / servingCount,
            carbs: recipe.ingredients.compactMap { $0.nutrition?.totalCarbs }.reduce(0, +) / servingCount,
            fat: recipe.ingredients.compactMap { $0.nutrition?.totalFat }.reduce(0, +) / servingCount
        )
        cache[key] = result
        if cache.count > 80 { cache.removeValue(forKey: cache.keys.first!) }
        return result
    }
}

actor RecipeDetailSnapshotCache {
    static let shared = RecipeDetailSnapshotCache()

    private var online: [String: OnlineRecipeDetailSnapshot] = [:]
    private var overview: [String: RecipeOverviewSnapshot] = [:]
    private let cap = 100

    func onlineSnapshot(recipe: OnlineRecipe, inStock: Set<String>,
                        expiringNames: [String], allergens: [String]) -> OnlineRecipeDetailSnapshot {
        let key = onlineKey(recipe: recipe, inStock: inStock, expiringNames: expiringNames, allergens: allergens)
        if let cached = online[key] { return cached }
        let result = OnlineRecipeDetailSnapshot(
            steps: RecipeStepSplitter.split(recipe.instructions),
            coverage: RecipeCoverageBuilder.make(for: recipe, inStock: inStock, expiringNames: expiringNames),
            stockStatus: OnlineRecipeMatch.status(recipe, inStock: inStock),
            dietLabels: DietaryClassifier.flags(for: recipe.ingredients, title: recipe.title).labels,
            allergenHits: OnlineRecipeFacts.allergenHits(recipe, allergens: allergens),
            hasRealInstructions: OnlineRecipeFacts.hasRealInstructions(recipe.instructions)
        )
        online[key] = result
        trim(&online)
        return result
    }

    func overviewSnapshot(title: String, ingredients: [String], steps: [String],
                          inventory: [LocalInventoryItem]) -> RecipeOverviewSnapshot {
        let key = overviewKey(title: title, ingredients: ingredients, steps: steps, inventory: inventory)
        if let cached = overview[key] { return cached }
        let rows = ingredients.enumerated().map { index, line in
            RecipeOverviewIngredientState(
                id: "\(index)-\(line.lowercased())", line: line,
                isInStock: IngredientStockMatch.inStock(line, items: inventory, minLevel: 0.1)
            )
        }
        let timerSeconds = steps.reduce(0) { $0 + (StepTimerEngine.detectSeconds(in: $1) ?? 0) }
        let result = RecipeOverviewSnapshot(
            rows: rows,
            missingItems: rows.filter { !$0.isInStock }.map(\.line),
            estimatedTimerMinutes: timerSeconds > 0 ? Int((Double(timerSeconds) / 60).rounded()) : nil
        )
        overview[key] = result
        trim(&overview)
        return result
    }

    private func onlineKey(recipe: OnlineRecipe, inStock: Set<String>,
                           expiringNames: [String], allergens: [String]) -> String {
        [recipe.id, recipe.title, recipe.ingredients.joined(separator: "|"), recipe.instructions,
         inStock.sorted().joined(separator: "|"), expiringNames.sorted().joined(separator: "|"),
         allergens.sorted().joined(separator: "|")].joined(separator: "§")
    }

    private func overviewKey(title: String, ingredients: [String], steps: [String],
                             inventory: [LocalInventoryItem]) -> String {
        let pantry = inventory.map { "\($0.name.lowercased()):\($0.effectiveLevel)" }.sorted().joined(separator: "|")
        return [title, ingredients.joined(separator: "|"), steps.joined(separator: "|"), pantry].joined(separator: "§")
    }

    private func trim<T>(_ dictionary: inout [String: T]) {
        guard dictionary.count > cap else { return }
        for key in dictionary.keys.prefix(dictionary.count - cap) { dictionary.removeValue(forKey: key) }
    }
}
