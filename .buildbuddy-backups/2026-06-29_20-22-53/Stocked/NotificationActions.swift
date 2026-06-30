// NotificationActions.swift — Rich notification actions + item deep-linking (#17).
//
// Expiry reminders previously only carried a screen hint (userInfo["action"] = "openInventory")
// and tapping them just switched to the Inventory tab. This adds:
//   • Action BUTTONS on expiry reminders — "Add to Grocery" and "Mark Used" — so the user can
//     act on a spoiling item straight from the notification without opening the app.
//   • A per-item DEEP LINK — tapping the body of an expiry reminder opens that exact item.
//
// The notification delegate (in HouseholdSharingUI) forwards responses here. Action buttons
// mutate the store directly via HouseholdShareBridge; a plain tap posts a deep-link so
// MainTabView can switch to Inventory and open the item.

import Foundation
import UserNotifications

// MARK: - Identifiers

enum StockedNotificationCategory {
    /// Category for per-item expiry reminders (carries item id + name in userInfo).
    static let expiryItem = "EXPIRY_ITEM"
}

enum StockedNotificationAction {
    static let addToGrocery = "ADD_TO_GROCERY"
    static let markUsed     = "MARK_USED"
}

enum StockedNotificationKey {
    static let action   = "action"      // existing screen-hint key (e.g. "openInventory")
    static let itemID   = "itemID"      // UUID string of the inventory item
    static let itemName = "itemName"    // display name, used for grocery add + toasts
}

extension Notification.Name {
    /// Posted when the user taps an item-specific reminder; payload is the item's UUID string.
    static let stockedOpenInventoryItem = Notification.Name("stockedOpenInventoryItem")
}

// MARK: - Category registration

enum NotificationActionRegistrar {
    /// Registers notification categories + their action buttons. Call once at launch
    /// (before scheduling), e.g. from the app delegate's didFinishLaunching.
    @MainActor
    static func registerCategories() {
        let addToGrocery = UNNotificationAction(
            identifier: StockedNotificationAction.addToGrocery,
            title: "Add to Grocery",
            options: []                       // runs in background, no app foreground needed
        )
        let markUsed = UNNotificationAction(
            identifier: StockedNotificationAction.markUsed,
            title: "Mark Used",
            options: []
        )
        let expiryCategory = UNNotificationCategory(
            identifier: StockedNotificationCategory.expiryItem,
            actions: [addToGrocery, markUsed],
            intentIdentifiers: [],
            options: []
        )
        // Preserve any categories other code may register by unioning rather than replacing.
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var merged = existing
            merged.insert(expiryCategory)
            UNUserNotificationCenter.current().setNotificationCategories(merged)
        }
    }
}

// MARK: - Response handling

enum NotificationActionHandler {
    /// Handles a notification response (tap or action button). Returns true if it consumed
    /// the response, so the delegate can skip its legacy screen-routing switch.
    @MainActor
    static func handle(_ response: UNNotificationResponse) -> Bool {
        let info = response.notification.request.content.userInfo
        let itemID   = info[StockedNotificationKey.itemID]   as? String
        let itemName = info[StockedNotificationKey.itemName] as? String ?? ""

        switch response.actionIdentifier {
        case StockedNotificationAction.addToGrocery:
            guard !itemName.isEmpty else { return true }
            HouseholdShareBridge.shared.store?.addToGroceryIfMissing(itemName, recommended: false)
            return true

        case StockedNotificationAction.markUsed:
            if let idStr = itemID, let uuid = UUID(uuidString: idStr) {
                HouseholdShareBridge.shared.store?.removeInventoryItem(id: uuid)
            }
            return true

        case UNNotificationDefaultActionIdentifier:
            // Body tap: deep-link to the specific item if we have one; the delegate's
            // legacy switch will otherwise handle the screen-level "action" hint.
            if let idStr = itemID {
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.inventory)
                NotificationCenter.default.post(name: .stockedOpenInventoryItem, object: idStr)
                return true
            }
            return false

        default:
            return false
        }
    }
}
