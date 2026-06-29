// CommonGroceryDB.swift
//
// A local list of common grocery/pantry items, so the app can recognize, suggest, and
// categorize everyday items without an API round-trip. This cuts network calls for the
// 90% case (milk, eggs, chicken, rice) and works fully offline.
//
// Pairs with IngredientMatcher: lookups are canonicalized first, so "ground beef",
// "beef mince", and "80/20 beef" all resolve to the same entry. Additive; nothing depends
// on it until callers opt in (e.g. grocery autocomplete, category inference).

import Foundation

/// One known common item and the aisle/category it belongs to.
struct CommonGroceryItem: Equatable {
    let name: String
    let category: StorageCategory
    /// Typical aisle label for grocery sorting (kept simple and store-agnostic).
    let aisle: String
}

enum CommonGroceryDB {

    /// The canonical common-items table. Names are already in canonical form
    /// (lowercase, singular-ish) so they line up with IngredientMatcher.canonical output.
    static let items: [CommonGroceryItem] = [
        // Produce
        .init(name: "banana",      category: .pantry,  aisle: "Produce"),
        .init(name: "apple",       category: .fridge,  aisle: "Produce"),
        .init(name: "onion",       category: .pantry,  aisle: "Produce"),
        .init(name: "garlic",      category: .pantry,  aisle: "Produce"),
        .init(name: "potato",      category: .pantry,  aisle: "Produce"),
        .init(name: "tomato",      category: .fridge,  aisle: "Produce"),
        .init(name: "lettuce",     category: .fridge,  aisle: "Produce"),
        .init(name: "carrot",      category: .fridge,  aisle: "Produce"),
        .init(name: "pepper",      category: .fridge,  aisle: "Produce"),
        .init(name: "spinach",     category: .fridge,  aisle: "Produce"),
        .init(name: "avocado",     category: .fridge,  aisle: "Produce"),
        .init(name: "lemon",       category: .fridge,  aisle: "Produce"),
        .init(name: "lime",        category: .fridge,  aisle: "Produce"),
        .init(name: "broccoli",    category: .fridge,  aisle: "Produce"),
        .init(name: "mushroom",    category: .fridge,  aisle: "Produce"),
        // Dairy & eggs
        .init(name: "milk",        category: .fridge,  aisle: "Dairy"),
        .init(name: "egg",         category: .fridge,  aisle: "Dairy"),
        .init(name: "butter",      category: .fridge,  aisle: "Dairy"),
        .init(name: "cheese",      category: .fridge,  aisle: "Dairy"),
        .init(name: "yogurt",      category: .fridge,  aisle: "Dairy"),
        .init(name: "cream",       category: .fridge,  aisle: "Dairy"),
        .init(name: "sour cream",  category: .fridge,  aisle: "Dairy"),
        // Meat & seafood
        .init(name: "chicken",     category: .fridge,  aisle: "Meat & Seafood"),
        .init(name: "beef",        category: .fridge,  aisle: "Meat & Seafood"),
        .init(name: "pork",        category: .fridge,  aisle: "Meat & Seafood"),
        .init(name: "bacon",       category: .fridge,  aisle: "Meat & Seafood"),
        .init(name: "shrimp",      category: .freezer, aisle: "Meat & Seafood"),
        .init(name: "salmon",      category: .fridge,  aisle: "Meat & Seafood"),
        .init(name: "turkey",      category: .fridge,  aisle: "Meat & Seafood"),
        // Pantry / dry goods
        .init(name: "rice",        category: .pantry,  aisle: "Pantry"),
        .init(name: "pasta",       category: .pantry,  aisle: "Pantry"),
        .init(name: "flour",       category: .pantry,  aisle: "Baking"),
        .init(name: "sugar",       category: .pantry,  aisle: "Baking"),
        .init(name: "salt",        category: .pantry,  aisle: "Spices"),
        .init(name: "black pepper", category: .pantry, aisle: "Spices"),
        .init(name: "olive oil",   category: .pantry,  aisle: "Pantry"),
        .init(name: "vegetable oil", category: .pantry, aisle: "Pantry"),
        .init(name: "canned tomatoes", category: .pantry, aisle: "Pantry"),
        .init(name: "broth",       category: .pantry,  aisle: "Pantry"),
        .init(name: "beans",       category: .pantry,  aisle: "Pantry"),
        .init(name: "cereal",      category: .pantry,  aisle: "Breakfast"),
        .init(name: "bread",       category: .pantry,  aisle: "Bakery"),
        .init(name: "peanut butter", category: .pantry, aisle: "Pantry"),
        .init(name: "honey",       category: .pantry,  aisle: "Pantry"),
        .init(name: "coffee",      category: .pantry,  aisle: "Beverages"),
        .init(name: "tea",         category: .pantry,  aisle: "Beverages"),
        // Frozen
        .init(name: "ice cream",   category: .freezer, aisle: "Frozen"),
        .init(name: "frozen vegetables", category: .freezer, aisle: "Frozen"),
        // Beverages
        .init(name: "water",       category: .pantry,  aisle: "Beverages"),
        .init(name: "juice",       category: .fridge,  aisle: "Beverages"),
        .init(name: "soda",        category: .pantry,  aisle: "Beverages"),
    ]

    /// Fast lookup by canonical name. Built once.
    private static let byCanonical: [String: CommonGroceryItem] = {
        var map: [String: CommonGroceryItem] = [:]
        for it in items { map[it.name] = it }
        return map
    }()

    /// Look up a raw item name. Canonicalizes first, so synonyms and prep words resolve.
    /// Returns nil if the item is not a known common item (caller can fall back to an API).
    static func lookup(_ rawName: String) -> CommonGroceryItem? {
        let canon = IngredientMatcher.canonical(rawName)
        if let hit = byCanonical[canon] { return hit }
        // Try the first word (e.g. "chicken breast" -> "chicken")
        if let first = canon.components(separatedBy: .whitespaces).first, first != canon {
            return byCanonical[first]
        }
        return nil
    }

    /// True if this is a recognized common item — a cheap offline check before any network call.
    static func isCommon(_ rawName: String) -> Bool { lookup(rawName) != nil }

    /// Best-guess storage category for a raw name, or nil if unknown.
    static func category(for rawName: String) -> StorageCategory? { lookup(rawName)?.category }

    /// Best-guess aisle for grocery sorting, or nil if unknown.
    static func aisle(for rawName: String) -> String? { lookup(rawName)?.aisle }
}
