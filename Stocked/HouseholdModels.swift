// HouseholdModels.swift — models for the household activity feed and member list.
//
// These back the mockup's Household Activity (feed) and Household Members screens. They're
// plain value types; the CloudKit layer (HouseholdCloudKit) reads/writes the activity events,
// and members are derived from the CKShare participants.

import Foundation

// MARK: - Activity feed

/// A single entry in the household activity feed ("Alex added Chicken Breast to Grocery List").
nonisolated struct HouseholdActivity: Identifiable, Codable, Hashable, Sendable {
    nonisolated enum Kind: String, Codable, CaseIterable, Sendable {
        case groceryAdded, groceryRemoved, groceryChecked
        case inventoryAdded, inventoryUpdated, inventoryRemoved
        case recipeAdded, recipeUpdated, recipeImported
        case memberJoined, memberLeft, householdCreated
        case memberRenamed

        /// Which filter tab this belongs to in the Activity screen.
        var category: Category {
            switch self {
            case .groceryAdded, .groceryRemoved, .groceryChecked: return .lists
            case .inventoryAdded, .inventoryUpdated, .inventoryRemoved: return .inventory
            case .recipeAdded, .recipeUpdated, .recipeImported: return .recipes
            case .memberJoined, .memberLeft, .householdCreated: return .lists
            case .memberRenamed: return .lists
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
            case .recipeImported:  return "imported"
            case .memberJoined:    return "joined"
            case .memberLeft:      return "left"
            case .householdCreated:return "created the household"
            case .memberRenamed:   return "changed their name to"
            }
        }
        /// Where the verb points ("…to Grocery List", "…in Inventory").
        var target: String {
            switch self {
            case .groceryAdded, .groceryRemoved, .groceryChecked: return "Grocery List"
            case .inventoryAdded, .inventoryUpdated, .inventoryRemoved: return "Inventory"
            case .recipeAdded, .recipeUpdated, .recipeImported: return "Recipe"
            default: return ""
            }
        }
    }

    nonisolated enum Category: String, CaseIterable, Sendable { case all, lists, inventory, recipes
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
        case .recipeAdded, .recipeUpdated, .recipeImported: return itemName
        case .memberRenamed:                        return itemName
        default:                                     return itemName
        }
    }
}

// MARK: - Member

/// A person in the household.
nonisolated struct HouseholdMember: Identifiable, Hashable, Sendable {
    /// Access level. The owner assigns these to control what each person can do. Ordered from
    /// most to least privileged; the raw values are what the server stores.
    nonisolated enum Role: String, CaseIterable, Sendable {
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

        /// Canonical grants sent to the Worker. The legacy `canAdd`/`canEdit`/`canRemove`
        /// accessors remain for older UI and server versions; new surfaces should ask the
        /// effective member permission set instead of recreating role rules.
        var defaultPermissions: Set<HouseholdPermission> {
            switch self {
            case .owner:
                return Set(HouseholdPermission.allCases)
            case .manager:
                return Set(HouseholdPermission.allCases).subtracting([.transferOwnership])
            case .adult:
                return [.view, .inventoryAdd, .inventoryEdit, .inventoryRemove,
                        .groceryAdd, .groceryEdit, .groceryRemove,
                        .recipeEdit, .mealPlanEdit, .backupExport]
            case .teen, .member:
                return [.view, .inventoryAdd, .inventoryEdit,
                        .groceryAdd, .groceryEdit, .recipeEdit, .mealPlanEdit]
            case .kid:
                return [.view]
            }
        }
    }

    var id: String               // stable member id (matches memberId on the server)
    var name: String
    var role: Role
    /// Owner-assigned custom label shown instead of the role's default (e.g. "Mom", "Big Sis").
    var customLabel: String? = nil
    // #4 Per-permission overrides. When set, these win over the role's defaults, so the owner can
    // fine-tune one member (e.g. a teen who's allowed to remove). nil = use the role default.
    var overrideCanAdd: Bool? = nil
    var overrideCanEdit: Bool? = nil
    var overrideCanRemove: Bool? = nil
    /// Additive fine-grained policy. nil means an older server/member record and therefore
    /// falls back to the role plus the three legacy overrides above. Explicit denials are
    /// evaluated last and always win over both role defaults and grants.
    var permissionGrants: Set<HouseholdPermission>? = nil
    var permissionDenials: Set<HouseholdPermission> = []

    // Effective permissions = override if present, else the role default.
    var effectiveCanAdd: Bool    { overrideCanAdd    ?? role.canAdd }
    var effectiveCanEdit: Bool   { overrideCanEdit   ?? role.canEdit }
    var effectiveCanRemove: Bool { overrideCanRemove ?? role.canRemove }
    var effectivePermissions: Set<HouseholdPermission> {
        var permissions = role.defaultPermissions
        if effectiveCanAdd {
            permissions.formUnion([.inventoryAdd, .groceryAdd])
        } else {
            permissions.subtract([.inventoryAdd, .groceryAdd])
        }
        if effectiveCanEdit {
            permissions.formUnion([.inventoryEdit, .groceryEdit])
        } else {
            permissions.subtract([.inventoryEdit, .groceryEdit])
        }
        if effectiveCanRemove {
            permissions.formUnion([.inventoryRemove, .groceryRemove])
        } else {
            permissions.subtract([.inventoryRemove, .groceryRemove])
        }
        permissions.formUnion(permissionGrants ?? [])
        permissions.subtract(permissionDenials)
        return permissions
    }
    func can(_ permission: HouseholdPermission) -> Bool {
        effectivePermissions.contains(permission)
    }
    var joinedAt: Date? = nil
    var isMe: Bool = false

    /// The label to show: the owner's custom label if set, else the role's default.
    var displayLabel: String { (customLabel?.isEmpty == false ? customLabel! : role.label) }

    // Optional profile fields (mockup's Member Profile screen). Populated when available.
    var dietaryPreference: String?
    var favoriteIngredients: [String] = []
    var dislikes: [String] = []
    var allergies: [String] = []
}

/// Server-enforced capabilities. Raw values are stable wire identifiers; additions are safe
/// because old clients ignore unknown grants and continue using their role defaults.
nonisolated enum HouseholdPermission: String, Codable, CaseIterable, Hashable, Sendable {
    case view
    case inventoryAdd, inventoryEdit, inventoryRemove
    case groceryAdd, groceryEdit, groceryRemove
    case recipeEdit, mealPlanEdit
    case manageMembers, manageHousehold, transferOwnership
    case backupExport, backupRestore
}

/// Persisted effective access for the current device's household member. The custom wire shape
/// ignores unknown future permissions and fails closed when an older/corrupt snapshot lacks its
/// grant list; owners and solo kitchens are normalized by HouseholdSync instead.
nonisolated struct HouseholdMemberAccessSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var role: HouseholdMember.Role
    var permissions: Set<HouseholdPermission>
    var canAdd: Bool
    var canEdit: Bool
    var canRemove: Bool

    static var restrictedMember: Self {
        Self(role: .member, permissions: [.view], canAdd: false, canEdit: false, canRemove: false)
    }

    static var owner: Self {
        Self(role: .owner, permissions: Set(HouseholdPermission.allCases),
             canAdd: true, canEdit: true, canRemove: true)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, role, permissions, canAdd, canEdit, canRemove
    }

    init(role: HouseholdMember.Role, permissions: Set<HouseholdPermission>,
         canAdd: Bool, canEdit: Bool, canRemove: Bool) {
        self.role = role
        self.permissions = permissions
        self.canAdd = canAdd
        self.canEdit = canEdit
        self.canRemove = canRemove
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let rawRole = try c.decodeIfPresent(String.self, forKey: .role)
        role = rawRole.flatMap(HouseholdMember.Role.init(rawValue:)) ?? .kid
        if let rawPermissions = try c.decodeIfPresent([String].self, forKey: .permissions) {
            permissions = Set(rawPermissions.compactMap(HouseholdPermission.init(rawValue:)))
        } else {
            permissions = role == .owner ? Set(HouseholdPermission.allCases) : [.view]
        }
        let hasAdd = permissions.contains(.inventoryAdd) || permissions.contains(.groceryAdd)
        let hasEdit = permissions.contains(.inventoryEdit) || permissions.contains(.groceryEdit)
        let hasRemove = permissions.contains(.inventoryRemove) || permissions.contains(.groceryRemove)
        canAdd = (try c.decodeIfPresent(Bool.self, forKey: .canAdd) ?? hasAdd) && hasAdd
        canEdit = (try c.decodeIfPresent(Bool.self, forKey: .canEdit) ?? hasEdit) && hasEdit
        canRemove = (try c.decodeIfPresent(Bool.self, forKey: .canRemove) ?? hasRemove) && hasRemove
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(role.rawValue, forKey: .role)
        try c.encode(permissions.map(\.rawValue).sorted(), forKey: .permissions)
        try c.encode(canAdd, forKey: .canAdd)
        try c.encode(canEdit, forKey: .canEdit)
        try c.encode(canRemove, forKey: .canRemove)
    }
}

// MARK: - Pending invite (mockup's Pending Invites screen)

nonisolated struct HouseholdInvite: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var inviteeName: String
    var sentAt: Date
    var code: String
    /// Invites expire 7 days after sending (per the mockup copy).
    var expiresAt: Date { Calendar.current.date(byAdding: .day, value: 7, to: sentAt) ?? sentAt }
    var isExpired: Bool { Date() > expiresAt }
}

// MARK: - Per-household notification preferences (mockup's Customize Notifications screen)

nonisolated struct HouseholdNotificationPrefs: Codable, Equatable, Sendable {
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
nonisolated enum HouseholdEntityType: String, Codable, Sendable, Hashable {
    case inventoryItem
    case groceryItem
    case userRecipe
    case generatedRecipe
    case savedRecipe
    case plannedMeal
    case householdActivity
    /// Launch readiness 1.4 — the generic bucket for the feature collections (leftovers, family,
    /// events, shared costs, store layouts, harvests, labels, takeout). One case for all eight:
    /// the queue only exists to trigger pushes and mark ids locked, and push sends full state,
    /// so per-collection cases would add nothing but enum churn. Decode-safe: the raw value only
    /// appears in queues written after this ships.
    case featureData
}

/// What happened to the entity.
nonisolated enum HouseholdOperationType: String, Codable, Sendable {
    case create
    case update
    case delete
    case restore
}

/// Canonical capability required for a local collaborative mutation. Keeping the mapping pure
/// prevents UI/store call sites from drifting back to coarse role checks.
nonisolated enum HouseholdMutationAuthorization {
    static func requiredPermission(entityType: HouseholdEntityType,
                                   operationType: HouseholdOperationType) -> HouseholdPermission? {
        switch entityType {
        case .inventoryItem:
            switch operationType {
            case .create, .restore: return .inventoryAdd
            case .update: return .inventoryEdit
            case .delete: return .inventoryRemove
            }
        case .groceryItem:
            switch operationType {
            case .create, .restore: return .groceryAdd
            case .update: return .groceryEdit
            case .delete: return .groceryRemove
            }
        case .userRecipe, .generatedRecipe, .savedRecipe:
            return .recipeEdit
        case .plannedMeal:
            return .mealPlanEdit
        case .householdActivity, .featureData:
            return nil
        }
    }
}

/// Which path moved (or will move) data. Worker routes are primary by design.
nonisolated enum HouseholdSyncRoute: String, Codable, Sendable {
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
nonisolated struct PendingHouseholdOperation: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var entityID: UUID
    var entityType: HouseholdEntityType
    var operationType: HouseholdOperationType
    var payloadJSON: Data? = nil
    var createdAt: Date = Date()
    var retryCount: Int = 0
    var lastError: String? = nil
    /// Stable across retries and request-response loss. The Worker must retain recently seen
    /// keys per household and return the same acknowledgement for a replay.
    var idempotencyKey: String
    /// Monotonic per-device sequence for diagnostics and checkpoint advancement.
    var clientSequence: UInt64 = 0
    var baseServerRevision: Int = 0
    var recordRevision: UInt64 = 0
    var fieldRevisions: [String: UInt64] = [:]
    var quantityOperation: HouseholdQuantityOperation? = nil

    init(id: UUID = UUID(), entityID: UUID, entityType: HouseholdEntityType,
         operationType: HouseholdOperationType, payloadJSON: Data? = nil,
         createdAt: Date = Date(), retryCount: Int = 0, lastError: String? = nil,
         idempotencyKey: String? = nil, clientSequence: UInt64 = 0,
         baseServerRevision: Int = 0, recordRevision: UInt64 = 0,
         fieldRevisions: [String: UInt64] = [:],
         quantityOperation: HouseholdQuantityOperation? = nil) {
        self.id = id
        self.entityID = entityID
        self.entityType = entityType
        self.operationType = operationType
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.retryCount = retryCount
        self.lastError = lastError
        self.idempotencyKey = idempotencyKey ?? id.uuidString.lowercased()
        self.clientSequence = clientSequence
        self.baseServerRevision = baseServerRevision
        self.recordRevision = recordRevision
        self.fieldRevisions = fieldRevisions
        self.quantityOperation = quantityOperation
    }

    private enum CodingKeys: String, CodingKey {
        case id, entityID, entityType, operationType, payloadJSON, createdAt, retryCount,
             lastError, idempotencyKey, clientSequence, baseServerRevision, recordRevision,
             fieldRevisions, quantityOperation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        entityID = try c.decode(UUID.self, forKey: .entityID)
        entityType = try c.decode(HouseholdEntityType.self, forKey: .entityType)
        operationType = try c.decode(HouseholdOperationType.self, forKey: .operationType)
        payloadJSON = try c.decodeIfPresent(Data.self, forKey: .payloadJSON)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
            ?? id.uuidString.lowercased()
        clientSequence = try c.decodeIfPresent(UInt64.self, forKey: .clientSequence) ?? 0
        baseServerRevision = try c.decodeIfPresent(Int.self, forKey: .baseServerRevision) ?? 0
        recordRevision = try c.decodeIfPresent(UInt64.self, forKey: .recordRevision) ?? 0
        fieldRevisions = try c.decodeIfPresent([String: UInt64].self, forKey: .fieldRevisions) ?? [:]
        quantityOperation = try c.decodeIfPresent(HouseholdQuantityOperation.self, forKey: .quantityOperation)
    }
}

/// Pure durable-journal compaction rule. State updates coalesce while retaining unacknowledged
/// quantity intents; lifecycle boundaries (create/delete/restore) supersede every older intent for
/// that entity so a stale delta can never mutate or resurrect removed state.
nonisolated enum HouseholdOperationJournal {
    nonisolated struct Replacement: Sendable {
        var entityID: UUID
        var entityType: HouseholdEntityType
        var operationType: HouseholdOperationType
    }

    private struct EntityKey: Hashable {
        var id: UUID
        var type: HouseholdEntityType
    }

    static func retaining(_ existing: [PendingHouseholdOperation],
                          replacingWith replacements: [Replacement]) -> [PendingHouseholdOperation] {
        var latest: [EntityKey: HouseholdOperationType] = [:]
        for replacement in replacements {
            latest[EntityKey(id: replacement.entityID, type: replacement.entityType)] = replacement.operationType
        }
        return existing.filter { operation in
            guard let replacement = latest[EntityKey(id: operation.entityID, type: operation.entityType)] else {
                return true
            }
            switch replacement {
            case .update:
                return operation.quantityOperation != nil
            case .create, .delete, .restore:
                return false
            }
        }
    }


    static func markingFailure(_ existing: [PendingHouseholdOperation], operationIDs: Set<UUID>,
                               message: String) -> [PendingHouseholdOperation] {
        existing.map { operation in
            guard operationIDs.contains(operation.id) else { return operation }
            var failed = operation
            failed.retryCount += 1
            failed.lastError = message
            return failed
        }
    }
}

/// Commutative quantity intent. Concurrent +1/-1 edits can be combined instead of choosing one
/// absolute quantity through last-write-wins. The idempotency key makes replay a no-op.
nonisolated struct HouseholdQuantityOperation: Codable, Identifiable, Sendable, Equatable, Hashable {
    var id: UUID = UUID()
    var idempotencyKey: String
    var entityID: UUID
    var entityType: HouseholdEntityType
    var delta: Int
    var baseValue: Int?
    var baseRecordRevision: UInt64
    var actorID: String
    var createdAt: Date

    init(id: UUID = UUID(), idempotencyKey: String? = nil, entityID: UUID,
         entityType: HouseholdEntityType, delta: Int, baseValue: Int? = nil,
         baseRecordRevision: UInt64 = 0, actorID: String = "", createdAt: Date = Date()) {
        self.id = id
        self.idempotencyKey = idempotencyKey ?? id.uuidString.lowercased()
        self.entityID = entityID
        self.entityType = entityType
        self.delta = delta
        self.baseValue = baseValue
        self.baseRecordRevision = baseRecordRevision
        self.actorID = actorID
        self.createdAt = createdAt
    }

    /// Applies each logical operation once. Ordering cannot change the result.
    static func mergedValue(base: Int, operations: [HouseholdQuantityOperation]) -> Int {
        var seen = Set<String>()
        let delta = operations.reduce(into: 0) { total, operation in
            if seen.insert(operation.idempotencyKey).inserted { total += operation.delta }
        }
        return max(0, base + delta)
    }
}

/// Per-record and per-field clocks. The record clock advances for every mutation; fields advance
/// only when changed so a future Worker can merge independent edits without replacing a record.
nonisolated struct HouseholdRecordRevision: Codable, Sendable, Equatable {
    var record: UInt64 = 0
    var fields: [String: UInt64] = [:]
    var serverCheckpoint: Int = 0
    var writerID: String = ""
    var updatedAt: Date = .distantPast

    mutating func advance(changedFields: Set<String>, writerID: String, at date: Date = Date()) {
        record &+= 1
        for field in changedFields { fields[field] = max(fields[field] ?? 0, record) }
        self.writerID = writerID
        updatedAt = date
    }

    func merged(with remote: HouseholdRecordRevision) -> HouseholdRecordRevision {
        var result = record > remote.record ? self : remote
        for key in Set(fields.keys).union(remote.fields.keys) {
            result.fields[key] = max(fields[key] ?? 0, remote.fields[key] ?? 0)
        }
        result.serverCheckpoint = max(serverCheckpoint, remote.serverCheckpoint)
        return result
    }
}

nonisolated struct HouseholdSyncCheckpoint: Codable, Sendable, Equatable {
    var protocolVersion: Int = 2
    var serverRevision: Int = 0
    var cursor: String? = nil
    var collectionRevisions: [String: Int] = [:]
    var lastClientSequence: UInt64 = 0
    var recordedAt: Date = .distantPast
}

nonisolated struct HouseholdSyncReceipt: Codable, Identifiable, Sendable, Equatable {
    nonisolated enum Outcome: String, Codable, Sendable { case acknowledged, partial, rejected }
    var id: UUID = UUID()
    var requestID: UUID
    var outcome: Outcome
    var acknowledgedIdempotencyKeys: Set<String>
    var serverRevision: Int
    var receivedAt: Date = Date()
    var roundTripMilliseconds: Int = 0
    var detail: String? = nil
}

/// Receipt-to-journal acknowledgement is kept pure so response-loss and partial-ack semantics can
/// be fixture-tested without a live Worker or the HouseholdSync singleton.
nonisolated enum HouseholdAcknowledgement {
    static func operationIDs(captured: [PendingHouseholdOperation],
                             receipt: HouseholdSyncReceipt) -> Set<UUID> {
        switch receipt.outcome {
        case .rejected:
            return []
        case .acknowledged where receipt.acknowledgedIdempotencyKeys.isEmpty:
            // Legacy Worker/full-state acknowledgement.
            return Set(captured.map(\.id))
        case .acknowledged, .partial:
            return Set(captured.compactMap {
                receipt.acknowledgedIdempotencyKeys.contains($0.idempotencyKey) ? $0.id : nil
            })
        }
    }
}

nonisolated enum HouseholdSyncHealth: String, Codable, Sendable {
    case healthy, syncing, degraded, stalled, neverSynced
}

nonisolated enum HouseholdAutomaticSyncDecision: Equatable, Sendable {
    case push, pull, wait
}

/// Pure launch/poll timing policy so persisted backoff behavior can be tested without clocks or
/// network calls. Manual sync intentionally remains outside this policy.
nonisolated enum HouseholdAutomaticSyncPolicy {
    static func decision(hasPendingOperations: Bool, retryIsAllowed: Bool,
                         serverImposedPause: Bool) -> HouseholdAutomaticSyncDecision {
        if serverImposedPause && !retryIsAllowed { return .wait }
        if hasPendingOperations && retryIsAllowed { return .push }
        return .pull
    }
}

/// Snapshot of sync health, persisted so diagnostics survive relaunch.
nonisolated struct HouseholdSyncStatus: Codable, Sendable, Equatable {
    var lastSuccessfulPush: Date? = nil
    var lastSuccessfulPull: Date? = nil
    var pendingOperationCount: Int = 0
    var lastError: String? = nil
    var activeRoute: HouseholdSyncRoute? = nil
    var lastCompletedRoute: HouseholdSyncRoute? = nil
    var hasStuckOperations: Bool = false          // #6 an op has failed 8+ times; surface to user
    var nextRetryAllowedAt: Date? = nil           // persisted exponential-backoff gate
    var backoffIsServerImposed: Bool = false      // 429/quota pauses survive relaunch/reconnect
    var lastServerRevision: Int = 0               // monotonic Worker document revision
    var checkpoint = HouseholdSyncCheckpoint()
    var receipts: [HouseholdSyncReceipt] = []
    var recordRevisions: [String: HouseholdRecordRevision] = [:]
    var nextClientSequence: UInt64 = 1
    var consecutiveFailureCount: Int = 0
    var lastRoundTripMilliseconds: Int? = nil

    var health: HouseholdSyncHealth {
        if activeRoute != nil && lastError == nil && pendingOperationCount > 0 { return .syncing }
        if hasStuckOperations { return .stalled }
        if receipts.last?.outcome == .partial && pendingOperationCount > 0 { return .degraded }
        if lastError != nil || consecutiveFailureCount > 0 { return .degraded }
        if lastSuccessfulPush == nil && lastSuccessfulPull == nil { return .neverSynced }
        return .healthy
    }

    private enum CodingKeys: String, CodingKey {
        case lastSuccessfulPush, lastSuccessfulPull, pendingOperationCount, lastError,
             activeRoute, lastCompletedRoute, hasStuckOperations, nextRetryAllowedAt,
             backoffIsServerImposed, lastServerRevision,
             checkpoint, receipts, recordRevisions, nextClientSequence,
             consecutiveFailureCount, lastRoundTripMilliseconds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSuccessfulPush = try c.decodeIfPresent(Date.self, forKey: .lastSuccessfulPush)
        lastSuccessfulPull = try c.decodeIfPresent(Date.self, forKey: .lastSuccessfulPull)
        pendingOperationCount = try c.decodeIfPresent(Int.self, forKey: .pendingOperationCount) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        activeRoute = try c.decodeIfPresent(HouseholdSyncRoute.self, forKey: .activeRoute)
        // Pre-contract builds left activeRoute persisted after completion. Treat that legacy
        // value as diagnostic history, never as evidence that relaunch resumed an in-flight call.
        lastCompletedRoute = try c.decodeIfPresent(HouseholdSyncRoute.self, forKey: .lastCompletedRoute)
            ?? activeRoute
        activeRoute = nil
        hasStuckOperations = try c.decodeIfPresent(Bool.self, forKey: .hasStuckOperations) ?? false
        nextRetryAllowedAt = try c.decodeIfPresent(Date.self, forKey: .nextRetryAllowedAt)
        backoffIsServerImposed = try c.decodeIfPresent(Bool.self, forKey: .backoffIsServerImposed) ?? false
        lastServerRevision = try c.decodeIfPresent(Int.self, forKey: .lastServerRevision) ?? 0
        checkpoint = try c.decodeIfPresent(HouseholdSyncCheckpoint.self, forKey: .checkpoint)
            ?? HouseholdSyncCheckpoint(serverRevision: lastServerRevision)
        receipts = try c.decodeIfPresent([HouseholdSyncReceipt].self, forKey: .receipts) ?? []
        recordRevisions = try c.decodeIfPresent([String: HouseholdRecordRevision].self,
                                                forKey: .recordRevisions) ?? [:]
        nextClientSequence = try c.decodeIfPresent(UInt64.self, forKey: .nextClientSequence) ?? 1
        consecutiveFailureCount = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailureCount) ?? 0
        lastRoundTripMilliseconds = try c.decodeIfPresent(Int.self, forKey: .lastRoundTripMilliseconds)
    }
}


/// Durable deletion state. A tombstone is removed only after the exact captured push that
/// included it is acknowledged, so an offline delete cannot resurrect after app relaunch.
nonisolated struct HouseholdTombstoneState: Codable, Sendable, Equatable {
    var inventory: Set<String> = []
    var grocery: Set<String> = []
    var userRecipes: Set<String> = []
    var generatedRecipes: Set<String> = []
    var plannedMeals: Set<String> = []
    var revision: UInt64 = 0
    var deletedAt: [String: Date] = [:]

    init(inventory: Set<String> = [], grocery: Set<String> = [],
         userRecipes: Set<String> = [], generatedRecipes: Set<String> = [],
         plannedMeals: Set<String> = [], revision: UInt64 = 0,
         deletedAt: [String: Date] = [:]) {
        self.inventory = inventory
        self.grocery = grocery
        self.userRecipes = userRecipes
        self.generatedRecipes = generatedRecipes
        self.plannedMeals = plannedMeals
        self.revision = revision
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case inventory, grocery, userRecipes, generatedRecipes, plannedMeals, revision, deletedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inventory = try c.decodeIfPresent(Set<String>.self, forKey: .inventory) ?? []
        grocery = try c.decodeIfPresent(Set<String>.self, forKey: .grocery) ?? []
        userRecipes = try c.decodeIfPresent(Set<String>.self, forKey: .userRecipes) ?? []
        generatedRecipes = try c.decodeIfPresent(Set<String>.self, forKey: .generatedRecipes) ?? []
        plannedMeals = try c.decodeIfPresent(Set<String>.self, forKey: .plannedMeals) ?? []
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        deletedAt = try c.decodeIfPresent([String: Date].self, forKey: .deletedAt) ?? [:]
    }
}

// MARK: - Conflict Review (sync plan Drop 5, Option B: safety net over LWW)
// When a pull is about to overwrite a local item or recipe that still has an unsynced local
// edit queued, and the incoming remote version differs, we do NOT silently apply last-write-
// wins. Instead we capture both sides here and let the user choose in a review sheet. This
// catches the painful case (your just-made edit clobbered) without a full revision system.

nonisolated struct HouseholdConflict: Identifiable, Sendable {
    var id: UUID                          // the entity id in conflict
    var entityType: HouseholdEntityType
    var mineTitle: String                 // human label for the local version
    var theirsTitle: String               // human label for the remote version
    var mineDetail: String                // short summary of the local version
    var theirsDetail: String              // short summary of the remote version
    var mineJSON: Data                     // encoded local version (for restore-on-keep-mine)
    var theirsJSON: Data                   // encoded remote version (for use-theirs)
    var isRemoteDeletion: Bool = false     // #8 the other side DELETED this while I edited it
}
