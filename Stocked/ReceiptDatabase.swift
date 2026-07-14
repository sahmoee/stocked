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
nonisolated struct LearnedReceiptItem: Codable, Sendable {
    var rawName:       String         // original text from receipt
    var resolvedName:  String         // cleaned, human-readable name
    var zone:          String         // last assigned zone
    var scanCount:     Int    = 1     // how many times this item has been scanned
    var lastSeen:      Date   = Date()
    var userConfirmed: Bool   = false // true if user has manually confirmed/edited
}

// MARK: - Receipt Record
nonisolated struct ReceiptRecord: Codable, Identifiable, Sendable {
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
        let key = FoodNameMatcher.normalized(name)
        if let learned = learnedItems[key] { return learned.zone }
        if let learned = FoodNameMatcher.bestMatch(for: name,
                                                   in: Array(learnedItems.values),
                                                   name: \.resolvedName,
                                                   minimumScore: 0.8) {
            return learned.zone
        }
        return ZoneClassifier.classify(name).rawValue
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
        ZoneClassifier.classify(name).rawValue
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
