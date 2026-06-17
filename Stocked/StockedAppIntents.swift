// StockedAppIntents.swift — #19 Siri / Shortcuts support.
//
// NOTE on the design: a parameterized "Add <item>" intent (with an @Parameter String)
// failed to compile on this toolchain with "Invalid parameter type. AppEntity and
// AppEnum are the only allowed types" — even after renaming the parameter. To stay
// reliable across SDK versions, both shortcuts are PARAMETER-FREE and simply open the
// app to the right place (the same pattern that compiles cleanly). The user then types
// the item / picks a recipe in-app. No @Parameter, nothing for the resolver to reject.

import AppIntents
import Foundation

// MARK: - Open the grocery list (to add an item)

@available(iOS 16.0, *)
struct OpenGroceryListIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Stocked Grocery List"
    static var description = IntentDescription("Open Stocked to add an item to your grocery list.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Flag so the app can route to the Grocery tab on next foreground.
        UserDefaults.standard.set(true, forKey: "pendingOpenGrocery")
        return .result()
    }
}

// MARK: - Start cooking (opens the app)

@available(iOS 16.0, *)
struct StartCookingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Cooking with Stocked"
    static var description = IntentDescription("Open Stocked to find something to cook.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Flag the launch intent so the app can route to Cook Now on next foreground.
        UserDefaults.standard.set(true, forKey: "pendingStartCooking")
        return .result()
    }
}

// MARK: - Shortcut phrases (no parameters — fully SDK-safe)

@available(iOS 16.0, *)
struct StockedShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenGroceryListIntent(),
            phrases: [
                "Open my \(.applicationName) grocery list",
                "Add to my \(.applicationName) list"
            ],
            shortTitle: "Grocery List",
            systemImageName: "cart.badge.plus"
        )
        AppShortcut(
            intent: StartCookingIntent(),
            phrases: [
                "Start cooking with \(.applicationName)",
                "What can I cook with \(.applicationName)"
            ],
            shortTitle: "Start Cooking",
            systemImageName: "frying.pan.fill"
        )
    }
}

// MARK: - Direct grocery-list writer (kept for future programmatic use)
// Appends straight to the persisted grocery list, mirroring LocalGroceryItem's
// Codable shape, so it stays in sync with the app's store without needing the
// live session. Not used by the parameter-free shortcuts above, but available.

enum StockedGroceryWriter {
    private static let key = "grocery_items"   // DBKey.groceryItems.rawValue

    private struct GroceryItemDTO: Codable {
        var quantity: Int = 1
        var id = UUID()
        var name: String
        var isChecked: Bool = false
        var isRecommended: Bool = false
        var recipeSource: String = ""
    }

    static func append(name: String) {
        let ud = UserDefaults.standard
        var items: [GroceryItemDTO] = []
        if let data = ud.data(forKey: key),
           let decoded = try? JSONDecoder().decode([GroceryItemDTO].self, from: data) {
            items = decoded
        }
        guard !items.contains(where: { $0.name.lowercased() == name.lowercased() }) else { return }
        items.append(GroceryItemDTO(name: name))
        if let data = try? JSONEncoder().encode(items) {
            ud.set(data, forKey: key)
        }
    }
}
