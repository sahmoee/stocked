// PreviewStates.swift — Reusable sample data for SwiftUI previews and manual QA (#9).
//
// SwiftUI previews and on-device QA need to see screens in states that are hard to reach with
// real data: empty, richly populated, items expiring, low stock, error/loading. This file builds
// those states as ready-made stores and fixtures so any preview can show them in one line, and so
// the same scenarios can be exercised in light/dark and large text.
//
// Debug-oriented but compiled in all configs (no #if DEBUG) so previews work from any scheme.
// Nothing here runs in normal app flow; views opt in from their #Preview blocks.

import SwiftUI

enum PreviewStates {

    // MARK: - Inventory fixtures

    /// A spread of items, including some expiring soon and some low, for a "real kitchen" look.
    static var populatedInventory: [LocalInventoryItem] {
        [
            make("Whole Milk", level: 0.4, zone: "Fridge", days: 2),     // expiring soon
            make("Eggs", level: 0.9, zone: "Fridge", days: 12, qty: 12),
            make("Chicken Breast", level: 0.2, zone: "Fridge", days: 1), // expiring + low
            make("Rice", level: 0.8, zone: "Pantry", days: nil, qty: 1),
            make("Olive Oil", level: 0.15, zone: "Pantry", days: nil),   // low
            make("Frozen Peas", level: 1.0, zone: "Freezer", days: 200),
            make("Cheddar", level: 0.6, zone: "Fridge", days: 20),
            make("Bananas", level: 0.5, zone: "Pantry", days: 3),        // expiring soon
        ]
    }

    /// Items that are all expiring within the window — for the "Use It Soon" full state.
    static var expiringInventory: [LocalInventoryItem] {
        [
            make("Spinach", level: 0.5, zone: "Fridge", days: 1),
            make("Strawberries", level: 0.7, zone: "Fridge", days: 2),
            make("Leftover Curry", level: 1.0, zone: "Fridge", days: 0, leftover: true),
            make("Ground Beef", level: 0.3, zone: "Fridge", days: 3),
        ]
    }

    /// Empty — for empty-state design.
    static var emptyInventory: [LocalInventoryItem] { [] }

    // MARK: - Grocery fixtures

    static var populatedGrocery: [LocalGroceryItem] {
        [
            LocalGroceryItem(quantity: 1, name: "Milk", isChecked: false),
            LocalGroceryItem(quantity: 2, name: "Bread", isChecked: false, isRecommended: true),
            LocalGroceryItem(quantity: 1, name: "Eggs", isChecked: true),
            LocalGroceryItem(quantity: 1, name: "Tomatoes", isChecked: false, isRecommended: true, recipeSource: "Pasta Night"),
        ]
    }

    static var emptyGrocery: [LocalGroceryItem] { [] }

    // MARK: - Recipe fixtures

    static var sampleRecipe: GeneratedRecipe {
        GeneratedRecipe(
            title: "Garlic Butter Chicken",
            cookTime: "25 minutes",
            servings: 4,
            difficulty: "Easy",
            ingredients: [
                RecipeIngredientLine(amount: "2", name: "chicken breasts"),
                RecipeIngredientLine(amount: "3 tbsp", name: "butter"),
                RecipeIngredientLine(amount: "4 cloves", name: "garlic"),
            ],
            steps: ["Season the chicken.", "Sear in butter.", "Add garlic and finish."],
            tips: "Let it rest before slicing."
        )
    }

    // MARK: - Builder

    private static func make(_ name: String, level: Double, zone: String,
                             days: Int?, qty: Int = 1, leftover: Bool = false) -> LocalInventoryItem {
        var item = LocalInventoryItem(name: name, level: level, zone: zone, quantity: qty)
        if let days {
            item.expirationDate = Calendar.current.date(byAdding: .day, value: days, to: Date())
        }
        item.isLeftover = leftover
        return item
    }
}

// MARK: - Preview scenario wrapper
//
// Wrap a view in a labeled scenario so a single preview file can show empty, populated, dark, and
// large-text variants side by side without repeating boilerplate.

struct PreviewScenario<Content: View>: View {
    let label: String
    let dark: Bool
    let largeText: Bool
    @ViewBuilder var content: () -> Content

    init(_ label: String, dark: Bool = false, largeText: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label; self.dark = dark; self.largeText = largeText; self.content = content
    }

    var body: some View {
        content()
            .preferredColorScheme(dark ? .dark : .light)
            .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
            .previewDisplayName(label)
    }
}
