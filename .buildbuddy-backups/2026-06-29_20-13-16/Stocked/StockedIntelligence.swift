// StockedIntelligence.swift — Central intelligence layer for Stocked.
// Handles: ingredient co-occurrence, zone NLP, cook time extraction,
//          DRI percent-daily-value, substitute stock checking.
import Foundation
import NaturalLanguage

// MARK: - Ingredient Co-occurrence Engine
// Derives pairing scores from the bundled RecipeNLG dataset.
// Falls back to a curated starter matrix for instant results on first launch.
// MainActor-isolated: holds a mutable session cache (`co`) that warm(for:) updates
// after an async SQLite read, and the only callers are SwiftUI views on the main
// actor. Isolation makes that cache access data-race-free.
@MainActor
final class IngredientCooccurrence {

    static let shared = IngredientCooccurrence()
    private init() { buildIfNeeded() }

    // co[A][B] = number of recipes that contain both A and B
    private var co: [String: [String: Int]] = [:]
    private let minCount = 2   // must appear together at least N times to surface

    // Top pairings for a given ingredient, sorted by co-occurrence count.
    // Now backed by the prebuilt SQLite `cooccurrence` table (RecipeStore) instead
    // of an in-memory matrix built by parsing the 98 MB JSON. The first call for a
    // given ingredient queries SQLite and caches the result in `co` for the session.
    func pairings(for ingredient: String, limit: Int = 8) -> [String] {
        let key = normalize(ingredient)
        // Session cache (populated lazily from SQLite, see warm(for:)).
        if let row = co[key] {
            let live = row.sorted { $0.value > $1.value }
                          .prefix(limit)
                          .filter { $0.value >= minCount }
                          .map { $0.key.capitalized }
            if !live.isEmpty { return live }
        }
        // Curated fallback — 60 common ingredients (instant, and covers gaps).
        return curatedPairings(for: key)
    }

    // Whether we have any data for an ingredient
    func hasPairings(for ingredient: String) -> Bool {
        let key = normalize(ingredient)
        return !(co[key]?.isEmpty ?? true)
            || !curatedPairings(for: key).isEmpty
    }

    /// Lazily fetch and cache pairings for one ingredient from the prebuilt DB.
    /// Safe to call from a Task; updates the session cache so the subsequent sync
    /// `pairings(for:)` returns live, data-derived pairings.
    func warm(for ingredient: String, limit: Int = 25) async {
        let key = normalize(ingredient)
        guard co[key] == nil else { return }
        let pairs = await RecipeStore.shared.pairings(forIngredient: key, limit: limit)
        guard !pairs.isEmpty else { return }
        var row: [String: Int] = [:]
        for p in pairs { row[normalize(p.name)] = p.count }
        co[key] = row
    }

    // MARK: - Build
    private func buildIfNeeded() {
        // Nothing to build at launch anymore. Pairings are read on demand from the
        // prebuilt SQLite cooccurrence table (see warm(for:) / pairings(for:)),
        // which removes the old launch-time path that loaded the entire 98 MB recipe
        // corpus into memory just to derive a co-occurrence matrix.
    }

    private func normalize(_ s: String) -> String {
        s.lowercased()
         .trimmingCharacters(in: .whitespacesAndNewlines)
         .components(separatedBy: CharacterSet.letters.inverted)
         .joined(separator: " ")
         .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Curated fallback (60 ingredients × top-6 pairings)
    private func curatedPairings(for key: String) -> [String] {
        let c: [String: [String]] = [
            "garlic":       ["Butter","Olive Oil","Parsley","Lemon","Pasta","Chicken","Onion","Thyme"],
            "butter":       ["Garlic","Lemon","Parsley","Sage","Cream","Flour","Honey"],
            "lemon":        ["Garlic","Parsley","Butter","Chicken","Fish","Olive Oil","Honey"],
            "olive oil":    ["Garlic","Lemon","Basil","Tomato","Pasta","Pepper","Rosemary"],
            "chicken":      ["Garlic","Lemon","Rosemary","Thyme","Onion","Olive Oil","Cream"],
            "pasta":        ["Garlic","Olive Oil","Parmesan","Tomato","Basil","Cream","Bacon"],
            "tomato":       ["Basil","Garlic","Olive Oil","Mozzarella","Onion","Balsamic"],
            "onion":        ["Garlic","Butter","Olive Oil","Beef","Chicken","Carrot","Thyme"],
            "eggs":         ["Butter","Cheese","Bacon","Onion","Cream","Chives","Spinach"],
            "beef":         ["Onion","Garlic","Rosemary","Thyme","Carrot","Mushroom","Red Wine"],
            "salmon":       ["Lemon","Dill","Garlic","Butter","Capers","Cream","Asparagus"],
            "potatoes":     ["Butter","Garlic","Rosemary","Cream","Cheese","Onion","Bacon"],
            "rice":         ["Soy Sauce","Garlic","Ginger","Onion","Butter","Chicken Broth","Sesame Oil"],
            "basil":        ["Tomato","Mozzarella","Olive Oil","Garlic","Pasta","Pine Nuts"],
            "cheese":       ["Pasta","Eggs","Bread","Tomato","Onion","Pepper","Bacon"],
            "cream":        ["Mushroom","Pasta","Butter","Garlic","Chicken","Shallot"],
            "mushroom":     ["Garlic","Butter","Cream","Thyme","Soy Sauce","Onion","Shallot"],
            "ginger":       ["Garlic","Soy Sauce","Sesame Oil","Rice","Chicken","Lime"],
            "avocado":      ["Lemon","Lime","Cilantro","Onion","Tomato","Eggs","Chili"],
            "spinach":      ["Garlic","Lemon","Olive Oil","Cream","Pasta","Eggs","Nutmeg"],
            "flour":        ["Butter","Eggs","Sugar","Milk","Baking Powder","Salt","Vanilla"],
            "sugar":        ["Butter","Eggs","Flour","Vanilla","Cream","Lemon","Cinnamon"],
            "milk":         ["Eggs","Butter","Flour","Sugar","Vanilla","Cream","Cheese"],
            "bacon":        ["Eggs","Cheese","Onion","Garlic","Potato","Lettuce","Tomato"],
            "shrimp":       ["Garlic","Butter","Lemon","Olive Oil","Pasta","Chili","Parsley"],
            "tofu":         ["Soy Sauce","Ginger","Garlic","Sesame Oil","Green Onion","Chili"],
            "apple":        ["Cinnamon","Sugar","Lemon","Butter","Oats","Vanilla","Nutmeg"],
            "banana":       ["Oats","Honey","Milk","Vanilla","Cinnamon","Peanut Butter","Eggs"],
            "carrot":       ["Ginger","Garlic","Onion","Cumin","Honey","Olive Oil","Thyme"],
            "broccoli":     ["Garlic","Olive Oil","Lemon","Parmesan","Sesame Oil","Soy Sauce"],
            "pepper":       ["Onion","Garlic","Olive Oil","Tomato","Cumin","Beef","Rice"],
            "cinnamon":     ["Sugar","Apple","Vanilla","Butter","Nutmeg","Ginger","Honey"],
            "soy sauce":    ["Ginger","Garlic","Sesame Oil","Rice","Green Onion","Honey"],
            "honey":        ["Lemon","Ginger","Mustard","Garlic","Butter","Thyme","Soy Sauce"],
            "lime":         ["Cilantro","Garlic","Chili","Coconut Milk","Ginger","Honey"],
            "cilantro":     ["Lime","Garlic","Onion","Chili","Cumin","Avocado","Jalapeño"],
            "cumin":        ["Garlic","Onion","Chili Powder","Cilantro","Coriander","Lime"],
            "chili":        ["Garlic","Cumin","Onion","Tomato","Lime","Cilantro","Beef"],
            "coconut milk": ["Curry","Ginger","Garlic","Lime","Rice","Lemongrass","Chili"],
            "pork":         ["Garlic","Soy Sauce","Ginger","Apple","Onion","Rosemary","Mustard"],
            "lamb":         ["Rosemary","Garlic","Mint","Lemon","Cumin","Onion","Thyme"],
            "asparagus":    ["Lemon","Butter","Garlic","Parmesan","Olive Oil","Bacon","Egg"],
            "cauliflower":  ["Garlic","Butter","Cheese","Cumin","Turmeric","Olive Oil","Cream"],
            "zucchini":     ["Garlic","Olive Oil","Tomato","Parmesan","Basil","Onion","Mint"],
            "leek":         ["Butter","Cream","Potato","Garlic","Thyme","Chicken Broth","Cheese"],
            "peas":         ["Butter","Mint","Bacon","Garlic","Cream","Onion","Ham"],
            "corn":         ["Butter","Lime","Cilantro","Chili","Cheese","Jalapeño","Onion"],
            "oats":         ["Honey","Banana","Cinnamon","Milk","Almond","Vanilla","Maple Syrup"],
            "almond":       ["Honey","Vanilla","Oats","Cream","Chocolate","Cinnamon","Coconut"],
            "chocolate":    ["Butter","Sugar","Eggs","Cream","Vanilla","Raspberry","Coffee"],
            "vanilla":      ["Sugar","Butter","Eggs","Cream","Flour","Milk","Chocolate"],
            "parmesan":     ["Pasta","Olive Oil","Garlic","Basil","Lemon","Cream","Eggs"],
            "mozzarella":   ["Tomato","Basil","Olive Oil","Garlic","Balsamic","Prosciutto"],
            "ricotta":      ["Pasta","Spinach","Lemon","Eggs","Parmesan","Basil","Honey"],
            "thyme":        ["Garlic","Butter","Chicken","Lemon","Rosemary","Olive Oil","Onion"],
            "rosemary":     ["Garlic","Olive Oil","Lemon","Potato","Chicken","Lamb","Thyme"],
            "parsley":      ["Garlic","Lemon","Olive Oil","Butter","Capers","Tomato","Onion"],
            "dill":         ["Salmon","Lemon","Cream","Cucumber","Capers","Yogurt","Garlic"],
            "oregano":      ["Garlic","Olive Oil","Tomato","Feta","Lemon","Olives","Basil"],
            "turmeric":     ["Ginger","Garlic","Coconut Milk","Cumin","Coriander","Black Pepper"],
        ]
        return c.first(where: { key.contains($0.key) || $0.key.contains(key) })?.value ?? []
    }
}

// MARK: - Zone Auto-Categoriser (NLP-based)
// Called from AddItemSheet.onChange(of: itemName) to suggest a zone before the user picks.
struct ZoneClassifier {

    // Returns best-guess StorageCategory for a typed ingredient name
    static func classify(_ name: String) -> StorageCategory {
        let t = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Freezer
        if anyMatch(t, ["frozen","ice cream","gelato","sorbet","popsicle"]) { return .freezer }

        // Staples — spices, condiments, oils, baking. Checked BEFORE Fridge so seasoning
        // peppers ("black pepper", "cayenne pepper", "lemon pepper") aren't swallowed by
        // the Fridge "pepper" (bell pepper) match.
        if anyMatch(t, ["salt","pepper","garlic powder","onion powder","cumin","oregano","paprika",
                        "cinnamon","turmeric","vanilla","baking soda","baking powder","yeast",
                        "spice","herb","seasoning","sauce","vinegar","mustard","ketchup","soy sauce",
                        "olive oil","vegetable oil","coconut oil","sugar","brown sugar","honey",
                        "syrup","hot sauce","worcestershire","fish sauce","oyster sauce","tahini",
                        "miso","cayenne","chili flakes","chili powder","curry powder","nutmeg",
                        "ginger powder","bay leaf","bay leaves","coriander","cardamom","clove",
                        "rosemary","thyme","basil","sage","dill","extract"]) {
            // …but a few "pepper"/"herb" things are genuinely fresh produce → Fridge.
            if anyMatch(t, ["bell pepper","jalapeño","jalapeno","fresh herb","fresh basil",
                            "bell peppers","poblano","serrano","habanero"]) {
                return .fridge
            }
            return .staples
        }

        // Fridge — dairy + produce + cold drinks
        if anyMatch(t, ["milk","cheese","butter","yogurt","cream","egg","chicken","beef","pork","lamb",
                        "fish","salmon","shrimp","tuna steak","tofu","lettuce","spinach","kale",
                        "celery","carrot","pepper","tomato","strawberr","blueberr","raspberry",
                        "mushroom","fresh herb","fresh basil","deli","ham","bacon","salami","prosciutto",
                        "orange juice","apple juice","fresh juice","greek yogurt","sour cream",
                        // cold drinks → Fridge
                        "beer","wine","cider","hard seltzer","kombucha","energy drink","sports drink",
                        "sparkling water","mineral water","seltzer","tonic","club soda",
                        "cold brew","iced coffee","iced tea","almond milk","oat milk","soy milk",
                        "rice milk","coconut water","kefir","protein shake","lemonade",
                        "smoothie"]) { return .fridge }

        // Pantry — dry goods + shelf-stable drinks
        if anyMatch(t, ["pasta","rice","bread","can","flour","cereal","oat","bean","lentil",
                        "broth","stock","jam","chip","cracker","cookie","soup","nut","seed",
                        "quinoa","couscous","tortilla","noodle","ramen",
                        // shelf-stable drinks → Pantry
                        "soda","cola","pepsi","sprite","gatorade","powerade","coffee","tea",
                        "hot chocolate","cocoa","protein powder","juice box","juice pouch",
                        "coconut milk","evaporated milk","water"]) { return .pantry }

        return .pantry
    }

    private static func anyMatch(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains(where: { text.contains($0) })
    }

    private static func tagWithNL(_ text: String) -> StorageCategory {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        // If NL identifies any food-related noun, default to Pantry
        // (better than wrong zone)
        return .pantry
    }
}

// MARK: - Cook Time Estimator
// Parses recipe instruction steps and sums detected durations.
struct CookTimeEstimator {

    /// Returns a formatted cook time string like "35 min" or "1 hr 10 min"
    /// by summing all time mentions found in the instruction steps.
    static func estimate(from steps: [String]) -> String? {
        var totalSeconds = 0
        for step in steps {
            if let secs = StepTimerEngine.detectSeconds(in: step) {
                totalSeconds += secs
            }
        }
        guard totalSeconds > 60 else { return nil }
        let mins = totalSeconds / 60
        if mins < 60 { return "\(mins) min" }
        let hrs  = mins / 60
        let rem  = mins % 60
        return rem == 0 ? "\(hrs) hr" : "\(hrs) hr \(rem) min"
    }
}

// MARK: - USDA Dietary Reference Intake (DRI) Tables
// Adult (19–50 years) daily values — used to compute % Daily Value labels.
struct DRITable {

    struct DRI {
        let calories:    Int     // kcal
        let protein:     Double  // g
        let totalFat:    Double  // g
        let saturatedFat: Double // g (< this)
        let totalCarbs:  Double  // g
        let dietaryFiber: Double // g
        let sodium:      Double  // mg
        let calcium:     Double  // mg
        let iron:        Double  // mg
        let potassium:   Double  // mg
        let vitaminD:    Double  // mcg
    }

    // FDA's 2020–2025 Daily Values (used on Nutrition Facts labels)
    static let adult = DRI(
        calories:    2000,
        protein:     50,
        totalFat:    78,
        saturatedFat: 20,
        totalCarbs:  275,
        dietaryFiber: 28,
        sodium:      2300,
        calcium:     1300,
        iron:        18,
        potassium:   4700,
        vitaminD:    20
    )

    // Returns percent of daily value, clamped to 0–999%
    static func percent(_ value: Double, of dailyValue: Double) -> Int {
        guard dailyValue > 0 else { return 0 }
        return min(999, Int((value / dailyValue * 100).rounded()))
    }

    static func label(value: Double, dailyValue: Double, unit: String) -> String {
        "\(percent(value, of: dailyValue))%  (\(String(format: "%.1f", value))\(unit))"
    }
}

// MARK: - Import Format Detector
// Identifies third-party export schemas from JSON keys.
enum ImportFormat {
    case stocked        // native — KitchenSnapshot
    case anyList        // AnyList JSON export
    case paprika        // Paprika Recipe Manager export
    case mealime        // Mealime meal plan export
    case unknown

    static func detect(from data: Data) -> ImportFormat {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown }

        if json["exportedAt"] != nil && json["displayName"] != nil { return .stocked }
        if json["items"] != nil && json["categories"] != nil { return .anyList }
        if json["recipes"] != nil && (json["rating"] != nil || (json["recipes"] as? [[String: Any]])?.first?["rating"] != nil) { return .paprika }
        if json["mealPlan"] != nil || json["meal_plan"] != nil { return .mealime }
        // Array of recipe objects
        if let arr = json["recipes"] as? [[String: Any]], let first = arr.first {
            if first["ingredients"] != nil && first["directions"] != nil { return .paprika }
        }
        return .unknown
    }
}

// MARK: - Quantity Parser
// Extracts (amount, unit, baseName) from ingredient strings like "2 cups flour"
struct ParsedQuantity {
    var amount:   Double   // numeric amount (0 = unspecified)
    var unit:     String   // "cup", "tbsp", "g", "oz", "" = count/unspecified
    var baseName: String   // normalized ingredient name without amount/unit

    // Canonical unit for consolidation math
    var canonicalUnit: String {
        switch unit.lowercased() {
        case "cup","cups","c":            return "cup"
        case "tablespoon","tablespoons","tbsp","tbs","tb": return "tbsp"
        case "teaspoon","teaspoons","tsp","ts":            return "tsp"
        case "ounce","ounces","oz":       return "oz"
        case "pound","pounds","lb","lbs": return "lb"
        case "gram","grams","g":          return "g"
        case "kilogram","kilograms","kg": return "kg"
        case "milliliter","milliliters","ml","millilitre": return "ml"
        case "liter","liters","l","litre","litres":        return "l"
        case "pinch","pinches":           return "pinch"
        case "can","cans":                return "can"
        case "slice","slices":            return "slice"
        case "clove","cloves":            return "clove"
        default:                          return unit.lowercased()
        }
    }

    // Human-readable display: "1½ cups" / "200g" / "3"
    var display: String {
        let u = canonicalUnit
        let n = smartFraction(amount)
        return u.isEmpty ? n : "\(n) \(u)"
    }

    // Conversion table to a shared "ml" base for volume merging
    private static let toML: [String: Double] = [
        "cup": 240, "tbsp": 14.787, "tsp": 4.929,
        "l": 1000, "ml": 1
    ]
    private static let toG: [String: Double] = [
        "lb": 453.592, "oz": 28.3495, "kg": 1000, "g": 1
    ]

    // Merge two quantities of the same ingredient
    func merging(with other: ParsedQuantity) -> ParsedQuantity {
        let aUnit = canonicalUnit, bUnit = other.canonicalUnit
        // Same unit — simple add
        if aUnit == bUnit {
            return ParsedQuantity(amount: amount + other.amount, unit: aUnit, baseName: baseName)
        }
        // Volume — convert both to ml then back to the larger unit
        if let aML = Self.toML[aUnit], let bML = Self.toML[bUnit] {
            let total = amount * aML + other.amount * bML
            // Express in the larger original unit
            let preferredUnit = aML >= bML ? aUnit : bUnit
            let backFactor = Self.toML[preferredUnit] ?? 1
            return ParsedQuantity(amount: total / backFactor, unit: preferredUnit, baseName: baseName)
        }
        // Weight — same pattern
        if let aG = Self.toG[aUnit], let bG = Self.toG[bUnit] {
            let total = amount * aG + other.amount * bG
            let preferredUnit = aG >= bG ? aUnit : bUnit
            let backFactor = Self.toG[preferredUnit] ?? 1
            return ParsedQuantity(amount: total / backFactor, unit: preferredUnit, baseName: baseName)
        }
        // Incompatible units — keep original, just bump amount to signal "more"
        return ParsedQuantity(amount: amount + other.amount, unit: aUnit, baseName: baseName)
    }

    // Compiled ONCE — was previously rebuilt on every parse() call, which runs per
    // ingredient during recipe matching (a hot path that contributed to the ICU/regex
    // allocation storm). Reusing one instance removes those per-call allocations.
    private static let quantityRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^([\d]+[½¼¾]?|[\d]*[½¼¾]|[\d]+/[\d]+|[\d]*\.[\d]+)?\s*([a-zA-Z]+\.?)?\s*(.+)$"#)
    }()

    static func parse(_ raw: String) -> ParsedQuantity {
        let s = raw.trimmingCharacters(in: .whitespaces)
        // Regex: optional leading number (incl. fractions ½ ¼ ¾ 1/2 1/4 3/4), optional unit, rest = name
        guard let regex = quantityRegex,
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        else { return ParsedQuantity(amount: 0, unit: "", baseName: s.lowercased()) }

        let g = { (i: Int) -> String in
            guard let r = Range(match.range(at: i), in: s) else { return "" }
            return String(s[r]).trimmingCharacters(in: .whitespaces)
        }

        let amountStr = g(1)
        let unitStr   = g(2)
        let nameStr   = g(3)

        let amount = parseAmount(amountStr)
        return ParsedQuantity(amount: amount, unit: unitStr, baseName: nameStr.lowercased())
    }

    private static func parseAmount(_ s: String) -> Double {
        if s.isEmpty { return 0 }
        if s.contains("½") { return (Double(s.replacingOccurrences(of: "½", with: "")) ?? 0) + 0.5 }
        if s.contains("¼") { return (Double(s.replacingOccurrences(of: "¼", with: "")) ?? 0) + 0.25 }
        if s.contains("¾") { return (Double(s.replacingOccurrences(of: "¾", with: "")) ?? 0) + 0.75 }
        if s.contains("/") {
            let p = s.components(separatedBy: "/")
            if p.count == 2, let n = Double(p[0]), let d = Double(p[1]), d != 0 { return n / d }
        }
        return Double(s) ?? 0
    }

    // Normalized base name for dedup (strips common suffixes)
    var normalizedName: String {
        let base = baseName.lowercased().trimmingCharacters(in: .whitespaces)
        // Strip a trailing plural "s" without a regex (the regex form compiled an ICU
        // pattern on every call, on a hot dedup path).
        if base.count > 3, base.hasSuffix("s"), !base.hasSuffix("ss") {
            return String(base.dropLast())
        }
        return base
    }
}

// MARK: - Smart Fraction Display
// Converts a decimal like 0.75 → "¾", 1.5 → "1½", 2.333 → "2⅓"
func smartFraction(_ value: Double) -> String {
    if value == 0 { return "" }
    let whole = Int(value)
    let frac  = value - Double(whole)
    let fracStr: String
    switch frac {
    case 0:            fracStr = ""
    case 0.1..<0.17:   fracStr = "⅛"
    case 0.17..<0.29:  fracStr = "¼"
    case 0.29..<0.42:  fracStr = "⅓"
    case 0.42..<0.58:  fracStr = "½"
    case 0.58..<0.71:  fracStr = "⅔"
    case 0.71..<0.88:  fracStr = "¾"
    case 0.88...:      fracStr = ""   // round up
    default:           fracStr = ""
    }
    let roundedWhole = frac >= 0.88 ? whole + 1 : whole
    if roundedWhole == 0 { return fracStr.isEmpty ? "1" : fracStr }
    return fracStr.isEmpty ? "\(roundedWhole)" : "\(roundedWhole)\(fracStr)"
}

// MARK: - Grocery Consolidator
// Merges duplicate ingredient names across recipe pushes.
struct GroceryConsolidator {

    // Normalize a grocery item name for comparison
    static func normalizeKey(_ name: String) -> String {
        ParsedQuantity.parse(name).normalizedName
    }

    // Consolidate a list of grocery items — merge duplicates by ingredient base name
    static func consolidate(_ items: [LocalGroceryItem]) -> [LocalGroceryItem] {
        var seen: [String: Int] = [:]    // normalizedName → index in result
        var result: [LocalGroceryItem] = []

        for item in items {
            let key = normalizeKey(item.name)
            if let idx = seen[key] {
                // Already have this ingredient — bump quantity
                result[idx].quantity += item.quantity
            } else {
                seen[key] = result.count
                result.append(item)
            }
        }
        return result
    }
}
