// PackKnowledge.swift
// What happens to a pack once it's open. A tin of tomatoes keeps two years on the shelf and five
// days in the fridge once opened; the shelf date on the label stops meaning anything the moment
// the lid comes off. This table carries the "once opened" clock per food, whether the rest can
// be frozen, and the usual pack size, so opening an item or cooking with part of it re-dates it.

import Foundation

nonisolated struct PackFacts: Sendable, Equatable {
    /// Days it keeps in the fridge after opening.
    let openedDays: Int
    /// True when the opened remainder freezes well (tomato paste, broth, coconut milk).
    let freezesOpen: Bool
    /// Typical pack as sold, e.g. 14 oz for a tin of tomatoes.
    let packSize: Double?
    let packUnit: String?
}

nonisolated enum PackKnowledge {
    private struct Row {
        let phrases: [String]
        let facts: PackFacts
        init(_ phrases: [String], opened: Int, freezes: Bool, pack: Double? = nil, unit: String? = nil) {
            self.phrases = phrases
            self.facts = PackFacts(openedDays: opened, freezesOpen: freezes, packSize: pack, packUnit: unit)
        }
    }

    // Order matters: the first row with a matching phrase wins, so specific names sit above
    // the general ones ("tomato paste" before "tomato", "cream cheese" before "cheese").
    private static let rows: [Row] = [
        // Tins, jars and cartons
        Row(["tomato paste"], opened: 7, freezes: true, pack: 6, unit: "oz"),
        Row(["diced tomato", "crushed tomato", "canned tomato", "tinned tomato", "tomato sauce"], opened: 5, freezes: true, pack: 14.5, unit: "oz"),
        Row(["coconut milk", "coconut cream"], opened: 4, freezes: true, pack: 13.5, unit: "fl oz"),
        Row(["chicken broth", "beef broth", "vegetable broth", "stock", "broth"], opened: 5, freezes: true, pack: 32, unit: "fl oz"),
        Row(["pasta sauce", "marinara"], opened: 5, freezes: true, pack: 24, unit: "oz"),
        Row(["black beans", "chickpeas", "kidney beans", "pinto beans", "cannellini", "canned beans"], opened: 4, freezes: true, pack: 15, unit: "oz"),
        Row(["evaporated milk", "condensed milk"], opened: 5, freezes: false, pack: 12, unit: "fl oz"),
        Row(["pumpkin puree"], opened: 5, freezes: true, pack: 15, unit: "oz"),
        Row(["salsa"], opened: 10, freezes: false, pack: 16, unit: "oz"),
        Row(["pesto"], opened: 7, freezes: true, pack: 6, unit: "oz"),
        Row(["hummus"], opened: 7, freezes: false, pack: 10, unit: "oz"),
        Row(["wine"], opened: 4, freezes: true, pack: 750, unit: "ml"),
        // Dairy
        Row(["heavy cream", "whipping cream", "half and half"], opened: 7, freezes: false, pack: 16, unit: "fl oz"),
        Row(["sour cream", "creme fraiche"], opened: 10, freezes: false, pack: 16, unit: "oz"),
        Row(["cream cheese"], opened: 10, freezes: false, pack: 8, unit: "oz"),
        Row(["ricotta"], opened: 5, freezes: false, pack: 15, unit: "oz"),
        Row(["fresh mozzarella", "burrata"], opened: 4, freezes: false, pack: 8, unit: "oz"),
        Row(["shredded cheese", "grated cheese"], opened: 7, freezes: true, pack: 8, unit: "oz"),
        Row(["buttermilk"], opened: 14, freezes: true, pack: 32, unit: "fl oz"),
        Row(["milk"], opened: 7, freezes: true, pack: 1, unit: "gal"),
        Row(["yogurt", "yoghurt"], opened: 7, freezes: false, pack: 32, unit: "oz"),
        // Meat and protein
        Row(["bacon"], opened: 7, freezes: true, pack: 12, unit: "oz"),
        Row(["deli", "sliced turkey", "sliced ham", "salami", "prosciutto"], opened: 4, freezes: true, pack: 8, unit: "oz"),
        Row(["hot dog", "sausage"], opened: 5, freezes: true, pack: 16, unit: "oz"),
        Row(["tofu"], opened: 4, freezes: true, pack: 14, unit: "oz"),
        Row(["ground beef", "ground turkey", "ground pork", "ground chicken"], opened: 2, freezes: true, pack: 1, unit: "lb"),
        Row(["chicken breast", "chicken thigh", "chicken"], opened: 2, freezes: true, pack: 2, unit: "lb"),
        // Bakery and produce bought in bags
        Row(["tortilla"], opened: 7, freezes: true, pack: 10, unit: "count"),
        Row(["pizza dough"], opened: 3, freezes: true, pack: 1, unit: "lb"),
        Row(["bread", "bagel", "pita"], opened: 5, freezes: true),
        Row(["bagged salad", "salad mix", "spinach", "arugula", "spring mix"], opened: 3, freezes: false, pack: 5, unit: "oz"),
        Row(["cilantro", "parsley", "basil", "fresh herb"], opened: 5, freezes: true, pack: 1, unit: "bunch")
    ]

    static func facts(for name: String) -> PackFacts? {
        rows.first { FoodNameMatcher.anyPhrase(in: name, phrases: $0.phrases) }?.facts
    }

    /// Fraction of a pack a recipe line uses ("6 oz" of a 14.5 oz tin → 0.41).
    ///
    /// Weight and liquid volume share one ounce scale — close enough for a kitchen, and recipes
    /// mix them freely ("13.5 oz coconut milk"). "1 can" or "1 jar" means the whole pack.
    /// Returns nil when the units can't be compared, so callers keep their own estimate.
    static func fractionUsed(amount: Double, unit: String, packSize: Double?, packUnit: String?) -> Double? {
        guard amount > 0 else { return nil }
        let used = unit.lowercased().trimmingCharacters(in: .whitespaces)
        if ["can", "cans", "jar", "jars", "package", "packages", "pkg", "carton", "bunch", "bag"].contains(used) {
            return min(1, amount)
        }
        guard let packSize, packSize > 0, let packUnit,
              let usedScale = scale(of: used), let packScale = scale(of: packUnit),
              usedScale.family == packScale.family else { return nil }
        return min(1, (amount * usedScale.factor) / (packSize * packScale.factor))
    }

    static func fractionUsed(amount: Double, unit: String, of facts: PackFacts) -> Double? {
        fractionUsed(amount: amount, unit: unit, packSize: facts.packSize, packUnit: facts.packUnit)
    }

    private enum UnitFamily { case ounces, count }

    private static func scale(of unit: String) -> (family: UnitFamily, factor: Double)? {
        switch unit.lowercased().trimmingCharacters(in: .whitespaces) {
        case "oz", "ounce", "ounces", "fl oz", "floz", "fl", "fluid ounce", "fluid ounces": return (.ounces, 1)
        case "lb", "lbs", "pound", "pounds": return (.ounces, 16)
        case "g", "gram", "grams": return (.ounces, 1 / 28.35)
        case "kg", "kilogram", "kilograms": return (.ounces, 35.27)
        case "ml", "milliliter", "milliliters", "millilitre": return (.ounces, 1 / 29.57)
        case "l", "liter", "liters", "litre", "litres": return (.ounces, 33.81)
        case "cup", "cups": return (.ounces, 8)
        case "gal", "gallon", "gallons": return (.ounces, 128)
        case "", "count", "ct", "each", "whole", "item", "items": return (.count, 1)
        default: return nil
        }
    }
}

// MARK: - Opening an item

/// What `applyOpenedShelfLife` changed, so the caller can offer Undo or Freeze.
struct OpenedShelfLifeChange {
    let itemID: UUID
    let itemName: String
    let previousExpiry: Date?
    let newExpiry: Date?
    let openedAt: Date
    let markedOpened: Bool
    let facts: PackFacts?

    /// The item now runs out before it otherwise would, and the rest can be frozen.
    var suggestsFreezing: Bool {
        guard let facts, facts.freezesOpen, let newExpiry else { return false }
        return previousExpiry.map { newExpiry < $0 } ?? true
    }

    var message: String {
        guard let facts else { return "Marked \(itemName) opened" }
        let keeps = "\(itemName) keeps \(facts.openedDays) day\(facts.openedDays == 1 ? "" : "s") once opened"
        return suggestsFreezing ? keeps + " — freeze what you won't use" : keeps
    }
}

extension GuestDataStore {
    /// Record that an item was opened and bring its expiry forward to its opened shelf life.
    ///
    /// Never pushes an expiry later, and leaves frozen items alone (freezing stops the clock).
    /// Returns nil when nothing changed, or when the household doesn't allow inventory edits.
    @discardableResult
    func applyOpenedShelfLife(id: UUID, at date: Date = Date()) -> OpenedShelfLifeChange? {
        guard HouseholdSync.shared.authorize(.inventoryEdit),
              let index = inventoryIndex(of: id) else { return nil }
        let item = inventoryItems[index]
        guard item.quantity > 0, item.level > 0, !item.isLeftover else { return nil }

        let history = InventoryOpenedHistory.shared
        let alreadyOpened = history.openedDate(for: id)
        let openedAt = alreadyOpened ?? date
        let marked = alreadyOpened == nil
            && history.markOpened(id: id, at: date,
                                  activeIDs: Set(inventoryItems.filter { $0.quantity > 0 && $0.level > 0 }.map(\.id)))

        let facts = PackKnowledge.facts(for: item.name)
        var newExpiry = item.expirationDate
        if item.storageCategory != .freezer, let facts,
           let openedLimit = Calendar.current.date(byAdding: .day, value: facts.openedDays, to: openedAt),
           item.expirationDate.map({ openedLimit < $0 }) ?? true {
            newExpiry = openedLimit
            inventoryItems[index].expirationDate = openedLimit
            var provenance = inventoryItems[index].fieldProvenance ?? [:]
            provenance["expiry"] = FieldProvenance(sourceID: "opened-shelf-life",
                                                    sourceName: "Opened shelf life", badge: .estimated,
                                                    observedAt: date)
            inventoryItems[index].fieldProvenance = provenance
        }

        guard marked || newExpiry != item.expirationDate else { return nil }
        return OpenedShelfLifeChange(itemID: id, itemName: item.name.displayNormalized,
                                     previousExpiry: item.expirationDate, newExpiry: newExpiry,
                                     openedAt: openedAt, markedOpened: marked, facts: facts)
    }

    /// Reverse `applyOpenedShelfLife`. Leaves the item alone if its expiry was edited since.
    func undoOpenedShelfLife(_ change: OpenedShelfLifeChange) {
        if change.markedOpened {
            InventoryOpenedHistory.shared.undoOpened(id: change.itemID, expected: change.openedAt)
        }
        guard let index = inventoryIndex(of: change.itemID),
              inventoryItems[index].expirationDate == change.newExpiry,
              change.newExpiry != change.previousExpiry else { return }
        inventoryItems[index].expirationDate = change.previousExpiry
    }
}
