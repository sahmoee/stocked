// Models.swift
import Foundation

// Normalizes brand tokens for display — e.g. any casing of "HEB" becomes "H-E-B".
// Matches whole words only (so it won't touch substrings inside other words).
nonisolated private let _hebDisplayRegex: NSRegularExpression? = {
    // Compiled ONCE and reused. Previously this regex was rebuilt on EVERY call to
    // displayNormalized — and displayNormalized is called per row in Grocery, Inventory,
    // and the recipe lists. Each NSRegularExpression(pattern:) allocates ICU regex/pattern/
    // matcher/UnicodeSet objects; rebuilding it per render spawned hundreds of thousands of
    // persistent ICU allocations (the runaway memory that crashed those screens on iPad).
    try? NSRegularExpression(pattern: #"(?i)\bH[\-\s]?E[\-\s]?B\b"#)
}()

nonisolated extension String {
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

nonisolated enum AccountType: String, Codable, Sendable { case registered; case guest }

// MARK: - Inventory Item
// MARK: - Storage Category
nonisolated enum StorageCategory: String, Codable, CaseIterable, Sendable {
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

    // ── Sync ──────────────────────────────────────────────────────
    // Last-modified timestamp (ms since epoch) for household last-write-wins merging. Defaulted
    // to 0 so legacy items decode; any real edit stamps it via touch(). Older data with 0 always
    // loses to a real edit, which is the safe direction.
    var updatedAt:      Double = 0
    var lastWriterID:   String = ""   // deterministic tie-breaker for equal LWW timestamps

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
    var barcode:          String?
    var productLabels:    [String]?
    var productIngredients: String?
    var nutritionSource:  String?
    var isLeftover:       Bool = false
    var leftoverMeal:     String?
    var hasStash:         Bool = false
    var imageData:        Data?          // photo of the actual product
    var parQuantity:       Int?          // #14 par level — keep at least N in stock; below → auto-reorder

    // ── Provenance ────────────────────────────────────────────────
    // How this item got into inventory and how much to trust it (nil = legacy/unknown, treated
    // as user-added). Set by the receipt scanner (AI parsed / needs review), the AI Inventory
    // Assistant, and manual add (user added). Lets any surface show a SourceBadge without
    // re-deriving provenance. Optional + defaulted so existing saved items decode cleanly.
    var sourceBadge:      SourceBadge?

    // ── Staleness (drift-proofing #A3) ────────────────────────────
    // When the user last confirmed this item is really still in the kitchen — set by
    // Pantry Check nudges, level edits, and restocks. nil = never confirmed (legacy items
    // decode cleanly and fall back to purchaseDate for staleness math).
    var lastConfirmedAt:  Date?

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
    /// Canonical "expiring soon" test. Routes through the single shared threshold
    /// (KitchenThresholds.expiringSoonDays) so Home, Inventory, Cook, and the Daily Brief
    /// all agree. Expired items are NOT "expiring soon" (they are already expired); callers
    /// that want both should use `isExpiringSoonOrExpired`.
    func isExpiringSoon(within days: Int = KitchenThresholds.expiringSoonDays) -> Bool {
        guard let d = daysUntilExpiry else { return false }
        return d >= 0 && d <= days
    }
    /// Back-compat computed accessor (many call sites use the property form).
    var isExpiringSoon: Bool { isExpiringSoon() }
    /// "Needs attention" = expiring within the window OR already expired. This is the
    /// definition the Home and Inventory "expiring" lists use, centralized here so the
    /// `<= N days || isExpired` pattern is not re-spelled at each call site.
    var isExpiringSoonOrExpired: Bool { isExpired || isExpiringSoon() }
    /// #3 — low relative to this item's own threshold (default 25%).
    /// #14 — below the user's par level ("keep at least N in stock"). Drives auto-reorder
    /// through the same low-stock → grocery pipeline as fill-level lows.
    var isBelowPar: Bool { parQuantity.map { quantity < $0 } ?? false }
    var isLow: Bool { (effectiveLevel > 0 && effectiveLevel < KitchenThresholds.lowFillLevel) || isBelowPar }
    var isExpired:      Bool { (daysUntilExpiry ?? 1) < 0 }
    var effectiveLevel: Double {
        // #13 perf: compute the day delta once instead of going through isExpired +
        // isExpiringSoon, each of which independently hit Calendar/dateComponents.
        guard let exp = expirationDate else { return level }
        let days = LocalInventoryItem.cal.dateComponents([.day], from: Date(), to: exp).day ?? 999
        if days < 0  { return 0 }
        if days <= KitchenThresholds.expiringSoonDays { return level * 0.5 }
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
nonisolated struct RecipeIngredient: Identifiable, Codable, Sendable, Equatable {
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
nonisolated struct UserRecipe: Identifiable, Codable, Sendable, Equatable {
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
    var updatedAt:    Double   = 0          // last-modified ms since epoch, for household last-write-wins
    var lastWriterID: String   = ""         // deterministic tie-breaker when timestamps tie

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
    var assignedTo:    String = ""   // #E2 household: member asked to buy this ("" = unassigned)
    var sizeText:      String = ""   // measured size for display, e.g. "14 oz" ("" = none)
    var updatedAt:     Double = 0    // last-modified ms since epoch, for household last-write-wins
    var lastWriterID:  String = ""   // deterministic tie-breaker when timestamps tie
}

// MARK: - User-added substitution entry
nonisolated struct UserSubstitutionEntry: Identifiable, Codable, Sendable {
    var id          = UUID()
    var ingredient: String       // e.g. "oat milk"
    var substitute: String       // e.g. "almond milk"
    var notes:      String = ""
    var dateAdded:  Date   = Date()
}
nonisolated struct OCRTranslation: Identifiable, Codable, Sendable {
    var id         = UUID()
    var rawText:   String    // e.g. "Org. Chkn Brst"
    var resolved:  String   // e.g. "Chicken Breast"
    var useCount:  Int = 1
}

// MARK: - User Cooking Profile (from onboarding quiz)
nonisolated struct UserCookingProfile: Codable, Sendable {
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
    // Optional user-supplied profile photo (JPEG data). When present it takes precedence over
    // avatarEmoji wherever the chef avatar is shown. Optional with a nil default so existing
    // saved profiles (which never encoded this key) decode cleanly.
    var avatarPhotoData:  Data?    = nil
    var completedSetup:   Bool     = false
}

// MARK: - Price Record (tracks purchase price history per item)
nonisolated struct PriceRecord: Identifiable, Codable, Sendable {
    var id        = UUID()
    var itemName: String
    var price:    Double
    var store:    String
    var date:     Date = Date()
    var formattedPrice: String { String(format: "$%.2f", price) }
}

// MARK: - Inventory constants
nonisolated enum ContainerType {
    static let all = ["item","package","bag","box","can","bottle","jar","carton","case","bunch","dozen","loaf","roll","tube","tray"]
}
nonisolated enum MeasurementUnit {
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
nonisolated struct GeneratedRecipe: Identifiable, Codable, Sendable, Equatable {
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
    var updatedAt:          Double = 0    // last-modified ms since epoch, for household last-write-wins
    var lastWriterID:       String = ""  // deterministic tie-breaker when timestamps tie

    nonisolated enum RecipeSource: String, Codable, Sendable { case generated, manual, surprise }
}

nonisolated struct RecipeIngredientLine: Identifiable, Codable, Sendable, Equatable {
    var id      = UUID()
    var amount:  String
    var name:    String
    var inStock: Bool = true

    /// #12 Cook-from-what-I-have ranking helper lives on the store; this scales a recipe's
    /// ingredient amount string by a factor for the #10 serving-size scaler. Parses a leading
    /// number (incl. simple fractions like 1/2) and multiplies it, leaving the unit text intact.
    static func scaledAmount(_ amount: String, by factor: Double) -> String {
        let trimmed = amount.trimmingCharacters(in: .whitespaces)
        guard factor > 0, !trimmed.isEmpty else { return amount }
        // Grab the leading numeric token (supports "1", "1.5", "1/2", "3 1/2").
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        func parseNumber(_ s: String) -> Double? {
            if s.contains("/") {
                let f = s.split(separator: "/")
                if f.count == 2, let n = Double(f[0]), let d = Double(f[1]), d != 0 { return n / d }
                return nil
            }
            return Double(s)
        }
        // Mixed number "3 1/2"
        if parts.count == 2, let whole = Double(parts[0]), let frac = parseNumber(parts[1]) {
            let scaled = (whole + frac) * factor
            let rest = "" // consumed both tokens
            return trimNumber(scaled) + rest
        }
        if let first = parts.first, let n = parseNumber(first) {
            let scaled = n * factor
            let rest = parts.count > 1 ? " " + parts[1] : ""
            return trimNumber(scaled) + rest
        }
        return amount   // no leading number → leave as-is
    }
    private static func trimNumber(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.2g", v)
    }

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
nonisolated struct ConsumptionRecord: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var itemName: String        // normalized lowercase name
    var purchasedAt: Date?      // when it was last added (if known)
    var depletedAt: Date        // when it hit empty
    var wasted: Bool = false    // #19 — removed past expiry (thrown out) rather than used up
    var estimatedValue: Double? = nil   // #19 — item's known price at removal, for $ wasted
    // #D3 waste post-mortem — why it went to waste ("too much" / "forgot" / "plans changed").
    // Optional + defaulted so the existing log decodes; set later from the Daily Brief ask.
    var wasteReason: String? = nil
    /// Days the item lasted, if we know when it was bought.
    var daysLasted: Double? {
        guard let p = purchasedAt else { return nil }
        let s = depletedAt.timeIntervalSince(p) / 86400.0
        return s > 0 ? s : nil
    }
}

nonisolated struct PlannedMeal: Identifiable, Codable, Sendable, Equatable {
    var id        = UUID()
    var dayIndex: Int          // 0 = today, 1 = tomorrow …
    var title:    String
    var servings: Int
    var ingredients: [String]
    var mealType: String       // "Breakfast" | "Lunch" | "Dinner"
    var isCooked: Bool = false
    var isBuilding: Bool = false   // true while accumulating dragged inventory items
    var updatedAt: Double = 0      // #13 last-modified ms, for household last-write-wins
    var lastWriterID: String = "" // deterministic tie-breaker when timestamps tie
    // Cook Now workspace (Direction B+): cook-ahead lifecycle. A meal cooked
    // early moves through these while STAYING on its planned day — cooking early
    // changes only the cook time, never the plan. Additive + decode-safe; old
    // saved meals decode as .none.
    var cookAheadStatus: CookAheadStatus = .none
}

/// The cook-ahead lifecycle for a planned meal. `.none` means a normal planned
/// meal (not cooked ahead). The rest track food cooked before its planned slot.
nonisolated enum CookAheadStatus: String, Codable, Sendable {
    case none          // normal planned meal
    case prepped       // ingredients prepped ahead
    case marinating
    case cookingEarly  // actively cooking before the slot
    case cooked        // fully cooked, not yet stored
    case cooling
    case stored
    case readyToReheat
    case served

    var isCookedAhead: Bool { self != .none && self != .served }
    var label: String {
        switch self {
        case .none:          return "Planned"
        case .prepped:       return "Prepped ahead"
        case .marinating:    return "Marinating"
        case .cookingEarly:  return "Cooking early"
        case .cooked:        return "Cooked"
        case .cooling:       return "Cooling"
        case .stored:        return "Stored"
        case .readyToReheat: return "Ready to reheat"
        case .served:        return "Served"
        }
    }
    var icon: String {
        switch self {
        case .none:          return "calendar"
        case .prepped:       return "list.bullet.clipboard"
        case .marinating:    return "drop"
        case .cookingEarly:  return "flame"
        case .cooked:        return "checkmark.circle"
        case .cooling:       return "wind"
        case .stored:        return "refrigerator"
        case .readyToReheat: return "microwave"
        case .served:        return "fork.knife"
        }
    }
}
