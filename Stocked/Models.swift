// Models.swift
import Foundation

// Normalizes brand tokens for display — e.g. any casing of "H-E-B" becomes "HEB".
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
        return re.stringByReplacingMatches(in: self, range: range, withTemplate: "HEB")
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
nonisolated struct LocalInventoryItem: Identifiable, Codable, Sendable, Equatable, Hashable {
    // id-based hash so the UICollectionView diffable data source (CollectionGrid)
    // can track items; equality stays full-field (synthesized).
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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
    /// Winning source for resolved product fields. String keys keep the persisted model decoupled
    /// from review UI enums and allow future fields to round-trip without another schema rewrite.
    var fieldProvenance:  [String: FieldProvenance]?

    // ── Staleness (drift-proofing #A3) ────────────────────────────
    // When the user last confirmed this item is really still in the kitchen — set by
    // Pantry Check nudges, level edits, and restocks. nil = never confirmed (legacy items
    // decode cleanly and fall back to purchaseDate for staleness math).
    var lastConfirmedAt:  Date?

    /// One shared confidence state for every hub. This is intentionally derived from
    /// persisted facts instead of stored separately, so a confirmation, scan, expiry,
    /// or quantity edit changes Recipes, Home, Inventory, and Cook at the same time.
    var confidence: InventoryConfidence {
        guard effectiveLevel > 0 else { return .outOfStock }
        if isExpired { return .possiblyExpired }
        let anchor = lastConfirmedAt ?? purchaseDate
        guard let anchor else { return sourceBadge == nil ? .unknown : .probable }
        let age = Date().timeIntervalSince(anchor)
        if age <= 7 * 86_400 { return .confirmed }
        if age <= 30 * 86_400 { return .probable }
        return .unknown
    }

    /// Shared canonical product identity for inventory deduplication, receipts, substitutions,
    /// and store routing. It is derived so legacy rows gain identity without a storage migration.
    var productIdentity: ProductIdentity {
        ProductCatalog.identity(for: name, brand: brand, barcode: barcode)
    }

    func confidenceAssessment(at now: Date = Date()) -> InventoryConfidenceAssessment {
        let state: InventoryConfidence
        var reasons: [String] = []
        if effectiveLevel <= 0 {
            state = .outOfStock
            reasons.append("Quantity or effective level is empty")
        } else if let expirationDate, expirationDate < now {
            state = .possiblyExpired
            reasons.append("Expiration date has passed")
        } else if let anchor = lastConfirmedAt ?? purchaseDate {
            let age = max(0, now.timeIntervalSince(anchor))
            if age <= 7 * 86_400 {
                state = .confirmed
                reasons.append("Confirmed within the last 7 days")
            } else if age <= 30 * 86_400 {
                state = .probable
                reasons.append("Observed within the last 30 days")
            } else {
                state = .unknown
                reasons.append("Has not been confirmed recently")
            }
        } else if sourceBadge != nil {
            state = .probable
            reasons.append("Has source provenance but no confirmation date")
        } else {
            state = .unknown
            reasons.append("No confirmation or source provenance")
        }
        if let sourceBadge { reasons.append("Source: \(sourceBadge.rawValue)") }
        if barcode != nil { reasons.append("Barcode identity available") }
        let sourceFactor = sourceBadge?.confidence ?? 0.55
        let score = min(1, state.recommendationWeight * 0.75 + sourceFactor * 0.25)
        return InventoryConfidenceAssessment(state: state, score: score, reasons: reasons,
                                             shouldReview: state.requiresReview || sourceBadge == .needsReview)
    }

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
        return LocalInventoryItem.cal.dateComponents(
            [.day],
            from: LocalInventoryItem.cal.startOfDay(for: Date()),
            to: LocalInventoryItem.cal.startOfDay(for: exp)
        ).day
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

    private enum CodingKeys: String, CodingKey {
        case id, name, updatedAt, lastWriterID, quantity, containerType, sizeAmount, sizeUnit,
             level, quantityUsed, storageCategory, subZone, customCategory, expirationDate,
             brand, price, purchaseDate, addedBy, storePurchasedAt, nutrition, barcode,
             productLabels, productIngredients, nutritionSource, isLeftover, leftoverMeal,
             hasStash, imageData, parQuantity, sourceBadge, fieldProvenance, lastConfirmedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        lastWriterID = try c.decodeIfPresent(String.self, forKey: .lastWriterID) ?? ""
        quantity = try c.decodeIfPresent(Int.self, forKey: .quantity) ?? 1
        containerType = try c.decodeIfPresent(String.self, forKey: .containerType) ?? "item"
        sizeAmount = try c.decodeIfPresent(Double.self, forKey: .sizeAmount)
        sizeUnit = try c.decodeIfPresent(String.self, forKey: .sizeUnit)
        level = try c.decodeIfPresent(Double.self, forKey: .level) ?? 1
        quantityUsed = try c.decodeIfPresent(Double.self, forKey: .quantityUsed)
        storageCategory = try c.decodeIfPresent(StorageCategory.self, forKey: .storageCategory) ?? .pantry
        subZone = try c.decodeIfPresent(String.self, forKey: .subZone)
        customCategory = try c.decodeIfPresent(String.self, forKey: .customCategory)
        expirationDate = try c.decodeIfPresent(Date.self, forKey: .expirationDate)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        price = try c.decodeIfPresent(Double.self, forKey: .price)
        purchaseDate = try c.decodeIfPresent(Date.self, forKey: .purchaseDate)
        addedBy = try c.decodeIfPresent(String.self, forKey: .addedBy)
        storePurchasedAt = try c.decodeIfPresent(String.self, forKey: .storePurchasedAt)
        nutrition = try c.decodeIfPresent(NutritionFacts.self, forKey: .nutrition)
        barcode = try c.decodeIfPresent(String.self, forKey: .barcode)
        productLabels = try c.decodeIfPresent([String].self, forKey: .productLabels)
        productIngredients = try c.decodeIfPresent(String.self, forKey: .productIngredients)
        nutritionSource = try c.decodeIfPresent(String.self, forKey: .nutritionSource)
        isLeftover = try c.decodeIfPresent(Bool.self, forKey: .isLeftover) ?? false
        leftoverMeal = try c.decodeIfPresent(String.self, forKey: .leftoverMeal)
        hasStash = try c.decodeIfPresent(Bool.self, forKey: .hasStash) ?? false
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
        parQuantity = try c.decodeIfPresent(Int.self, forKey: .parQuantity)
        sourceBadge = try c.decodeIfPresent(SourceBadge.self, forKey: .sourceBadge)
        fieldProvenance = try c.decodeIfPresent([String: FieldProvenance].self, forKey: .fieldProvenance)
        lastConfirmedAt = try c.decodeIfPresent(Date.self, forKey: .lastConfirmedAt)
    }
}

/// Trustworthiness of an inventory claim, shared by recommendation and stock surfaces.
nonisolated enum InventoryConfidence: String, Codable, Sendable, CaseIterable {
    case confirmed
    case probable
    case unknown
    case possiblyExpired
    case outOfStock

    var displayName: String {
        switch self {
        case .confirmed: return "Confirmed on hand"
        case .probable: return "Probably on hand"
        case .unknown: return "Needs confirmation"
        case .possiblyExpired: return "Possibly expired"
        case .outOfStock: return "Out of stock"
        }
    }

    var recommendationWeight: Double {
        switch self {
        case .confirmed: return 1
        case .probable: return 0.8
        case .unknown: return 0.45
        case .possiblyExpired, .outOfStock: return 0
        }
    }

    var requiresReview: Bool {
        switch self {
        case .confirmed, .probable: return false
        case .unknown, .possiblyExpired, .outOfStock: return true
        }
    }
}

nonisolated struct InventoryConfidenceAssessment: Equatable, Sendable {
    var state: InventoryConfidence
    var score: Double
    var reasons: [String]
    var shouldReview: Bool
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
    /// Original publisher metadata supplied by Stocked's recipe manager. Optional so
    /// recipes written by every older app version remain decode-compatible.
    var sourceURL:    String?   = nil
    var sourceName:   String?   = nil
    var categories:   [String]? = nil
    var isFavorited:  Bool     = false
    var dateCreated:  Date     = Date()
    var cookCount:    Int      = 0          // how many times this recipe has been cooked
    var lastCooked:   Date?                 // date of most recent cook
    var updatedAt:    Double   = 0          // last-modified ms since epoch, for household last-write-wins
    var lastWriterID: String   = ""         // deterministic tie-breaker when timestamps tie
    var dishRole:     DishRole = .unspecified  // classification for prep discovery; legacy recipes decode as .unspecified

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

    init(quantity: Int = 1, id: UUID = UUID(), name: String = "", isChecked: Bool = false,
         isRecommended: Bool = false, recipeSource: String = "", recipeId: String = "",
         addedByName: String = "", assignedTo: String = "", sizeText: String = "",
         updatedAt: Double = 0, lastWriterID: String = "") {
        self.quantity = quantity; self.id = id; self.name = name; self.isChecked = isChecked
        self.isRecommended = isRecommended; self.recipeSource = recipeSource; self.recipeId = recipeId
        self.addedByName = addedByName; self.assignedTo = assignedTo; self.sizeText = sizeText
        self.updatedAt = updatedAt; self.lastWriterID = lastWriterID
    }

    private enum CodingKeys: String, CodingKey {
        case quantity, id, name, isChecked, isRecommended, recipeSource, recipeId,
             addedByName, assignedTo, sizeText, updatedAt, lastWriterID
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quantity = try c.decodeIfPresent(Int.self, forKey: .quantity) ?? 1
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isChecked = try c.decodeIfPresent(Bool.self, forKey: .isChecked) ?? false
        isRecommended = try c.decodeIfPresent(Bool.self, forKey: .isRecommended) ?? false
        recipeSource = try c.decodeIfPresent(String.self, forKey: .recipeSource) ?? ""
        recipeId = try c.decodeIfPresent(String.self, forKey: .recipeId) ?? ""
        addedByName = try c.decodeIfPresent(String.self, forKey: .addedByName) ?? ""
        assignedTo = try c.decodeIfPresent(String.self, forKey: .assignedTo) ?? ""
        sizeText = try c.decodeIfPresent(String.self, forKey: .sizeText) ?? ""
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        lastWriterID = try c.decodeIfPresent(String.self, forKey: .lastWriterID) ?? ""
    }
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
    /// Shared brand ranking payload consumed by product resolution and substitutions. Defaults
    /// neutral so older profiles and existing UI behavior remain unchanged.
    var brandPreferences: BrandPreferences = BrandPreferences()
    var avatarEmoji:      String   = "👨‍🍳"   // chef icon picked during onboarding
    // Optional user-supplied profile photo (JPEG data). When present it takes precedence over
    // avatarEmoji wherever the chef avatar is shown. Optional with a nil default so existing
    // saved profiles (which never encoded this key) decode cleanly.
    var avatarPhotoData:  Data?    = nil
    var completedSetup:   Bool     = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case householdSize, cookingGoal, dietaryStyle, allergens, cuisinePrefs, skillLevel,
             weeklyMealCount, mealPrepDay, budgetLevel, cookingEquipment, avatarEmoji,
             brandPreferences, avatarPhotoData, completedSetup
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        householdSize = try c.decodeIfPresent(Int.self, forKey: .householdSize) ?? 2
        cookingGoal = try c.decodeIfPresent(String.self, forKey: .cookingGoal) ?? ""
        dietaryStyle = try c.decodeIfPresent(String.self, forKey: .dietaryStyle) ?? ""
        allergens = try c.decodeIfPresent([String].self, forKey: .allergens) ?? []
        cuisinePrefs = try c.decodeIfPresent([String].self, forKey: .cuisinePrefs) ?? []
        skillLevel = try c.decodeIfPresent(String.self, forKey: .skillLevel) ?? "Home Cook"
        weeklyMealCount = try c.decodeIfPresent(Int.self, forKey: .weeklyMealCount) ?? 5
        mealPrepDay = try c.decodeIfPresent(String.self, forKey: .mealPrepDay) ?? "Sunday"
        budgetLevel = try c.decodeIfPresent(String.self, forKey: .budgetLevel) ?? "Moderate"
        cookingEquipment = try c.decodeIfPresent([String].self, forKey: .cookingEquipment) ?? []
        brandPreferences = try c.decodeIfPresent(BrandPreferences.self, forKey: .brandPreferences)
            ?? BrandPreferences()
        avatarEmoji = try c.decodeIfPresent(String.self, forKey: .avatarEmoji) ?? "👨‍🍳"
        avatarPhotoData = try c.decodeIfPresent(Data.self, forKey: .avatarPhotoData)
        completedSetup = try c.decodeIfPresent(Bool.self, forKey: .completedSetup) ?? false
    }
}

// MARK: - Price Record (tracks purchase price history per item)
nonisolated struct PriceRecord: Identifiable, Codable, Sendable, Equatable {
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
    var cuisine:            String   = ""
    var missingIngredients: [String] = []
    var isFavorited:        Bool = false
    var isHidden:           Bool = false
    var imageURL:           String?
    var imageData:          Data?
    var source:             RecipeSource = .generated
    var updatedAt:          Double = 0    // last-modified ms since epoch, for household last-write-wins
    var lastWriterID:       String = ""  // deterministic tie-breaker when timestamps tie

    init(id: UUID = UUID(), title: String, cookTime: String, servings: Int, difficulty: String,
         ingredients: [RecipeIngredientLine], steps: [String], tips: String,
         mealCategory: String = "", cuisine: String = "", missingIngredients: [String] = [],
         isFavorited: Bool = false, isHidden: Bool = false, imageURL: String? = nil,
         imageData: Data? = nil, source: RecipeSource = .generated, updatedAt: Double = 0,
         lastWriterID: String = "") {
        self.id = id; self.title = title; self.cookTime = cookTime; self.servings = servings
        self.difficulty = difficulty; self.ingredients = ingredients; self.steps = steps; self.tips = tips
        self.mealCategory = mealCategory; self.cuisine = cuisine; self.missingIngredients = missingIngredients
        self.isFavorited = isFavorited; self.isHidden = isHidden; self.imageURL = imageURL
        self.imageData = imageData; self.source = source; self.updatedAt = updatedAt
        self.lastWriterID = lastWriterID
    }

    nonisolated enum RecipeSource: String, Codable, Sendable { case generated, manual, surprise }

    private enum CodingKeys: String, CodingKey {
        case id, title, cookTime, servings, difficulty, ingredients, steps, tips, mealCategory,
             cuisine, missingIngredients, isFavorited, isHidden, imageURL, imageData, source,
             updatedAt, lastWriterID
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Recipe"
        cookTime = try c.decodeIfPresent(String.self, forKey: .cookTime) ?? ""
        servings = try c.decodeIfPresent(Int.self, forKey: .servings) ?? 4
        difficulty = try c.decodeIfPresent(String.self, forKey: .difficulty) ?? "Medium"
        ingredients = try c.decodeIfPresent([RecipeIngredientLine].self, forKey: .ingredients) ?? []
        steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
        tips = try c.decodeIfPresent(String.self, forKey: .tips) ?? ""
        mealCategory = try c.decodeIfPresent(String.self, forKey: .mealCategory) ?? ""
        cuisine = try c.decodeIfPresent(String.self, forKey: .cuisine) ?? ""
        missingIngredients = try c.decodeIfPresent([String].self, forKey: .missingIngredients) ?? []
        isFavorited = try c.decodeIfPresent(Bool.self, forKey: .isFavorited) ?? false
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
        source = try c.decodeIfPresent(RecipeSource.self, forKey: .source) ?? .generated
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        lastWriterID = try c.decodeIfPresent(String.self, forKey: .lastWriterID) ?? ""
    }
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
