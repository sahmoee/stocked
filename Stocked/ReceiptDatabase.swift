// ReceiptDatabase.swift
// On-device receipt learning database.
// Every item scanned from a receipt is remembered:
//   - Name normalisation (removes weights, codes, abbreviations)
//   - Zone learning (remembers where user placed items before)
//   - Frequency tracking (most-scanned items get priority in suggestions)
//   - Receipt history (full scans stored for reference)
// All data stored in Documents/StockedDB/receipts.json — never expires automatically.
import Foundation

// MARK: - Learned Item
struct LearnedReceiptItem: Codable {
    var rawName:       String         // original text from receipt
    var resolvedName:  String         // cleaned, human-readable name
    var zone:          String         // last assigned zone
    var scanCount:     Int    = 1     // how many times this item has been scanned
    var lastSeen:      Date   = Date()
    var userConfirmed: Bool   = false // true if user has manually confirmed/edited
}

// MARK: - Receipt Record
struct ReceiptRecord: Codable, Identifiable {
    var id         = UUID()
    var date       = Date()
    var storeName: String   = ""
    var rawText:   String
    var items:     [LearnedReceiptItem]
    var totalItems: Int { items.count }
}

// MARK: - ReceiptDatabase
// #9 — MainActor-isolated to match the app's other view-facing stores. All call sites are
// in @MainActor view code, so this removes any cross-actor access risk without changing them.
@MainActor
final class ReceiptDatabase {
    static let shared = ReceiptDatabase()
    private init() { load() }

    private let db     = LocalDatabase.shared
    private let key    = "receipt_database"
    private let histKey = "receipt_history"

    // In-memory cache
    private(set) var learnedItems:  [String: LearnedReceiptItem] = [:]  // keyed by normalized name
    private(set) var receiptHistory: [ReceiptRecord]             = []

    // MARK: - Load
    private func load() {
        if let items = db.load([LearnedReceiptItem].self, key: key) {
            learnedItems = Dictionary(uniqueKeysWithValues: items.map { ($0.resolvedName.lowercased(), $0) })
        }
        receiptHistory = db.load([ReceiptRecord].self, key: histKey) ?? []
    }

    // MARK: - Learn from a scan
    func learn(rawText: String, items: [LearnedReceiptItem], storeName: String = "") {
        // Store full receipt record
        let record = ReceiptRecord(storeName: storeName, rawText: rawText, items: items)
        receiptHistory.append(record)
        // Keep last 50 receipts
        if receiptHistory.count > 50 { receiptHistory = Array(receiptHistory.suffix(50)) }

        // Update learned items
        for item in items {
            let key = item.resolvedName.lowercased()
            if var existing = learnedItems[key] {
                existing.scanCount  += 1
                existing.lastSeen   = Date()
                existing.zone       = item.zone   // update zone from latest
                learnedItems[key]   = existing
            } else {
                learnedItems[key] = item
            }
        }
        save()
    }

    // MARK: - User confirms/edits an item
    func confirm(resolvedName: String, correctedName: String, zone: String) {
        let key = resolvedName.lowercased()
        var item = learnedItems[key] ?? LearnedReceiptItem(rawName: resolvedName, resolvedName: resolvedName, zone: zone)
        item.resolvedName  = correctedName
        item.zone          = zone
        item.userConfirmed = true
        item.scanCount    += 1
        learnedItems[correctedName.lowercased()] = item
        if key != correctedName.lowercased() { learnedItems.removeValue(forKey: key) }
        save()
    }

    // MARK: - Lookup: best zone for an item name
    func bestZone(for name: String) -> String {
        let key = name.lowercased()
        if let learned = learnedItems[key] { return learned.zone }
        // Fuzzy match — find closest learned item
        for (k, item) in learnedItems where k.contains(key) || key.contains(k) {
            return item.zone
        }
        return guessZone(for: name)
    }

    // MARK: - Top items (for suggestions)
    func topItems(limit: Int = 20) -> [LearnedReceiptItem] {
        Array(learnedItems.values
            .sorted { $0.scanCount > $1.scanCount }
            .prefix(limit))
    }

    // MARK: - Normalize raw receipt text to clean item name
    func normalize(_ raw: String) -> String {
        var s = raw.uppercased()

        // Remove common receipt noise
        let noisePatterns = [
            "#[0-9]+",                    // item codes
            "[0-9]+\\.[0-9]+",           // prices
            "\\$[0-9\\.]+",              // dollar amounts
            "\\b[0-9]+(OZ|LB|KG|G|CT|PK|PCS|EA|BG|BTL|GAL|QT|PT|FL OZ)\\b",  // weights/counts
            "\\b(ORGANIC|NATURAL|FRESH|FROZEN|PREMIUM|BRAND|STORE)\\b",
            "\\b(WAS|SALE|TAX|TAXABLE|TOTAL|SUBTOTAL|CHANGE|CASH|CARD|DEBIT|CREDIT)\\b",
        ]
        for pattern in noisePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            }
        }

        // Common abbreviations → full words
        let abbrevs: [(String, String)] = [
            ("CHKN", "Chicken"), ("BRST", "Breast"), ("GND", "Ground"),
            ("ORG", "Organic"), ("WHL", "Whole"), ("MLK", "Milk"),
            ("CHZ", "Cheese"), ("YGT", "Yogurt"), ("BTR", "Butter"),
            ("VEG", "Vegetable"), ("GRPS", "Grapes"), ("BNNS", "Bananas"),
            // ── H-E-B store brands & common HEB receipt shorthand (Texas) ──
            ("HCF", "Hill Country Fare"),       // HEB value store brand
            ("CRMY CRTNS", "Creamy Creations"), // HEB ice cream brand
            ("MEAL SIMPLE", "Meal Simple"),     // HEB prepared-meal line
            ("MLSMPL", "Meal Simple"),
            ("CNTRL MKT", "Central Market"),    // HEB premium brand
            ("TX ORG", "Texas Organic"),
            ("SHURFINE", "Shurfine"),
            ("FRTS", "Fruits"), ("VEGTBL", "Vegetable"), ("TOMATO", "Tomato"),
            ("AVOCDO", "Avocado"), ("TORTLLA", "Tortilla"), ("TORT", "Tortilla"),
        ]
        for (abbr, full) in abbrevs {
            s = s.replacingOccurrences(of: abbr, with: full)
        }

        // Clean up whitespace and capitalize properly
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Title case
        return cleaned.split(separator: " ")
            .map { word -> String in
                let w = String(word)
                return w.prefix(1).uppercased() + w.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    // MARK: - Heuristic zone guesser
    func guessZone(for name: String) -> String {
        let lower = name.lowercased()

        // ── FREEZER ──────────────────────────────────────────────────
        let freezerWords  = ["frozen","ice cream","gelato","sorbet","popsicle","ice cube","frost",
                             "ice pop","frozen pizza","frozen meal","frozen veg","frozen fruit",
                             "tv dinner","freezer","waffle fries","tater tot","ice","frozen yogurt"]
        if freezerWords.contains(where: { lower.contains($0) }) { return "Freezer" }

        // ── FRIDGE ───────────────────────────────────────────────────
        // Brand-name refrigerated drinks first (these would otherwise be caught by the
        // generic "tea"/"juice" pantry rules below — e.g. Arizona tea belongs in the fridge).
        let fridgeBrands  = ["arizona","snapple","gold peak","pure leaf","brisk","lipton tea",
                             "tropicana","simply orange","minute maid","naked juice","bolthouse",
                             "horizon","fairlife","silk","oatly","chobani","yakult","gt's","health-ade",
                             "vitaminwater","bodyarmor","red bull","monster","celsius","starbucks",
                             "la croix","spindrift","topo chico","perrier","san pellegrino","poppi","olipop"]
        if fridgeBrands.contains(where: { lower.contains($0) }) { return "Fridge" }

        // Refrigerated drink TYPES (bottled/canned teas, fresh juices, cold drinks)
        let fridgeDrinks  = ["iced tea","bottled tea","canned tea","sweet tea","green tea drink",
                             "orange juice","apple juice","fresh juice","cold-pressed","lemonade",
                             "smoothie","kombucha","cold brew","iced coffee","kefir","horchata",
                             "coconut water","energy drink","sports drink","probiotic drink",
                             "almond milk","oat milk","soy milk","rice milk","cashew milk","creamer"]
        if fridgeDrinks.contains(where: { lower.contains($0) }) { return "Fridge" }

        // Dairy, eggs, fresh meat/seafood, fresh produce, deli, refrigerated staples
        let fridgeWords   = ["milk","cheese","butter","yogurt","yoghurt","cream","egg","sour cream",
                             "cottage cheese","cream cheese","half and half","heavy cream","whipped",
                             "chicken","beef","pork","turkey","bacon","sausage","ham","steak","ground",
                             "fish","salmon","shrimp","tuna steak","cod","tilapia","crab","scallop",
                             "lettuce","spinach","kale","celery","carrot","cucumber","zucchini","squash",
                             "bell pepper","broccoli","cauliflower","tomato","strawberr","blueberr",
                             "raspberry","blackberr","grape","mushroom","tofu","tempeh","hummus","salsa",
                             "guacamole","deli","lunch meat","cold cut","hot dog","tortellini","gnocchi",
                             "fresh pasta","pico","dressing","refrigerated","pickle","kimchi","sauerkraut",
                             "beer","wine","cider","hard seltzer","sparkling water","mineral water",
                             "sparkling","seltzer","tonic","club soda","prosecco","champagne"]
        if fridgeWords.contains(where: { lower.contains($0) }) { return "Fridge" }

        // ── STAPLES — spices, oils, condiments, baking ───────────────
        let staplesWords  = ["salt","pepper","garlic powder","onion powder","cumin","oregano",
                             "paprika","cinnamon","turmeric","vanilla","baking soda","baking powder",
                             "yeast","spice","herb","seasoning","vinegar","mustard","ketchup",
                             "soy sauce","fish sauce","hot sauce","worcestershire","tahini","miso",
                             "olive oil","vegetable oil","coconut oil","canola oil","avocado oil",
                             "sesame oil","cooking spray","sugar","brown sugar","powdered sugar",
                             "honey","maple syrup","syrup","molasses","cornstarch","corn starch",
                             "bouillon","extract","food coloring","sprinkles","cocoa powder"]
        if staplesWords.contains(where: { lower.contains($0) }) { return "Staples" }

        // ── PANTRY — shelf-stable dry goods + drinks ─────────────────
        let pantryWords   = ["pasta","rice","bread","can","flour","cereal","oat","bean","lentil",
                             "broth","stock","jam","jelly","peanut butter","chip","cracker","cookie",
                             "soup","nut","seed","quinoa","couscous","tortilla","wrap","bagel","pita",
                             "noodle","ramen","granola","raisin","dried","trail mix","popcorn","pretzel",
                             "candy","chocolate bar","instant","mac and cheese","stuffing","crouton",
                             // shelf-stable drinks
                             "soda","cola","pepsi","sprite","7up","dr pepper","gatorade","powerade",
                             "coffee","tea","hot chocolate","cocoa","protein powder","drink mix",
                             "juice box","juice pouch","coconut milk","evaporated milk","condensed milk"]
        if pantryWords.contains(where: { lower.contains($0) }) { return "Pantry" }

        return "Pantry"
    }

    // MARK: - Clear history (manual only)
    func clearHistory() {
        receiptHistory = []
        db.delete(key: histKey)
    }

    func clearAll() {
        learnedItems   = [:]
        receiptHistory = []
        db.delete(key: key)
        db.delete(key: histKey)
    }

    // MARK: - Persist
    private func save() {
        db.save(Array(learnedItems.values), key: key)
        db.save(receiptHistory, key: histKey)
    }
}
