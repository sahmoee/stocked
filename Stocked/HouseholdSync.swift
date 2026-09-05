// HouseholdSync.swift — Worker-backed household sync (replaces CloudKit CKShare).
//
// WHY THIS EXISTS: the CloudKit CKShare approach produced unreliable "share not found"
// errors — share URLs would rot, and regenerating a code from the host didn't recover. This
// client instead uses the Stocked Cloudflare Worker as the single source of truth: a household
// is one JSON document stored under its short code, and members push/pull the whole document.
// No per-device share URLs, no CloudKit account coupling.
//
// Mirrors the surface HouseholdCloudKit exposed so the existing 12 household screens work with
// minimal changes: state, joinCode, createHousehold(), joinByCode(), leaveHousehold(),
// syncNow(), fetchActivity(), fetchMembers(), logActivity(), myDisplayName.

import Foundation
import Observation
import os
import UIKit

/// The JSON graph is immutable while boxed. Foundation's `[String: Any]` cannot express
/// Sendable, so this narrowly-scoped wrapper lets expensive serialization run off MainActor.
nonisolated private struct HouseholdJSONBox: @unchecked Sendable {
    let value: [String: Any]
}

@MainActor
@Observable
final class HouseholdSync {
    static let shared = HouseholdSync()
    private static let accessSnapshotKey = "hh_member_access_v1"
    private init() {
        switch UserDefaults.standard.string(forKey: "hh_role") {
        case "owner":  state = .owner
        case "member": state = .member
        default:       state = .idle
        }
        joinCode = UserDefaults.standard.string(forKey: "hh_code")
        restorePersistedAccess()
        loadQueue()
    }

    // MARK: - Observable state (matches the old manager so views compile)

    enum State: Equatable { case idle, creating, owner, member, syncing }
    private(set) var state: State = .idle

    /// The current device's access level in the household, for gating UI actions. Refreshed
    /// whenever members are fetched. Owner is always .owner; a plain member defaults to .adult
    /// until the owner assigns a level. Views can read HouseholdSync.shared.myAccessRole and its
    /// permission flags (canAdd/canEdit/canRemove) to show or disable controls.
    var myAccessRole: HouseholdMember.Role = .owner
    // #4 My effective permissions (role default, overridden per-member by the owner). The Add
    // Item gate and any edit/remove gating read these so overrides are honored, not just the role.
    var myCanAdd: Bool = true
    var myCanEdit: Bool = true
    var myCanRemove: Bool = true
    private(set) var myPermissions: Set<HouseholdPermission> = Set(HouseholdPermission.allCases)
    private(set) var lastError: String?
    private(set) var joinCode: String?

    private func applyAccessSnapshot(_ snapshot: HouseholdMemberAccessSnapshot) {
        myAccessRole = snapshot.role
        myPermissions = snapshot.permissions
        myCanAdd = snapshot.canAdd
        myCanEdit = snapshot.canEdit
        myCanRemove = snapshot.canRemove
    }

    private func persistCurrentAccess() {
        guard state == .owner || state == .member else { return }
        let snapshot = HouseholdMemberAccessSnapshot(
            role: myAccessRole, permissions: myPermissions,
            canAdd: myCanAdd, canEdit: myCanEdit, canRemove: myCanRemove)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.accessSnapshotKey)
        }
    }

    /// Restore capabilities before GuestDataStore can accept a local mutation. A legacy member
    /// without a snapshot is view-only until a verified member list arrives; owners/solo users
    /// retain full access.
    private func restorePersistedAccess() {
        switch state {
        case .owner:
            applyAccessSnapshot(.owner)
        case .member:
            let decoded = UserDefaults.standard.data(forKey: Self.accessSnapshotKey)
                .flatMap { try? JSONDecoder().decode(HouseholdMemberAccessSnapshot.self, from: $0) }
            if let decoded, decoded.role != .owner {
                applyAccessSnapshot(decoded)
            } else {
                applyAccessSnapshot(.restrictedMember)
            }
        default:
            applyAccessSnapshot(.owner)
            UserDefaults.standard.removeObject(forKey: Self.accessSnapshotKey)
        }
    }

    // MARK: - Durable operation queue (sync plan Drop 1)
    // Every household-bound local mutation enqueues an operation, persisted through
    // LocalDatabase immediately so offline edits survive relaunch. The Worker push sends full
    // state, so ONE successful push satisfies the entire queue; the queue exists for
    // durability, retry, and diagnostics — not payload transport.

    private(set) var pendingOps: [PendingHouseholdOperation] = []
    private(set) var syncStatus = HouseholdSyncStatus()

    // Conflicts detected during a pull, awaiting user review. Observable so the settings badge
    // and review sheet update live. Populated only on the pull path (see applyHousehold), because
    // the push path has already reconciled through the server.
    private(set) var pendingConflicts: [HouseholdConflict] = []
    // Set true only while applying a PULL (not a push response), so applyHousehold knows to
    // divert clobbering overwrites of locally-edited entities into pendingConflicts.
    private var detectConflictsOnApply = false
    // #1 changed-since: the newest household updatedAt we've applied, sent on each pull so the
    // server can answer "unchanged" cheaply. Lets us poll fast for near-instant sync.
    private var lastAppliedUpdatedAt: Double = 0

    private func loadQueue() {
        pendingOps = LocalDatabase.shared.loadArray(PendingHouseholdOperation.self,
                                                    key: DBKey.householdOpQueue.rawValue) ?? []
        syncStatus = LocalDatabase.shared.load(HouseholdSyncStatus.self,
                                               key: DBKey.householdSyncStatus.rawValue) ?? HouseholdSyncStatus()
        // v1 queue entries decode with sequence zero. Repair them once in stable creation order
        // without changing their ids/idempotency keys, so a request replay remains the same op.
        var nextSequence = max(syncStatus.nextClientSequence, 1)
        for index in pendingOps.indices.sorted(by: { pendingOps[$0].createdAt < pendingOps[$1].createdAt }) {
            if pendingOps[index].clientSequence == 0 {
                pendingOps[index].clientSequence = nextSequence
                nextSequence &+= 1
            } else {
                nextSequence = max(nextSequence, pendingOps[index].clientSequence &+ 1)
            }
        }
        syncStatus.nextClientSequence = nextSequence
        syncStatus.pendingOperationCount = pendingOps.count
        nextRetryAllowedAt = syncStatus.nextRetryAllowedAt ?? .distantPast
        backoffIsServerImposed = syncStatus.backoffIsServerImposed
        persistQueue()
    }
    private func persistQueue() {
        LocalDatabase.shared.save(pendingOps, key: DBKey.householdOpQueue.rawValue)
        syncStatus.pendingOperationCount = pendingOps.count
        LocalDatabase.shared.save(syncStatus, key: DBKey.householdSyncStatus.rawValue)
    }

    /// Record a household-bound mutation. Dedupes per entity: a newer operation on the same
    /// entity replaces the older one (an update superseded by a delete keeps the delete; a
    /// re-create after delete keeps the create). No-op when not in a household.
    func enqueue(entityID: UUID, entityType: HouseholdEntityType,
                 operation: HouseholdOperationType,
                 changedFields: Set<String> = ["*"]) {
        guard state == .owner || state == .member else { return }
        pendingOps = HouseholdOperationJournal.retaining(pendingOps, replacingWith: [
            .init(entityID: entityID, entityType: entityType, operationType: operation)
        ])
        let revision = advanceRecordRevision(entityID: entityID, entityType: entityType,
                                             changedFields: changedFields)
        pendingOps.append(makePendingOperation(entityID: entityID, entityType: entityType,
                                               operation: operation, revision: revision))
        persistQueue()
    }

    /// Record an additive quantity intent alongside the absolute snapshot operation. A Worker
    /// that understands protocol v2 applies unique deltas against the common base; a v1 Worker
    /// safely ignores this additive field and continues using the absolute quantity.
    func enqueueQuantityDelta(entityID: UUID, entityType: HouseholdEntityType,
                              delta: Int, baseValue: Int? = nil) {
        guard state == .owner || state == .member, delta != 0,
              entityType == .inventoryItem || entityType == .groceryItem else { return }
        let revision = advanceRecordRevision(entityID: entityID, entityType: entityType,
                                             changedFields: ["quantity"])
        let quantity = HouseholdQuantityOperation(
            entityID: entityID, entityType: entityType, delta: delta, baseValue: baseValue,
            baseRecordRevision: revision.record > 0 ? revision.record - 1 : 0,
            actorID: memberId)
        pendingOps.append(makePendingOperation(
            id: quantity.id, entityID: entityID, entityType: entityType, operation: .update,
            revision: revision, idempotencyKey: quantity.idempotencyKey,
            quantityOperation: quantity))
        persistQueue()
    }

    /// Batch variant: one persist for a bulk mutation (receipt import, AI assistant apply).
    func enqueueBatch(_ ops: [(id: UUID, type: HouseholdEntityType, op: HouseholdOperationType)]) {
        guard state == .owner || state == .member, !ops.isEmpty else { return }
        struct EntityKey: Hashable { let id: UUID; let type: HouseholdEntityType }
        // Last mutation wins for each entity in this batch. Filtering the durable queue once
        // avoids O(existing × batch) `removeAll` work during large receipt/recipe imports.
        var replacements: [EntityKey: HouseholdOperationType] = [:]
        replacements.reserveCapacity(ops.count)
        for operation in ops {
            replacements[EntityKey(id: operation.id, type: operation.type)] = operation.op
        }
        pendingOps = HouseholdOperationJournal.retaining(
            pendingOps,
            replacingWith: replacements.map {
                .init(entityID: $0.key.id, entityType: $0.key.type, operationType: $0.value)
            })
        pendingOps.reserveCapacity(pendingOps.count + replacements.count)
        for (key, operation) in replacements {
            let revision = advanceRecordRevision(entityID: key.id, entityType: key.type,
                                                 changedFields: ["*"])
            pendingOps.append(makePendingOperation(entityID: key.id, entityType: key.type,
                                                   operation: operation, revision: revision))
        }
        persistQueue()
    }

    private func revisionKey(entityID: UUID, entityType: HouseholdEntityType) -> String {
        "\(entityType.rawValue):\(entityID.uuidString.lowercased())"
    }

    @discardableResult
    private func advanceRecordRevision(entityID: UUID, entityType: HouseholdEntityType,
                                       changedFields: Set<String>) -> HouseholdRecordRevision {
        let key = revisionKey(entityID: entityID, entityType: entityType)
        var revision = syncStatus.recordRevisions[key] ?? HouseholdRecordRevision()
        revision.advance(changedFields: changedFields, writerID: memberId)
        syncStatus.recordRevisions[key] = revision
        return revision
    }

    private func makePendingOperation(id: UUID = UUID(), entityID: UUID,
                                      entityType: HouseholdEntityType,
                                      operation: HouseholdOperationType,
                                      revision: HouseholdRecordRevision,
                                      idempotencyKey: String? = nil,
                                      quantityOperation: HouseholdQuantityOperation? = nil)
        -> PendingHouseholdOperation {
        let sequence = syncStatus.nextClientSequence
        syncStatus.nextClientSequence &+= 1
        return PendingHouseholdOperation(
            id: id, entityID: entityID, entityType: entityType, operationType: operation,
            idempotencyKey: idempotencyKey, clientSequence: sequence,
            baseServerRevision: syncStatus.checkpoint.serverRevision,
            recordRevision: revision.record, fieldRevisions: revision.fields,
            quantityOperation: quantityOperation)
    }

    /// A push only acknowledges operations captured in that request. Mutations created while the
    /// request was in flight stay queued for the next pass instead of being silently discarded.
    private func markQueueCompleted(operationIDs: Set<UUID>, route: HouseholdSyncRoute,
                                    receipt: HouseholdSyncReceipt) {
        let completedSequence = pendingOps
            .filter { operationIDs.contains($0.id) }
            .map(\.clientSequence)
            .max() ?? 0
        pendingOps.removeAll { operationIDs.contains($0.id) }
        syncStatus.lastSuccessfulPush = Date()
        syncStatus.lastError = nil
        syncStatus.lastCompletedRoute = route
        syncStatus.activeRoute = nil
        syncStatus.consecutiveFailureCount = 0
        syncStatus.lastRoundTripMilliseconds = receipt.roundTripMilliseconds
        syncStatus.receipts.append(receipt)
        if syncStatus.receipts.count > 50 { syncStatus.receipts.removeFirst(syncStatus.receipts.count - 50) }
        syncStatus.lastServerRevision = max(syncStatus.lastServerRevision, receipt.serverRevision)
        syncStatus.checkpoint.serverRevision = max(syncStatus.checkpoint.serverRevision,
                                                   receipt.serverRevision)
        syncStatus.checkpoint.lastClientSequence = max(
            syncStatus.checkpoint.lastClientSequence, completedSequence)
        syncStatus.checkpoint.recordedAt = receipt.receivedAt
        if receipt.outcome == .partial && !pendingOps.isEmpty {
            // A partial response is progress, not transport failure, but immediately replaying
            // the remainder can spin if the server repeatedly accepts no additional keys.
            nextRetryAllowedAt = Date().addingTimeInterval(1)
            syncStatus.nextRetryAllowedAt = nextRetryAllowedAt
            backoffIsServerImposed = false
            syncStatus.backoffIsServerImposed = false
        } else {
            nextRetryAllowedAt = .distantPast
            backoffIsServerImposed = false
            syncStatus.nextRetryAllowedAt = nil
            syncStatus.backoffIsServerImposed = false
        }
        syncStatus.hasStuckOperations = pendingOps.contains { $0.retryCount >= 8 }
        persistQueue()
    }
    private func markQueueFailed(_ message: String, failure: StockedServiceError?,
                                 operationIDs: Set<UUID>) {
        // Only work serialized into this request failed. Mutations enqueued while it was in
        // flight were never sent and must not inherit retry count, error, or stuck status.
        pendingOps = HouseholdOperationJournal.markingFailure(
            pendingOps, operationIDs: operationIDs, message: message)
        syncStatus.lastError = message
        syncStatus.consecutiveFailureCount += 1
        syncStatus.activeRoute = nil
        // Persisted exponential backoff with jitter. Honor server Retry-After, and pause longer
        // after a KV quota response so a client loop cannot keep spending the remaining quota.
        let maxRetry = pendingOps.map(\.retryCount).max() ?? 0
        let exponential = min(pow(2.0, Double(maxRetry)), 300)
        let serverDelay: TimeInterval
        switch failure {
        case .rateLimited(let retryAfter): serverDelay = retryAfter ?? 60
        case .quotaExhausted: serverDelay = 60 * 60
        default: serverDelay = exponential
        }
        let jitter = Double.random(in: 0.8...1.2)
        // RL-008: mark server-imposed pauses so a reconnect doesn't clear them (see
        // noteConnectivityRestored).
        switch failure {
        case .rateLimited, .quotaExhausted: backoffIsServerImposed = true
        default: backoffIsServerImposed = false
        }
        syncStatus.backoffIsServerImposed = backoffIsServerImposed
        nextRetryAllowedAt = Date().addingTimeInterval(NetworkRetryPolicy.queueDelay(
            exponential: exponential, serverMinimum: serverDelay,
            serverImposed: backoffIsServerImposed, jitter: jitter))
        syncStatus.nextRetryAllowedAt = nextRetryAllowedAt
        syncStatus.hasStuckOperations = pendingOps.contains { $0.retryCount >= 8 }
        persistQueue()
    }
    // #6 backoff gate: the poller checks this before attempting a push.
    private var nextRetryAllowedAt: Date = .distantPast
    var retryIsAllowed: Bool { Date() >= nextRetryAllowedAt }
    // RL-008: remember whether the current backoff was a server-imposed pause (quota /
    // rate limit). A network reconnect resets transport backoff — the failures were the
    // dead connection's fault — but must NOT reset a server pause, or a flapping network
    // could burn the remaining KV quota.
    @ObservationIgnored private var backoffIsServerImposed = false

    /// RL-008: called by OfflineQueueCenter on an offline→online transition. Clears the
    /// persisted transport backoff so recovery is immediate, leaving server-imposed pauses
    /// (quota, 429) intact.
    func noteConnectivityRestored() {
        guard !backoffIsServerImposed else { return }
        nextRetryAllowedAt = .distantPast
        syncStatus.nextRetryAllowedAt = nil
        syncStatus.backoffIsServerImposed = false
        LocalDatabase.shared.save(syncStatus, key: DBKey.householdSyncStatus.rawValue)
    }

    /// RL-008: one coalesced recovery pass after reconnect. syncNow is single-flight and
    /// only acknowledges the operations captured in its request, so calling this alongside
    /// the poller can never duplicate or drop work.
    func reconnectSync() async {
        guard let store = pollStore, state == .owner || state == .member else { return }
        if pendingOps.isEmpty {
            await pullNow(into: store)
        } else if retryIsAllowed {
            await syncNow(store: store)
        }
    }

    /// RL-008: replay a queued one-shot mutation (see OfflineQueueCenter). Same transport
    /// as every other household call; returns success so the queue knows whether to drain.
    func replayPost(_ path: String, _ body: [String: Any]) async -> Bool {
        await post(path, body) != nil
    }
    private func markPullSucceeded(route: HouseholdSyncRoute) {
        syncStatus.lastSuccessfulPull = Date()
        syncStatus.lastCompletedRoute = route
        syncStatus.activeRoute = nil
        syncStatus.lastError = nil
        syncStatus.consecutiveFailureCount = 0
        LocalDatabase.shared.save(syncStatus, key: DBKey.householdSyncStatus.rawValue)
    }

    enum SyncStage: Equatable {
        case checkingAccount, creating, joining, findingZone
        case uploading(Int), downloading(Int)
        case done(invAdded: Int, groAdded: Int)
        case failed(String)
        var isTerminal: Bool {
            if case .done = self { return true }
            if case .failed = self { return true }
            return false
        }
    }
    private(set) var syncStage: SyncStage? = nil
    private(set) var isRepairingHouseholdStorage = false
    func clearStage() { syncStage = nil }

    /// Display name used for attribution and the member list. Set from the app.
    var myDisplayName: String {
        get { UserDefaults.standard.string(forKey: "hh_my_name") ?? "You" }
        set { UserDefaults.standard.set(newValue.isEmpty ? "You" : newValue, forKey: "hh_my_name") }
    }

    /// Stable per-install identity. Two devices (or two guests) could share the same display
    /// name — "You", "Chef", or two people both called Jess — so the server must dedupe members
    /// by THIS id, not the name. Generated once per install and persisted; never changes.
    var memberId: String {
        if let existing = UserDefaults.standard.string(forKey: "hh_member_id"), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "hh_member_id")
        return fresh
    }

    /// Resolve a usable, non-generic display name to send to the server. Prefers an explicitly
    /// set name, then the device name (e.g. "Jess's iPad"), and only falls back to "Member" if
    /// somehow both are empty. This is what stops every unnamed device from showing up as "You".
    private func resolvedName() -> String {
        let saved = (UserDefaults.standard.string(forKey: "hh_my_name") ?? "").trimmingCharacters(in: .whitespaces)
        if !saved.isEmpty && saved != "You" { return saved }
        // Previously fell back to UIDevice.current.name, which returns "iPhone" on iOS 16+
        // (Apple no longer exposes the user-set device name to apps), so members showed as
        // "iPhone". The app now feeds the real profile name via updateDisplayName(_:) before
        // creating/joining, so a device-name fallback is no longer used. If somehow still
        // unset, "Member" is a neutral placeholder rather than a misleading device name.
        return "Member"
    }

    /// Whether the user has set a custom household display name themselves. Once true, the
    /// auto-sync from the profile name (updateDisplayName) stops overwriting it.
    var nameIsCustom: Bool {
        get { UserDefaults.standard.bool(forKey: "hh_name_custom") }
        set { UserDefaults.standard.set(newValue, forKey: "hh_name_custom") }
    }

    // ── Selective sync (#2): which data categories this device shares/receives. Default ON. ──
    private func syncFlag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
    var syncInventory: Bool { get { syncFlag("hh_sync_inv") } set { UserDefaults.standard.set(newValue, forKey: "hh_sync_inv") } }
    var syncGrocery:   Bool { get { syncFlag("hh_sync_gro") } set { UserDefaults.standard.set(newValue, forKey: "hh_sync_gro") } }
    var syncRecipes:   Bool { get { syncFlag("hh_sync_rec") } set { UserDefaults.standard.set(newValue, forKey: "hh_sync_rec") } }
    var syncMealPlans: Bool { get { syncFlag("hh_sync_mp")  } set { UserDefaults.standard.set(newValue, forKey: "hh_sync_mp")  } }

    // ── Household name (#3): shared name for the whole household. Persists locally and, once the
    // user sets it, rides along on push so every device sees it (LWW among members who set one). ──
    var householdName: String {
        get { UserDefaults.standard.string(forKey: "hh_display_name") ?? "My Stocked. Kitchen" }
        set { UserDefaults.standard.set(newValue, forKey: "hh_display_name") }
    }
    var householdNameIsCustom: Bool {
        get { UserDefaults.standard.bool(forKey: "hh_display_name_custom") }
        set { UserDefaults.standard.set(newValue, forKey: "hh_display_name_custom") }
    }
    /// Save + sync the household name. Marks it custom so it rides on the next push and sticks.
    func setHouseholdName(_ name: String, store: GuestDataStore? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, authorize(.manageHousehold) else { return }
        householdName = trimmed
        householdNameIsCustom = true
        if state == .owner || state == .member {
            // One stable synthetic entity makes the shared name part of the same relaunch-safe
            // journal as the snapshot it rides in, without creating a second control queue.
            enqueue(entityID: UUID(uuidString: "4D3A7047-A782-4D91-8EE2-9B7621783F15")!,
                    entityType: .featureData, operation: .update,
                    changedFields: ["householdName"])
            if let store { Task { await syncNow(store: store) } }
        }
    }

    /// Called by the app (from AppSession) whenever the user's profile name is known or changes.
    /// Updates the local display name and, if already in a household, propagates the rename to the
    /// server so every device and the Daily Brief see the new name. Skips when the user has
    /// explicitly chosen a household-specific name (see setMyName).
    func updateDisplayName(_ name: String, store: GuestDataStore? = nil) {
        guard !nameIsCustom else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "chef", trimmed != "You" else { return }
        propagateName(trimmed, store: store)
    }

    /// User explicitly sets THEIR OWN household display name (Settings → Your Name). Marks it
    /// custom (so the profile name won't clobber it), persists it, and syncs it to every device +
    /// the Daily Brief / activity feed via the setname endpoint.
    func setMyName(_ name: String, store: GuestDataStore? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        nameIsCustom = true
        propagateName(trimmed, store: store)
    }

    /// Shared rename path: set local name + push the rename to the server, then pull so the
    /// member list / attribution reflect it immediately.
    private func propagateName(_ trimmed: String, store: GuestDataStore?) {
        let previous = myDisplayName
        myDisplayName = trimmed
        guard previous != trimmed, state == .owner || state == .member,
              let code = joinCode, !code.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.post("/household/setname", ["code": code, "actorId": self.memberId, "memberId": self.memberId, "name": trimmed])
            if let store { await self.pullNow(into: store) }
        }
    }

    private func persist() {
        switch state {
        case .owner:  UserDefaults.standard.set("owner", forKey: "hh_role")
        case .member: UserDefaults.standard.set("member", forKey: "hh_role")
        case .idle:   UserDefaults.standard.removeObject(forKey: "hh_role")
        default: break
        }
        UserDefaults.standard.set(joinCode, forKey: "hh_code")
    }

    // MARK: - Public API (used by the household screens)

    /// Create a new household on the Worker. Returns true on success; joinCode is then set.
    @discardableResult
    func createHousehold() async -> Bool {
        syncStage = .creating
        state = .creating
        // Use the profile name the app already set (via updateDisplayName / the household views).
        // Only fall back to resolvedName() when nothing usable is set, so we never overwrite a
        // real name with a placeholder.
        let current = myDisplayName.trimmingCharacters(in: .whitespaces)
        if current.isEmpty || current == "You" { myDisplayName = resolvedName() }
        let body: [String: Any] = [
            "ownerName": myDisplayName, "memberId": memberId,
            "syncProtocolVersion": 2,
            "capabilities": HouseholdPermission.allCases.map(\.rawValue),
        ]
        guard let resp = await post("/household/create", body) else {
            fail("Couldn't create a household. Check your connection and try again.")
            return false
        }
        guard let code = resp["code"] as? String else {
            fail("The server didn't return a household code.")
            return false
        }
        joinCode = code
        state = .owner
        applyAccessSnapshot(.owner)
        persistCurrentAccess()
        persist()
        if let hh = resp["household"] as? [String: Any] { await applyHousehold(hh, into: nil) }
        syncStage = .done(invAdded: 0, groAdded: 0)
        lastError = nil
        // Begin automatic incoming sync for the owner too. pollStore was cached at app launch;
        // if present, start the poller now so the owner receives members' changes this session
        // without waiting for a relaunch.
        if let store = pollStore { startAutoSync(store: store) }
        return true
    }

    /// Mint a fresh invite code for the current household (owner action). The old code stops
    /// working; existing members stay in the household. Returns the new code on success.
    @discardableResult
    func regenerateCode() async -> Bool {
        guard let code = joinCode, state == .owner else {
            fail("Only the household owner can regenerate the code.")
            return false
        }
        guard let resp = await post("/household/regenerate", [
            "code": code, "actorId": memberId, "syncProtocolVersion": 2,
            "requestId": UUID().uuidString.lowercased(),
        ]),
              let newCode = resp["code"] as? String else {
            fail("Couldn't regenerate the code. Check your connection and try again.")
            return false
        }
        joinCode = newCode
        persist()
        lastError = nil
        return true
    }

    /// Join an existing household by code. Pulls its current snapshot into the local store.
    @discardableResult
    func joinByCode(_ rawCode: String, into store: GuestDataStore) async -> Bool {
        let code = HouseholdSync.normalize(rawCode)
        guard code.count == 8 else {
            fail("That doesn't look like a valid 8 character code.")
            return false
        }
        syncStage = .joining
        myDisplayName = resolvedName()   // never join as "You"
        let body: [String: Any] = [
            "code": code, "memberName": myDisplayName, "memberId": memberId,
            "syncProtocolVersion": 2,
            "capabilities": HouseholdPermission.allCases.map(\.rawValue),
        ]
        guard let resp = await post("/household/join", body) else {
            fail("Couldn't find a household with that code.")
            return false
        }
        guard (resp["ok"] as? Bool) == true, let hh = resp["household"] as? [String: Any] else {
            fail("Couldn't find a household with that code.")
            return false
        }
        joinCode = code
        state = .member
        // Never carry solo/full permissions across the transition into a household. The member
        // response refresh replaces this fail-closed snapshot once the server identifies us.
        applyAccessSnapshot(.restrictedMember)
        persistCurrentAccess()
        persist()
        let counts = await applyHousehold(hh, into: store)
        syncStage = .done(invAdded: counts.inv, groAdded: counts.gro)
        lastError = nil
        startAutoSync(store: store)   // begin automatic incoming sync
        return true
    }

    // MARK: - Automatic incoming sync (polling)

    @ObservationIgnored private var pollTask: Task<Void, Never>? = nil
    @ObservationIgnored private var deferredSyncTask: Task<Void, Never>? = nil
    @ObservationIgnored private weak var pollStore: GuestDataStore? = nil

    /// Pull the latest household snapshot and merge it in, without pushing. Cheap; used by the
    /// auto-sync poller and on foreground so changes made elsewhere appear on their own.
    func pullNow(into store: GuestDataStore) async {
        guard let code = joinCode, state == .owner || state == .member else { return }
        // #1 changed-since: send the last updatedAt we applied; the server returns a tiny
        // "unchanged" reply when nothing is new, so frequent polling stays cheap.
        syncStatus.activeRoute = .workerPull
        persistQueue()
        let pullBody: [String: Any] = [
            "code": code, "since": lastAppliedUpdatedAt,
            "sinceRevision": syncStatus.checkpoint.serverRevision,
            "memberId": memberId, "memberName": myDisplayName,
            "syncProtocolVersion": 2,
            "checkpoint": checkpointDict(syncStatus.checkpoint),
        ]
        guard let resp = await post("/household/pull", pullBody) else {
            syncStatus.lastError = lastPostFailure?.localizedDescription ?? "Household pull failed."
            syncStatus.consecutiveFailureCount += 1
            syncStatus.activeRoute = nil
            persistQueue()
            return
        }
        if (resp["unchanged"] as? Bool) == true {
            advanceCheckpoint(response: resp, household: nil)
            markPullSucceeded(route: .workerPull); return
        }
        guard let hh = resp["household"] as? [String: Any] else {
            syncStatus.lastError = "The household server returned an incomplete pull response."
            syncStatus.consecutiveFailureCount += 1
            syncStatus.activeRoute = nil
            persistQueue()
            return
        }
        detectConflictsOnApply = true          // pull path: guard local unsynced edits
        _ = await applyHousehold(hh, into: store)
        detectConflictsOnApply = false
        if let u = hh["updatedAt"] as? Double { lastAppliedUpdatedAt = u }
        advanceCheckpoint(response: resp, household: hh)
        markPullSucceeded(route: .workerPull)
    }

    /// Start a background poll so household changes from other members appear automatically,
    /// no manual sync needed. Safe to call repeatedly (it restarts a single task). Call on app
    /// launch / foreground once a household exists.
    func startAutoSync(store: GuestDataStore, everySeconds: UInt64 = 6) {
        pollStore = store
        // RL-008: the offline queue center needs the connectivity monitors running and a
        // chance to flush relaunch-surviving work. Activate before the household guard so
        // reconnect recovery works even for devices not in a household.
        OfflineQueueCenter.shared.activate()
        pollTask?.cancel()
        deferredSyncTask?.cancel()
        deferredSyncTask = nil
        guard state == .owner || state == .member else { return }
        // Relaunch-surviving work is pushed immediately only when its persisted retry gate allows
        // it. Keep the kick task retained so background/leave can cancel it.
        if HouseholdAutomaticSyncPolicy.decision(
            hasPendingOperations: !pendingOps.isEmpty,
            retryIsAllowed: retryIsAllowed,
            serverImposedPause: backoffIsServerImposed) == .push {
            deferredSyncTask = Task { @MainActor [weak self, weak store] in
                await Task.yield()
                guard !Task.isCancelled, let self, let store else { return }
                self.deferredSyncTask = nil
                guard self.retryIsAllowed else { return }
                await self.syncNow(store: store)
            }
        }
        pollTask = Task { @MainActor [weak self, weak store] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: everySeconds * 1_000_000_000)
                guard let self, let store else { return }
                guard self.state == .owner || self.state == .member else { continue }
                // Pending local ops → push (which also pulls the merged state back).
                // Clean queue → lightweight pull only.
                switch HouseholdAutomaticSyncPolicy.decision(
                    hasPendingOperations: !self.pendingOps.isEmpty,
                    retryIsAllowed: self.retryIsAllowed,
                    serverImposedPause: self.backoffIsServerImposed) {
                case .pull:
                    await self.pullNow(into: store)
                case .push:
                    await self.syncNow(store: store)
                case .wait:
                    continue
                }
            }
        }
    }
    func stopAutoSync() {
        pollTask?.cancel(); pollTask = nil
        deferredSyncTask?.cancel(); deferredSyncTask = nil
        fgTask?.cancel(); fgTask = nil
    }
    @ObservationIgnored private var fgTask: Task<Void, Never>? = nil
    /// Pull immediately (e.g. on foreground), then let the poller continue.
    func syncOnForeground() {
        guard let store = pollStore, state == .owner || state == .member else { return }
        fgTask?.cancel()
        fgTask = Task { [weak self, weak store] in
            guard let self, let store else { return }
            await self.pullNow(into: store)
        }
    }
    /// #18 Pause polling when the app backgrounds (no orphaned network loop); resume on foreground.
    func pauseAutoSync() {
        pollTask?.cancel(); pollTask = nil
        deferredSyncTask?.cancel(); deferredSyncTask = nil
        fgTask?.cancel(); fgTask = nil
    }
    func resumeAutoSync() {
        guard let store = pollStore, pollTask == nil, state == .owner || state == .member else { return }
        startAutoSync(store: store)
    }

    @ObservationIgnored private var syncInFlight = false
    @ObservationIgnored private var syncRequestedWhileInFlight = false

    /// Manual two-way sync for an existing owner/member: push local collaborative data, pull merged.
    /// Single-flight prevents overlapping poll/foreground/manual pushes from acknowledging edits
    /// that were not present in the request body.
    func syncNow(store: GuestDataStore) async {
        guard let code = joinCode, state == .owner || state == .member else { return }
        if syncInFlight {
            syncRequestedWhileInFlight = true
            return
        }
        deferredSyncTask?.cancel()
        deferredSyncTask = nil
        syncInFlight = true
        defer {
            syncInFlight = false
            // Remaining journal work is owned by the normal poll/reconnect loop. Only a sync
            // explicitly requested while this call was in flight gets a deferred continuation.
            // This prevents failure/partial receipts from self-spawning an unbounded retry loop.
            let shouldContinue = syncRequestedWhileInFlight
            syncRequestedWhileInFlight = false
            if shouldContinue && !Task.isCancelled {
                let remainingDelay = max(0, nextRetryAllowedAt.timeIntervalSinceNow)
                deferredSyncTask?.cancel()
                deferredSyncTask = Task { @MainActor [weak self, weak store] in
                    if remainingDelay > 0 {
                        let nanoseconds = UInt64(min(remainingDelay, 60 * 60) * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: nanoseconds)
                        guard !Task.isCancelled else { return }
                    }
                    guard let self, let store else { return }
                    self.deferredSyncTask = nil
                    guard self.retryIsAllowed else { return }
                    await self.syncNow(store: store)
                }
            }
        }

        let capturedOps = pendingOps
        let capturedOperationIDs = Set(capturedOps.map(\.id))
        let capturedTombstones = store.householdTombstoneSnapshot()
        let requestID = UUID()
        let requestStartedAt = Date()
        syncStatus.activeRoute = .workerPush
        persistQueue()
        syncStage = .uploading(store.groceryItems.count)
        // #2 — only include the categories the user chose to share. Omitted categories aren't
        // merged server-side, so this device keeps that data private to itself.
        var body: [String: Any] = [
            "code": code, "actorId": memberId,
            "requestId": requestID.uuidString.lowercased(),
            "syncProtocolVersion": 2,
            "checkpoint": checkpointDict(syncStatus.checkpoint),
            "operations": capturedOps.map(operationDict),
            "quantityOperations": capturedOps.compactMap(\.quantityOperation).map(quantityOperationDict),
            "tombstoneRevision": capturedTombstones.revision,
            "tombstoneDeletedAt": capturedTombstones.deletedAt.mapValues {
                $0.timeIntervalSince1970 * 1_000
            },
        ]
        if syncGrocery {
            body["grocery"] = store.groceryItems.map { groceryDict($0) }
            body["groDeleted"] = Array(capturedTombstones.grocery)
        }
        if syncInventory {
            body["inventory"] = store.inventoryItems.map { inventoryDict($0) }
            body["invDeleted"] = Array(capturedTombstones.inventory)
        }
        if syncRecipes {
            // Household-private recipes are user data, not public catalogue candidates. Text-only
            // recipes are complete collaborative records and must never be filtered by imagery.
            body["userRecipes"] = store.userRecipes.map { userRecipeDict($0) }
            body["genRecipes"] = store.savedGeneratedRecipes.map { genRecipeDict($0) }
            body["userRecipeDeleted"] = Array(capturedTombstones.userRecipes)
            body["genRecipeDeleted"] = Array(capturedTombstones.generatedRecipes)
        }
        if syncMealPlans {
            body["plannedMeals"] = store.plannedMeals.map { plannedMealDict($0) }
            body["mealDeleted"] = Array(capturedTombstones.plannedMeals)
        }
        // #3 — carry the household name so it syncs, but only once this user has set one
        // (avoids a member who never renamed it clobbering the owner's name with the default).
        if householdNameIsCustom { body["householdName"] = householdName }
        // Launch readiness 1.4 — the feature collections (leftovers, family, events, shared
        // costs, store layouts, harvests, labels, takeout) ride the same push. Gated on the
        // inventory toggle: they're all kitchen-contents data, and a user who opted their
        // inventory out of sharing has clearly opted this out too.
        let capturedFeatureTombstones = FeatureSync.shared.tombstoneSnapshot()
        if syncInventory {
            body.merge(FeatureSync.shared.pushPayload()) { _, new in new }
        }
        // Fit the Worker's body limit before sending. Over it the server answers 413 and
        // nothing syncs at all — not the recipe carrying the big photo, the entire kitchen.
        // The Mac shed pictures to stay under; the phone did not, so a phone that had
        // collected a dozen photographed recipes could stop syncing groceries.
        body = await HouseholdSync.trimmedForPush(body)

        guard let resp = await post("/household/push", body),
              let hh = resp["household"] as? [String: Any] else {
            let message = lastPostFailure?.localizedDescription
                ?? "Sync didn't finish. Check your connection and try again."
            fail(message)
            markQueueFailed(message, failure: lastPostFailure, operationIDs: capturedOperationIDs)
            return
        }

        let receipt = syncReceipt(from: resp, household: hh, requestID: requestID,
                                  captured: capturedOps, startedAt: requestStartedAt)
        if receipt.outcome == .rejected {
            let message = receipt.detail ?? "The household server rejected this sync batch."
            fail(message)
            markQueueFailed(message, failure: nil, operationIDs: capturedOperationIDs)
            return
        }
        let acknowledgedIDs = HouseholdAcknowledgement.operationIDs(captured: capturedOps,
                                                                     receipt: receipt)
        let fullyAcknowledged = receipt.outcome == .acknowledged
            && acknowledgedIDs == capturedOperationIDs
        if fullyAcknowledged {
            store.acknowledgeHouseholdTombstones(capturedTombstones)
            FeatureSync.shared.acknowledgeTombstones(capturedFeatureTombstones)   // 1.4
        }
        markQueueCompleted(operationIDs: acknowledgedIDs, route: .workerPush, receipt: receipt)
        let counts = await applyHousehold(hh, into: store)
        if let updated = hh["updatedAt"] as? Double { lastAppliedUpdatedAt = updated }
        advanceCheckpoint(response: resp, household: hh)
        markPullSucceeded(route: .workerPush)
        syncStage = .done(invAdded: counts.inv, groAdded: counts.gro)
        lastError = nil
    }

    /// Leave the household (members) or tear it down (owner if last member).
    func leaveHousehold() {
        guard let code = joinCode else { resetLocal(); return }
        let name = myDisplayName
        let mid = memberId
        Task { _ = await post("/household/leave", [
            "code": code, "memberName": name, "memberId": mid, "actorId": mid,
            "requestId": UUID().uuidString.lowercased(),
        ]) }
        resetLocal()
    }

    /// Remove another member through the same server-enforced leave endpoint. The Worker checks
    /// `manageMembers`, protects the owner, and treats a repeated request as idempotent.
    @discardableResult
    func removeMember(memberId targetId: String) async -> Bool {
        guard let code = joinCode, targetId != memberId,
              state == .owner || state == .member, can(.manageMembers) else {
            fail("You don't have permission to remove that household member.")
            return false
        }
        let body: [String: Any] = [
            "code": code, "actorId": memberId, "memberId": memberId,
            "targetMemberId": targetId, "requestId": UUID().uuidString.lowercased(),
        ]
        guard let response = await post("/household/leave", body),
              (response["ok"] as? Bool) == true else {
            fail("Couldn't remove that member. Check your connection and try again.")
            return false
        }
        lastError = nil
        return true
    }

    private func resetLocal() {
        stopAutoSync()          // #18 cancel the polling task so it can't run after leaving
        state = .idle
        joinCode = nil
        applyAccessSnapshot(.owner)
        UserDefaults.standard.removeObject(forKey: "hh_role")
        UserDefaults.standard.removeObject(forKey: "hh_code")
        UserDefaults.standard.removeObject(forKey: Self.accessSnapshotKey)
    }

    // MARK: - Activity + members (for the feed and member screens)

    func logActivity(_ kind: HouseholdActivity.Kind, itemName: String) async {
        guard PrivacyControlCenter.shared.allowHouseholdActivity,
              let code = joinCode, state == .owner || state == .member else { return }
        // RL-008: each event carries a stable eventId + its ORIGINAL timestamp, so a replay
        // of a request whose response was lost merges as the same event, never a duplicate,
        // and an offline edit keeps its true time in the feed after reconnect.
        let event: [String: Any] = [
            "eventId": UUID().uuidString,
            "kind": kind.rawValue, "itemName": itemName,
            "actorName": myDisplayName, "date": Date().timeIntervalSince1970 * 1000,
        ]
        let body: [String: Any] = ["code": code, "activity": [event]]
        // Push a single activity event (server merges + caps). Previously fire-and-forget —
        // an offline edit's feed entry just vanished. Now a failed post lands in the durable
        // offline queue and replays on reconnect (RL-008: never silently discard local work).
        if await post("/household/push", body) == nil {
            OfflineQueueCenter.shared.enqueueWorkerMutation(kind: "activity",
                                                            path: "/household/push",
                                                            body: body)
        }
    }

    /// Announces recipes arriving from the shared Stocked Mac catalogue. Every recipe
    /// uses a deterministic event id, so multiple household devices ingesting the same
    /// Worker response converge on one feed row instead of producing one row per phone.
    func logStockedMacImports(_ recipes: [(id: UUID, title: String, importedAt: Date)]) async {
        guard PrivacyControlCenter.shared.allowHouseholdActivity,
              let code = joinCode, state == .owner || state == .member, !recipes.isEmpty else { return }
        let activity: [[String: Any]] = recipes.map { recipe in
            [
                "eventId": "stocked-mac-recipe-\(recipe.id.uuidString.lowercased())",
                "kind": HouseholdActivity.Kind.recipeImported.rawValue,
                "itemName": recipe.title,
                "actorName": "Stocked Mac",
                "date": recipe.importedAt.timeIntervalSince1970 * 1000,
            ]
        }
        let body: [String: Any] = ["code": code, "activity": activity]
        if await post("/household/push", body) == nil {
            OfflineQueueCenter.shared.enqueueWorkerMutation(kind: "activity",
                                                            path: "/household/push",
                                                            body: body)
        }
    }

    /// #3 Fire-and-forget activity emit for use from store didSets. No-op outside a household.
    /// Coalesced lightly: only emits when in a household and not applying a remote snapshot.
    func emitActivity(_ kind: HouseholdActivity.Kind, itemName: String) {
        guard PrivacyControlCenter.shared.allowHouseholdActivity,
              state == .owner || state == .member else { return }
        Task { await logActivity(kind, itemName: itemName) }
    }

    func fetchActivity(limit: Int = 50) async -> [HouseholdActivity] {
        guard let code = joinCode, state == .owner || state == .member else { return [] }
        guard let resp = await post("/household/pull", ["code": code]),
              let hh = resp["household"] as? [String: Any],
              let raw = hh["activity"] as? [[String: Any]] else { return [] }
        return raw.compactMap { parseActivity($0) }.prefix(limit).map { $0 }
    }

    private func members(from household: [String: Any]) -> [HouseholdMember]? {
        guard let raw = household["members"] as? [[String: Any]] else { return nil }
        let ownerName = household["ownerName"] as? String
        let ownerId = household["ownerId"] as? String
        let myId = memberId
        return raw.map { member in
            let name = (member["name"] as? String) ?? "Member"
            let mid = (member["memberId"] as? String) ?? name
            let joined = (member["joinedAt"] as? Double).map {
                Date(timeIntervalSince1970: $0 / 1000)
            }
            let isOwner = (ownerId != nil) ? (mid == ownerId) : (name == ownerName)
            let storedRole = (member["role"] as? String).flatMap(HouseholdMember.Role.init(rawValue:))
            let role: HouseholdMember.Role = isOwner ? .owner : (storedRole ?? .adult)
            let customLabel = (member["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let permissionGrants = (member["permissions"] as? [String]).map {
                Set($0.compactMap(HouseholdPermission.init(rawValue:)))
            }
            let permissionDenials = Set(
                ((member["deniedPermissions"] as? [String]) ?? [])
                    .compactMap(HouseholdPermission.init(rawValue:)))
            return HouseholdMember(
                id: mid, name: name, role: role, customLabel: customLabel,
                overrideCanAdd: member["overrideCanAdd"] as? Bool,
                overrideCanEdit: member["overrideCanEdit"] as? Bool,
                overrideCanRemove: member["overrideCanRemove"] as? Bool,
                permissionGrants: permissionGrants, permissionDenials: permissionDenials,
                joinedAt: joined, isMe: mid == myId)
        }
    }

    func fetchMembers() async -> [HouseholdMember] {
        guard let code = joinCode, state == .owner || state == .member else { return [] }
        guard let resp = await post("/household/pull", ["code": code]),
              let hh = resp["household"] as? [String: Any],
              let mapped = members(from: hh) else {
            // An offline/error fallback is display-only. Never replace the last server-verified
            // member snapshot with permissive role defaults just because the pull failed.
            let solo = [HouseholdMember(id: "me", name: myDisplayName,
                                        role: state == .owner ? .owner : myAccessRole,
                                        joinedAt: nil, isMe: true)]
            return solo
        }
        refreshMyAccessRole(from: mapped)
        return mapped
    }

    /// Privileged action: set a member's access level and optional custom label. The client gate
    /// mirrors the permission sent to the Worker; the Worker remains the enforcement boundary.
    @discardableResult
    func setMemberRole(memberId targetId: String, role: HouseholdMember.Role, label: String?,
                       overrideCanAdd: Bool? = nil, overrideCanEdit: Bool? = nil,
                       overrideCanRemove: Bool? = nil,
                       permissionGrants: Set<HouseholdPermission>? = nil,
                       permissionDenials: Set<HouseholdPermission> = []) async -> Bool {
        guard let code = joinCode, state == .owner || state == .member,
              can(.manageMembers) else {
            fail("You don't have permission to manage household members.")
            return false
        }
        var body: [String: Any] = ["code": code, "memberId": targetId, "role": role.rawValue,
                                   "actorId": memberId]
        if let label { body["label"] = label }
        // #4 send explicit overrides; a JSON null clears an override back to the role default.
        body["overrideCanAdd"]    = overrideCanAdd    as Any? ?? NSNull()
        body["overrideCanEdit"]   = overrideCanEdit   as Any? ?? NSNull()
        body["overrideCanRemove"] = overrideCanRemove as Any? ?? NSNull()
        if let permissionGrants {
            body["permissions"] = permissionGrants.map(\.rawValue).sorted()
        }
        if !permissionDenials.isEmpty {
            body["deniedPermissions"] = permissionDenials.map(\.rawValue).sorted()
        }
        guard let resp = await post("/household/setrole", body),
              (resp["ok"] as? Bool) == true else {
            fail("Couldn't update that member. Check your connection and try again.")
            return false
        }
        lastError = nil
        return true
    }

    /// The current device's own role in the household, derived from the member list. Used to gate
    /// what actions the UI offers. Owner is always .owner; otherwise read the stored role.
    func myRole(from members: [HouseholdMember]) -> HouseholdMember.Role {
        if state == .owner { return .owner }
        return members.first(where: { $0.isMe })?.role ?? .adult
    }

    func can(_ permission: HouseholdPermission) -> Bool {
        guard state == .owner || state == .member else { return true }
        return myPermissions.contains(permission)
    }

    /// Mutation-boundary authorization with one consistent, observable failure path. The Worker
    /// still enforces the same permission server-side; this keeps denied local edits from briefly
    /// appearing, being journaled, and then bouncing back after sync.
    @discardableResult
    func authorize(_ permission: HouseholdPermission) -> Bool {
        guard can(permission) else {
            fail("You don't have permission to make that household change.")
            return false
        }
        return true
    }

    /// Refresh the cached myAccessRole from a member list (called after fetchMembers).
    private func refreshMyAccessRole(from members: [HouseholdMember]) {
        // Not in a household → treat as owner (full access) so solo use is never restricted.
        guard state == .owner || state == .member else {
            applyAccessSnapshot(.owner)
            UserDefaults.standard.removeObject(forKey: Self.accessSnapshotKey)
            return
        }
        if state == .owner {
            applyAccessSnapshot(.owner)
            persistCurrentAccess()
            return
        }
        // Missing `me` is not evidence that access was broadened. Preserve the prior snapshot
        // until a complete member response explicitly identifies this device.
        guard let me = members.first(where: { $0.isMe }) else { return }
        applyAccessSnapshot(HouseholdMemberAccessSnapshot(
            role: me.role, permissions: me.effectivePermissions,
            canAdd: me.effectiveCanAdd, canEdit: me.effectiveCanEdit,
            canRemove: me.effectiveCanRemove))
        persistCurrentAccess()
    }

    // MARK: - Networking

    @ObservationIgnored private var lastPostFailure: StockedServiceError? = nil

    private func post(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        lastPostFailure = nil
        guard !Task.isCancelled else { lastPostFailure = .cancelled; return nil }
        guard let url = URL(string: BuildConfig.receiptWorkerURL + path) else {
            lastPostFailure = .notConfigured("Household sync")
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&request)
        request.timeoutInterval = 12
        let boxedBody = HouseholdJSONBox(value: body)
        guard let encoded = await Task.detached(priority: .utility, operation: {
            try? JSONSerialization.data(withJSONObject: boxedBody.value)
        }).value else {
            lastPostFailure = .invalidRequest("Household sync couldn't encode the local snapshot.")
            return nil
        }
        request.httpBody = encoded
        let repairDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]
        defer { isRepairingHouseholdStorage = false }
        for attempt in 0...repairDelays.count {
          do {
            try Task.checkCancellation()
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                lastPostFailure = .malformedResponse("Household sync returned no HTTP response.")
                return nil
            }
            let responseBox = await Task.detached(priority: .utility) { () -> HouseholdJSONBox? in
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
                return HouseholdJSONBox(value: object)
            }.value
            try Task.checkCancellation()
            let object = responseBox?.value
            guard (200...299).contains(http.statusCode) else {
                let detail = object?["error"] as? String
                let code = object?["code"] as? String
                if code == "householdCrash" || (http.statusCode == 503 && code != "kvQuota") {
                    if attempt < repairDelays.count {
                        isRepairingHouseholdStorage = true
                        lastError = "Repairing household storage…"
                        try await Task.sleep(for: repairDelays[attempt])
                        continue
                    }
                    lastPostFailure = .transport(detail ?? "Household storage repair couldn't finish. Sync will retry automatically.")
                } else if code == "kvQuota" {
                    lastPostFailure = .quotaExhausted(detail ?? "Household sync storage is temporarily unavailable.")
                } else if http.statusCode == 429 {
                    let retry = NetworkRetryPolicy.retryAfterSeconds(http.value(forHTTPHeaderField: "Retry-After"))
                    lastPostFailure = .rateLimited(retryAfter: retry)
                } else {
                    lastPostFailure = .httpStatus(http.statusCode, detail)
                }
                Log.transfer.error("Household \(path, privacy: .public) HTTP \(http.statusCode)")
                return nil
            }
            guard let object else {
                lastPostFailure = .malformedResponse("Household sync returned an unreadable response. Local changes remain queued.")
                return nil
            }
            lastError = nil
            return object
        } catch is CancellationError {
            lastPostFailure = .cancelled
            return nil
        } catch {
            lastPostFailure = Task.isCancelled || (error as? URLError)?.code == .cancelled
                ? .cancelled : .transport(error.localizedDescription)
            return nil
          }
        }
        return nil
    }

    private func fail(_ message: String) {
        lastError = message
        syncStage = .failed(message)
    }

    // MARK: - Durable protocol v2 wire contracts

    private func checkpointDict(_ checkpoint: HouseholdSyncCheckpoint) -> [String: Any] {
        var value: [String: Any] = [
            "protocolVersion": checkpoint.protocolVersion,
            "serverRevision": checkpoint.serverRevision,
            "collectionRevisions": checkpoint.collectionRevisions,
            "lastClientSequence": checkpoint.lastClientSequence,
            "recordedAt": checkpoint.recordedAt.timeIntervalSince1970 * 1_000,
        ]
        if let cursor = checkpoint.cursor { value["cursor"] = cursor }
        return value
    }

    private func operationDict(_ operation: PendingHouseholdOperation) -> [String: Any] {
        var value: [String: Any] = [
            "operationId": operation.id.uuidString.lowercased(),
            "idempotencyKey": operation.idempotencyKey,
            "entityId": operation.entityID.uuidString.lowercased(),
            "entityType": operation.entityType.rawValue,
            "operationType": operation.operationType.rawValue,
            "createdAt": operation.createdAt.timeIntervalSince1970 * 1_000,
            "clientSequence": operation.clientSequence,
            "baseServerRevision": operation.baseServerRevision,
            "recordRevision": operation.recordRevision,
            "fieldRevisions": operation.fieldRevisions,
        ]
        if let payload = operation.payloadJSON { value["payload"] = payload.base64EncodedString() }
        return value
    }

    private func quantityOperationDict(_ operation: HouseholdQuantityOperation) -> [String: Any] {
        var value: [String: Any] = [
            "operationId": operation.id.uuidString.lowercased(),
            "idempotencyKey": operation.idempotencyKey,
            "entityId": operation.entityID.uuidString.lowercased(),
            "entityType": operation.entityType.rawValue,
            "delta": operation.delta,
            "baseRecordRevision": operation.baseRecordRevision,
            "actorId": operation.actorID,
            "createdAt": operation.createdAt.timeIntervalSince1970 * 1_000,
        ]
        if let base = operation.baseValue { value["baseValue"] = base }
        return value
    }

    private func syncReceipt(from response: [String: Any], household: [String: Any],
                             requestID: UUID, captured: [PendingHouseholdOperation],
                             startedAt: Date) -> HouseholdSyncReceipt {
        let raw = response["receipt"] as? [String: Any]
        let rawOutcome = raw?["outcome"] as? String
        let outcome = rawOutcome.flatMap(HouseholdSyncReceipt.Outcome.init(rawValue:))
            ?? .acknowledged
        let acknowledged = (raw?["acknowledgedIdempotencyKeys"] as? [String])
            ?? (raw?["acknowledgedOperations"] as? [String])
            ?? (raw == nil ? captured.map(\.idempotencyKey) : [])
        let revision = (raw?["serverRevision"] as? NSNumber)?.intValue
            ?? (response["revision"] as? NSNumber)?.intValue
            ?? (household["revision"] as? NSNumber)?.intValue
            ?? syncStatus.lastServerRevision
        let id = (raw?["receiptId"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        return HouseholdSyncReceipt(
            id: id, requestID: requestID, outcome: outcome,
            acknowledgedIdempotencyKeys: Set(acknowledged), serverRevision: revision,
            receivedAt: Date(),
            roundTripMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
            detail: raw?["detail"] as? String)
    }

    private func advanceCheckpoint(response: [String: Any], household: [String: Any]?) {
        let raw = (response["checkpoint"] as? [String: Any])
            ?? (household?["checkpoint"] as? [String: Any])
        let revision = (raw?["serverRevision"] as? NSNumber)?.intValue
            ?? (response["revision"] as? NSNumber)?.intValue
            ?? (household?["revision"] as? NSNumber)?.intValue
            ?? syncStatus.lastServerRevision
        syncStatus.lastServerRevision = max(syncStatus.lastServerRevision, revision)
        syncStatus.checkpoint.serverRevision = max(syncStatus.checkpoint.serverRevision, revision)
        if let cursor = raw?["cursor"] as? String { syncStatus.checkpoint.cursor = cursor }
        if let revisions = raw?["collectionRevisions"] as? [String: NSNumber] {
            for (key, value) in revisions {
                syncStatus.checkpoint.collectionRevisions[key] = max(
                    syncStatus.checkpoint.collectionRevisions[key] ?? 0, value.intValue)
            }
        }
        syncStatus.checkpoint.recordedAt = Date()
        persistQueue()
    }

    private func revisionMetadata(entityID: UUID,
                                  entityType: HouseholdEntityType) -> [String: Any] {
        let revision = syncStatus.recordRevisions[
            revisionKey(entityID: entityID, entityType: entityType)
        ] ?? HouseholdRecordRevision()
        return [
            "recordRevision": revision.record,
            "fieldRevisions": revision.fields,
            "serverCheckpoint": revision.serverCheckpoint,
        ]
    }

    private func adoptRevisionMetadata(_ dictionary: [String: Any], entityID: UUID,
                                       entityType: HouseholdEntityType) {
        let record = (dictionary["recordRevision"] as? NSNumber)?.uint64Value ?? 0
        let rawFields = dictionary["fieldRevisions"] as? [String: NSNumber] ?? [:]
        let fields = rawFields.mapValues(\.uint64Value)
        guard record > 0 || !fields.isEmpty else { return }
        let remote = HouseholdRecordRevision(
            record: record, fields: fields,
            serverCheckpoint: (dictionary["serverCheckpoint"] as? NSNumber)?.intValue ?? 0,
            writerID: (dictionary["lastWriterID"] as? String) ?? "",
            updatedAt: Date(timeIntervalSince1970:
                ((dictionary["updatedAt"] as? Double) ?? 0) / 1_000))
        let key = revisionKey(entityID: entityID, entityType: entityType)
        syncStatus.recordRevisions[key] = (syncStatus.recordRevisions[key]
            ?? HouseholdRecordRevision()).merged(with: remote)
    }

    // MARK: - Mapping between the household document and local models

    private func inventoryDict(_ item: LocalInventoryItem) -> [String: Any] {
        var value: [String: Any] = [
            "id": item.id.uuidString, "name": item.name, "quantity": item.quantity,
            "zone": item.zone, "level": item.effectiveLevel, "brand": item.brand ?? "",
            "updatedAt": item.updatedAt, "lastWriterID": item.lastWriterID,
        ]
        value.merge(revisionMetadata(entityID: item.id, entityType: .inventoryItem)) { _, new in new }
        return value
    }
    private func groceryDict(_ item: LocalGroceryItem) -> [String: Any] {
        var value: [String: Any] = [
            "id": item.id.uuidString, "name": item.name, "quantity": item.quantity,
            "isChecked": item.isChecked, "recipeSource": item.recipeSource,
            "addedByName": item.addedByName, "updatedAt": item.updatedAt,
            "lastWriterID": item.lastWriterID,
            "assignedTo": item.assignedTo, "sizeText": item.sizeText,
        ]
        value.merge(revisionMetadata(entityID: item.id, entityType: .groceryItem)) { _, new in new }
        return value
    }
    private func parseGrocery(_ d: [String: Any]) -> LocalGroceryItem? {
        guard let name = d["name"] as? String, !name.isEmpty else { return nil }
        var item = LocalGroceryItem(name: name, isChecked: (d["isChecked"] as? Bool) ?? false)
        if let idStr = d["id"] as? String, let uuid = UUID(uuidString: idStr) { item.id = uuid }
        item.quantity = (d["quantity"] as? Int) ?? 1
        item.recipeSource = (d["recipeSource"] as? String) ?? ""
        item.addedByName = (d["addedByName"] as? String) ?? ""
        item.assignedTo = (d["assignedTo"] as? String) ?? ""
        item.sizeText = (d["sizeText"] as? String) ?? ""
        item.updatedAt = (d["updatedAt"] as? Double) ?? 0
        item.lastWriterID = (d["lastWriterID"] as? String) ?? ""
        return item
    }
    private func parseInventory(_ d: [String: Any]) -> LocalInventoryItem? {
        guard let name = d["name"] as? String, !name.isEmpty else { return nil }
        let zone = (d["zone"] as? String) ?? "Pantry"
        var item = LocalInventoryItem(name: name, level: (d["level"] as? Double) ?? 1.0,
                                      zone: zone, quantity: (d["quantity"] as? Int) ?? 1)
        if let idStr = d["id"] as? String, let uuid = UUID(uuidString: idStr) { item.id = uuid }
        if let brand = d["brand"] as? String, !brand.isEmpty { item.brand = brand }
        item.storageCategory = StorageCategory(rawValue: zone) ?? .pantry
        item.updatedAt = (d["updatedAt"] as? Double) ?? 0
        item.lastWriterID = (d["lastWriterID"] as? String) ?? ""
        return item
    }

    // Recipes are complex Codable structs transported as their JSON object. #2: recipe images are
    // now included so the whole household sees the photo, but capped so one huge image can't bloat
    // the shared document — anything over the cap is dropped from the synced copy (stays local).
    private static let maxSyncedImageBytes = 200_000   // ~200 KB per recipe image

    /// The whole push body has to fit the Worker's 2 MB limit, or the server answers 413 and
    /// nothing syncs — see `MAX_BODY` in the Worker's household route. Kept under it with
    /// headroom for the fields added after this check runs.
    nonisolated private static let maxPushBodyBytes = 1_700_000

    /// Sheds `imageData` from the largest recipes until the encoded body fits.
    ///
    /// Recipes keep their `imageURL`, so a device that receives a stripped record still
    /// shows the picture — it just loads it from the web rather than out of the payload.
    /// Nothing is ever dropped: only pictures come off, never recipes. Mirrors
    /// `MacHouseholdSync.trimmedForPush` so both ends degrade the same way.
    nonisolated private static func trimmedForPush(_ body: [String: Any]) async -> [String: Any] {
        let boxed = HouseholdJSONBox(value: body)
        let result = await Task.detached(priority: .utility) { () -> HouseholdJSONBox in
            func size(_ value: [String: Any]) -> Int {
                (try? JSONSerialization.data(withJSONObject: value))?.count ?? 0
            }
            guard size(boxed.value) > maxPushBodyBytes else { return boxed }

            var trimmed = boxed.value
            for key in ["genRecipes", "userRecipes"] {
                guard var rows = trimmed[key] as? [[String: Any]] else { continue }
                let order = rows.indices.sorted {
                    ((rows[$0]["imageData"] as? String)?.count ?? 0)
                        > ((rows[$1]["imageData"] as? String)?.count ?? 0)
                }
                for index in order {
                    guard size(trimmed) > maxPushBodyBytes else { break }
                    guard rows[index]["imageData"] != nil else { continue }
                    rows[index]["imageData"] = nil
                    trimmed[key] = rows
                }
                trimmed[key] = rows
                if size(trimmed) <= maxPushBodyBytes { break }
            }
            return HouseholdJSONBox(value: trimmed)
        }.value
        return result.value
    }

    private func userRecipeDict(_ r: UserRecipe) -> [String: Any] {
        var x = r
        if let d = x.imageData, d.count > Self.maxSyncedImageBytes { x.imageData = nil }
        guard let data = try? JSONEncoder().encode(x),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ["id": r.id.uuidString, "title": r.title, "updatedAt": r.updatedAt, "lastWriterID": r.lastWriterID]
        }
        obj["updatedAt"] = r.updatedAt
        obj["lastWriterID"] = r.lastWriterID
        obj.merge(revisionMetadata(entityID: r.id, entityType: .userRecipe)) { _, new in new }
        return obj
    }
    private func parseUserRecipe(_ d: [String: Any]) -> UserRecipe? {
        guard let data = try? JSONSerialization.data(withJSONObject: d),
              var r = try? JSONDecoder().decode(UserRecipe.self, from: data) else { return nil }
        r.updatedAt = (d["updatedAt"] as? Double) ?? 0
        r.lastWriterID = (d["lastWriterID"] as? String) ?? ""
        return r
    }
    private func genRecipeDict(_ r: GeneratedRecipe) -> [String: Any] {
        var x = r
        if let d = x.imageData, d.count > Self.maxSyncedImageBytes { x.imageData = nil }
        guard let data = try? JSONEncoder().encode(x),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ["id": r.id.uuidString, "title": r.title, "updatedAt": r.updatedAt, "lastWriterID": r.lastWriterID]
        }
        obj["updatedAt"] = r.updatedAt
        obj["lastWriterID"] = r.lastWriterID
        obj.merge(revisionMetadata(entityID: r.id, entityType: .generatedRecipe)) { _, new in new }
        return obj
    }
    private func parseGenRecipe(_ d: [String: Any]) -> GeneratedRecipe? {
        guard let data = try? JSONSerialization.data(withJSONObject: d),
              var r = try? JSONDecoder().decode(GeneratedRecipe.self, from: data) else { return nil }
        r.updatedAt = (d["updatedAt"] as? Double) ?? 0
        r.lastWriterID = (d["lastWriterID"] as? String) ?? ""
        return r
    }
    private func plannedMealDict(_ m: PlannedMeal) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(m),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ["id": m.id.uuidString, "title": m.title, "updatedAt": m.updatedAt, "lastWriterID": m.lastWriterID]
        }
        obj["updatedAt"] = m.updatedAt
        obj["lastWriterID"] = m.lastWriterID
        obj.merge(revisionMetadata(entityID: m.id, entityType: .plannedMeal)) { _, new in new }
        return obj
    }
    private func parsePlannedMeal(_ d: [String: Any]) -> PlannedMeal? {
        guard let data = try? JSONSerialization.data(withJSONObject: d),
              var m = try? JSONDecoder().decode(PlannedMeal.self, from: data) else { return nil }
        m.updatedAt = (d["updatedAt"] as? Double) ?? 0
        m.lastWriterID = (d["lastWriterID"] as? String) ?? ""
        return m
    }
    private func parseActivity(_ d: [String: Any]) -> HouseholdActivity? {
        guard let kindRaw = d["kind"] as? String,
              let kind = HouseholdActivity.Kind(rawValue: kindRaw) else { return nil }
        let dateMs = (d["date"] as? Double) ?? (Date().timeIntervalSince1970 * 1000)
        return HouseholdActivity(
            kind: kind,
            itemName: (d["itemName"] as? String) ?? "",
            actorName: (d["actorName"] as? String) ?? "Someone",
            date: Date(timeIntervalSince1970: dateMs / 1000))
    }

    /// Merge a household document's grocery (and inventory for members) into the local store.
    /// Returns how many items were added so the sync prompt can report progress.
    @discardableResult
    private func applyHousehold(_ hh: [String: Any], into store: GuestDataStore?) async -> (inv: Int, gro: Int) {
        if let members = members(from: hh) { refreshMyAccessRole(from: members) }
        guard let store else { return (0, 0) }
        // Suppress the store's own household push while we write remote data in, so applying a
        // pulled snapshot doesn't immediately echo back out as another push (sync loop).
        store.isApplyingHouseholdRemote = true
        defer { store.isApplyingHouseholdRemote = false }

        // Server-side tombstones: ids that were deleted somewhere in the household. Drop them
        // locally too so a delete on one device propagates to the others.
        //
        // Local pending tombstones are unioned in: a delete made on THIS device has
        // not reached the server yet, so the snapshot coming back still contains the
        // row. Without this union the pull cheerfully restores what the user just
        // swiped away — the grocery resurrection bug, arriving by a third route.
        let invTombstones = Set((hh["invDeleted"] as? [String]) ?? [])
            .union(store.pendingInvTombstones)
        let groTombstones = Set((hh["groDeleted"] as? [String]) ?? [])
            .union(store.pendingGroTombstones)

        // Ids with an unsynced local edit queued. On a pull, an incoming DIFFERENT version of one
        // of these is a conflict (your edit vs someone else's), diverted for review rather than
        // silently overwritten. Empty on the push path, so pushes always apply straight through.
        let lockedIDs: Set<UUID> = detectConflictsOnApply ? Set(pendingOps.map { $0.entityID }) : []

        // #3 — adopt the household's shared name when the server has one and we haven't set our own.
        if let remoteName = (hh["name"] as? String)?.trimmingCharacters(in: .whitespaces),
           !remoteName.isEmpty, !householdNameIsCustom, householdName != remoteName {
            householdName = remoteName
        }

        var groAdded = 0
        if syncGrocery, let groRaw = hh["grocery"] as? [[String: Any]] {
            for dictionary in groRaw {
                if let rawID = dictionary["id"] as? String, let id = UUID(uuidString: rawID) {
                    adoptRevisionMetadata(dictionary, entityID: id, entityType: .groceryItem)
                }
            }
            let remote = groRaw.compactMap { parseGrocery($0) }
            var byID = Dictionary(keepingLastValues: store.groceryItems.map { ($0.id, $0) })
            for r in remote {
                if let local = byID[r.id] {
                    if lockedIDs.contains(r.id) && r.updatedAt != local.updatedAt {
                        recordGroceryConflict(mine: local, theirs: r)   // divert, keep local for now
                    } else if HouseholdMergePolicy.remoteWins(remoteUpdatedAt: r.updatedAt, remoteWriterID: r.lastWriterID, localUpdatedAt: local.updatedAt, localWriterID: local.lastWriterID) {
                        // G7 — audit a silent LWW overwrite (self-guards when names match).
                        SyncConflictLog.shared.record(entityType: "Grocery", entityName: local.name,
                                                      replaced: local.name, winning: r.name, writer: r.lastWriterID)
                        byID[r.id] = r   // newer wins
                    }
                } else if !groTombstones.contains(r.id.uuidString) {
                    byID[r.id] = r; groAdded += 1
                }
            }
            // Apply deletions.
            for id in byID.keys where groTombstones.contains(id.uuidString) {
                if lockedIDs.contains(id), let mine = byID[id] {
                    recordGroceryDeleteConflict(mine: mine)   // #8 their delete vs my edit
                } else { byID[id] = nil }
            }
            let merged = Array(byID.values)
            if merged != store.groceryItems { store.groceryItems = merged }
        }

        // Inventory: last-write-wins by updatedAt, honoring tombstones. Adds, edits (quantity,
        // title, zone), and removals all converge this way.
        var invAdded = 0
        if syncInventory, let invRaw = hh["inventory"] as? [[String: Any]] {
            for dictionary in invRaw {
                if let rawID = dictionary["id"] as? String, let id = UUID(uuidString: rawID) {
                    adoptRevisionMetadata(dictionary, entityID: id, entityType: .inventoryItem)
                }
            }
            let remote = invRaw.compactMap { parseInventory($0) }
            var byID = Dictionary(keepingLastValues: store.inventoryItems.map { ($0.id, $0) })
            for r in remote {
                if let local = byID[r.id] {
                    if lockedIDs.contains(r.id) && r.updatedAt != local.updatedAt {
                        recordInventoryConflict(mine: local, theirs: r)
                    } else if HouseholdMergePolicy.remoteWins(remoteUpdatedAt: r.updatedAt, remoteWriterID: r.lastWriterID, localUpdatedAt: local.updatedAt, localWriterID: local.lastWriterID) {
                        // #19 — the remote wins and the local value is about to be discarded.
                        // The outcome is unchanged (last-write-wins), but a real local edit no
                        // longer disappears without a trace the user can find.
                        if local.updatedAt > 0, local != r {
                            SyncConflictLog.shared.record(
                                entityType: "Inventory",
                                entityName: local.name,
                                replaced: HouseholdSync.describe(local),
                                winning: HouseholdSync.describe(r),
                                writer: r.addedBy ?? "")
                        }
                        byID[r.id] = r
                    }
                } else if !invTombstones.contains(r.id.uuidString) {
                    byID[r.id] = r; invAdded += 1
                }
            }
            var remotelyRemoved: [LocalInventoryItem] = []
            for id in byID.keys where invTombstones.contains(id.uuidString) {
                if lockedIDs.contains(id), let mine = byID[id] {
                    recordInventoryDeleteConflict(mine: mine)
                } else {
                    if detectConflictsOnApply, let gone = byID[id] { remotelyRemoved.append(gone) }
                    byID[id] = nil
                }
            }
            let merged = Array(byID.values)
            if merged != store.inventoryItems {
                let previous = Dictionary(uniqueKeysWithValues: store.inventoryItems.map { ($0.id, $0.updatedAt) })
                store.inventoryItems = merged
                let changed = merged.filter { previous[$0.id] != $0.updatedAt }.map(\.id)
                RetailEnrichmentMaintenance.enqueueInventoryItems(ids: changed, store: store)
            }
            // #12 — undo across the household: when another member's delete lands here via a
            // pull, offer a 10s undo. Re-adding uses a FRESH id (the old id is tombstoned
            // server-side, so restoring it would just be deleted again on the next pull);
            // the new item then pushes back out to the whole household.
            if !remotelyRemoved.isEmpty {
                let count = remotelyRemoved.count
                ToastCenter.shared.undo(count == 1
                                        ? "\(remotelyRemoved[0].name) was removed by your household"
                                        : "\(count) items were removed by your household") { [weak store] in
                    guard let store else { return }
                    for old in remotelyRemoved {
                        var copy = old
                        copy.id = UUID()
                        copy.updatedAt = Date().timeIntervalSince1970 * 1000
                        copy.lastWriterID = HouseholdSync.shared.memberId
                        store.inventoryItems.append(copy)
                    }
                }
            }
        }

        // Recipes: last-write-wins by updatedAt, honoring tombstones. UserRecipe/GeneratedRecipe
        // aren't Equatable, so we track whether anything actually changed and only assign then
        // (assigning always would still be safe because the remote-apply guard blocks a push loop,
        // but this avoids needless local saves).
        let userRecipeTombstones = Set((hh["userRecipeDeleted"] as? [String]) ?? [])
        if syncRecipes, let raw = hh["userRecipes"] as? [[String: Any]] {
            for dictionary in raw {
                if let rawID = dictionary["id"] as? String, let id = UUID(uuidString: rawID) {
                    adoptRevisionMetadata(dictionary, entityID: id, entityType: .userRecipe)
                }
            }
            let remote = raw.compactMap { parseUserRecipe($0) }
            var byID = Dictionary(keepingLastValues: store.userRecipes.map { ($0.id, $0) })
            var touched = false
            for r in remote {
                if let local = byID[r.id] {
                    if lockedIDs.contains(r.id) && r.updatedAt != local.updatedAt {
                        recordUserRecipeConflict(mine: local, theirs: r)
                    } else if HouseholdMergePolicy.remoteWins(remoteUpdatedAt: r.updatedAt, remoteWriterID: r.lastWriterID, localUpdatedAt: local.updatedAt, localWriterID: local.lastWriterID) {
                        SyncConflictLog.shared.record(entityType: "Recipe", entityName: local.title,
                                                      replaced: local.title, winning: r.title, writer: r.lastWriterID)
                        byID[r.id] = r; touched = true
                    }
                } else if !userRecipeTombstones.contains(r.id.uuidString) {
                    byID[r.id] = r; touched = true
                }
            }
            for id in byID.keys where userRecipeTombstones.contains(id.uuidString) { byID[id] = nil; touched = true }
            if touched {
                store.userRecipes = Array(byID.values)
                await RecipeDatabaseManager.shared.syncHouseholdRecipes(remote)
            }
        }
        let genRecipeTombstones = Set((hh["genRecipeDeleted"] as? [String]) ?? [])
        if syncRecipes, let raw = hh["genRecipes"] as? [[String: Any]] {
            for dictionary in raw {
                if let rawID = dictionary["id"] as? String, let id = UUID(uuidString: rawID) {
                    adoptRevisionMetadata(dictionary, entityID: id, entityType: .generatedRecipe)
                }
            }
            let remote = raw.compactMap { parseGenRecipe($0) }
            var byID = Dictionary(keepingLastValues: store.savedGeneratedRecipes.map { ($0.id, $0) })
            var touched = false
            for r in remote {
                if let local = byID[r.id] {
                    if lockedIDs.contains(r.id) && r.updatedAt != local.updatedAt {
                        recordGenRecipeConflict(mine: local, theirs: r)
                    } else if HouseholdMergePolicy.remoteWins(remoteUpdatedAt: r.updatedAt, remoteWriterID: r.lastWriterID, localUpdatedAt: local.updatedAt, localWriterID: local.lastWriterID) {
                        SyncConflictLog.shared.record(entityType: "Saved recipe", entityName: local.title,
                                                      replaced: local.title, winning: r.title, writer: r.lastWriterID)
                        byID[r.id] = r; touched = true
                    }
                } else if !genRecipeTombstones.contains(r.id.uuidString) {
                    byID[r.id] = r; touched = true
                }
            }
            for id in byID.keys where genRecipeTombstones.contains(id.uuidString) { byID[id] = nil; touched = true }
            if touched { store.savedGeneratedRecipes = Array(byID.values) }
        }
        // #13 Planned meals: LWW merge honoring tombstones, same pattern as recipes.
        let mealTombstones = Set((hh["mealDeleted"] as? [String]) ?? [])
        if syncMealPlans, let raw = hh["plannedMeals"] as? [[String: Any]] {
            for dictionary in raw {
                if let rawID = dictionary["id"] as? String, let id = UUID(uuidString: rawID) {
                    adoptRevisionMetadata(dictionary, entityID: id, entityType: .plannedMeal)
                }
            }
            let remote = raw.compactMap { parsePlannedMeal($0) }
            var byID = Dictionary(keepingLastValues: store.plannedMeals.map { ($0.id, $0) })
            var touched = false
            for r in remote {
                if let local = byID[r.id] {
                    if HouseholdMergePolicy.remoteWins(remoteUpdatedAt: r.updatedAt, remoteWriterID: r.lastWriterID, localUpdatedAt: local.updatedAt, localWriterID: local.lastWriterID) {
                        // #19 — planned meals were the one collection with NO conflict check at
                        // all, so a meal you moved could be silently reverted by another device.
                        // Still last-write-wins, but no longer invisible.
                        if local.updatedAt > 0, local.title != r.title || local.dayIndex != r.dayIndex {
                            SyncConflictLog.shared.record(
                                entityType: "Planned meal",
                                entityName: local.title,
                                replaced: "\(local.title) · day \(local.dayIndex)",
                                winning: "\(r.title) · day \(r.dayIndex)")
                        }
                        byID[r.id] = r; touched = true
                    }
                } else if !mealTombstones.contains(r.id.uuidString) {
                    byID[r.id] = r; touched = true
                }
            }
            for id in byID.keys where mealTombstones.contains(id.uuidString) { byID[id] = nil; touched = true }
            if touched { store.plannedMeals = Array(byID.values) }
        }

        // Launch readiness 1.4 — merge the feature collections (leftovers, family, events, shared
        // costs, store layouts, harvests, labels, takeout) with the same per-id LWW policy.
        // Gated like the push: these travel with the inventory toggle.
        if syncInventory {
            FeatureSync.shared.apply(hh)
        }
        return (invAdded, groAdded)
    }

    // MARK: - Conflict recording + resolution (Drop 5, Option B)

    /// #19 — a short readable summary of an inventory item, for the "what was replaced" log.
    /// Deliberately the fields a user would notice changing.
    nonisolated static func describe(_ item: LocalInventoryItem) -> String {
        var parts = ["\(item.quantity)× \(item.name)"]
        parts.append(item.zone)
        if let exp = item.expirationDate {
            parts.append("exp \(exp.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }

    private func addConflict(_ c: HouseholdConflict) {
        // De-dupe by entity id: a newer pull replaces an unresolved conflict for the same item.
        pendingConflicts.removeAll { $0.id == c.id }
        pendingConflicts.append(c)
    }
    // #8 delete-vs-edit recorders. "Theirs" is a deletion, so theirsJSON is empty and the flag is set.
    private func recordInventoryDeleteConflict(mine: LocalInventoryItem) {
        guard let m = try? JSONEncoder().encode(mine) else { return }
        addConflict(HouseholdConflict(id: mine.id, entityType: .inventoryItem,
            mineTitle: mine.name, theirsTitle: "Removed by someone",
            mineDetail: "Qty \(mine.quantity) in \(mine.zone)", theirsDetail: "Deleted from the household",
            mineJSON: m, theirsJSON: Data(), isRemoteDeletion: true))
    }
    private func recordGroceryDeleteConflict(mine: LocalGroceryItem) {
        guard let m = try? JSONEncoder().encode(mine) else { return }
        addConflict(HouseholdConflict(id: mine.id, entityType: .groceryItem,
            mineTitle: mine.name, theirsTitle: "Removed by someone",
            mineDetail: "Qty \(mine.quantity)", theirsDetail: "Deleted from the household",
            mineJSON: m, theirsJSON: Data(), isRemoteDeletion: true))
    }
    private func recordInventoryConflict(mine: LocalInventoryItem, theirs: LocalInventoryItem) {
        let enc = JSONEncoder()
        guard let m = try? enc.encode(mine), let t = try? enc.encode(theirs) else { return }
        addConflict(HouseholdConflict(
            id: mine.id, entityType: .inventoryItem,
            mineTitle: mine.name, theirsTitle: theirs.name,
            mineDetail: "Qty \(mine.quantity) in \(mine.zone)",
            theirsDetail: "Qty \(theirs.quantity) in \(theirs.zone)",
            mineJSON: m, theirsJSON: t))
    }
    private func recordGroceryConflict(mine: LocalGroceryItem, theirs: LocalGroceryItem) {
        let enc = JSONEncoder()
        guard let m = try? enc.encode(mine), let t = try? enc.encode(theirs) else { return }
        addConflict(HouseholdConflict(
            id: mine.id, entityType: .groceryItem,
            mineTitle: mine.name, theirsTitle: theirs.name,
            mineDetail: "Qty \(mine.quantity)\(mine.isChecked ? ", checked" : "")",
            theirsDetail: "Qty \(theirs.quantity)\(theirs.isChecked ? ", checked" : "")",
            mineJSON: m, theirsJSON: t))
    }
    private func recordUserRecipeConflict(mine: UserRecipe, theirs: UserRecipe) {
        let enc = JSONEncoder()
        guard let m = try? enc.encode(mine), let t = try? enc.encode(theirs) else { return }
        addConflict(HouseholdConflict(
            id: mine.id, entityType: .userRecipe,
            mineTitle: mine.title, theirsTitle: theirs.title,
            mineDetail: "\(mine.ingredients.count) ingredients, \(mine.instructions.count) steps",
            theirsDetail: "\(theirs.ingredients.count) ingredients, \(theirs.instructions.count) steps",
            mineJSON: m, theirsJSON: t))
    }
    private func recordGenRecipeConflict(mine: GeneratedRecipe, theirs: GeneratedRecipe) {
        let enc = JSONEncoder()
        guard let m = try? enc.encode(mine), let t = try? enc.encode(theirs) else { return }
        addConflict(HouseholdConflict(
            id: mine.id, entityType: .generatedRecipe,
            mineTitle: mine.title, theirsTitle: theirs.title,
            mineDetail: "\(mine.ingredients.count) ingredients, \(mine.steps.count) steps",
            theirsDetail: "\(theirs.ingredients.count) ingredients, \(theirs.steps.count) steps",
            mineJSON: m, theirsJSON: t))
    }

    /// Resolve one conflict. keepMine=true re-stamps the local version so it wins on the next
    /// push; keepMine=false applies the remote version locally. Either way the conflict clears.
    func resolveConflict(_ conflict: HouseholdConflict, keepMine: Bool, store: GuestDataStore) {
        let dec = JSONDecoder()
        let now = Date().timeIntervalSince1970 * 1000
        store.isApplyingHouseholdRemote = true
        defer { store.isApplyingHouseholdRemote = false }
        // #8 deletion conflict: "use theirs" applies the delete; "keep mine" restores + re-queues.
        if conflict.isRemoteDeletion {
            if keepMine {
                enqueue(entityID: conflict.id, entityType: conflict.entityType, operation: .update)
            } else {
                switch conflict.entityType {
                case .inventoryItem: store.inventoryItems.removeAll { $0.id == conflict.id }
                case .groceryItem:   store.groceryItems.removeAll { $0.id == conflict.id }
                case .userRecipe:    store.userRecipes.removeAll { $0.id == conflict.id }
                case .generatedRecipe: store.savedGeneratedRecipes.removeAll { $0.id == conflict.id }
                default: break
                }
            }
            pendingConflicts.removeAll { $0.id == conflict.id }
            return
        }
        switch conflict.entityType {
        case .inventoryItem:
            if keepMine, var mine = try? dec.decode(LocalInventoryItem.self, from: conflict.mineJSON) {
                mine.updatedAt = now
                if let i = store.inventoryItems.firstIndex(where: { $0.id == mine.id }) { store.inventoryItems[i] = mine }
            } else if let theirs = try? dec.decode(LocalInventoryItem.self, from: conflict.theirsJSON) {
                if let i = store.inventoryItems.firstIndex(where: { $0.id == theirs.id }) { store.inventoryItems[i] = theirs }
            }
        case .groceryItem:
            if keepMine, var mine = try? dec.decode(LocalGroceryItem.self, from: conflict.mineJSON) {
                mine.updatedAt = now
                if let i = store.groceryItems.firstIndex(where: { $0.id == mine.id }) { store.groceryItems[i] = mine }
            } else if let theirs = try? dec.decode(LocalGroceryItem.self, from: conflict.theirsJSON) {
                if let i = store.groceryItems.firstIndex(where: { $0.id == theirs.id }) { store.groceryItems[i] = theirs }
            }
        case .userRecipe:
            if keepMine, var mine = try? dec.decode(UserRecipe.self, from: conflict.mineJSON) {
                mine.updatedAt = now
                if let i = store.userRecipes.firstIndex(where: { $0.id == mine.id }) { store.userRecipes[i] = mine }
            } else if let theirs = try? dec.decode(UserRecipe.self, from: conflict.theirsJSON) {
                if let i = store.userRecipes.firstIndex(where: { $0.id == theirs.id }) { store.userRecipes[i] = theirs }
            }
        case .generatedRecipe:
            if keepMine, var mine = try? dec.decode(GeneratedRecipe.self, from: conflict.mineJSON) {
                mine.updatedAt = now
                if let i = store.savedGeneratedRecipes.firstIndex(where: { $0.id == mine.id }) { store.savedGeneratedRecipes[i] = mine }
            } else if let theirs = try? dec.decode(GeneratedRecipe.self, from: conflict.theirsJSON) {
                if let i = store.savedGeneratedRecipes.firstIndex(where: { $0.id == theirs.id }) { store.savedGeneratedRecipes[i] = theirs }
            }
        default: break
        }
        pendingConflicts.removeAll { $0.id == conflict.id }
        // If keeping mine, re-queue so the next push carries the local version to the household.
        if keepMine { enqueue(entityID: conflict.id, entityType: conflict.entityType, operation: .update) }
    }
    func dismissConflict(_ conflict: HouseholdConflict) {
        pendingConflicts.removeAll { $0.id == conflict.id }
    }

    // MARK: - Code normalization (shared with the join field)

    static func normalize(_ raw: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String(raw.uppercased().filter { allowed.contains($0) })
    }
}

// MARK: - #11 Household member presence
// The worker records a lastSeen timestamp per member whenever their device polls
// (/household/pull with memberId). This fetches that map for the members screen.
extension HouseholdSync {
    /// name → seconds since that member's device last synced. Empty on any failure.
    func fetchPresence() async -> [String: TimeInterval] {
        guard let code = joinCode, state == .owner || state == .member else { return [:] }
        guard let resp = await post("/household/presence", ["code": code]),
              let raw = resp["presence"] as? [String: Any] else { return [:] }
        let now = Date().timeIntervalSince1970 * 1000
        var out: [String: TimeInterval] = [:]
        for (_, v) in raw {
            guard let entry = v as? [String: Any],
                  let name = entry["name"] as? String,
                  let ts = entry["ts"] as? Double else { continue }
            out[name] = max(0, (now - ts) / 1000)
        }
        return out
    }
}
