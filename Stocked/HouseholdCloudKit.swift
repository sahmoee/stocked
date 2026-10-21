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
    // Additive sync-v2 metadata. Older records simply decode as revision zero.
    enum Sync {
        static let updatedAt = "updatedAt"
        static let lastWriterID = "lastWriterID"
        static let recordRevision = "recordRevision"
        static let fieldRevisions = "fieldRevisions"
    }
}

// MARK: - Manager

@MainActor
@Observable
final class HouseholdCloudKit {
    nonisolated deinit {}
    static let shared = HouseholdCloudKit()
    private init() {
        // Restore the persisted household role so launch-time subscription re-registration
        // and sync know whether we're an owner or a member.
        switch UserDefaults.standard.string(forKey: "householdRole") {
        case "owner":  state = .owner
        case "member": state = .member
        default:       state = .idle
        }
        if let name = UserDefaults.standard.string(forKey: "householdMemberZoneName"),
           let owner = UserDefaults.standard.string(forKey: "householdMemberZoneOwner") {
            memberZoneID = CKRecordZone.ID(zoneName: name, ownerName: owner)
        }
        // Restore the previously published join code so it stays visible across launches.
        joinCode = UserDefaults.standard.string(forKey: "householdJoinCode")
        // The owner's zone is deterministic; restore it on launch so sync/code paths don't fail
        // just because the in-memory ownerZoneID wasn't repopulated after a relaunch.
        if state == .owner {
            ownerZoneID = CKRecordZone.ID(zoneName: HouseholdSchema.zoneName,
                                          ownerName: CKCurrentUserDefaultName)
        }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scopeEpoch &+= 1 // Invalidate callbacks before checking the new identity.
                _ = await self.accountAvailable()
            }
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
        scopeEpoch &+= 1
        state = .idle
        ownerZoneID = nil
        joinCode = nil
        memberZoneID = nil
        syncStage = nil
        lastError = nil
        UserDefaults.standard.removeObject(forKey: "householdMemberZoneName")
        UserDefaults.standard.removeObject(forKey: "householdMemberZoneOwner")
        UserDefaults.standard.removeObject(forKey: "householdRole")
        UserDefaults.standard.removeObject(forKey: "householdJoinCode")
        Log.transfer.notice("Left household (local state reset)")
    }

    // The household's custom zone (owner side). Members operate on the shared DB.
    @ObservationIgnored private var ownerZoneID: CKRecordZone.ID?
    @ObservationIgnored private var scopeEpoch: UInt64 = 0
    @ObservationIgnored private var memberZoneID: CKRecordZone.ID?
    @ObservationIgnored private var syncInFlight = false
    @ObservationIgnored private var accountObserver: NSObjectProtocol?

    private func isCurrent(_ epoch: UInt64) -> Bool {
        epoch == scopeEpoch && !Task.isCancelled
    }

    private func rememberMemberZone(_ zone: CKRecordZone.ID) {
        memberZoneID = zone
        UserDefaults.standard.set(zone.zoneName, forKey: "householdMemberZoneName")
        UserDefaults.standard.set(zone.ownerName, forKey: "householdMemberZoneOwner")
    }

    /// Legacy installs may adopt a single household zone, never an arbitrary first zone.
    static func selectMemberZone(_ zones: [CKRecordZone.ID], expected: CKRecordZone.ID?) -> CKRecordZone.ID? {
        if let expected { return zones.first { $0 == expected } }
        let candidates = zones.filter { $0.zoneName == HouseholdSchema.zoneName }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Shared by manual sync and join migration. A failed pull must never upload stale data.
    static func transfer(pull: () async -> Bool, push: () async -> Bool) async -> Bool {
        guard await pull(), !Task.isCancelled else { return false }
        return await push()
    }

    private func failSync(_ message: String) {
        lastError = message
        syncStage = .failed(message)
    }

    // MARK: - Account check

    /// Confirm the user is signed into iCloud before any CloudKit work.
    func accountAvailable() async -> Bool {
        let epoch = scopeEpoch
        do {
            guard try await container.accountStatus() == .available, isCurrent(epoch) else { return false }
            let identity = try await container.userRecordID().recordName
            guard isCurrent(epoch) else { return false }
            let previous = UserDefaults.standard.string(forKey: "householdCloudAccount")
            if let previous, previous != identity {
                leaveHousehold()
                UserDefaults.standard.set(identity, forKey: "householdCloudAccount")
                return false // An account switch requires an explicit new create/join action.
            }
            UserDefaults.standard.set(identity, forKey: "householdCloudAccount")
            return true
        } catch { return false }
    }

    // MARK: - Owner: create the shared household

    /// Create a custom zone and a CKShare for it. Returns the share so the caller can
    /// present UICloudSharingController (the Messages/Mail invite). Idempotent-ish: if a
    /// zone already exists it reuses it.
    func createHousehold() async -> CKShare? {
        scopeEpoch &+= 1
        let epoch = scopeEpoch
        syncStage = .checkingAccount
        guard await accountAvailable() else {
            guard isCurrent(epoch) else { return nil }
            lastError = "Sign into iCloud to start a household."
            syncStage = .failed("Not signed into iCloud. Open Settings and sign in, then try again.")
            return nil
        }
        guard isCurrent(epoch) else { return nil }
        state = .creating
        syncStage = .creating
        let zoneID = CKRecordZone.ID(zoneName: HouseholdSchema.zoneName, ownerName: CKCurrentUserDefaultName)
        let zone = CKRecordZone(zoneID: zoneID)

        do {
            // Create the zone (no-op if it already exists).
            _ = try await privateDB.modifyRecordZones(saving: [zone], deleting: [])
            guard isCurrent(epoch) else { return nil }
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

            guard isCurrent(epoch) else { return nil }
            let share = CKShare(rootRecord: root)
            share[CKShare.SystemFieldKey.title] = "My Stocked. Kitchen" as CKRecordValue
            share.publicPermission = .none   // invite-only

            let saveResult = try await privateDB.modifyRecords(saving: [root, share], deleting: [])
            guard isCurrent(epoch) else { return nil }
            for record in [root, share] {
                guard let outcome = saveResult.saveResults[record.recordID] else { throw CKError(.internalError) }
                _ = try outcome.get()
            }
            state = .owner
            persistRole()
            await registerSubscription(on: privateDB, id: "household-owner-sub")
            guard isCurrent(epoch) else { return nil }

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
                guard isCurrent(epoch) else { return nil }
            }
            if let url = shareURL {
                await publishCodeMapping(shareURL: url)
                guard isCurrent(epoch) else { return nil }
            } else {
                Log.transfer.error("Share URL unavailable after create — join code not published")
                lastError = "Household created, but the join code isn't ready yet. Tap Sync now to finish."
            }
            Log.transfer.notice("Household created with share")
            syncStage = .done(invAdded: 0, groAdded: 0)
            return share
        } catch {
            guard isCurrent(epoch) else { return nil }
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
        scopeEpoch &+= 1
        let epoch = scopeEpoch
        guard await accountAvailable(), isCurrent(epoch) else { return false }
        do {
            _ = try await container.accept(metadata)
            guard isCurrent(epoch) else { return false }
            ownerZoneID = nil
            rememberMemberZone(metadata.share.recordID.zoneID)
            state = .member
            persistRole()
            await registerSubscription(on: sharedDB, id: "household-member-sub")
            guard isCurrent(epoch) else { return false }
            Log.transfer.notice("Accepted household share")
            return true
        } catch {
            guard isCurrent(epoch) else { return false }
            lastError = "Couldn't join household: \(error.localizedDescription)"
            return false
        }
    }

    /// Merge the joiner's existing local pantry into the household: pull what's already
    /// shared (so we adopt it), then push our local items up. Both sides converge with no
    /// duplication because records are keyed by each item's stable UUID.
    /// User-initiated manual sync for an existing household member/owner. Shows progress.
    func syncNow(store: GuestDataStore) async {
        await runTransfer(store: store, joining: false)
    }

    func migrateLocalIntoHousehold(store: GuestDataStore) async {
        await runTransfer(store: store, joining: true)
    }

    private func runTransfer(store: GuestDataStore, joining: Bool) async {
        guard state == .owner || state == .member, !syncInFlight else { return }
        let epoch = scopeEpoch
        syncInFlight = true
        defer { syncInFlight = false }
        lastError = nil
        guard await accountAvailable(), isCurrent(epoch) else {
            if isCurrent(epoch) {
                failSync("Sign into iCloud to sync your household, then try again.")
            }
            return
        }
        if state == .owner, joinCode == nil {
            await republishCodeIfNeeded()
            guard isCurrent(epoch) else { return }
        }
        let before = (store.inventoryItems.count, store.groceryItems.count)
        var after = before
        let completed = await Self.transfer(pull: {
            self.syncStage = .downloading(0)
            guard await self.pull(into: store), self.isCurrent(epoch) else { return false }
            after = (store.inventoryItems.count, store.groceryItems.count)
            return true
        }, push: {
            guard self.isCurrent(epoch) else { return false }
            self.syncStage = .uploading(store.inventoryItems.count)
            return await self.push(store: store)
        })
        guard isCurrent(epoch) else { return }
        guard completed else {
            if case .failed = syncStage { return }
            failSync("Couldn't finish syncing the shared kitchen. Check your connection and try again.")
            return
        }
        if joining, after.0 == 0, after.1 == 0, before.0 == 0, before.1 == 0 {
            failSync("Joined the household, but no items have come through yet. Ask the owner to sync, then try again.")
            return
        }
        syncStage = .done(invAdded: after.0 - before.0, groAdded: after.1 - before.1)
    }

    // MARK: - Code-based join (fallback for people who'd rather type a code than tap a link)

    /// Owner-side recovery: if the household exists but no join code was published, fetch the
    /// existing share's URL and publish a code now. Reports each failure point (instead of
    /// silently returning) so a stuck "owner with no code" state is diagnosable on-device.
    private func republishCodeIfNeeded() async {
        let epoch = scopeEpoch
        guard joinCode == nil else { return }
        let zoneID = ownerZoneID
            ?? CKRecordZone.ID(zoneName: HouseholdSchema.zoneName, ownerName: CKCurrentUserDefaultName)
        let rootID = CKRecord.ID(recordName: "HouseholdRoot", zoneID: zoneID)

        // 1. Fetch the household root record.
        let root: CKRecord
        do {
            root = try await privateDB.record(for: rootID)
            guard isCurrent(epoch) else { return }
        } catch {
            guard isCurrent(epoch) else { return }
            // The root/share doesn't exist — the household was never fully created. Recreate it.
            Log.transfer.error("republishCode: root fetch failed: \(error.localizedDescription, privacy: .public)")
            await recreateShareAndCode(zoneID: zoneID)
            guard isCurrent(epoch) else { return }
            return
        }

        // 2. Get the share reference off the root.
        guard let shareRef = root.share else {
            Log.transfer.notice("republishCode: root has no share; recreating share")
            await recreateShareAndCode(zoneID: zoneID, existingRoot: root)
            guard isCurrent(epoch) else { return }
            return
        }

        // 3. Fetch the share's public URL (with retry) and publish the code.
        let shareURL = await fetchOwnShareURL(shareID: shareRef.recordID)
        guard isCurrent(epoch) else { return }
        if let url = shareURL {
            await publishCodeMapping(shareURL: url)
            guard isCurrent(epoch) else { return }
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
        let epoch = scopeEpoch
        do {
            let root: CKRecord
            if let existingRoot { root = existingRoot }
            else {
                let rootID = CKRecord.ID(recordName: "HouseholdRoot", zoneID: zoneID)
                root = (try? await privateDB.record(for: rootID))
                    ?? CKRecord(recordType: "Household", recordID: rootID)
                guard isCurrent(epoch) else { return }
                if root["createdAt"] == nil { root["createdAt"] = Date() as CKRecordValue }
            }
            guard isCurrent(epoch) else { return }
            let share = CKShare(rootRecord: root)
            share[CKShare.SystemFieldKey.title] = "My Stocked. Kitchen" as CKRecordValue
            share.publicPermission = .none
            let result = try await privateDB.modifyRecords(saving: [root, share], deleting: [])
            guard isCurrent(epoch) else { return }
            var url = (result.saveResults[share.recordID].flatMap { try? $0.get() } as? CKShare)?.url
            if url == nil { url = await fetchOwnShareURL(shareID: share.recordID) }
            guard isCurrent(epoch) else { return }
            if let url {
                await publishCodeMapping(shareURL: url)
                guard isCurrent(epoch) else { return }
            } else {
                lastError = "Created the household share, but the link isn't ready yet. Tap Sync now again in a few seconds."
            }
        } catch {
            guard isCurrent(epoch) else { return }
            lastError = "Couldn't set up sharing: \(error.localizedDescription)"
            Log.transfer.error("recreateShareAndCode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-fetch the owner's CKShare from the private DB to obtain its public .url, which is
    /// NOT available synchronously on the first save. CloudKit can take many seconds to
    /// provision the public share URL, so retry generously (up to ~30s total) before giving up.
    private func fetchOwnShareURL(shareID: CKRecord.ID) async -> URL? {
        let epoch = scopeEpoch
        for attempt in 0..<12 {
            if let share = (try? await privateDB.record(for: shareID)) as? CKShare,
               let url = share.url {
                guard isCurrent(epoch) else { return nil }
                return url
            }
            guard isCurrent(epoch) else { return nil }
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
        let epoch = scopeEpoch
        let code = Self.makeCode()
        let id = CKRecord.ID(recordName: "code_\(code)")
        let rec = CKRecord(recordType: codeMapType, recordID: id)
        rec["shareURL"] = shareURL.absoluteString as CKRecordValue
        rec["createdAt"] = Date() as CKRecordValue
        do {
            _ = try await publicDB.modifyRecords(saving: [rec], deleting: [])
            guard isCurrent(epoch) else { return }
            joinCode = code
            UserDefaults.standard.set(code, forKey: "householdJoinCode")
            lastError = nil
            Log.transfer.notice("Published household join code")
        } catch {
            guard isCurrent(epoch) else { return }
            lastError = "Couldn't publish the join code (public database). \(error.localizedDescription)"
            Log.transfer.error("Code publish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Join a household by entering its code: look up the public mapping, fetch the share
    /// metadata from the URL, and accept it.
    func joinByCode(_ rawCode: String, into store: GuestDataStore) async -> Bool {
        var epoch = scopeEpoch
        syncStage = .checkingAccount
        guard await accountAvailable() else {
            guard isCurrent(epoch) else { return false }
            lastError = "Sign into iCloud to join a household."
            syncStage = .failed("Not signed into iCloud. Open Settings and sign in, then try again.")
            return false
        }
        guard isCurrent(epoch) else { return false }
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
            guard isCurrent(epoch) else { return false }
            guard let urlStr = rec["shareURL"] as? String, let url = URL(string: urlStr) else {
                lastError = "That code didn't match a household."
                syncStage = .failed("That code didn't match a household.")
                return false
            }
            // Fetch the share metadata from the URL, then accept it.
            let metadata = try await fetchShareMetadata(from: url)
            guard isCurrent(epoch) else { return false }
            let ok = await acceptShare(metadata)
            guard ok else { return false }
            epoch = scopeEpoch
            if ok {
                await migrateLocalIntoHousehold(store: store)
                guard isCurrent(epoch) else { return false }
            } else {
                syncStage = .failed(lastError ?? "Couldn't accept the household invite.")
            }
            return ok
        } catch {
            guard isCurrent(epoch) else { return false }
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
        if let u = item.sizeUnit { r[HouseholdSchema.Inv.sizeUnit] = u as CKRecordValue }
        r[HouseholdSchema.Inv.zone] = item.zone as CKRecordValue
        if let e = item.expirationDate { r[HouseholdSchema.Inv.expiration] = e as CKRecordValue }
        if let b = item.brand { r[HouseholdSchema.Inv.brand] = b as CKRecordValue }
        r[HouseholdSchema.Inv.level] = item.level as CKRecordValue
        r[HouseholdSchema.Sync.updatedAt] = item.updatedAt as CKRecordValue
        r[HouseholdSchema.Sync.lastWriterID] = item.lastWriterID as CKRecordValue
        r[HouseholdSchema.Sync.recordRevision] = Int64(max(0, item.updatedAt)) as CKRecordValue
        r[HouseholdSchema.Sync.fieldRevisions] = revisionData(
            fields: ["name": item.updatedAt, "quantity": item.updatedAt,
                     "zone": item.updatedAt, "level": item.updatedAt]) as CKRecordValue
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
        item.updatedAt = (r[HouseholdSchema.Sync.updatedAt] as? Double) ?? 0
        item.lastWriterID = (r[HouseholdSchema.Sync.lastWriterID] as? String) ?? ""
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
        r[HouseholdSchema.Sync.updatedAt] = item.updatedAt as CKRecordValue
        r[HouseholdSchema.Sync.lastWriterID] = item.lastWriterID as CKRecordValue
        r[HouseholdSchema.Sync.recordRevision] = Int64(max(0, item.updatedAt)) as CKRecordValue
        r[HouseholdSchema.Sync.fieldRevisions] = revisionData(
            fields: ["name": item.updatedAt, "quantity": item.updatedAt,
                     "isChecked": item.updatedAt]) as CKRecordValue
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
        item.updatedAt = (r[HouseholdSchema.Sync.updatedAt] as? Double) ?? 0
        item.lastWriterID = (r[HouseholdSchema.Sync.lastWriterID] as? String) ?? ""
        return item
    }

    private func revisionData(fields: [String: Double]) -> Data {
        (try? JSONEncoder().encode(fields)) ?? Data()
    }

    // MARK: - Push / pull (Session 1: manual; later: CKSyncEngine + subscriptions)

    /// Resolve the zone + database to operate on (owner uses private, member uses shared).
    private func activeZoneAndDB() async -> (CKRecordZone.ID, CKDatabase)? {
        let epoch = scopeEpoch
        guard state == .owner || state == .member else { return nil }
        guard await accountAvailable(), isCurrent(epoch) else { return nil }
        if state == .owner {
            let zone = ownerZoneID ?? CKRecordZone.ID(zoneName: HouseholdSchema.zoneName,
                                                      ownerName: CKCurrentUserDefaultName)
            return (zone, privateDB)
        }
        for _ in 0..<6 {
            let zones = try? await sharedDB.allRecordZones()
            guard isCurrent(epoch), state == .member else { return nil }
            if let zone = Self.selectMemberZone(zones?.map(\.zoneID) ?? [], expected: memberZoneID) {
                rememberMemberZone(zone)
                return (zone, sharedDB)
            }
            // Multiple legacy memberships require selecting the intended invitation again.
            if memberZoneID == nil, (zones?.count ?? 0) > 1 { return nil }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) }
            catch { return nil }
        }
        return nil
    }

    /// Push the full local pantry to the shared zone, with conflict handling.
    @discardableResult
    func push(store: GuestDataStore) async -> Bool {
        let epoch = scopeEpoch
        guard let (zoneID, db) = await activeZoneAndDB(), isCurrent(epoch) else { return false }
        let records = store.inventoryItems.map { record(from: $0, zoneID: zoneID) }
                    + store.groceryItems.map { record(from: $0, zoneID: zoneID) }
        let capturedTombstones = store.householdTombstoneSnapshot()
        let inventoryDeletes = capturedTombstones.inventory.compactMap(UUID.init(uuidString:)).map {
            CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)
        }
        let groceryDeletes = capturedTombstones.grocery.compactMap(UUID.init(uuidString:)).map {
            CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)
        }
        let deleteIDs = inventoryDeletes + groceryDeletes
        do {
            let result = try await db.modifyRecords(saving: records, deleting: deleteIDs,
                                                    savePolicy: .changedKeys)
            guard isCurrent(epoch) else { return false }
            // Inspect for per-record conflicts (someone else changed the same record).
            var conflicts: [CKRecord] = []
            for record in records {
                guard let saveResult = result.saveResults[record.recordID] else {
                    throw CKError(.internalError)
                }
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
                } else { _ = try saveResult.get() }
            }
            for id in deleteIDs {
                guard let outcome = result.deleteResults[id] else { throw CKError(.internalError) }
                _ = try outcome.get()
            }
            if !conflicts.isEmpty {
                let retried = try await db.modifyRecords(saving: conflicts, deleting: [], savePolicy: .changedKeys)
                guard isCurrent(epoch) else { return false }
                for record in conflicts {
                    guard let outcome = retried.saveResults[record.recordID] else { throw CKError(.internalError) }
                    _ = try outcome.get()
                }
                Log.transfer.notice("Resolved \(conflicts.count, privacy: .public) household conflicts")
            }
            let acknowledgedDeletes = Set(result.deleteResults.compactMap { id, outcome in
                if case .success = outcome { return id.recordName }
                return nil
            })
            if !acknowledgedDeletes.isEmpty {
                store.acknowledgeHouseholdTombstones(HouseholdTombstoneState(
                    inventory: capturedTombstones.inventory.intersection(acknowledgedDeletes),
                    grocery: capturedTombstones.grocery.intersection(acknowledgedDeletes),
                    revision: capturedTombstones.revision,
                    deletedAt: capturedTombstones.deletedAt.filter {
                        acknowledgedDeletes.contains($0.key)
                    }))
            }
            Log.transfer.notice("Pushed \(records.count, privacy: .public) household records")
            return true
        } catch {
            guard isCurrent(epoch) else { return false }
            failSync("Sync push failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Pull all records from the shared zone and merge into the local store.
    /// Uses CKFetchRecordZoneChangesOperation rather than CKQuery so it does NOT require the
    /// recordName field to be marked queryable in the CloudKit schema (which is what caused
    /// "Field 'recordName' is not marked queryable"). Also yields a change token for delta sync.
    @discardableResult
    func pull(into store: GuestDataStore) async -> Bool {
        let epoch = scopeEpoch
        guard let (zoneID, db) = await activeZoneAndDB(), isCurrent(epoch) else { return false }
        var inv: [LocalInventoryItem] = []
        var gro: [LocalGroceryItem] = []
        var deletedInventory = Set<UUID>()
        var deletedGrocery = Set<UUID>()

        // Resume from a saved change token if we have one (delta sync; nil = full fetch).
        // Owner identity is part of the checkpoint scope; legacy zone-only tokens cannot
        // be reused after an account/owner change. A fresh scoped key safely replays once.
        guard let account = UserDefaults.standard.string(forKey: "householdCloudAccount") else { return false }
        let tokenScope = Data((account + "\u{0}" + zoneID.ownerName + "\u{0}" + zoneID.zoneName).utf8).base64EncodedString()
        let tokenKey = "householdZoneToken_v3_" + tokenScope
        var stagedToken: Data?
        var recordFailure: Error?
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
                    guard case .success(let rec) = result else {
                        if case .failure(let error) = result { recordFailure = error }
                        return
                    }
                    if rec.recordType == HouseholdSchema.inventoryType {
                        guard let item = self.inventoryItem(from: rec) else { recordFailure = CKError(.internalError); return }
                        inv.append(item)
                    }
                    if rec.recordType == HouseholdSchema.groceryType {
                        guard let item = self.groceryItem(from: rec) else { recordFailure = CKError(.internalError); return }
                        gro.append(item)
                    }
                    let total = inv.count + gro.count
                    Task { @MainActor in
                        guard self.isCurrent(epoch) else { return }
                        if case .downloading = self.syncStage { self.syncStage = .downloading(total) }
                    }
                }
                op.recordWithIDWasDeletedBlock = { recordID, recordType in
                    guard let id = UUID(uuidString: recordID.recordName) else { return }
                    if recordType == HouseholdSchema.inventoryType { deletedInventory.insert(id) }
                    if recordType == HouseholdSchema.groceryType { deletedGrocery.insert(id) }
                }
                op.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
                    if let token, let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                        stagedToken = data
                    }
                }
                op.recordZoneFetchResultBlock = { _, result in
                    if case .failure(let error) = result { recordFailure = error }
                    if case .success(let (token, _, _)) = result,
                       let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                        stagedToken = data
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
            guard isCurrent(epoch) else { return false }
            if let recordFailure { throw recordFailure }
            // Remote rows must bypass local mutation permission/restamping/queue hooks.
            // Keep this suppression strictly synchronous; user actions never run under it.
            Self.applyRemoteChanges(to: store) {
                mergeInventory(remote: inv, deleted: deletedInventory, into: store)
                mergeGrocery(remote: gro, deleted: deletedGrocery, into: store)
            }
            // Do not checkpoint an in-memory/coalesced merge. If either durable write fails,
            // leave the previous token intact so the idempotent merge replays on retry.
            try LocalDatabase.shared.saveDataDurably(JSONEncoder().encode(store.inventoryItems), key: DBKey.inventoryItems.rawValue)
            try LocalDatabase.shared.saveDataDurably(JSONEncoder().encode(store.groceryItems), key: DBKey.groceryItems.rawValue)
            if let stagedToken { UserDefaults.standard.set(stagedToken, forKey: tokenKey) }
            Log.transfer.notice("Pulled household: \(inv.count, privacy: .public) inv, \(gro.count, privacy: .public) gro")
            return true
        } catch {
            guard isCurrent(epoch) else { return false }
            // If our saved change token went stale, clear it and do a full re-fetch once.
            if let ck = error as? CKError, ck.code == .changeTokenExpired, savedToken != nil {
                UserDefaults.standard.removeObject(forKey: tokenKey)
                Log.transfer.notice("Change token expired; retrying full pull")
                return await pull(into: store)
            } else {
                lastError = "Sync pull failed: \(error.localizedDescription)"
                syncStage = .failed("Sync failed: \(error.localizedDescription)")
                return false
            }
        }
    }

    static func applyRemoteChanges(to store: GuestDataStore, _ changes: () -> Void) {
        let wasApplyingRemote = store.isApplyingHouseholdRemote
        store.isApplyingHouseholdRemote = true
        defer { store.isApplyingHouseholdRemote = wasApplyingRemote }
        changes()
    }

    // TOMBSTONE-AWARE (July 2026) — same fix as SharedPantrySync.mergeGrocery, and
    // it has to be made in both: this path runs for CloudKit households, that one
    // for the key-value store, and a delete that survives one merge only to be
    // undone by the other is still a delete that does not stick.
    private func mergeInventory(remote: [LocalInventoryItem], deleted: Set<UUID> = [],
                                into store: GuestDataStore) {
        let tombstones = store.pendingInvTombstones
        var byID = Dictionary(keepingLastValues: store.inventoryItems.map { ($0.id, $0) })
        for id in deleted where !tombstones.contains(id.uuidString) { byID[id] = nil }
        for item in remote where !tombstones.contains(item.id.uuidString) {
            if let local = byID[item.id] {
                if HouseholdMergePolicy.remoteWins(remoteUpdatedAt: item.updatedAt,
                                                    remoteWriterID: item.lastWriterID,
                                                    localUpdatedAt: local.updatedAt,
                                                    localWriterID: local.lastWriterID) {
                    byID[item.id] = item
                }
            } else { byID[item.id] = item }
        }
        let merged = Array(byID.values)
            .filter { !tombstones.contains($0.id.uuidString) }
            .sorted { $0.name < $1.name }
        if merged != store.inventoryItems { store.inventoryItems = merged }
    }
    private func mergeGrocery(remote: [LocalGroceryItem], deleted: Set<UUID> = [],
                              into store: GuestDataStore) {
        let tombstones = store.pendingGroTombstones
        var byID = Dictionary(keepingLastValues: store.groceryItems.map { ($0.id, $0) })
        for id in deleted where !tombstones.contains(id.uuidString) { byID[id] = nil }
        for item in remote where !tombstones.contains(item.id.uuidString) {
            if let local = byID[item.id] {
                if HouseholdMergePolicy.remoteWins(remoteUpdatedAt: item.updatedAt,
                                                    remoteWriterID: item.lastWriterID,
                                                    localUpdatedAt: local.updatedAt,
                                                    localWriterID: local.lastWriterID) {
                    byID[item.id] = item
                }
            } else { byID[item.id] = item }
        }
        let merged = Array(byID.values).filter { !tombstones.contains($0.id.uuidString) }
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
        let epoch = scopeEpoch
        guard let (zoneID, db) = await activeZoneAndDB(), isCurrent(epoch) else { return }
        let rec = CKRecord(recordType: HouseholdSchema.activityType,
                           recordID: CKRecord.ID(recordName: "act_\(UUID().uuidString)", zoneID: zoneID))
        rec[HouseholdSchema.Act.kind] = kind.rawValue as CKRecordValue
        rec[HouseholdSchema.Act.itemName] = itemName as CKRecordValue
        rec[HouseholdSchema.Act.actorName] = myDisplayName as CKRecordValue
        rec[HouseholdSchema.Act.date] = Date() as CKRecordValue
        do {
            _ = try await db.modifyRecords(saving: [rec], deleting: [])
        } catch {
            Log.transfer.error("logActivity failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetch recent activity (newest first) for the feed screen.
    func fetchActivity(limit: Int = 50) async -> [HouseholdActivity] {
        guard state == .owner || state == .member else { return [] }
        let epoch = scopeEpoch
        guard let (zoneID, db) = await activeZoneAndDB(), isCurrent(epoch) else { return [] }
        let q = CKQuery(recordType: HouseholdSchema.activityType, predicate: NSPredicate(value: true))
        q.sortDescriptors = [NSSortDescriptor(key: HouseholdSchema.Act.date, ascending: false)]
        do {
            let (matches, _) = try await db.records(matching: q, inZoneWith: zoneID, resultsLimit: limit)
            guard isCurrent(epoch) else { return [] }
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
        let epoch = scopeEpoch
        guard let (zoneID, db) = await activeZoneAndDB(), isCurrent(epoch) else { return [] }
        do {
            let rootID = CKRecord.ID(recordName: "HouseholdRoot", zoneID: zoneID)
            guard let root = try? await db.record(for: rootID),
                  let shareRef = root.share else { return ownerOnlyMember() }
            guard isCurrent(epoch) else { return [] }
            guard let share = try? await db.record(for: shareRef.recordID) as? CKShare else {
                return ownerOnlyMember()
            }
            guard isCurrent(epoch) else { return [] }
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
}
