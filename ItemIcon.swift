// ItemIcon.swift — resolves an inventory item to its bundled icon (from Icons.xcassets).
//
// Drop into the Stocked target after adding Icons.xcassets. Resolution order:
//   1. exact item slug            e.g. "Chicken Breast" -> "chicken_breast"
//   2. the item's category icon   e.g. category "protein" -> "protein"
//   3. "unknown" placeholder
//
// Usage:
//   ItemIcon(name: item.name, category: item.category)      // category is optional
//   ItemIcon(name: "Ribeye")
//   Image(IconResolver.assetName(for: "Olive Oil", category: "pantry"))  // if you want the raw name

import SwiftUI

enum IconResolver {

    /// Slugify exactly like the icon manifest (build_manifest.py):
    /// lowercase, "&" -> " and ", every run of non-alphanumerics -> "_", trimmed.
    static func slug(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: "&", with: " and ")
        let underscored = lowered.replacingOccurrences(
            of: "[^a-z0-9]+", with: "_", options: .regularExpression)
        return underscored.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /// Item category (as stored in items.csv) -> the category-icon asset slug.
    static let categoryIcon: [String: String] = [
        "protein": "protein", "produce": "produce", "fruit": "fruit", "dairy": "dairy",
        "frozen": "frozen", "pantry": "pantry", "beverage": "beverages", "baking": "baking",
        "condiment": "condiments", "spice": "spices", "snack": "snacks",
        // handy aliases in case your model uses slightly different words:
        "beverages": "beverages", "condiments": "condiments", "spices": "spices",
        "snacks": "snacks", "seafood": "seafood", "grains": "grains", "pasta": "pasta",
        "breakfast": "breakfast", "meat": "protein", "vegetable": "produce",
        "vegetables": "produce", "fruits": "fruit",
    ]

    /// Returns the best asset name that actually exists in the bundle.
    static func assetName(for name: String, category: String? = nil) -> String {
        let s = slug(name)
        if assetExists(s) { return s }
        if let c = category {
            let mapped = categoryIcon[c.lowercased()] ?? slug(c)
            if assetExists(mapped) { return mapped }
        }
        return "unknown"
    }

    private static func assetExists(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(named: name) != nil
        #elseif canImport(AppKit)
        return NSImage(named: name) != nil
        #else
        return false
        #endif
    }
}

/// Small view: renders the resolved icon, square and scalable.
struct ItemIcon: View {
    let name: String
    var category: String? = nil
    var body: some View {
        Image(IconResolver.assetName(for: name, category: category))
            .resizable()
            .scaledToFit()
            .accessibilityLabel(name)
    }
}
