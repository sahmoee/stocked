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

@MainActor
@Observable
final class HouseholdSync {
    static let shared = HouseholdSync()
    private init() {
        switch UserDefaults.standard.string(forKey: "hh_role") {
        case "owner":  state = .owner
        case "member": state = .member
        default:       state = .idle
        }
        joinCode = UserDefaults.standard.string(forKey: "hh_code")
    }

    // MARK: - Observable state (matches the old manager so views compile)

    enum State: Equatable { case idle, creating, owner, member, syncing }
    private(set) var state: State = .idle

    /// The current device's access level in the household, for gating UI actions. Refreshed
    /// whenever members are fetched. Owner is always .owner; a plain member defaults to .adult
    /// until the owner assigns a level. Views can read HouseholdSync.shared.myAccessRole and its
    /// permission flags (canAdd/canEdit/canRemove) to show or disable controls.
    var myAccessRole: HouseholdMember.Role = .owner
    private(set) var lastError: String?
    private(set) var joinCode: String?

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
        let device = UIDevice.current.name.trimmingCharacters(in: .whitespaces)
        if !device.isEmpty { return device }
        return "Member"
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
        myDisplayName = resolvedName()   // never create as "You"
        let body: [String: Any] = ["ownerName": myDisplayName, "memberId": memberId]
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
        persist()
        if let hh = resp["household"] as? [String: Any] { applyHousehold(hh, into: nil) }
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
        guard let resp = await post("/household/regenerate", ["code": code]),
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
        let body: [String: Any] = ["code": code, "memberName": myDisplayName, "memberId": memberId]
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
        persist()
        let counts = applyHousehold(hh, into: store)
        syncStage = .done(invAdded: counts.inv, groAdded: counts.gro)
        lastError = nil
        startAutoSync(store: store)   // begin automatic incoming sync
        return true
    }

    // MARK: - Automatic incoming sync (polling)

    @ObservationIgnored private var pollTask: Task<Void, Never>? = nil
    @ObservationIgnored private weak var pollStore: GuestDataStore? = nil

    /// Pull the latest household snapshot and merge it in, without pushing. Cheap; used by the
    /// auto-sync poller and on foreground so changes made elsewhere appear on their own.
    func pullNow(into store: GuestDataStore) async {
        guard let code = joinCode, state == .owner || state == .member else { return }
        guard let resp = await post("/household/pull", ["code": code]),
              let hh = resp["household"] as? [String: Any] else { return }
        _ = applyHousehold(hh, into: store)
    }

    /// Start a background poll so household changes from other members appear automatically,
    /// no manual sync needed. Safe to call repeatedly (it restarts a single task). Call on app
    /// launch / foreground once a household exists.
    func startAutoSync(store: GuestDataStore, everySeconds: UInt64 = 20) {
        pollStore = store
        pollTask?.cancel()
        guard state == .owner || state == .member else { return }
        pollTask = Task { @MainActor [weak self, weak store] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: everySeconds * 1_000_000_000)
                guard let self, let store else { return }
                guard self.state == .owner || self.state == .member else { continue }
                await self.pullNow(into: store)
            }
        }
    }
    func stopAutoSync() { pollTask?.cancel(); pollTask = nil }
    /// Pull immediately (e.g. on foreground), then let the poller continue.
    func syncOnForeground() {
        guard let store = pollStore, state == .owner || state == .member else { return }
        Task { await pullNow(into: store) }
    }

    /// Manual two-way sync for an existing owner/member: push local collaborative data, pull merged.
    func syncNow(store: GuestDataStore) async {
        guard let code = joinCode, state == .owner || state == .member else { return }
        // Do NOT overwrite `state` here. `state` carries the device ROLE (owner/member); the old
        // code set it to .syncing, which made every role guard (the poller, pushHouseholdDebounced,
        // pullNow) fail while a sync was in flight, and the restore line read the already-clobbered
        // state and demoted the owner to member. A failed sync left state stuck at .syncing, which
        // permanently blocked all future syncs and pulls. Progress is tracked via syncStage only.
        syncStage = .uploading(store.groceryItems.count)
        let body: [String: Any] = [
            "code": code,
            "grocery": store.groceryItems.map { groceryDict($0) },
            "inventory": store.inventoryItems.map { inventoryDict($0) },
            "invDeleted": Array(store.pendingInvTombstones),
            "groDeleted": Array(store.pendingGroTombstones),
        ]
        guard let resp = await post("/household/push", body),
              let hh = resp["household"] as? [String: Any] else {
            fail("Sync didn't finish. Check your connection and try again.")
            return
        }
        // Server accepted our deletions; clear the local pending set.
        store.pendingInvTombstones.removeAll()
        store.pendingGroTombstones.removeAll()
        let counts = applyHousehold(hh, into: store)
        syncStage = .done(invAdded: counts.inv, groAdded: counts.gro)
        lastError = nil
    }

    /// Leave the household (members) or tear it down (owner if last member).
    func leaveHousehold() {
        guard let code = joinCode else { resetLocal(); return }
        let name = myDisplayName
        let mid = memberId
        Task { _ = await post("/household/leave", ["code": code, "memberName": name, "memberId": mid]) }
        resetLocal()
    }

    private func resetLocal() {
        state = .idle
        joinCode = nil
        UserDefaults.standard.removeObject(forKey: "hh_role")
        UserDefaults.standard.removeObject(forKey: "hh_code")
    }

    // MARK: - Activity + members (for the feed and member screens)

    func logActivity(_ kind: HouseholdActivity.Kind, itemName: String) async {
        guard let code = joinCode, state == .owner || state == .member else { return }
        let event: [String: Any] = [
            "kind": kind.rawValue, "itemName": itemName,
            "actorName": myDisplayName, "date": Date().timeIntervalSince1970 * 1000,
        ]
        // Push a single activity event (server merges + caps).
        _ = await post("/household/push", ["code": code, "activity": [event]])
    }

    func fetchActivity(limit: Int = 50) async -> [HouseholdActivity] {
        guard let code = joinCode, state == .owner || state == .member else { return [] }
        guard let resp = await post("/household/pull", ["code": code]),
              let hh = resp["household"] as? [String: Any],
              let raw = hh["activity"] as? [[String: Any]] else { return [] }
        return raw.compactMap { parseActivity($0) }.prefix(limit).map { $0 }
    }

    func fetchMembers() async -> [HouseholdMember] {
        guard let code = joinCode, state == .owner || state == .member else { return [] }
        guard let resp = await post("/household/pull", ["code": code]),
              let hh = resp["household"] as? [String: Any],
              let raw = hh["members"] as? [[String: Any]] else {
            let solo = [HouseholdMember(id: "me", name: myDisplayName, role: state == .owner ? .owner : .member, joinedAt: nil, isMe: true)]
            refreshMyAccessRole(from: solo)
            return solo
        }
        let ownerName = hh["ownerName"] as? String
        let ownerId = hh["ownerId"] as? String
        let myId = memberId
        let mapped: [HouseholdMember] = raw.map { m in
            let name = (m["name"] as? String) ?? "Member"
            let mid = (m["memberId"] as? String) ?? name
            let joined = (m["joinedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            let isOwner = (ownerId != nil) ? (mid == ownerId) : (name == ownerName)
            let storedRole = (m["role"] as? String).flatMap { HouseholdMember.Role(rawValue: $0) }
            let role: HouseholdMember.Role = isOwner ? .owner : (storedRole ?? .adult)
            let customLabel = (m["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return HouseholdMember(
                id: mid,
                name: name,
                role: role,
                customLabel: customLabel,
                joinedAt: joined,
                isMe: mid == myId)
        }
        refreshMyAccessRole(from: mapped)
        return mapped
    }

    /// Owner action: set a member's access level and optional custom label. Persists to the
    /// household document so every device sees it. No-op if the current device isn't the owner.
    @discardableResult
    func setMemberRole(memberId targetId: String, role: HouseholdMember.Role, label: String?) async -> Bool {
        guard let code = joinCode, state == .owner else {
            fail("Only the household owner can change member levels.")
            return false
        }
        var body: [String: Any] = ["code": code, "memberId": targetId, "role": role.rawValue,
                                   "actorId": memberId]
        if let label { body["label"] = label }
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

    /// Refresh the cached myAccessRole from a member list (called after fetchMembers).
    private func refreshMyAccessRole(from members: [HouseholdMember]) {
        // Not in a household → treat as owner (full access) so solo use is never restricted.
        guard state == .owner || state == .member else { myAccessRole = .owner; return }
        myAccessRole = myRole(from: members)
    }

    // MARK: - Networking

    private func post(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        guard let url = URL(string: BuildConfig.receiptWorkerURL + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&req)   // X-Stocked-Key shared secret
        req.timeoutInterval = 12
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        guard (200...299).contains(http.statusCode) else {
            Log.transfer.error("Household \(path, privacy: .public) HTTP \(http.statusCode)")
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func fail(_ message: String) {
        lastError = message
        syncStage = .failed(message)
    }

    // MARK: - Mapping between the household document and local models

    private func inventoryDict(_ item: LocalInventoryItem) -> [String: Any] {
        [
            "id": item.id.uuidString, "name": item.name, "quantity": item.quantity,
            "zone": item.zone, "level": item.effectiveLevel, "brand": item.brand ?? "",
            "updatedAt": item.updatedAt,
        ]
    }
    private func groceryDict(_ item: LocalGroceryItem) -> [String: Any] {
        [
            "id": item.id.uuidString, "name": item.name, "quantity": item.quantity,
            "isChecked": item.isChecked, "recipeSource": item.recipeSource,
            "addedByName": item.addedByName, "updatedAt": item.updatedAt,
        ]
    }
    private func parseGrocery(_ d: [String: Any]) -> LocalGroceryItem? {
        guard let name = d["name"] as? String, !name.isEmpty else { return nil }
        var item = LocalGroceryItem(name: name, isChecked: (d["isChecked"] as? Bool) ?? false)
        if let idStr = d["id"] as? String, let uuid = UUID(uuidString: idStr) { item.id = uuid }
        item.quantity = (d["quantity"] as? Int) ?? 1
        item.recipeSource = (d["recipeSource"] as? String) ?? ""
        item.addedByName = (d["addedByName"] as? String) ?? ""
        item.updatedAt = (d["updatedAt"] as? Double) ?? 0
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
        return item
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
    private func applyHousehold(_ hh: [String: Any], into store: GuestDataStore?) -> (inv: Int, gro: Int) {
        guard let store else { return (0, 0) }
        // Suppress the store's own household push while we write remote data in, so applying a
        // pulled snapshot doesn't immediately echo back out as another push (sync loop).
        store.isApplyingHouseholdRemote = true
        defer { store.isApplyingHouseholdRemote = false }

        // Server-side tombstones: ids that were deleted somewhere in the household. Drop them
        // locally too so a delete on one device propagates to the others.
        let invTombstones = Set((hh["invDeleted"] as? [String]) ?? [])
        let groTombstones = Set((hh["groDeleted"] as? [String]) ?? [])

        var groAdded = 0
        if let groRaw = hh["grocery"] as? [[String: Any]] {
            let remote = groRaw.compactMap { parseGrocery($0) }
            var byID = Dictionary(uniqueKeysWithValues: store.groceryItems.map { ($0.id, $0) })
            for r in remote {
                if let local = byID[r.id] {
                    if r.updatedAt >= local.updatedAt { byID[r.id] = r }   // newer wins
                } else if !groTombstones.contains(r.id.uuidString) {
                    byID[r.id] = r; groAdded += 1
                }
            }
            // Apply deletions.
            for id in byID.keys where groTombstones.contains(id.uuidString) { byID[id] = nil }
            let merged = Array(byID.values)
            if merged != store.groceryItems { store.groceryItems = merged }
        }

        // Inventory: last-write-wins by updatedAt, honoring tombstones. Adds, edits (quantity,
        // title, zone), and removals all converge this way.
        var invAdded = 0
        if let invRaw = hh["inventory"] as? [[String: Any]] {
            let remote = invRaw.compactMap { parseInventory($0) }
            var byID = Dictionary(uniqueKeysWithValues: store.inventoryItems.map { ($0.id, $0) })
            for r in remote {
                if let local = byID[r.id] {
                    if r.updatedAt >= local.updatedAt { byID[r.id] = r }
                } else if !invTombstones.contains(r.id.uuidString) {
                    byID[r.id] = r; invAdded += 1
                }
            }
            for id in byID.keys where invTombstones.contains(id.uuidString) { byID[id] = nil }
            let merged = Array(byID.values)
            if merged != store.inventoryItems { store.inventoryItems = merged }
        }
        return (invAdded, groAdded)
    }

    // MARK: - Code normalization (shared with the join field)

    static func normalize(_ raw: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String(raw.uppercased().filter { allowed.contains($0) })
    }
}
