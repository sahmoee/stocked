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

/// A person in the household.
struct HouseholdMember: Identifiable, Hashable {
    /// Access level. The owner assigns these to control what each person can do. Ordered from
    /// most to least privileged; the raw values are what the server stores.
    enum Role: String, CaseIterable {
        case owner, manager, adult, teen, kid, member

        /// Default display label for the level (the owner can override with a custom label).
        var label: String {
            switch self {
            case .owner:   return "Owner"
            case .manager: return "Manager"
            case .adult:   return "Adult"
            case .teen:    return "Teen"
            case .kid:     return "Kid"
            case .member:  return "Member"
            }
        }

        /// What this level is allowed to do to the shared pantry. Sensible defaults the owner
        /// can rely on: kids view only, teens add/edit, adults also remove, managers/owner also
        /// manage members. Enforced in the UI and on the server.
        var canAdd: Bool    { self != .kid }
        var canEdit: Bool   { self != .kid }
        var canRemove: Bool { self == .owner || self == .manager || self == .adult }
        var canManageMembers: Bool { self == .owner || self == .manager }
        var isOwnerLevel: Bool { self == .owner }
    }

    var id: String               // stable member id (matches memberId on the server)
    var name: String
    var role: Role
    /// Owner-assigned custom label shown instead of the role's default (e.g. "Mom", "Big Sis").
    var customLabel: String? = nil
    var joinedAt: Date?
    var isMe: Bool = false

    /// The label to show: the owner's custom label if set, else the role's default.
    var displayLabel: String { (customLabel?.isEmpty == false ? customLabel! : role.label) }

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

// MARK: - Household Sync Foundation (Drop 1 of the sync plan)
// Types for the durable local operation queue and sync status. Backend-agnostic: the
// Worker remains the primary household store; these types harden it (offline edits
// survive relaunch and retry) and leave room for future routes without model changes.

/// What kind of household data an operation touches.
enum HouseholdEntityType: String, Codable, Sendable {
    case inventoryItem
    case groceryItem
    case userRecipe
    case generatedRecipe
    case savedRecipe
    case plannedMeal
    case householdActivity
}

/// What happened to the entity.
enum HouseholdOperationType: String, Codable, Sendable {
    case create
    case update
    case delete
    case restore
}

/// Which path moved (or will move) data. Worker routes are primary by design.
enum HouseholdSyncRoute: String, Codable, Sendable {
    case workerPush
    case workerPull
    case iCloudKVNudge
    case foregroundRefresh
    case backgroundRefresh
    case manualSync
    case localQueueRetry
}

/// A durable record of a household-bound local mutation that has not yet been confirmed
/// pushed. Because the Worker push sends FULL inventory/grocery state plus tombstones, one
/// successful push satisfies every pending operation at once — so payloadJSON stays nil for
/// inventory and grocery; the queue's job is durability and retry, not payload transport.
struct PendingHouseholdOperation: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var entityID: UUID
    var entityType: HouseholdEntityType
    var operationType: HouseholdOperationType
    var payloadJSON: Data? = nil
    var createdAt: Date = Date()
    var retryCount: Int = 0
    var lastError: String? = nil
}

/// Snapshot of sync health, persisted so diagnostics survive relaunch.
struct HouseholdSyncStatus: Codable, Sendable {
    var lastSuccessfulPush: Date? = nil
    var lastSuccessfulPull: Date? = nil
    var pendingOperationCount: Int = 0
    var lastError: String? = nil
    var activeRoute: HouseholdSyncRoute? = nil
}
