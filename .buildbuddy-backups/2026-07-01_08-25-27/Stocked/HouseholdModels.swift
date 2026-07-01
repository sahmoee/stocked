// HouseholdModels.swift — models for the household activity feed and member list.
//
// These back the mockup's Household Activity (feed) and Household Members screens. They're
// plain value types; the CloudKit layer (HouseholdCloudKit) reads/writes the activity events,
// and members are derived from the CKShare participants.

import Foundation

// MARK: - Activity feed

/// A single entry in the household activity feed ("Alex added Chicken Breast to Grocery List").
struct HouseholdActivity: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case groceryAdded, groceryRemoved, groceryChecked
        case inventoryAdded, inventoryUpdated, inventoryRemoved
        case recipeAdded, recipeUpdated
        case memberJoined, memberLeft, householdCreated

        /// Which filter tab this belongs to in the Activity screen.
        var category: Category {
            switch self {
            case .groceryAdded, .groceryRemoved, .groceryChecked: return .lists
            case .inventoryAdded, .inventoryUpdated, .inventoryRemoved: return .inventory
            case .recipeAdded, .recipeUpdated: return .recipes
            case .memberJoined, .memberLeft, .householdCreated: return .lists
            }
        }
        /// Verb shown in the feed.
        var verb: String {
            switch self {
            case .groceryAdded:    return "added"
            case .groceryRemoved:  return "removed"
            case .groceryChecked:  return "checked off"
            case .inventoryAdded:  return "added"
            case .inventoryUpdated:return "updated"
            case .inventoryRemoved:return "removed"
            case .recipeAdded:     return "created"
            case .recipeUpdated:   return "updated"
            case .memberJoined:    return "joined"
            case .memberLeft:      return "left"
            case .householdCreated:return "created the household"
            }
        }
        /// Where the verb points ("…to Grocery List", "…in Inventory").
        var target: String {
            switch self {
            case .groceryAdded, .groceryRemoved, .groceryChecked: return "Grocery List"
            case .inventoryAdded, .inventoryUpdated, .inventoryRemoved: return "Inventory"
            case .recipeAdded, .recipeUpdated: return "Recipe"
            default: return ""
            }
        }
    }

    enum Category: String, CaseIterable { case all, lists, inventory, recipes
        var label: String {
            switch self { case .all: return "All"; case .lists: return "Lists"
            case .inventory: return "Inventory"; case .recipes: return "Recipes" }
        }
    }

    var id = UUID()
    var kind: Kind
    var itemName: String         // e.g. "Chicken Breast"
    var actorName: String        // e.g. "Alex"
    var date: Date = Date()

    /// "Chicken Breast to Grocery List" / "Milk in Inventory" — the bold middle of the feed row.
    var phrase: String {
        switch kind {
        case .groceryAdded, .groceryRemoved:       return "\(itemName) to \(kind.target)"
        case .groceryChecked:                       return itemName
        case .inventoryAdded, .inventoryUpdated, .inventoryRemoved: return "\(itemName) in \(kind.target)"
        case .recipeAdded, .recipeUpdated:          return itemName
        default:                                     return itemName
        }
    }
}

// MARK: - Member

/// A person in the household (derived from CKShare participants).
struct HouseholdMember: Identifiable, Hashable {
    enum Role: String { case owner, member
        var label: String { self == .owner ? "Organizer" : "Member" }
    }
    var id: String               // stable participant id (or userRecordID)
    var name: String
    var role: Role
    var joinedAt: Date?
    var isMe: Bool = false

    // Optional profile fields (mockup's Member Profile screen). Populated when available.
    var dietaryPreference: String?
    var favoriteIngredients: [String] = []
    var dislikes: [String] = []
    var allergies: [String] = []
}

// MARK: - Pending invite (mockup's Pending Invites screen)

struct HouseholdInvite: Identifiable, Codable, Hashable {
    var id = UUID()
    var inviteeName: String
    var sentAt: Date
    var code: String
    /// Invites expire 7 days after sending (per the mockup copy).
    var expiresAt: Date { Calendar.current.date(byAdding: .day, value: 7, to: sentAt) ?? sentAt }
    var isExpired: Bool { Date() > expiresAt }
}

// MARK: - Per-household notification preferences (mockup's Customize Notifications screen)

struct HouseholdNotificationPrefs: Codable, Equatable {
    var groceryAdded   = true
    var groceryRemoved = false
    var inventoryAdded = true
    var inventoryUpdated = false
    var lowStock       = true
    var recipesAdded   = false
    var recipesUpdated = false
    var remindersChanged = true

    private static let key = "household_notif_prefs_v1"
    static func load() -> HouseholdNotificationPrefs {
        guard let d = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(HouseholdNotificationPrefs.self, from: d) else { return .init() }
        return p
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}
