// HouseholdCloudKit.swift
// ─────────────────────────────────────────────────────────────────────────────
// TRUE multi-account household sharing via CloudKit shared zones (CKShare).
// Unlike SharedPantrySync (iCloud KV, single Apple ID only), this lets DIFFERENT
// people on DIFFERENT Apple IDs share one pantry.
//
// ARCHITECTURE (built across sessions; this file is the foundation):
//   • A "household owner" creates a custom record zone + a CKShare for it.
//   • Inventory and grocery items live as CKRecords in that shared zone.
//   • Members join via the share URL (Messages/Mail) OR via a short code that maps
//     to the share (code lookup stored on a discoverable record).
//   • Changes sync via CKModifyRecordsOperation + CKDatabaseSubscription push.
//
// PREREQUISITES (must be set up in Xcode for this to function):
//   1. Target → Signing & Capabilities → iCloud → CloudKit enabled, container
//      "iCloud.Stocked" checked.
//   2. Background Modes → Remote notifications (for push-driven sync).
//   3. CloudKit Dashboard: the record types below will be created on first save in
//      development; promote the schema to production before App Store release.
//
// STATUS: Session 1 = zone + share creation, record mapping, manual push/pull.
//         Later sessions = subscriptions/push, code-lookup join, conflict UI,
//         migration of existing local pantry into the shared zone.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import CloudKit
import os

// MARK: - Record type / field names (single source of truth)

enum HouseholdSchema {
    static let inventoryType = "SharedInventoryItem"
    static let groceryType   = "SharedGroceryItem"
    static let zoneName      = "HouseholdZone"

    // Inventory fields
    enum Inv {
        static let name = "name"; static let quantity = "quantity"
        static let containerType = "containerType"; static let sizeAmount = "sizeAmount"
        static let sizeUnit = "sizeUnit"; static let zone = "zone"
        static let expiration = "expiration"; static let brand = "brand"
        static let level = "level"
    }
    // Grocery fields
    enum Gro {
        static let name = "name"; static let quantity = "quantity"
        static let isChecked = "isChecked"; static let recipeSource = "recipeSource"
        static let addedByName = "addedByName"   // household attribution
    }
    // Activity feed
    static let activityType = "HouseholdActivity"
    enum Act {
        static let kind = "kind"; static let itemName = "itemName"
        static let actorName = "actorName"; static let date = "date"
    }
}

// MARK: - Manager

@MainActor
@Observable
final class HouseholdCloudKit {
    static let shared = HouseholdCloudKit()
    private init() {
        // Restore the persisted household role so launch-time subscription re-registration
        // and sync know whether we're an owner or a member.
        switch UserDefaults.standard.string(forKey: "householdRole") {
        case "owner":  state = .owner
        case "member": state = .member
        default:       state = .idle
        }
        // Restore the previously published join code so it stays visible across launches.
        joinCode = UserDefaults.standard.string(forKey: "householdJoinCode")
        // The owner's zone is deterministic; restore it on launch so sync/code paths don't fail
        // just because the in-memory ownerZoneID wasn't repopulated after a relaunch.
        if state == .owner {
            ownerZoneID = CKRecordZone.ID(zoneName: HouseholdSchema.zoneName,
                                          ownerName: CKCurrentUserDefaultName)
        }
    }

    @ObservationIgnored private let container = CKContainer(identifier: "iCloud.Stocked")
    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private var sharedDB:  CKDatabase { container.sharedCloudDatabase }
    private var publicDB:  CKDatabase { container.publicCloudDatabase }

    // Public record type that maps a join code → share URL (for the code-join fallback).
    @ObservationIgnored private let codeMapType = "HouseholdCodeMap"

    // Observable status for the UI.
    private(set) var state: State = .idle
    private(set) var lastError: String?

    // Step-by-step progress for the on-screen sync prompt. nil = no prompt showing.
    enum SyncStage: Equatable {
        case checkingAccount
        case creating
        case joining
        case findingZone
        case uploading(Int)
        case downloading(Int)        // count of items pulled so far
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
    /// The shareable join code (owner side), shown in the UI for the code-join fallback.
    private(set) var joinCode: String?

    enum State: Equatable {
        case idle              // not in a household
        case creating          // setting up a household to share
        case owner             // this device owns the shared household
        case member            // this device joined someone else's household
        case syncing
    }

    /// Persist the role whenever it settles to owner/member/idle (not transient states).
    private func persistRole() {
        switch state {
        case .owner:  UserDefaults.standard.set("owner",  forKey: "householdRole")
        case .member: UserDefaults.standard.set("member", forKey: "householdRole")
        case .idle:   UserDefaults.standard.removeObject(forKey: "householdRole")
        default:      break
        }
    }

    /// Leave the current household: reset local role/state so the UI returns to the
    /// "not in a household" state. (Does not delete the owner's shared zone — that
    /// stays until the owner explicitly tears it down — but this device stops
    /// presenting itself as a member/owner.)
    func leaveHousehold() {
        state = .idle
        ownerZoneID = nil
        joinCode = nil
        UserDefaults.standard.removeObject(forKey: "householdRole")
        UserDefaults.standard.removeObject(forKey: "householdJoinCode")
        Log.transfer.notice("Left household (local state reset)")
    }

    // The household's custom zone (owner side). Members operate on the shared DB.
    @ObservationIgnored private var ownerZoneID: CKRecordZone.ID?

    // MARK: - Account check

    /// Confirm the user is signed into iCloud before any CloudKit work.
    func accountAvailable() async -> Bool {
        do { return try await container.accountStatus() == .available }
        catch { return false }
    }

    // MARK: - Owner: create the shared household

    /// Create a custom zone and a CKShare for it. Returns the share so the caller can
    /// present UICloudSharingController (the Messages/Mail invite). Idempotent-ish: if a
    /// zone already exists it reuses it.
    func createHousehold() async -> CKShare? {
        syncStage = .checkingAccount
        guard await accountAvailable() else {
            lastError = "Sign into iCloud to start a household."
            syncStage = .failed("Not signed into iCloud. Open Settings and sign in, then try again.")
            return nil
        }
        state = .creating
        syncStage = .creating
        let zoneID = CKRecordZone.ID(zoneName: HouseholdSchema.zoneName, ownerName: CKCurrentUserDefaultName)
        let zone = CKRecordZone(zoneID: zoneID)

        do {
            // Create the zone (no-op if it already exists).
            _ = try await privateDB.modifyRecordZones(saving: [zone], deleting: [])
            ownerZoneID = zoneID

            // A "household root" record that the share is attached to.
            let rootID = CKRecord.ID(recordName: "HouseholdRoot", zoneID: zoneID)
            let root: CKRecord
            if let existing = try? await privateDB.record(for: rootID) {
                root = existing
            } else {
                root = CKRecord(recordType: "Household", recordID: rootID)
                root["createdAt"] = Date() as CKRecordValue
            }

            let share = CKShare(rootRecord: root)
            share[CKShare.SystemFieldKey.title] = "My Stocked. Kitchen" as CKRecordValue
            share.publicPermission = .none   // invite-only

            let saveResult = try await privateDB.modifyRecords(saving: [root, share], deleting: [])
            state = .owner
            persistRole()
            await registerSubscription(on: privateDB, id: "household-owner-sub")

            // Publish a code → share-URL mapping so people can also join by typing a code
            // (not just tapping the link).
            // NOTE: CKShare.url is NOT populated synchronously on the first save — reading it
            // immediately returns nil (which previously meant the join code was never created).
            // Re-fetch the saved share to obtain its .url, with a short retry while CloudKit
            // finishes provisioning it.
            var shareURL: URL? =
                (saveResult.saveResults[share.recordID].flatMap { try? $0.get() } as? CKShare)?.url
            if shareURL == nil {
                shareURL = await fetchOwnShareURL(shareID: share.recordID)
            }
            if let url = shareURL {
                await publishCodeMapping(shareURL: url)
            } else {
                Log.transfer.error("Share URL unavailable after create — join code not published")
                lastError = "Household created, but the join code isn't ready yet. Tap Sync now to finish."
            }
            Log.transfer.notice("Household created with share")
            syncStage = .done(invAdded: 0, groAdded: 0)
            return share
        } catch {
            state = .idle
            lastError = "Couldn't create household: \(error.localizedDescription)"
            syncStage = .failed("Couldn't create household: \(error.localizedDescription)")
            Log.transfer.error("createHousehold failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Member: accept a share (called from the scene-delegate share-accept hook)

    /// Accept an incoming CKShare.Metadata (when the user taps a share link).
    func acceptShare(_ metadata: CKShare.Metadata) async -> Bool {
        guard await accountAvailable() else { return false }
        do {
            _ = try await container.accept(metadata)
            state = .member
            persistRole()
            await registerSubscription(on: sharedDB, id: "household-member-sub")
            Log.transfer.notice("Accepted household share")
            return true
        } catch {
            lastError = "Couldn't join household: \(error.localizedDescription)"
            return false
        }
    }

    /// Merge the joiner's existing local pantry into the household: pull what's already
    /// shared (so we adopt it), then push our local items up. Both sides converge with no
    /// duplication because records are keyed by each item's stable UUID.
    /// User-initiated manual sync for an existing household member/owner. Shows progress.
    func syncNow(store: GuestDataStore) async {
        guard state == .owner || state == .member else { return }
        syncStage = .findingZone
        guard await activeZoneAndDB() != nil else {
            syncStage = .failed("Couldn't reach the shared kitchen. Check your connection and try again.")
            return
        }
        // Self-heal: if we're the owner but never got a join code (e.g. the share URL wasn't
        // ready at create time), republish it now.
        if state == .owner, joinCode == nil {
            await republishCodeIfNeeded()
        }
        let before = (store.inventoryItems.count, store.groceryItems.count)
        syncStage = .downloading(0)
        await pull(into: store)
        let after = (store.inventoryItems.count, store.groceryItems.count)
        syncStage = .uploading(store.inventoryItems.count)
        await push(store: store)
        if case .failed = syncStage { return }   // keep an error stage if pull set one
        syncStage = .done(invAdded: after.0 - before.0, groAdded: after.1 - before.1)
    }

    func migrateLocalIntoHousehold(store: GuestDataStore) async {
        // First make sure the shared zone is actually reachable (it can lag after accept).
        syncStage = .findingZone
        guard await activeZoneAndDB() != nil else {
            syncStage = .failed("Joined, but the shared kitchen isn't reachable yet. Wait a moment and tap \u{201C}Sync now\u{201D}.")
            return
        }
        syncStage = .downloading(0)
        let before = (store.inventoryItems.count, store.groceryItems.count)
        await pull(into: store)
        let afterPull = (store.inventoryItems.count, store.groceryItems.count)
        let pulledInv = afterPull.0 - before.0
        let pulledGro = afterPull.1 - before.1
        syncStage = .uploading(store.inventoryItems.count)
        await push(store: store)
        if case .failed = syncStage { return }
        // If we joined a household but pulled nothing AND had nothing to contribute beyond
        // our own, the share likely hasn't propagated the owner's records to us yet. Don't
        // claim a successful transfer — tell the truth so the user knows to retry.
        if pulledInv == 0 && pulledGro == 0 && before.0 == 0 && before.1 == 0 {
            syncStage = .failed("Joined the household, but no items have come through yet. Make sure the owner has tapped \u{201C}Sync now\u{201D}, then try again in a moment.")
            return
        }
        syncStage = .done(invAdded: pulledInv, groAdded: pulledGro)
    }

    // MARK: - Code-based join (fallback for people who'd rather type a code than tap a link)

    /// Owner-side recovery: if the household exists but no join code was published, fetch the
    /// existing share's URL and publish a code now. Reports each failure point (instead of
    /// silently returning) so a stuck "owner with no code" state is diagnosable on-device.
    private func republishCodeIfNeeded() async {
        guard joinCode == nil else { return }
        let zoneID = ownerZoneID
            ?? CKRecordZone.ID(zoneName: HouseholdSchema.zoneName, ownerName: CKCurrentUserDefaultName)
        let rootID = CKRecord.ID(recordName: "HouseholdRoot", zoneID: zoneID)

        // 1. Fetch the household root record.
        let root: CKRecord
        do {
            root = try await privateDB.record(for: rootID)
        } catch {
            // The root/share doesn't exist — the household was never fully created. Recreate it.
            Log.transfer.error("republishCode: root fetch failed: \(error.localizedDescription, privacy: .public)")
            await recreateShareAndCode(zoneID: zoneID)
            return
        }

        // 2. Get the share reference off the root.
        guard let shareRef = root.share else {
            Log.transfer.notice("republishCode: root has no share; recreating share")
            await recreateShareAndCode(zoneID: zoneID, existingRoot: root)
            return
        }

        // 3. Fetch the share's public URL (with retry) and publish the code.
        if let url = await fetchOwnShareURL(shareID: shareRef.recordID) {
            await publishCodeMapping(shareURL: url)
            if joinCode == nil {
                lastError = "Generated the share, but couldn't publish the join code. Check your connection and tap Sync now again."
            }
        } else {
            lastError = "Couldn't get the share link yet. Wait a few seconds and tap Sync now again."
        }
    }

    /// Last-resort recovery: (re)create the CKShare on the household root and publish a code.
    /// Handles the case where the original create saved a zone/root but never persisted a usable
    /// share (which is why no code ever appeared).
    private func recreateShareAndCode(zoneID: CKRecordZone.ID, existingRoot: CKRecord? = nil) async {
        do {
            let root: CKRecord
            if let existingRoot { root = existingRoot }
            else {
                let rootID = CKRecord.ID(recordName: "HouseholdRoot", zoneID: zoneID)
                root = (try? await privateDB.record(for: rootID))
                    ?? CKRecord(recordType: "Household", recordID: rootID)
                if root["createdAt"] == nil { root["createdAt"] = Date() as CKRecordValue }
            }
            let share = CKShare(rootRecord: root)
            share[CKShare.SystemFieldKey.title] = "My Stocked. Kitchen" as CKRecordValue
            share.publicPermission = .none
            let result = try await privateDB.modifyRecords(saving: [root, share], deleting: [])
            var url = (result.saveResults[share.recordID].flatMap { try? $0.get() } as? CKShare)?.url
            if url == nil { url = await fetchOwnShareURL(shareID: share.recordID) }
            if let url {
                await publishCodeMapping(shareURL: url)
            } else {
                lastError = "Created the household share, but the link isn't ready yet. Tap Sync now again in a few seconds."
            }
        } catch {
            lastError = "Couldn't set up sharing: \(error.localizedDescription)"
            Log.transfer.error("recreateShareAndCode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-fetch the owner's CKShare from the private DB to obtain its public .url, which is
    /// NOT available synchronously on the first save. CloudKit can take many seconds to
    /// provision the public share URL, so retry generously (up to ~30s total) before giving up.
    private func fetchOwnShareURL(shareID: CKRecord.ID) async -> URL? {
        for attempt in 0..<12 {
            if let share = (try? await privateDB.record(for: shareID)) as? CKShare,
               let url = share.url {
                return url
            }
            // Backoff capped at ~3s per try: 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.0, ... (~28s total)
            let secs = min(3.0, 0.5 * Double(attempt + 1))
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
        }
        return nil
    }

    /// Generate a reasonably-unguessable 8-character code and store a public record mapping
    /// it to the share URL. NOTE: this lives in the PUBLIC database, so the mapping is
    /// technically fetchable by anyone who knows/guesses the code — that's why it's 8 chars,
    /// not 6. The share itself is still invite-only; the code only yields the join URL.
    private func publishCodeMapping(shareURL: URL) async {
        let code = Self.makeCode()
        let id = CKRecord.ID(recordName: "code_\(code)")
        let rec = CKRecord(recordType: codeMapType, recordID: id)
        rec["shareURL"] = shareURL.absoluteString as CKRecordValue
        rec["createdAt"] = Date() as CKRecordValue
        do {
            _ = try await publicDB.modifyRecords(saving: [rec], deleting: [])
            joinCode = code
            UserDefaults.standard.set(code, forKey: "householdJoinCode")
            lastError = nil
            Log.transfer.notice("Published household join code")
        } catch {
            lastError = "Couldn't publish the join code (public database). \(error.localizedDescription)"
            Log.transfer.error("Code publish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Join a household by entering its code: look up the public mapping, fetch the share
    /// metadata from the URL, and accept it.
    func joinByCode(_ rawCode: String, into store: GuestDataStore) async -> Bool {
        syncStage = .checkingAccount
        guard await accountAvailable() else {
            lastError = "Sign into iCloud to join a household."
            syncStage = .failed("Not signed into iCloud. Open Settings and sign in, then try again.")
            return false
        }
        // Normalize hard: uppercase, then keep ONLY the characters used in our code alphabet
        // (A to Z and 2 to 9). This strips smart quotes, spaces, dashes, and any stray punctuation
        // the keyboard may have inserted (e.g. iOS smart-quote substitution wrapping the code),
        // which would otherwise make the lookup fail.
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let code = String(rawCode.uppercased().filter { allowed.contains($0) })
        let id = CKRecord.ID(recordName: "code_\(code)")
        syncStage = .joining
        do {
            let rec = try await publicDB.record(for: id)
            guard let urlStr = rec["shareURL"] as? String, let url = URL(string: urlStr) else {
                lastError = "That code didn't match a household."
                syncStage = .failed("That code didn't match a household.")
                return false
            }
            // Fetch the share metadata from the URL, then accept it.
            let metadata = try await fetchShareMetadata(from: url)
            let ok = await acceptShare(metadata)
            if ok {
                await migrateLocalIntoHousehold(store: store)
            } else {
                syncStage = .failed(lastError ?? "Couldn't accept the household invite.")
            }
            return ok
        } catch {
            lastError = "Couldn't find a household for that code."
            syncStage = .failed("Couldn't find a household for code \(code). \(error.localizedDescription)")
            Log.transfer.error("joinByCode failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Fetch CKShare.Metadata from a share URL (wraps the operation in async).
    private func fetchShareMetadata(from url: URL) async throws -> CKShare.Metadata {
        try await withCheckedThrowingContinuation { cont in
            var finished = false
            let op = CKFetchShareMetadataOperation(shareURLs: [url])
            // Hold a strong reference to the operation until it completes. Without this, `op`
            // is a local that gets deallocated as soon as this closure returns, while CloudKit
            // still has dispatch work queued against it — its memory is reused and CloudKit's
            // internal `_setContext:` call lands on the wrong object ("unrecognized selector"
            // crash). The completion block captures `op`, keeping it alive until CloudKit is done.
            op.perShareMetadataResultBlock = { _, result in
                guard !finished else { return }
                switch result {
                case .success(let metadata): finished = true; cont.resume(returning: metadata)
                case .failure(let error):    finished = true; cont.resume(throwing: error)
                }
            }
            op.fetchShareMetadataResultBlock = { [op] result in
                _ = op   // retain until done
                guard !finished else { return }
                if case .failure(let error) = result { finished = true; cont.resume(throwing: error) }
            }
            container.add(op)
        }
    }

    /// 8-char code from an unambiguous alphabet (no 0/O/1/I).
    private static func makeCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).compactMap { _ in alphabet.randomElement() })
    }

    // MARK: - Real-time push (Session 3): database subscriptions

    /// Register a silent-push subscription so CloudKit notifies this device whenever any
    /// record in the household changes. Idempotent — re-saving the same subscription id is
    /// a no-op server-side. Called on create/join and re-ensured at launch.
    func registerSubscription(on db: CKDatabase, id: String) async {
        let sub = CKDatabaseSubscription(subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent background push
        sub.notificationInfo = info
        do {
            _ = try await db.modifySubscriptions(saving: [sub], deleting: [])
            Log.transfer.notice("Registered household subscription \(id, privacy: .public)")
        } catch {
            // A "duplicate subscription" error is fine — it already exists.
            Log.transfer.error("Subscription \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-ensure the right subscription exists for the current role. Safe to call at launch.
    func ensureSubscriptionsForCurrentRole() async {
        guard await accountAvailable() else { return }
        switch state {
        case .owner:  await registerSubscription(on: privateDB, id: "household-owner-sub")
        case .member: await registerSubscription(on: sharedDB,  id: "household-member-sub")
        default:      break
        }
    }

    /// Called from the AppDelegate when a household push arrives: pull the latest changes.
    func handleRemoteNotification(into store: GuestDataStore) async {
        await pull(into: store)
    }

    // MARK: - Record mapping

    private func record(from item: LocalInventoryItem, zoneID: CKRecordZone.ID) -> CKRecord {
        let id = CKRecord.ID(recordName: item.id.uuidString, zoneID: zoneID)
        let r = CKRecord(recordType: HouseholdSchema.inventoryType, recordID: id)
        r[HouseholdSchema.Inv.name] = item.name as CKRecordValue
        r[HouseholdSchema.Inv.quantity] = item.quantity as CKRecordValue
        r[HouseholdSchema.Inv.containerType] = item.containerType as CKRecordValue
        if let s = item.sizeAmount { r[HouseholdSchema.Inv.sizeAmount] = s as CKRecordValue }
        if let u = item.sizeUnit  { r[HouseholdSchema.Inv.sizeUnit] = u as CKRecordValue }
        r[HouseholdSchema.Inv.zone] = item.zone as CKRecordValue
        if let e = item.expirationDate { r[HouseholdSchema.Inv.expiration] = e as CKRecordValue }
        if let b = item.brand { r[HouseholdSchema.Inv.brand] = b as CKRecordValue }
        r[HouseholdSchema.Inv.level] = item.level as CKRecordValue
        return r
    }

    private func inventoryItem(from r: CKRecord) -> LocalInventoryItem? {
        guard let name = r[HouseholdSchema.Inv.name] as? String,
              let uuid = UUID(uuidString: r.recordID.recordName) else { return nil }
        var item = LocalInventoryItem(
            name: name,
            zone: (r[HouseholdSchema.Inv.zone] as? String) ?? "Pantry",
            quantity: (r[HouseholdSchema.Inv.quantity] as? Int) ?? 1,
            containerType: (r[HouseholdSchema.Inv.containerType] as? String) ?? "item",
            sizeAmount: r[HouseholdSchema.Inv.sizeAmount] as? Double,
            sizeUnit: r[HouseholdSchema.Inv.sizeUnit] as? String
        )
        item.id = uuid
        item.expirationDate = r[HouseholdSchema.Inv.expiration] as? Date
        item.brand = r[HouseholdSchema.Inv.brand] as? String
        if let lvl = r[HouseholdSchema.Inv.level] as? Double { item.level = lvl }
        return item
    }

    private func record(from item: LocalGroceryItem, zoneID: CKRecordZone.ID) -> CKRecord {
        let id = CKRecord.ID(recordName: item.id.uuidString, zoneID: zoneID)
        let r = CKRecord(recordType: HouseholdSchema.groceryType, recordID: id)
        r[HouseholdSchema.Gro.name] = item.name as CKRecordValue
        r[HouseholdSchema.Gro.quantity] = item.quantity as CKRecordValue
        r[HouseholdSchema.Gro.isChecked] = (item.isChecked ? 1 : 0) as CKRecordValue
        r[HouseholdSchema.Gro.recipeSource] = item.recipeSource as CKRecordValue
        r[HouseholdSchema.Gro.addedByName] = item.addedByName as CKRecordValue
        return r
    }

    private func groceryItem(from r: CKRecord) -> LocalGroceryItem? {
        guard let name = r[HouseholdSchema.Gro.name] as? String,
              let uuid = UUID(uuidString: r.recordID.recordName) else { return nil }
        var item = LocalGroceryItem(
            name: name,
            isChecked: ((r[HouseholdSchema.Gro.isChecked] as? Int) ?? 0) == 1
        )
        item.id = uuid
        item.quantity = (r[HouseholdSchema.Gro.quantity] as? Int) ?? 1
        item.recipeSource = (r[HouseholdSchema.Gro.recipeSource] as? String) ?? ""
        item.addedByName = (r[HouseholdSchema.Gro.addedByName] as? String) ?? ""
        return item
    }

    // MARK: - Push / pull (Session 1: manual; later: CKSyncEngine + subscriptions)

    /// Resolve the zone + database to operate on (owner uses private, member uses shared).
    private func activeZoneAndDB() async -> (CKRecordZone.ID, CKDatabase)? {
        if state == .owner {
            // ownerZoneID is only set in-memory during createHousehold(); it is NOT restored on
            // relaunch. But the owner's zone is deterministic, so reconstruct it rather than
            // failing. (This was the bug behind "Couldn't reach the shared kitchen" + no join
            // code: after any relaunch, ownerZoneID was nil and this returned nil.)
            if let z = ownerZoneID { return (z, privateDB) }
            let z = CKRecordZone.ID(zoneName: HouseholdSchema.zoneName, ownerName: CKCurrentUserDefaultName)
            // Make sure the zone actually exists in the private DB before claiming it; create it
            // if it's somehow missing (idempotent).
            if (try? await privateDB.recordZone(for: z)) != nil {
                ownerZoneID = z
                return (z, privateDB)
            }
            if let saved = try? await privateDB.modifyRecordZones(saving: [CKRecordZone(zoneID: z)], deleting: []),
               saved.saveResults[z] != nil {
                ownerZoneID = z
                return (z, privateDB)
            }
            return (z, privateDB)   // last resort: use the deterministic ID anyway
        }
        // Member: find the shared zone. Right after accepting a share, CloudKit may not have
        // provisioned the shared zone into sharedDB yet, so poll a few times before giving up.
        if state == .member {
            for attempt in 0..<6 {
                if let zones = try? await sharedDB.allRecordZones(), let z = zones.first {
                    return (z.zoneID, sharedDB)
                }
                Log.transfer.notice("Shared zone not visible yet (attempt \(attempt + 1, privacy: .public)); waiting")
                try? await Task.sleep(nanoseconds: 1_000_000_000)   // 1s between tries
            }
            return nil
        }
        // Fallback: a one-shot check (e.g. role not yet settled).
        if let zones = try? await sharedDB.allRecordZones(), let z = zones.first {
            return (z.zoneID, sharedDB)
        }
        if let z = ownerZoneID { return (z, privateDB) }
        return nil
    }

    /// Push the full local pantry to the shared zone, with conflict handling.
    func push(store: GuestDataStore) async {
        guard let (zoneID, db) = await activeZoneAndDB() else { return }
        state = .syncing
        let records = store.inventoryItems.map { record(from: $0, zoneID: zoneID) }
                    + store.groceryItems.map { record(from: $0, zoneID: zoneID) }
        do {
            let result = try await db.modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys)
            // Inspect for per-record conflicts (someone else changed the same record).
            var conflicts: [CKRecord] = []
            for (_, saveResult) in result.saveResults {
                if case .failure(let error) = saveResult,
                   let ckErr = error as? CKError, ckErr.code == .serverRecordChanged,
                   let serverRecord = ckErr.serverRecord,
                   let clientRecord = ckErr.clientRecord {
                    // Resolve last-write-wins: copy our fields onto the server's record
                    // (which has the current change tag) and re-save that.
                    for key in clientRecord.allKeys() {
                        serverRecord[key] = clientRecord[key]
                    }
                    conflicts.append(serverRecord)
                }
            }
            if !conflicts.isEmpty {
                _ = try? await db.modifyRecords(saving: conflicts, deleting: [], savePolicy: .changedKeys)
                Log.transfer.notice("Resolved \(conflicts.count, privacy: .public) household conflicts")
            }
            Log.transfer.notice("Pushed \(records.count, privacy: .public) household records")
        } catch {
            lastError = "Sync push failed: \(error.localizedDescription)"
        }
        state = (state == .syncing) ? (ownerZoneID != nil ? .owner : .member) : state
    }

    /// Pull all records from the shared zone and merge into the local store.
    /// Uses CKFetchRecordZoneChangesOperation rather than CKQuery so it does NOT require the
    /// recordName field to be marked queryable in the CloudKit schema (which is what caused
    /// "Field 'recordName' is not marked queryable"). Also yields a change token for delta sync.
    func pull(into store: GuestDataStore) async {
        guard let (zoneID, db) = await activeZoneAndDB() else { return }
        var inv: [LocalInventoryItem] = []
        var gro: [LocalGroceryItem] = []

        // Resume from a saved change token if we have one (delta sync; nil = full fetch).
        let tokenKey = "householdZoneToken_\(zoneID.zoneName)"
        var savedToken: CKServerChangeToken?
        if let data = UserDefaults.standard.data(forKey: tokenKey) {
            savedToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
                config.previousServerChangeToken = savedToken
                let op = CKFetchRecordZoneChangesOperation(
                    recordZoneIDs: [zoneID],
                    configurationsByRecordZoneID: [zoneID: config]
                )
                op.recordWasChangedBlock = { _, result in
                    guard case .success(let rec) = result else { return }
                    if rec.recordType == HouseholdSchema.inventoryType, let i = self.inventoryItem(from: rec) { inv.append(i) }
                    if rec.recordType == HouseholdSchema.groceryType, let g = self.groceryItem(from: rec) { gro.append(g) }
                    let total = inv.count + gro.count
                    Task { @MainActor in
                        if case .downloading = self.syncStage { self.syncStage = .downloading(total) }
                    }
                }
                op.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                    if let token, let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                        UserDefaults.standard.set(data, forKey: tokenKey)
                    }
                }
                op.recordZoneFetchResultBlock = { _, result in
                    if case .success(let (token, _, _)) = result,
                       let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                        UserDefaults.standard.set(data, forKey: tokenKey)
                    }
                }
                op.fetchRecordZoneChangesResultBlock = { [op] result in
                    _ = op   // retain the operation until completion (see fetchShareMetadata note)
                    switch result {
                    case .success:            cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
                db.add(op)
            }
            mergeInventory(remote: inv, into: store)
            mergeGrocery(remote: gro, into: store)
            Log.transfer.notice("Pulled household: \(inv.count, privacy: .public) inv, \(gro.count, privacy: .public) gro")
        } catch {
            // If our saved change token went stale, clear it and do a full re-fetch once.
            if let ck = error as? CKError, ck.code == .changeTokenExpired {
                UserDefaults.standard.removeObject(forKey: tokenKey)
                Log.transfer.notice("Change token expired; retrying full pull")
                if savedToken != nil { await pull(into: store) }
            } else {
                lastError = "Sync pull failed: \(error.localizedDescription)"
                syncStage = .failed("Sync failed: \(error.localizedDescription)")
            }
        }
    }

    private func mergeInventory(remote: [LocalInventoryItem], into store: GuestDataStore) {
        var byID = Dictionary(uniqueKeysWithValues: store.inventoryItems.map { ($0.id, $0) })
        for item in remote { byID[item.id] = item }
        let merged = Array(byID.values).sorted { $0.name < $1.name }
        if merged != store.inventoryItems { store.inventoryItems = merged }
    }
    private func mergeGrocery(remote: [LocalGroceryItem], into store: GuestDataStore) {
        var byID = Dictionary(uniqueKeysWithValues: store.groceryItems.map { ($0.id, $0) })
        for item in remote { byID[item.id] = item }
        let merged = Array(byID.values)
        if merged != store.groceryItems { store.groceryItems = merged }
    }
}

// MARK: - Activity feed + attribution (mockup: Household Activity, per-item "added by")

extension HouseholdCloudKit {

    /// The current user's display name, used to attribute grocery adds and activity. Set this
    /// from the app (e.g. on launch / profile change): HouseholdCloudKit.shared.myDisplayName = session.userName
    var myDisplayName: String {
        get { UserDefaults.standard.string(forKey: "household_my_name") ?? "You" }
        set { UserDefaults.standard.set(newValue.isEmpty ? "You" : newValue, forKey: "household_my_name") }
    }

    /// Append an activity event to the shared zone so every member sees it in the feed.
    /// Best-effort: failures are logged, never thrown (activity is non-critical).
    func logActivity(_ kind: HouseholdActivity.Kind, itemName: String) async {
        guard state == .owner || state == .member else { return }
        let zoneID = ownerZoneIDOrShared()
        let rec = CKRecord(recordType: HouseholdSchema.activityType,
                           recordID: CKRecord.ID(recordName: "act_\(UUID().uuidString)", zoneID: zoneID))
        rec[HouseholdSchema.Act.kind] = kind.rawValue as CKRecordValue
        rec[HouseholdSchema.Act.itemName] = itemName as CKRecordValue
        rec[HouseholdSchema.Act.actorName] = myDisplayName as CKRecordValue
        rec[HouseholdSchema.Act.date] = Date() as CKRecordValue
        do {
            let db = (state == .owner) ? privateDB : sharedDB
            _ = try await db.modifyRecords(saving: [rec], deleting: [])
        } catch {
            Log.transfer.error("logActivity failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetch recent activity (newest first) for the feed screen.
    func fetchActivity(limit: Int = 50) async -> [HouseholdActivity] {
        guard state == .owner || state == .member else { return [] }
        let zoneID = ownerZoneIDOrShared()
        let db = (state == .owner) ? privateDB : sharedDB
        let q = CKQuery(recordType: HouseholdSchema.activityType, predicate: NSPredicate(value: true))
        q.sortDescriptors = [NSSortDescriptor(key: HouseholdSchema.Act.date, ascending: false)]
        do {
            let (matches, _) = try await db.records(matching: q, inZoneWith: zoneID, resultsLimit: limit)
            var out: [HouseholdActivity] = []
            for (_, result) in matches {
                guard let r = try? result.get(),
                      let kindRaw = r[HouseholdSchema.Act.kind] as? String,
                      let kind = HouseholdActivity.Kind(rawValue: kindRaw) else { continue }
                out.append(HouseholdActivity(
                    kind: kind,
                    itemName: (r[HouseholdSchema.Act.itemName] as? String) ?? "",
                    actorName: (r[HouseholdSchema.Act.actorName] as? String) ?? "Someone",
                    date: (r[HouseholdSchema.Act.date] as? Date) ?? Date()))
            }
            return out
        } catch {
            Log.transfer.error("fetchActivity failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// The household members, derived from the CKShare participants.
    func fetchMembers() async -> [HouseholdMember] {
        guard state == .owner || state == .member else { return [] }
        do {
            let zoneID = ownerZoneIDOrShared()
            let rootID = CKRecord.ID(recordName: "HouseholdRoot", zoneID: zoneID)
            let db = (state == .owner) ? privateDB : sharedDB
            guard let root = try? await db.record(for: rootID),
                  let shareRef = root.share else { return ownerOnlyMember() }
            guard let share = try? await db.record(for: shareRef.recordID) as? CKShare else {
                return ownerOnlyMember()
            }
            var members: [HouseholdMember] = []
            for p in share.participants {
                let name = p.userIdentity.nameComponents?.formatted() ?? "Member"
                let isOwner = (p.role == .owner)
                let isMe = (p.userIdentity.userRecordID == nil) ? false : (p == share.currentUserParticipant)
                members.append(HouseholdMember(
                    id: p.userIdentity.userRecordID?.recordName ?? UUID().uuidString,
                    name: isMe ? myDisplayName : name,
                    role: isOwner ? .owner : .member,
                    joinedAt: nil,
                    isMe: isMe))
            }
            return members.isEmpty ? ownerOnlyMember() : members
        }
    }

    private func ownerOnlyMember() -> [HouseholdMember] {
        [HouseholdMember(id: "me", name: myDisplayName, role: state == .owner ? .owner : .member, joinedAt: nil, isMe: true)]
    }

    private func ownerZoneIDOrShared() -> CKRecordZone.ID {
        if state == .owner {
            return CKRecordZone.ID(zoneName: HouseholdSchema.zoneName, ownerName: CKCurrentUserDefaultName)
        }
        // Member: the shared zone id is discovered during join; fall back to the default shared zone.
        return CKRecordZone.ID(zoneName: HouseholdSchema.zoneName, ownerName: CKCurrentUserDefaultName)
    }
}
