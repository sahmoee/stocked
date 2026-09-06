// NutritionDatabase.swift — Static nutrition facts + USDA async fallback.
// Per 100g unless servingSize states otherwise.
// Items 1, 2, 4: USDA auto-fallback, real serving sizes, optional transFat/addedSugars.
import Foundation
import SwiftUI

// MARK: - Extended nutrition entry (internal)
private nonisolated struct RichNutrition: Sendable {
    var calories: Int
    var protein, carbs, fat, fiber, sugar: Double
    var sodium, potassium, calcium, iron, vitaminC: Double
    var saturatedFat, cholesterol: Double
    var transFat:    Double? = nil   // #2: nil = unknown, not zero
    var addedSugars: Double? = nil
    var vitaminD:    Double? = nil
    var servingSize: String  = "100g"   // #4: real sizes, not always 100g

    func toFacts() -> NutritionFacts {
        NutritionFacts(
            servingSize:  servingSize,
            calories:     calories,
            totalFat:     fat,
            saturatedFat: saturatedFat,
            transFat:     transFat ?? 0,
            cholesterol:  cholesterol,
            sodium:       sodium,
            totalCarbs:   carbs,
            dietaryFiber: fiber,
            totalSugars:  sugar,
            addedSugars:  addedSugars ?? 0,
            protein:      protein,
            vitaminD:     vitaminD ?? 0,
            calcium:      calcium,
            iron:         iron,
            potassium:    potassium
        )
    }
}

// MARK: - Nutrition Database
nonisolated struct NutritionDatabase {

    // #1: Synchronous lookup — static DB first, then normalised name fallback
    static func facts(for name: String) -> NutritionFacts? {
        let key = name.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .folding(options: .diacriticInsensitive, locale: .current)   // #6 borrowed here too
        if let val = richDb[key]                               { return val.toFacts() }
        if let match = richDb.first(where: { $0.key.contains(key) || key.contains($0.key) }) {
            return match.value.toFacts()
        }
        return nil
    }

    // #1: Async — static DB first, then live USDA FoodData Central automatically
    @MainActor
    static func factsAsync(for name: String) async -> NutritionFacts? {
        if let static_ = facts(for: name) { return static_ }          // instant cache hit
        return await USDANutritionClient.shared.facts(for: name)       // live USDA fallback
    }

    // #3: Allergen check — returns matching allergen names for a given item
    static func allergens(for name: String, userAllergens: [String]) -> [String] {
        let key = name.lowercased()
        var result: [String] = []
        for (ingredient, tags) in allergenMap {
            guard key.contains(ingredient) || ingredient.contains(key) else { continue }
            let matched = tags.filter { tag in userAllergens.contains { $0.lowercased() == tag.lowercased() } }
            result.append(contentsOf: matched)
        }
        return result
    }

    static func allNames() -> [String] { richDb.keys.sorted() }

    // MARK: - Allergen map (ingredient → allergen tags) #3
    private static let allergenMap: [String: [String]] = [
        "milk": ["Dairy"], "cheese": ["Dairy"], "butter": ["Dairy"], "cream": ["Dairy"],
        "yogurt": ["Dairy"], "whey": ["Dairy"], "casein": ["Dairy"],
        "egg": ["Eggs"], "eggs": ["Eggs"],
        "wheat": ["Gluten","Wheat"], "bread": ["Gluten","Wheat"], "flour": ["Gluten","Wheat"],
        "pasta": ["Gluten","Wheat"], "soy sauce": ["Gluten","Soy"],
        "peanut": ["Peanuts"], "peanut butter": ["Peanuts"],
        "almond": ["Tree Nuts"], "cashew": ["Tree Nuts"], "walnut": ["Tree Nuts"],
        "pecan": ["Tree Nuts"], "pistachio": ["Tree Nuts"], "hazelnut": ["Tree Nuts"],
        "shrimp": ["Shellfish"], "crab": ["Shellfish"], "lobster": ["Shellfish"],
        "clams": ["Shellfish"], "oyster": ["Shellfish"], "scallop": ["Shellfish"],
        "salmon": ["Fish"], "tuna": ["Fish"], "cod": ["Fish"], "tilapia": ["Fish"],
        "halibut": ["Fish"], "anchovy": ["Fish"],
        "soy": ["Soy"], "tofu": ["Soy"], "edamame": ["Soy"], "tempeh": ["Soy"],
        "sesame": ["Sesame"], "tahini": ["Sesame"],
        "sulfite": ["Sulfites"], "wine": ["Sulfites"],
    ]

    // MARK: - Static database #4 (real serving sizes)
    private static let richDb: [String: RichNutrition] = [
        // ── Proteins ─────────────────────────────────────────────────────
        "chicken breast": RichNutrition(calories:165,protein:31,carbs:0,fat:3.6,fiber:0,sugar:0,sodium:74,potassium:256,calcium:15,iron:1.0,vitaminC:0,saturatedFat:1.0,cholesterol:85,transFat:0,vitaminD:0.1,servingSize:"4 oz (113g)"),
        "chicken thigh":  RichNutrition(calories:209,protein:26,carbs:0,fat:11,fiber:0,sugar:0,sodium:88,potassium:220,calcium:12,iron:1.3,vitaminC:0,saturatedFat:3.0,cholesterol:95,servingSize:"4 oz (113g)"),
        "ground beef":    RichNutrition(calories:254,protein:26,carbs:0,fat:17,fiber:0,sugar:0,sodium:75,potassium:338,calcium:18,iron:2.7,vitaminC:0,saturatedFat:6.5,cholesterol:88,transFat:0.7,servingSize:"4 oz (113g)"),
        "salmon":         RichNutrition(calories:208,protein:20,carbs:0,fat:13,fiber:0,sugar:0,sodium:59,potassium:363,calcium:13,iron:0.8,vitaminC:3.9,saturatedFat:3.1,cholesterol:63,vitaminD:11.1,servingSize:"4 oz (113g)"),
        "tuna":           RichNutrition(calories:132,protein:28,carbs:0,fat:1.0,fiber:0,sugar:0,sodium:50,potassium:441,calcium:10,iron:1.3,vitaminC:0,saturatedFat:0.3,cholesterol:49,vitaminD:4.0,servingSize:"4 oz (113g)"),
        "shrimp":         RichNutrition(calories:99,protein:24,carbs:0.2,fat:0.3,fiber:0,sugar:0,sodium:111,potassium:259,calcium:70,iron:2.4,vitaminC:2.3,saturatedFat:0.1,cholesterol:189,servingSize:"3 oz (85g)"),
        "eggs":           RichNutrition(calories:155,protein:13,carbs:1.1,fat:11,fiber:0,sugar:1.1,sodium:124,potassium:126,calcium:56,iron:1.8,vitaminC:0,saturatedFat:3.3,cholesterol:373,vitaminD:1.1,servingSize:"2 large eggs (100g)"),
        "tofu":           RichNutrition(calories:76,protein:8,carbs:1.9,fat:4.8,fiber:0.3,sugar:0.7,sodium:7,potassium:121,calcium:350,iron:5.4,vitaminC:0.1,saturatedFat:0.7,cholesterol:0,servingSize:"3 oz (85g)"),
        "turkey":         RichNutrition(calories:189,protein:29,carbs:0,fat:7.4,fiber:0,sugar:0,sodium:68,potassium:298,calcium:21,iron:1.4,vitaminC:0,saturatedFat:2.3,cholesterol:89,servingSize:"4 oz (113g)"),
        "pork chop":      RichNutrition(calories:231,protein:26,carbs:0,fat:13,fiber:0,sugar:0,sodium:60,potassium:388,calcium:20,iron:0.9,vitaminC:0.4,saturatedFat:4.6,cholesterol:80,servingSize:"4 oz (113g)"),
        "bacon":          RichNutrition(calories:541,protein:37,carbs:1.4,fat:42,fiber:0,sugar:0,sodium:1717,potassium:565,calcium:10,iron:1.3,vitaminC:0,saturatedFat:14,cholesterol:110,servingSize:"2 slices (16g)"),
        // ── Dairy ─────────────────────────────────────────────────────────
        "milk":        RichNutrition(calories:61,protein:3.2,carbs:4.8,fat:3.3,fiber:0,sugar:5.1,sodium:43,potassium:150,calcium:113,iron:0.0,vitaminC:0.9,saturatedFat:2.1,cholesterol:10,vitaminD:1.0,servingSize:"1 cup (240ml)"),
        "whole milk":  RichNutrition(calories:149,protein:8,carbs:12,fat:8,fiber:0,sugar:12,sodium:105,potassium:322,calcium:276,iron:0.1,vitaminC:0,saturatedFat:4.6,cholesterol:24,vitaminD:3.2,servingSize:"1 cup (240ml)"),
        "2% milk":     RichNutrition(calories:122,protein:8,carbs:12,fat:4.8,fiber:0,sugar:12,sodium:115,potassium:342,calcium:285,iron:0.1,vitaminC:0,saturatedFat:3.1,cholesterol:20,vitaminD:2.9,servingSize:"1 cup (240ml)"),
        "butter":      RichNutrition(calories:717,protein:0.9,carbs:0.1,fat:81,fiber:0,sugar:0.1,sodium:11,potassium:24,calcium:24,iron:0.0,vitaminC:0,saturatedFat:51,cholesterol:215,transFat:3.0,servingSize:"1 tbsp (14g)"),
        "cheddar":     RichNutrition(calories:403,protein:25,carbs:1.3,fat:33,fiber:0,sugar:0.5,sodium:621,potassium:98,calcium:721,iron:0.7,vitaminC:0,saturatedFat:21,cholesterol:105,vitaminD:0.6,servingSize:"1 oz (28g)"),
        "mozzarella":  RichNutrition(calories:280,protein:28,carbs:2.2,fat:17,fiber:0,sugar:1.0,sodium:627,potassium:76,calcium:505,iron:0.4,vitaminC:0,saturatedFat:11,cholesterol:54,servingSize:"1 oz (28g)"),
        "greek yogurt":RichNutrition(calories:97,protein:9,carbs:3.6,fat:5,fiber:0,sugar:3.2,sodium:36,potassium:141,calcium:110,iron:0.1,vitaminC:0,saturatedFat:3.3,cholesterol:17,servingSize:"6 oz (170g)"),
        "yogurt":      RichNutrition(calories:61,protein:3.5,carbs:4.7,fat:3.3,fiber:0,sugar:4.7,sodium:46,potassium:155,calcium:121,iron:0.1,vitaminC:0.6,saturatedFat:2.1,cholesterol:13,servingSize:"6 oz (170g)"),
        "cream cheese":RichNutrition(calories:342,protein:6,carbs:4.1,fat:34,fiber:0,sugar:3.2,sodium:321,potassium:138,calcium:97,iron:0.5,vitaminC:0,saturatedFat:19,cholesterol:110,servingSize:"2 tbsp (29g)"),
        "heavy cream": RichNutrition(calories:340,protein:2.1,carbs:2.8,fat:36,fiber:0,sugar:2.8,sodium:38,potassium:95,calcium:72,iron:0.1,vitaminC:0.5,saturatedFat:23,cholesterol:134,servingSize:"2 tbsp (30ml)"),
        // ── Produce ───────────────────────────────────────────────────────
        "apple":       RichNutrition(calories:52,protein:0.3,carbs:14,fat:0.2,fiber:2.4,sugar:10,sodium:1,potassium:107,calcium:6,iron:0.1,vitaminC:4.6,saturatedFat:0,cholesterol:0,servingSize:"1 medium (182g)"),
        "banana":      RichNutrition(calories:89,protein:1.1,carbs:23,fat:0.3,fiber:2.6,sugar:12,sodium:1,potassium:358,calcium:5,iron:0.3,vitaminC:8.7,saturatedFat:0.1,cholesterol:0,servingSize:"1 medium (118g)"),
        "avocado":     RichNutrition(calories:160,protein:2,carbs:9,fat:15,fiber:6.7,sugar:0.7,sodium:7,potassium:485,calcium:12,iron:0.6,vitaminC:10,saturatedFat:2.1,cholesterol:0,servingSize:"½ avocado (68g)"),
        "spinach":     RichNutrition(calories:23,protein:2.9,carbs:3.6,fat:0.4,fiber:2.2,sugar:0.4,sodium:79,potassium:558,calcium:99,iron:2.7,vitaminC:28,saturatedFat:0.1,cholesterol:0,vitaminD:0,servingSize:"1 cup (30g)"),
        "broccoli":    RichNutrition(calories:34,protein:2.8,carbs:7,fat:0.4,fiber:2.6,sugar:1.7,sodium:33,potassium:316,calcium:47,iron:0.7,vitaminC:89,saturatedFat:0.1,cholesterol:0,vitaminD:0,servingSize:"1 cup (91g)"),
        "carrot":      RichNutrition(calories:41,protein:0.9,carbs:10,fat:0.2,fiber:2.8,sugar:4.7,sodium:69,potassium:320,calcium:33,iron:0.3,vitaminC:5.9,saturatedFat:0,cholesterol:0,servingSize:"1 medium (61g)"),
        "tomato":      RichNutrition(calories:18,protein:0.9,carbs:3.9,fat:0.2,fiber:1.2,sugar:2.6,sodium:5,potassium:237,calcium:10,iron:0.3,vitaminC:13,saturatedFat:0,cholesterol:0,servingSize:"1 medium (123g)"),
        "potato":      RichNutrition(calories:77,protein:2,carbs:17,fat:0.1,fiber:2.2,sugar:0.8,sodium:6,potassium:421,calcium:12,iron:0.8,vitaminC:19,saturatedFat:0,cholesterol:0,servingSize:"1 medium (148g)"),
        "sweet potato":RichNutrition(calories:86,protein:1.6,carbs:20,fat:0.1,fiber:3,sugar:4.2,sodium:55,potassium:337,calcium:30,iron:0.6,vitaminC:2.4,saturatedFat:0,cholesterol:0,vitaminD:0,servingSize:"1 medium (130g)"),
        "onion":       RichNutrition(calories:40,protein:1.1,carbs:9.3,fat:0.1,fiber:1.7,sugar:4.2,sodium:4,potassium:146,calcium:23,iron:0.2,vitaminC:7.4,saturatedFat:0,cholesterol:0,servingSize:"½ cup (80g)"),
        "garlic":      RichNutrition(calories:149,protein:6.4,carbs:33,fat:0.5,fiber:2.1,sugar:1,sodium:17,potassium:401,calcium:181,iron:1.7,vitaminC:31,saturatedFat:0.1,cholesterol:0,servingSize:"3 cloves (9g)"),
        "lemon":       RichNutrition(calories:29,protein:1.1,carbs:9.3,fat:0.3,fiber:2.8,sugar:2.5,sodium:2,potassium:138,calcium:26,iron:0.6,vitaminC:53,saturatedFat:0,cholesterol:0,servingSize:"1 medium (58g)"),
        "orange":      RichNutrition(calories:47,protein:0.9,carbs:12,fat:0.1,fiber:2.4,sugar:9.4,sodium:0,potassium:181,calcium:40,iron:0.1,vitaminC:53,saturatedFat:0,cholesterol:0,servingSize:"1 medium (131g)"),
        "mushroom":    RichNutrition(calories:22,protein:3.1,carbs:3.3,fat:0.3,fiber:1.0,sugar:2.0,sodium:5,potassium:318,calcium:3,iron:0.5,vitaminC:2.1,saturatedFat:0,cholesterol:0,vitaminD:0.2,servingSize:"1 cup (70g)"),
        "bell pepper": RichNutrition(calories:31,protein:1.0,carbs:6,fat:0.3,fiber:2.1,sugar:4.2,sodium:4,potassium:211,calcium:7,iron:0.4,vitaminC:128,saturatedFat:0,cholesterol:0,servingSize:"1 medium (119g)"),
        "cucumber":    RichNutrition(calories:15,protein:0.7,carbs:3.6,fat:0.1,fiber:0.5,sugar:1.7,sodium:2,potassium:147,calcium:16,iron:0.3,vitaminC:2.8,saturatedFat:0,cholesterol:0,servingSize:"½ cup (52g)"),
        "celery":      RichNutrition(calories:16,protein:0.7,carbs:3,fat:0.2,fiber:1.6,sugar:1.3,sodium:80,potassium:260,calcium:40,iron:0.2,vitaminC:3.1,saturatedFat:0,cholesterol:0,servingSize:"1 stalk (40g)"),
        "kale":        RichNutrition(calories:49,protein:4.3,carbs:9,fat:0.9,fiber:3.6,sugar:2.3,sodium:38,potassium:491,calcium:150,iron:1.5,vitaminC:120,saturatedFat:0.1,cholesterol:0,vitaminD:0,servingSize:"1 cup (67g)"),
        "zucchini":    RichNutrition(calories:17,protein:1.2,carbs:3.1,fat:0.3,fiber:1,sugar:2.5,sodium:8,potassium:261,calcium:16,iron:0.4,vitaminC:17,saturatedFat:0.1,cholesterol:0,servingSize:"1 medium (196g)"),
        // ── Grains & Pantry ───────────────────────────────────────────────
        "rice":        RichNutrition(calories:365,protein:7.1,carbs:80,fat:0.7,fiber:1.3,sugar:0,sodium:5,potassium:115,calcium:28,iron:4.3,vitaminC:0,saturatedFat:0.2,cholesterol:0,servingSize:"¼ cup dry (45g)"),
        "brown rice":  RichNutrition(calories:370,protein:7.9,carbs:77,fat:2.9,fiber:3.5,sugar:0,sodium:7,potassium:268,calcium:23,iron:2.2,vitaminC:0,saturatedFat:0.6,cholesterol:0,servingSize:"¼ cup dry (45g)"),
        "pasta":       RichNutrition(calories:371,protein:13,carbs:74,fat:1.5,fiber:3.2,sugar:0.6,sodium:6,potassium:215,calcium:21,iron:3.3,vitaminC:0,saturatedFat:0.3,cholesterol:0,servingSize:"2 oz dry (56g)"),
        "bread":       RichNutrition(calories:265,protein:9,carbs:49,fat:3.2,fiber:2.7,sugar:5,sodium:491,potassium:115,calcium:107,iron:3.6,vitaminC:0,saturatedFat:0.7,cholesterol:0,servingSize:"1 slice (30g)"),
        "oats":        RichNutrition(calories:389,protein:17,carbs:66,fat:7,fiber:10.6,sugar:1,sodium:2,potassium:429,calcium:54,iron:4.7,vitaminC:0,saturatedFat:1.2,cholesterol:0,servingSize:"½ cup dry (40g)"),
        "flour":       RichNutrition(calories:364,protein:10,carbs:76,fat:1,fiber:2.7,sugar:0.3,sodium:2,potassium:107,calcium:15,iron:4.6,vitaminC:0,saturatedFat:0.2,cholesterol:0,servingSize:"¼ cup (30g)"),
        "quinoa":      RichNutrition(calories:368,protein:14,carbs:64,fat:6.1,fiber:7,sugar:0,sodium:5,potassium:563,calcium:47,iron:4.6,vitaminC:0,saturatedFat:0.7,cholesterol:0,servingSize:"¼ cup dry (43g)"),
        // ── Pantry / Canned ───────────────────────────────────────────────
        "olive oil":        RichNutrition(calories:884,protein:0,carbs:0,fat:100,fiber:0,sugar:0,sodium:2,potassium:1,calcium:1,iron:0.6,vitaminC:0,saturatedFat:14,cholesterol:0,servingSize:"1 tbsp (14g)"),
        "canned tomatoes":  RichNutrition(calories:32,protein:1.5,carbs:7,fat:0.2,fiber:1.8,sugar:4.7,sodium:270,potassium:292,calcium:31,iron:1.3,vitaminC:22,saturatedFat:0,cholesterol:0,servingSize:"½ cup (121g)"),
        "black beans":      RichNutrition(calories:132,protein:8.9,carbs:24,fat:0.5,fiber:8.7,sugar:0.3,sodium:1,potassium:355,calcium:46,iron:3.6,vitaminC:0,saturatedFat:0.1,cholesterol:0,servingSize:"½ cup cooked (86g)"),
        "chickpeas":        RichNutrition(calories:364,protein:19,carbs:61,fat:6,fiber:17,sugar:11,sodium:24,potassium:875,calcium:105,iron:6.2,vitaminC:4,saturatedFat:0.6,cholesterol:0,servingSize:"½ cup cooked (82g)"),
        "lentils":          RichNutrition(calories:353,protein:25,carbs:60,fat:1.1,fiber:30,sugar:2.1,sodium:6,potassium:677,calcium:56,iron:6.5,vitaminC:4.4,saturatedFat:0.2,cholesterol:0,servingSize:"¼ cup dry (48g)"),
        "peanut butter":    RichNutrition(calories:588,protein:25,carbs:20,fat:50,fiber:6,sugar:9,sodium:459,potassium:558,calcium:49,iron:1.9,vitaminC:0,saturatedFat:10,cholesterol:0,transFat:0,servingSize:"2 tbsp (32g)"),
        "honey":            RichNutrition(calories:304,protein:0.3,carbs:82,fat:0,fiber:0.2,sugar:82,sodium:4,potassium:52,calcium:6,iron:0.4,vitaminC:0.5,saturatedFat:0,cholesterol:0,addedSugars:82,servingSize:"1 tbsp (21g)"),
        "sugar":            RichNutrition(calories:387,protein:0,carbs:100,fat:0,fiber:0,sugar:100,sodium:1,potassium:2,calcium:1,iron:0.1,vitaminC:0,saturatedFat:0,cholesterol:0,addedSugars:100,servingSize:"1 tbsp (12g)"),
        "salt":             RichNutrition(calories:0,protein:0,carbs:0,fat:0,fiber:0,sugar:0,sodium:38758,potassium:8,calcium:24,iron:0.3,vitaminC:0,saturatedFat:0,cholesterol:0,servingSize:"1 tsp (6g)"),
        "soy sauce":        RichNutrition(calories:53,protein:8.1,carbs:4.9,fat:0.1,fiber:0.8,sugar:1.7,sodium:5493,potassium:435,calcium:18,iron:2.3,vitaminC:0,saturatedFat:0,cholesterol:0,servingSize:"1 tbsp (16g)"),
        "coconut oil":      RichNutrition(calories:862,protein:0,carbs:0,fat:100,fiber:0,sugar:0,sodium:0,potassium:0,calcium:0,iron:0,vitaminC:0,saturatedFat:87,cholesterol:0,servingSize:"1 tbsp (14g)"),
        "chicken broth":    RichNutrition(calories:15,protein:1.0,carbs:1.4,fat:0.5,fiber:0,sugar:0.5,sodium:924,potassium:210,calcium:14,iron:0.3,vitaminC:0,saturatedFat:0.1,cholesterol:1,servingSize:"1 cup (240ml)"),
        "vegetable broth":  RichNutrition(calories:15,protein:0.7,carbs:2.8,fat:0,fiber:0.3,sugar:1.5,sodium:940,potassium:150,calcium:20,iron:0.5,vitaminC:2,saturatedFat:0,cholesterol:0,servingSize:"1 cup (240ml)"),
        "tomato paste":     RichNutrition(calories:82,protein:4.3,carbs:19,fat:0.5,fiber:4.3,sugar:12,sodium:59,potassium:1014,calcium:36,iron:3.9,vitaminC:21,saturatedFat:0.1,cholesterol:0,servingSize:"2 tbsp (33g)"),
        "mayonnaise":       RichNutrition(calories:680,protein:1,carbs:0.6,fat:75,fiber:0,sugar:0.4,sodium:635,potassium:20,calcium:10,iron:0.3,vitaminC:0,saturatedFat:11,cholesterol:55,servingSize:"1 tbsp (14g)"),
        "ketchup":          RichNutrition(calories:101,protein:1.9,carbs:27,fat:0.1,fiber:0.3,sugar:22,sodium:907,potassium:281,calcium:26,iron:0.5,vitaminC:4.6,saturatedFat:0,cholesterol:0,addedSugars:20,servingSize:"1 tbsp (17g)"),
        "hot sauce":        RichNutrition(calories:31,protein:1.5,carbs:5.8,fat:0.9,fiber:1.5,sugar:3.5,sodium:2240,potassium:173,calcium:18,iron:0.7,vitaminC:19,saturatedFat:0.2,cholesterol:0,servingSize:"1 tsp (5g)"),
    ]
}

// MARK: - Cached recipe nutrition aggregation
actor RecipeNutritionSummaryCache {
    static let shared = RecipeNutritionSummaryCache()
    private var cache: [String: NutritionFacts] = [:]

    func totals(ingredients: [String], servings: Int) -> NutritionFacts {
        let key = ingredients.joined(separator: "|").lowercased() + "#" + String(max(1, servings))
        if let cached = cache[key] { return cached }
        var cal = 0; var prot = 0.0; var carb = 0.0; var fat = 0.0
        var fib = 0.0; var sug = 0.0; var sod = 0.0
        for raw in ingredients {
            let parts = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
            var found: NutritionFacts?
            for startIndex in parts.indices {
                let candidate = parts[startIndex...].joined(separator: " ")
                if let facts = NutritionDatabase.facts(for: candidate) { found = facts; break }
            }
            guard let facts = found else { continue }
            cal += facts.calories
            prot += facts.protein
            carb += facts.totalCarbs
            fat += facts.totalFat
            fib += facts.dietaryFiber
            sug += facts.totalSugars
            sod += facts.sodium
        }
        let divisor = Double(max(1, servings))
        let result = NutritionFacts(
            servingSize: "Per serving (est.)",
            calories: Int(Double(cal) / divisor),
            totalFat: fat / divisor, saturatedFat: 0, transFat: 0, cholesterol: 0,
            sodium: sod / divisor, totalCarbs: carb / divisor, dietaryFiber: fib / divisor,
            totalSugars: sug / divisor, addedSugars: 0, protein: prot / divisor,
            vitaminD: 0, calcium: 0, iron: 0, potassium: 0
        )
        cache[key] = result
        if cache.count > 100, let first = cache.keys.first { cache.removeValue(forKey: first) }
        return result
    }
}

// MARK: - Recipe Nutrition Summary (used by CookingFlow)
struct RecipeNutritionSummary: View {
    @Environment(AppSession.self) private var session
    @Environment(\.stockedMotion) private var motion
    let ingredients: [String]
    let servings:    Int
    @State private var expanded = false
    @State private var totals = NutritionFacts()
    private var cacheKey: String {
        ingredients.joined(separator: "|") + "#" + String(max(1, servings))
    }

    var body: some View {
        let t = totals
        guard t.calories > 0 else {
            return AnyView(
                Color.clear
                    .frame(height: 0)
                    .task(id: cacheKey) {
                        totals = await RecipeNutritionSummaryCache.shared.totals(
                            ingredients: ingredients, servings: servings)
                    }
            )
        }

        return AnyView(
            VStack(spacing: 0) {
                // Header row — always visible
                Button { motion.animate(.standard, intent: .spatial) { expanded.toggle() } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "chart.bar.fill")
                            .scaledFont(13).foregroundStyle(Color.stockedGold)
                        Text("Estimated Nutrition")
                            .scaledFont(13, weight: .semibold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        Spacer()
                        // Macro pill previews
                        HStack(spacing: 6) {
                            macroPill("\(t.calories)kcal",  Color.stockedGold)
                            macroPill("\(Int(t.protein))g P", Color.stockedGreen)
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .scaledFont(10).foregroundStyle(session.themeTextColor.opacity(0.4))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)

                if expanded {
                    Divider().padding(.horizontal, 14)
                    HStack(spacing: 0) {
                        macroCell("Calories", "\(t.calories)", "kcal", highlighted: true)
                        Divider().frame(height: 44)
                        macroCell("Protein",  String(format: "%.1f", t.protein),    "g")
                        Divider().frame(height: 44)
                        macroCell("Carbs",    String(format: "%.1f", t.totalCarbs), "g")
                        Divider().frame(height: 44)
                        macroCell("Fat",      String(format: "%.1f", t.totalFat),   "g")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)

                    Text("Estimates based on ~100g per ingredient · \(max(1, servings)) servings")
                        .scaledFont(9).foregroundStyle(session.themeTextColor.opacity(0.35))
                        .padding(.bottom, 8)
                }
            }
            .background(session.isDarkMode ? Color.white.opacity(0.08) : Color.stockedWhite.opacity(0.32))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .task(id: cacheKey) {
                totals = await RecipeNutritionSummaryCache.shared.totals(
                    ingredients: ingredients, servings: servings)
            }
        )
    }

    private func macroPill(_ label: String, _ color: Color) -> some View {
        Text(label)
            .scaledFont(10, weight: .bold)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
    }
    private func macroCell(_ label: String, _ value: String, _ unit: String, highlighted: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value + unit)
                .scaledFont(14, weight: .bold, design: .rounded)
                .foregroundStyle(highlighted ? Color.stockedGold : session.themeTextColor)
            Text(label).scaledFont(9, weight: .semibold)
                .foregroundStyle(session.themeTextColor.opacity(0.4))
        }.frame(maxWidth: .infinity).padding(.vertical, 4)
    }
}
