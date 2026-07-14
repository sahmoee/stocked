// KitchenStock.swift — "Kitchen Goals" stock-% model.
//
// The user defines what "stocked" means to *them* by picking the staples they like to
// keep on hand (the bubble questionnaire in StockGoalsSetupView). Stock % is then a
// meaningful ratio — staples-in-stock / staples-they-track — instead of an arbitrary
// average fill level. Low categories feed straight into the grocery list.
import Foundation

// MARK: - Staple categories + curated defaults
// 6–10 near-universal items per category, mined to be the common kitchen essentials.
// "+ Add your own" in setup lets people extend any list; custom items land in `.other`.
enum StapleCategory: String, CaseIterable, Identifiable {
    case dairy      = "Dairy & Eggs"
    case produce    = "Produce"
    case pantry     = "Pantry & Grains"
    case proteins   = "Proteins"
    case condiments = "Condiments & Oils"
    case beverages  = "Beverages"
    case frozen     = "Frozen"
    case other      = "Other"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dairy:      return "🥛"
        case .produce:    return "🥬"
        case .pantry:     return "🍚"
        case .proteins:   return "🍗"
        case .condiments: return "🧂"
        case .beverages:  return "☕️"
        case .frozen:     return "🧊"
        case .other:      return "🧺"
        }
    }

    /// Curated default staples shown as pre-selected bubbles.
    var defaults: [String] {
        switch self {
        case .dairy:      return ["Milk", "Eggs", "Butter", "Cheese", "Yogurt", "Sour Cream"]
        case .produce:    return ["Onions", "Garlic", "Potatoes", "Tomatoes", "Carrots", "Lettuce", "Spinach", "Bananas", "Apples", "Lemons"]
        case .pantry:     return ["Rice", "Pasta", "Bread", "Flour", "Sugar", "Cereal", "Oats", "Black Beans", "Canned Tomatoes", "Peanut Butter"]
        case .proteins:   return ["Chicken", "Ground Beef", "Bacon", "Sausage", "Canned Tuna"]
        case .condiments: return ["Salt", "Black Pepper", "Olive Oil", "Ketchup", "Mustard", "Mayonnaise", "Soy Sauce", "Hot Sauce", "Vinegar"]
        case .beverages:  return ["Coffee", "Tea", "Orange Juice", "Soda"]
        case .frozen:     return ["Frozen Vegetables", "Frozen Fruit", "Ice Cream", "Frozen Pizza"]
        case .other:      return []
        }
    }

    /// The categories shown in setup, in order (everything except `.other`).
    static var selectable: [StapleCategory] { allCases.filter { $0 != .other } }
}

// MARK: - Calc
enum KitchenStock {

    /// Reverse map: lowercased staple name → its default category. Custom items fall to `.other`.
    static let categoryOf: [String: StapleCategory] = {
        var map: [String: StapleCategory] = [:]
        for cat in StapleCategory.selectable {
            for item in cat.defaults { map[item.lowercased()] = cat }
        }
        return map
    }()

    static func category(of staple: String) -> StapleCategory {
        categoryOf[staple.lowercased()] ?? .other
    }

    /// A staple counts as in-stock if any in-stock inventory name contains it (or vice versa),
    /// so "Milk" matches "Whole Milk" and "Eggs" matches "Large Eggs". `inStock` is the set of
    /// lowercased names from GuestDataStore.inStockNameSet.
    static func isInStock(_ staple: String, inStock: Set<String>) -> Bool {
        let s = staple.lowercased()
        guard !s.isEmpty else { return false }
        return inStock.contains { $0.contains(s) || s.contains($0) }
    }

    /// 0–100. Empty staples → 0.
    static func percent(staples: [String], inStock: Set<String>) -> Int {
        guard !staples.isEmpty else { return 0 }
        let have = staples.filter { isInStock($0, inStock: inStock) }.count
        return Int((Double(have) / Double(staples.count) * 100).rounded())
    }

    /// Staples the user tracks but doesn't currently have — the natural shopping list.
    static func lowStaples(staples: [String], inStock: Set<String>) -> [String] {
        staples.filter { !isInStock($0, inStock: inStock) }
    }

    struct CategoryStatus: Identifiable {
        let category: StapleCategory
        let have: Int
        let total: Int
        var id: String { category.rawValue }
        var percent: Int { total == 0 ? 0 : Int((Double(have) / Double(total) * 100).rounded()) }
    }

    /// Per-category breakdown (only categories the user actually selected staples in), ordered.
    static func byCategory(staples: [String], inStock: Set<String>) -> [CategoryStatus] {
        var grouped: [StapleCategory: [String]] = [:]
        for s in staples { grouped[category(of: s), default: []].append(s) }
        return StapleCategory.allCases.compactMap { cat in
            guard let items = grouped[cat], !items.isEmpty else { return nil }
            let have = items.filter { isInStock($0, inStock: inStock) }.count
            return CategoryStatus(category: cat, have: have, total: items.count)
        }
    }
}
