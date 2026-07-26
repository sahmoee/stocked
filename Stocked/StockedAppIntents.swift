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
nonisolated struct OpenGroceryListIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Add to Stocked Grocery List" }
    nonisolated static var description: IntentDescription { IntentDescription("Open Stocked to add an item to your grocery list.") }
    nonisolated static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        // Flag so the app can route to the Grocery tab on next foreground.
        UserDefaults.standard.set(true, forKey: "pendingOpenGrocery")
        return .result()
    }
}

// MARK: - Start cooking (opens the app)

@available(iOS 16.0, *)
nonisolated struct StartCookingIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Start Cooking with Stocked" }
    nonisolated static var description: IntentDescription { IntentDescription("Open Stocked to find something to cook.") }
    nonisolated static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        // Flag the launch intent so the app can route to Cook Now on next foreground.
        UserDefaults.standard.set(true, forKey: "pendingStartCooking")
        return .result()
    }
}

// MARK: - What's expiring soon (reads inventory, speaks the answer)
// Parameter-free (SDK-safe). Reads the persisted inventory directly via a minimal DTO so it
// works without the live session, and returns a spoken/printed result.

@available(iOS 16.0, *)
/// #drift — "Hey Siri, I used the milk in Stocked." Queues the item name; the app
/// drains the queue on next foreground and marks matching items used (level 0,
/// consumption logged, auto-restock honored). Queue-and-drain because the intent
/// can run outside the app's live data layer — writing the store's full item JSON
/// from here would risk clobbering fields this lightweight context doesn't decode.
struct MarkItemUsedIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Mark Item Used in Stocked" }
    nonisolated static var description: IntentDescription { IntentDescription("Tell Stocked you finished or used up an item.") }
    nonisolated static var openAppWhenRun: Bool { false }

    @Parameter(title: "Item name") var itemName: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = itemName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            return .result(dialog: "Which item did you use?")
        }
        let ud = UserDefaults.standard
        var pending = ud.stringArray(forKey: "stocked.pendingUsedItems") ?? []
        pending.append(name)
        ud.set(pending, forKey: "stocked.pendingUsedItems")
        return .result(dialog: "Got it — I'll mark \(name) as used in Stocked.")
    }
}

/// #drift — "Hey Siri, add milk to Stocked." Same queue-and-drain pattern as
/// MarkItemUsedIntent: queue the name, apply through the store on next foreground
/// (smart merge, crowd defaults, and household sync all honored).
struct AddItemIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Add Item to Stocked" }
    nonisolated static var description: IntentDescription { IntentDescription("Add an item to your Stocked kitchen inventory.") }
    nonisolated static var openAppWhenRun: Bool { false }

    @Parameter(title: "Item name") var itemName: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = itemName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            return .result(dialog: "What would you like to add?")
        }
        let ud = UserDefaults.standard
        var pending = ud.stringArray(forKey: "stocked.pendingAddItems") ?? []
        pending.append(name)
        ud.set(pending, forKey: "stocked.pendingAddItems")
        return .result(dialog: "Got it — I'll add \(name) to your kitchen in Stocked.")
    }
}

nonisolated struct WhatsExpiringIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "What's expiring in Stocked" }
    nonisolated static var description: IntentDescription { IntentDescription("Ask Stocked what food is expiring soon.") }
    nonisolated static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let names = StockedInventoryReader.expiringSoon(withinDays: 3)
        let dialog: IntentDialog
        if names.isEmpty {
            dialog = "Nothing in your kitchen is expiring in the next few days."
        } else if names.count == 1 {
            dialog = "\(names[0]) is expiring soon."
        } else {
            let head = names.prefix(3).joined(separator: ", ")
            let extra = names.count > 3 ? ", and \(names.count - 3) more" : ""
            dialog = IntentDialog("Expiring soon: \(head)\(extra).")
        }
        return .result(dialog: dialog)
    }
}

@available(iOS 16.0, *)
nonisolated enum StockedInventoryReader {
    private static let key = "inventory_items"   // DBKey.inventoryItems.rawValue

    private struct InvDTO: Codable {
        var name: String
        var quantity: Int = 1
        var expirationDate: Date?
    }

    /// Names of items expiring within `days`, soonest first.
    static func expiringSoon(withinDays days: Int) -> [String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([InvDTO].self, from: data) else { return [] }
        let now = Date()
        let cal = Calendar.current
        let soon: [(String, Int)] = items.compactMap { item in
            guard let exp = item.expirationDate,
                  let d = cal.dateComponents([.day], from: now, to: exp).day,
                  d <= days else { return nil }
            return (item.name, d)
        }
        return soon.sorted { $0.1 < $1.1 }.map { $0.0 }
    }
}

// MARK: - Shortcut phrases (no parameters — fully SDK-safe)
//
// THE app's single shortcuts provider. AppIntents allows exactly ONE
// `AppShortcutsProvider` conformance per app — a second one is a hard build error, not a
// warning — so every shortcut in Stocked must be registered here. Apple also caps this at
// 10 entries; we currently declare 9.
//
// Intents themselves live in two files (this one, and StockedAppIntentsPlus.swift for the
// kitchen-feature intents). That split is fine; only the *provider* must be unique.

@available(iOS 16.0, *)
nonisolated struct StockedShortcuts: AppShortcutsProvider {
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
        AppShortcut(
            intent: MarkItemUsedIntent(),
            phrases: [
                "Mark an item used in \(.applicationName)",
                "I used something in \(.applicationName)"
            ],
            shortTitle: "Mark Used",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: AddItemIntent(),
            phrases: [
                "Add an item to \(.applicationName)",
                "Add something to my \(.applicationName) kitchen"
            ],
            shortTitle: "Add Item",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: WhatsExpiringIntent(),
            phrases: [
                "What's expiring in \(.applicationName)",
                "What's going bad in \(.applicationName)"
            ],
            shortTitle: "What's Expiring",
            systemImageName: "clock.badge.exclamationmark"
        )

        // ── Improvement #17 — kitchen-feature intents (defined in StockedAppIntentsPlus.swift) ──
        // Registered here because the provider must be unique app-wide.
        AppShortcut(
            intent: WhatLeftoversIntent(),
            phrases: [
                "What leftovers do I have in \(.applicationName)",
                "Check my \(.applicationName) leftovers"
            ],
            shortTitle: "Leftovers",
            systemImageName: "takeoutbag.and.cup.and.straw"
        )
        AppShortcut(
            intent: WhatToThawIntent(),
            phrases: [
                "What should I thaw in \(.applicationName)",
                "\(.applicationName) thaw plan"
            ],
            shortTitle: "What to Thaw",
            systemImageName: "snowflake"
        )
        AppShortcut(
            intent: HowManyDaysOfFoodIntent(),
            phrases: [
                "How many days of food do I have in \(.applicationName)",
                "\(.applicationName) readiness"
            ],
            shortTitle: "Days of Food",
            systemImageName: "shield.checkered"
        )
        AppShortcut(
            intent: WhatCanIUseUpIntent(),
            phrases: [
                "What should I use up in \(.applicationName)",
                "\(.applicationName) what needs eating"
            ],
            shortTitle: "Use Up",
            systemImageName: "arrow.down.to.line.circle"
        )
    }
}

// MARK: - Direct grocery-list writer (kept for future programmatic use)
// Appends straight to the persisted grocery list, mirroring LocalGroceryItem's
// Codable shape, so it stays in sync with the app's store without needing the
// live session. Not used by the parameter-free shortcuts above, but available.

nonisolated enum StockedGroceryWriter {
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
