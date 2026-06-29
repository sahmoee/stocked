// Models.swift
import Foundation

// Normalizes brand tokens for display — e.g. any casing of "HEB" becomes "H-E-B".
// Matches whole words only (so it won't touch substrings inside other words).
private let _hebDisplayRegex: NSRegularExpression? = {
    // Compiled ONCE and reused. Previously this regex was rebuilt on EVERY call to
    // displayNormalized — and displayNormalized is called per row in Grocery, Inventory,
    // and the recipe lists. Each NSRegularExpression(pattern:) allocates ICU regex/pattern/
    // matcher/UnicodeSet objects; rebuilding it per render spawned hundreds of thousands of
    // persistent ICU allocations (the runaway memory that crashed those screens on iPad).
    try? NSRegularExpression(pattern: #"(?i)\bH[\-\s]?E[\-\s]?B\b"#)
}()

extension String {
    var displayNormalized: String {
        guard !isEmpty else { return self }
        // Fast path: only run the (now-cached) regex if the string could possibly contain
        // the token, so the common case allocates nothing at all.
        guard let re = _hebDisplayRegex,
              localizedCaseInsensitiveContains("h") else { return self }
        let range = NSRange(startIndex..., in: self)
        return re.stringByReplacingMatches(in: self, range: range, withTemplate: "H-E-B")
    }
}

enum AccountType: String, Codable { case registered; case guest }

// MARK: - Inventory Item
// MARK: - Storage Category
enum StorageCategory: String, Codable, CaseIterable {
    case fridge   = "Fridge"
    case freezer  = "Freezer"
    case pantry   = "Pantry"
    case staples  = "Staples"

    var displayName: String { rawValue }
    var icon: String {
        switch self {
        case .fridge:  return "❄️"
        case .freezer: return "🧊"
        case .pantry:  return "🏺"
        case .staples: return "🧂"
        }
    }
}

// MARK: - Inventory Item
nonisolated struct LocalInventoryItem: Identifiable, Codable, Sendable, Equatable {
    var id              = UUID()
    var name:           String = ""   // defaulted so a missing/null name can't fail decode (#5)

    // ── Structured quantity ───────────────────────────────────────
    var quantity:       Int    = 1           // how many containers
    var containerType:  String = "item"      // package, bag, box, can, bottle, jar, carton, case, item
    var sizeAmount:     Double?              // amount per container (e.g. 24)
    var sizeUnit:       String?              // unit per container (e.g. "cans", "oz", "g")

    // ── Legacy fill level (kept for backward-compat, used for low-stock calc) ──
    var level:          Double = 1.0

    // ── X-of-Y usage tracking ─────────────────────────────────────
    var quantityUsed:   Double?              // how much of current container has been used

    // ── Location ──────────────────────────────────────────────────
    var storageCategory: StorageCategory = .pantry
    var zone:            String { storageCategory.rawValue }  // convenience alias
    var subZone:         String?          // #8 e.g. "Door", "Top shelf", "Crisper"
    var customCategory:  String?          // #17 user-defined category beyond the 4 zones

    // ── Metadata ──────────────────────────────────────────────────
    var expirationDate:   Date?
    var brand:            String?
    var price:            Double?
    var purchaseDate:     Date?            // when this was bought (from receipt date)
    var addedBy:          String?          // household member who added it
    var storePurchasedAt: String?
    var nutrition:        NutritionFacts?
    var isLeftover:       Bool = false
    var leftoverMeal:     String?
    var hasStash:         Bool = false
    var imageData:        Data?          // photo of the actual product
    var parQuantity:       Int?          // #14 par level — keep at least N in stock; below → auto-reorder

    // ── Display ───────────────────────────────────────────────────
    var displayText: String {
        if let amt = sizeAmount, let unit = sizeUnit {
            return "\(quantity) \(containerType) (\(amt.clean) \(unit) each)"
        }
        return "\(quantity) \(containerType)"
    }

    // ── Computed helpers ──────────────────────────────────────────
    var daysUntilExpiry: Int? {
        guard let exp = expirationDate else { return nil }
        return LocalInventoryItem.cal.dateComponents([.day], from: Date(), to: exp).day
    }
    var isExpiringSoon: Bool { (daysUntilExpiry ?? 999) <= 3 }
    /// #3 — low relative to this item's own threshold (default 25%).
    /// #14 — below the user's par level ("keep at least N in stock"). Drives auto-reorder
    /// through the same low-stock → grocery pipeline as fill-level lows.
    var isBelowPar: Bool { parQuantity.map { quantity < $0 } ?? false }
    var isLow: Bool { (effectiveLevel > 0 && effectiveLevel < 0.25) || isBelowPar }
    var isExpired:      Bool { (daysUntilExpiry ?? 1) < 0 }
    var effectiveLevel: Double {
        // #13 perf: compute the day delta once instead of going through isExpired +
        // isExpiringSoon, each of which independently hit Calendar/dateComponents.
        guard let exp = expirationDate else { return level }
        let days = LocalInventoryItem.cal.dateComponents([.day], from: Date(), to: exp).day ?? 999
        if days < 0  { return 0 }
        if days <= 3 { return level * 0.5 }
        return level
    }
    // Shared calendar — `Calendar.current` rebuilds on each access, costly in row bodies.
    private static let cal = Calendar.current

    // ── Migration helper — build from old flat string ─────────────
    init(name: String, level: Double = 1.0, zone: String = "Pantry",
         quantity: Int = 1, containerType: String = "item",
         sizeAmount: Double? = nil, sizeUnit: String? = nil) {
        self.name          = name
        self.level         = level
        self.quantity      = quantity
        self.containerType = containerType
        self.sizeAmount    = sizeAmount
        self.sizeUnit      = sizeUnit
        self.storageCategory = StorageCategory(rawValue: zone) ?? .pantry
    }
}

// MARK: - Nutrition Facts
nonisolated struct NutritionFacts: Codable, Equatable, Sendable {
    var servingSize:  String = ""
    var calories:     Int    = 0
    var totalFat:     Double = 0
    var saturatedFat: Double = 0
    var transFat:     Double = 0
    var cholesterol:  Double = 0
    var sodium:       Double = 0
    var totalCarbs:   Double = 0
    var dietaryFiber: Double = 0
    var totalSugars:  Double = 0
    var addedSugars:  Double = 0
    var protein:      Double = 0
    var vitaminD:     Double = 0
    var calcium:      Double = 0
    var iron:         Double = 0
    var potassium:    Double = 0
}

// MARK: - Recipe Ingredient
struct RecipeIngredient: Identifiable, Codable, Sendable {
    var id         = UUID()
    var name:      String
    var amount:    String
    var brand:     String?
    var nutrition: NutritionFacts?
    var isOptional: Bool = false
    var notes:     String?
    // #6 — structured amount, additive and decode-safe (old saved recipes lack these →
    // decode as nil). `amount` remains the human-readable display string and source of
    // truth for the UI; quantity/unit power scaling and grocery consolidation.
    var quantity:  Double? = nil   // numeric amount (nil = unspecified)
    var unit:      String? = nil   // canonical unit ("cup","tbsp","oz"…), nil = count/none
    var prep:      String? = nil   // prep note ("sliced","minced"), nil = none
}

// MARK: - User Recipe
nonisolated struct UserRecipe: Identifiable, Codable, Sendable {
    var id            = UUID()
    var title:        String
    var description:  String   = ""
    var cookTime:     String   = ""
    var prepTime:     String   = ""
    var servings:     Int      = 4
    var difficulty:   String   = "Medium"
    var cuisine:      String   = ""
    var tags:         [String] = []
    var ingredients:  [RecipeIngredient] = []
    var instructions: [String] = []
    var notes:        String   = ""
    var imageData:    Data?
    var imageURL:     String?
    var isFavorited:  Bool     = false
    var dateCreated:  Date     = Date()
    var cookCount:    Int      = 0          // how many times this recipe has been cooked
    var lastCooked:   Date?                 // date of most recent cook

    var ingredientNames: [String] { ingredients.map(\.name) }
    var estimatedCalories: Int? {
        let total = ingredients.compactMap { $0.nutrition?.calories }.reduce(0, +)
        return total == 0 ? nil : total / max(1, servings)
    }
}

// MARK: - Past Meal (with rating + plate photo)
nonisolated struct LocalPastMeal: Identifiable, Codable, Sendable {
    var id        = UUID()
    var title:    String
    var date:     String
    var recipeId: UUID?
    var rating:   Int    = 0         // 1–5 stars
    var thumbUp:  Bool   = true
    var platePhotoData: Data?        // optional photo taken at plating
    var notes:    String = ""
}

// MARK: - Grocery
nonisolated struct LocalGroceryItem: Identifiable, Codable, Sendable, Equatable {
    var quantity: Int = 1
    var id            = UUID()
    var name:         String = ""      // defaulted for decode safety (#5)
    var isChecked:    Bool   = false   // defaulted for decode safety (#5)
    var isRecommended: Bool   = false
    var recipeSource:  String = ""   // Recipe name this ingredient came from ("" = manual)
    var recipeId:      String = ""   // #9 — owning recipe's stable id ("" = manual/legacy); lets a rename relabel the group
    var addedByName:   String = ""   // Household: display name of the member who added this ("" = me/unknown)
}

// MARK: - User-added substitution entry
struct UserSubstitutionEntry: Identifiable, Codable, Sendable {
    var id          = UUID()
    var ingredient: String       // e.g. "oat milk"
    var substitute: String       // e.g. "almond milk"
    var notes:      String = ""
    var dateAdded:  Date   = Date()
}
struct OCRTranslation: Identifiable, Codable, Sendable {
    var id         = UUID()
    var rawText:   String    // e.g. "Org. Chkn Brst"
    var resolved:  String   // e.g. "Chicken Breast"
    var useCount:  Int = 1
}

// MARK: - User Cooking Profile (from onboarding quiz)
struct UserCookingProfile: Codable {
    var householdSize:    Int      = 2
    var cookingGoal:      String   = ""        // e.g. "Eat Healthier"
    var dietaryStyle:     String   = ""        // e.g. "Omnivore"
    var allergens:        [String] = []
    var cuisinePrefs:     [String] = []
    var skillLevel:       String   = "Home Cook"
    var weeklyMealCount:  Int      = 5
    var mealPrepDay:      String   = "Sunday"
    var budgetLevel:      String   = "Moderate"
    var cookingEquipment: [String] = []
    var avatarEmoji:      String   = "👨‍🍳"   // chef icon picked during onboarding
    var completedSetup:   Bool     = false
}

// MARK: - Price Record (tracks purchase price history per item)
struct PriceRecord: Identifiable, Codable, Sendable {
    var id        = UUID()
    var itemName: String
    var price:    Double
    var store:    String
    var date:     Date = Date()
    var formattedPrice: String { String(format: "$%.2f", price) }
}

// MARK: - Inventory constants
enum ContainerType {
    static let all = ["item","package","bag","box","can","bottle","jar","carton","case","bunch","dozen","loaf","roll","tube","tray"]
}
enum MeasurementUnit {
    static let all = ["oz","lb","g","kg","ml","L","fl oz","count","pieces","slices","cans","cups","tbsp","tsp"]
}

// MARK: - Clean decimal formatting
nonisolated extension Double {
    var clean: String {
        truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", self)
            : String(self)
    }
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

// MARK: - Legacy
nonisolated struct LocalRecipe: Identifiable, Codable, Sendable {
    var id          = UUID()
    var title:      String
    var cookTime:   String
    var ingredients: [String] = []
    var isFavorited: Bool = false
}

// MARK: - Generated Recipe (AI / Surprise Me)
struct GeneratedRecipe: Identifiable, Codable, Sendable {
    var id            = UUID()
    var title:        String
    var cookTime:     String
    var servings:     Int
    var difficulty:   String          // "Easy" | "Medium" | "Hard"
    var ingredients:  [RecipeIngredientLine]
    var steps:        [String]
    var tips:               String
    var mealCategory:       String   = ""
    var missingIngredients: [String] = []
    var isFavorited:        Bool = false
    var isHidden:           Bool = false
    var imageURL:           String?
    var imageData:          Data?
    var source:             RecipeSource = .generated

    enum RecipeSource: String, Codable { case generated, manual, surprise }
}

struct RecipeIngredientLine: Identifiable, Codable, Sendable {
    var id      = UUID()
    var amount:  String
    var name:    String
    var inStock: Bool = true

    nonisolated init(amount: String, name: String, inStock: Bool = true) {
        self.id      = UUID()
        self.amount  = amount
        self.name    = name
        self.inStock = inStock
    }
}

// MARK: - Planned Meal (persisted via GuestDataStore)
// Close-the-loop #1 — one record each time an item is fully used up, so we can
// learn how fast a given item depletes and predict the next run-out.
struct ConsumptionRecord: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var itemName: String        // normalized lowercase name
    var purchasedAt: Date?      // when it was last added (if known)
    var depletedAt: Date        // when it hit empty
    var wasted: Bool = false    // #19 — removed past expiry (thrown out) rather than used up
    var estimatedValue: Double? = nil   // #19 — item's known price at removal, for $ wasted
    /// Days the item lasted, if we know when it was bought.
    var daysLasted: Double? {
        guard let p = purchasedAt else { return nil }
        let s = depletedAt.timeIntervalSince(p) / 86400.0
        return s > 0 ? s : nil
    }
}

struct PlannedMeal: Identifiable, Codable, Sendable, Equatable {
    var id        = UUID()
    var dayIndex: Int          // 0 = today, 1 = tomorrow …
    var title:    String
    var servings: Int
    var ingredients: [String]
    var mealType: String       // "Breakfast" | "Lunch" | "Dinner"
    var isCooked: Bool = false
    var isBuilding: Bool = false   // true while accumulating dragged inventory items
}
