// KitchenTransferManager.swift
// Handles all kitchen data export, import, backup, and transfer operations.
import SwiftUI
import Combine
import CloudKit
import CryptoKit
import CoreImage.CIFilterBuiltins
import os
import Security

// MARK: - Kitchen Preferences (settings carried in a backup)
// Optional in the snapshot so older backups without it still decode cleanly.
// nonisolated: pure value type; its Codable conformance is used by JSONDecoder off the main
// actor during import, so it must not infer main-actor isolation.
nonisolated struct KitchenPreferences: Codable, Sendable {
    // Theme (light/dark + font only — custom color channels removed)
    var appTheme: String          = ""
    var appFont: String           = ""
    var isDarkMode: Bool          = false
    // Behavior / shopping
    var preferredStore: String    = ""
    var autoAddMissingToGrocery: Bool = true
    var notificationsEnabled: Bool = true
    var homeButtonLayout: String  = ""
    var cookButtonShape: String   = ""
    var cookButtonSize: Double    = 0
    var preferredRecipeTab: Int   = 0
    // Streaks / history
    var cookStreak: Int           = 0
    var longestStreak: Int        = 0
}

// MARK: - Complete feature snapshot

/// Feature stores have their own persistence owners, but they belong in the same kitchen backup.
/// Keeping this optional at the snapshot boundary makes every schema-2 backup decode unchanged.
nonisolated struct KitchenFeatureSnapshot: Codable, Sendable {
    var leftovers: [LeftoverEntry] = []
    var familyProfiles: [EaterProfile] = []
    var events: [KitchenEvent] = []
    var sharedExpenses: [SharedExpense] = []
    var splitPeople: [String] = []
    var storeLayouts: [StoreLayout] = []
    var activeStore: String = ""
    var gardenHarvests: [HarvestEntry] = []
    var containerLabels: [ContainerLabel] = []
    var takeoutLog: [TakeoutEntry] = []
    // Optional keys preserve older feature snapshots. Missing fields never clear a newer store.
    var scheduledMeals: [ScheduledMeal]? = nil
    var mealPlanRules: [MealPlanRule]? = nil
    var mealPlanTemplates: [MealPlanTemplate]? = nil
    var smartCookbooks: [SmartCookbookRule]? = nil
}

// MARK: - Versioned backup contract

nonisolated enum KitchenRestoreSection: String, Codable, CaseIterable, Hashable, Sendable {
    case profile
    case inventory
    case grocery
    case mealHistory
    case recipes
    case mealPlans
    case preferences
    case features
}

nonisolated struct KitchenRestoreSelection: Sendable, Equatable {
    var sections: Set<KitchenRestoreSection>
    var merge: Bool

    init(sections: Set<KitchenRestoreSection> = Set(KitchenRestoreSection.allCases),
         merge: Bool = false) {
        self.sections = sections
        self.merge = merge
    }

    static let all = KitchenRestoreSelection()
}

nonisolated struct KitchenBackupSectionManifest: Codable, Sendable, Equatable {
    var section: KitchenRestoreSection
    var recordCount: Int
    var checksum: String
}

nonisolated struct KitchenBackupMediaEntry: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case inventoryPhoto, platePhoto, userRecipeImage, generatedRecipeImage }
    var kind: Kind
    var ownerID: String
    var byteCount: Int
    var checksum: String
    /// Media is currently embedded in the encrypted payload. This stable logical path lets a
    /// future streaming format externalize it without changing restore identity.
    var logicalPath: String
}

nonisolated struct KitchenBackupManifest: Codable, Sendable, Equatable {
    static let currentFormatVersion = 3
    static let formatIdentifier = "stocked.kitchen.backup"

    var format: String = formatIdentifier
    var formatVersion: Int = currentFormatVersion
    var snapshotSchemaVersion: Int
    var createdAt: Date
    var displayName: String
    var encrypted: Bool = true
    var algorithm: String = "AES.GCM.256+HMAC.SHA256"
    var keyID: String
    var payloadByteCount: Int
    var payloadChecksum: String
    var ciphertextChecksum: String
    var sections: [KitchenBackupSectionManifest]
    var media: [KitchenBackupMediaEntry]
}

nonisolated struct KitchenBackupEnvelope: Codable, Sendable {
    var manifest: KitchenBackupManifest
    var sealedPayload: Data
    /// Authenticates the otherwise-readable manifest together with the encrypted bytes.
    var manifestAuthentication: Data
}

nonisolated struct KitchenBackupPreview: Sendable, Equatable {
    var manifest: KitchenBackupManifest
    var counts: [KitchenRestoreSection: Int]
    var isEncrypted: Bool
    var checksumVerified: Bool
    var warnings: [String]
}

nonisolated struct KitchenRestoreReceipt: Sendable, Equatable {
    var restoredAt: Date
    var sections: Set<KitchenRestoreSection>
    var counts: [KitchenRestoreSection: Int]
    var merged: Bool
    var rollbackAvailable: Bool
}

nonisolated private struct KitchenRestoreRollbackJournal: Codable, Sendable {
    var createdAt: Date
    var package: Data
}

nonisolated private struct KitchenICloudBackupPayload: Sendable {
    var package: Data
    var recoveryKey: Data?
    var keyID: String?
}

nonisolated enum KitchenBackupError: LocalizedError, Equatable {
    case malformedPackage
    case unsupportedVersion(Int)
    case invalidFormat
    case integrityCheckFailed
    case encryptionFailed
    case decryptionFailed
    case keychain(OSStatus)
    case rollbackUnavailable
    case permissionDenied(HouseholdPermission)

    var errorDescription: String? {
        switch self {
        case .malformedPackage: return "The backup package is unreadable."
        case .unsupportedVersion(let version): return "This backup uses unsupported format version \(version)."
        case .invalidFormat: return "This file is not a Stocked kitchen backup."
        case .integrityCheckFailed: return "The backup did not pass its integrity check."
        case .encryptionFailed: return "The kitchen backup could not be encrypted."
        case .decryptionFailed: return "This backup cannot be decrypted on this Apple ID."
        case .keychain(let status): return "The secure backup key is unavailable (\(status))."
        case .rollbackUnavailable: return "No restore rollback is available."
        case .permissionDenied(let permission):
            return permission == .backupExport
                ? "You don't have permission to export household backups."
                : "You don't have permission to restore household backups."
        }
    }
}

// MARK: - Kitchen Snapshot
// nonisolated: decoded by JSONDecoder off the main actor; pure value type.
nonisolated struct KitchenSnapshot: Codable, Sendable {
    var schemaVersion:   Int    = 3
    var exportedAt:      String
    var displayName:     String
    var inventoryItems:  [LocalInventoryItem]
    var groceryItems:    [LocalGroceryItem]
    var pastMeals:       [LocalPastMeal]
    var savedRecipes:    [LocalRecipe]
    var userRecipes:     [UserRecipe]?      = nil   // optional → old backups still decode
    var generatedRecipes: [GeneratedRecipe]? = nil
    var plannedMeals:     [PlannedMeal]? = nil
    var preferences:     KitchenPreferences? = nil   // optional → old backups still decode
    var features:        KitchenFeatureSnapshot? = nil

    init(displayName: String, inventoryItems: [LocalInventoryItem],
         groceryItems: [LocalGroceryItem], pastMeals: [LocalPastMeal],
         userRecipes: [UserRecipe]? = nil,
         generatedRecipes: [GeneratedRecipe]? = nil,
         plannedMeals: [PlannedMeal]? = nil,
         preferences: KitchenPreferences? = nil,
         features: KitchenFeatureSnapshot? = nil) {
        self.exportedAt     = ISO8601DateFormatter().string(from: Date())
        self.displayName    = displayName
        self.inventoryItems = inventoryItems
        self.groceryItems   = groceryItems
        self.pastMeals      = pastMeals
        self.savedRecipes   = []
        self.userRecipes    = userRecipes
        self.generatedRecipes = generatedRecipes
        self.plannedMeals = plannedMeals
        self.preferences    = preferences
        self.features = features
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, exportedAt, displayName, inventoryItems, groceryItems, pastMeals,
             savedRecipes, userRecipes, generatedRecipes, plannedMeals, preferences, features
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        exportedAt = try c.decodeIfPresent(String.self, forKey: .exportedAt) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "My Kitchen"
        inventoryItems = try c.decodeIfPresent([LocalInventoryItem].self, forKey: .inventoryItems) ?? []
        groceryItems = try c.decodeIfPresent([LocalGroceryItem].self, forKey: .groceryItems) ?? []
        pastMeals = try c.decodeIfPresent([LocalPastMeal].self, forKey: .pastMeals) ?? []
        savedRecipes = try c.decodeIfPresent([LocalRecipe].self, forKey: .savedRecipes) ?? []
        userRecipes = try c.decodeIfPresent([UserRecipe].self, forKey: .userRecipes)
        generatedRecipes = try c.decodeIfPresent([GeneratedRecipe].self, forKey: .generatedRecipes)
        plannedMeals = try c.decodeIfPresent([PlannedMeal].self, forKey: .plannedMeals)
        preferences = try c.decodeIfPresent(KitchenPreferences.self, forKey: .preferences)
        features = try c.decodeIfPresent(KitchenFeatureSnapshot.self, forKey: .features)
    }
}

// MARK: - Pure backup codec

/// Authenticated encrypted package operations. Keychain access is deliberately outside this type
/// so integrity/version behavior is deterministic and directly testable with an injected key.
nonisolated enum KitchenBackupCodec {
    static func seal(_ snapshot: KitchenSnapshot, using key: SymmetricKey,
                     createdAt: Date = Date()) throws -> Data {
        let encoder = canonicalEncoder()
        let payload: Data
        do { payload = try encoder.encode(snapshot) }
        catch { throw KitchenBackupError.encryptionFailed }

        let sealed: Data
        do {
            guard let combined = try AES.GCM.seal(payload, using: key).combined else {
                throw KitchenBackupError.encryptionFailed
            }
            sealed = combined
        } catch let error as KitchenBackupError {
            throw error
        } catch {
            throw KitchenBackupError.encryptionFailed
        }

        var manifest = makeManifest(snapshot: snapshot, payload: payload, key: key, createdAt: createdAt)
        manifest.ciphertextChecksum = checksum(sealed)
        let manifestData = try encoder.encode(manifest)
        let authenticated = manifestData + sealed
        let mac = Data(HMAC<SHA256>.authenticationCode(for: authenticated, using: key))
        let envelope = KitchenBackupEnvelope(manifest: manifest, sealedPayload: sealed,
                                             manifestAuthentication: mac)
        do { return try encoder.encode(envelope) }
        catch { throw KitchenBackupError.encryptionFailed }
    }

    static func open(_ package: Data, using key: SymmetricKey) throws
        -> (snapshot: KitchenSnapshot, manifest: KitchenBackupManifest) {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(KitchenBackupEnvelope.self, from: package) else {
            throw KitchenBackupError.malformedPackage
        }
        let manifest = envelope.manifest
        guard manifest.format == KitchenBackupManifest.formatIdentifier else {
            throw KitchenBackupError.invalidFormat
        }
        guard (1...KitchenBackupManifest.currentFormatVersion).contains(manifest.formatVersion) else {
            throw KitchenBackupError.unsupportedVersion(manifest.formatVersion)
        }
        guard manifest.encrypted,
              manifest.payloadByteCount >= 0,
              checksum(envelope.sealedPayload) == manifest.ciphertextChecksum else {
            throw KitchenBackupError.integrityCheckFailed
        }
        let manifestData = try canonicalEncoder().encode(manifest)
        let authenticated = manifestData + envelope.sealedPayload
        guard HMAC<SHA256>.isValidAuthenticationCode(
            envelope.manifestAuthentication, authenticating: authenticated, using: key
        ) else {
            throw KitchenBackupError.integrityCheckFailed
        }
        let payload: Data
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealedPayload)
            payload = try AES.GCM.open(box, using: key)
        } catch {
            throw KitchenBackupError.decryptionFailed
        }
        guard payload.count == manifest.payloadByteCount,
              checksum(payload) == manifest.payloadChecksum else {
            throw KitchenBackupError.integrityCheckFailed
        }
        let snapshot: KitchenSnapshot
        do { snapshot = try decoder.decode(KitchenSnapshot.self, from: payload) }
        catch { throw KitchenBackupError.malformedPackage }
        guard snapshot.schemaVersion == manifest.snapshotSchemaVersion else {
            throw KitchenBackupError.integrityCheckFailed
        }
        let expected = makeManifest(snapshot: snapshot, payload: payload, key: key,
                                    createdAt: manifest.createdAt)
        guard expected.displayName == manifest.displayName,
              expected.keyID == manifest.keyID,
              expected.sections == manifest.sections,
              expected.media == manifest.media else {
            throw KitchenBackupError.integrityCheckFailed
        }
        return (snapshot, manifest)
    }

    static func isEncryptedPackage(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(KitchenBackupEnvelope.self, from: data)) != nil
    }

    static func manifest(in data: Data) -> KitchenBackupManifest? {
        try? JSONDecoder().decode(KitchenBackupEnvelope.self, from: data).manifest
    }

    static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func keyIdentifier(for key: SymmetricKey) -> String {
        let bytes = key.withUnsafeBytes { Data($0) }
        return String(checksum(bytes).prefix(16))
    }

    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func encodedChecksum<T: Encodable>(_ value: T) -> String {
        guard let data = try? canonicalEncoder().encode(value) else { return "" }
        return checksum(data)
    }

    private static func makeManifest(snapshot: KitchenSnapshot, payload: Data,
                                     key: SymmetricKey, createdAt: Date) -> KitchenBackupManifest {
        let features = snapshot.features
        var sections = [
            KitchenBackupSectionManifest(section: .profile, recordCount: 1,
                                         checksum: encodedChecksum(snapshot.displayName)),
            KitchenBackupSectionManifest(section: .inventory, recordCount: snapshot.inventoryItems.count,
                                         checksum: encodedChecksum(snapshot.inventoryItems)),
            KitchenBackupSectionManifest(section: .grocery, recordCount: snapshot.groceryItems.count,
                                         checksum: encodedChecksum(snapshot.groceryItems)),
            KitchenBackupSectionManifest(section: .mealHistory, recordCount: snapshot.pastMeals.count,
                                         checksum: encodedChecksum(snapshot.pastMeals)),
            KitchenBackupSectionManifest(section: .recipes,
                                         recordCount: snapshot.savedRecipes.count + (snapshot.userRecipes?.count ?? 0) + (snapshot.generatedRecipes?.count ?? 0),
                                         checksum: encodedChecksum([encodedChecksum(snapshot.savedRecipes), encodedChecksum(snapshot.userRecipes ?? []), encodedChecksum(snapshot.generatedRecipes ?? [])])),
            KitchenBackupSectionManifest(section: .mealPlans, recordCount: snapshot.plannedMeals?.count ?? 0,
                                         checksum: encodedChecksum(snapshot.plannedMeals ?? [])),
            KitchenBackupSectionManifest(section: .preferences, recordCount: snapshot.preferences == nil ? 0 : 1,
                                         checksum: encodedChecksum(snapshot.preferences)),
            KitchenBackupSectionManifest(section: .features,
                                         recordCount: featureCount(features), checksum: encodedChecksum(features)),
        ]
        sections.sort { $0.section.rawValue < $1.section.rawValue }

        var media: [KitchenBackupMediaEntry] = []
        func addMedia(_ data: Data?, kind: KitchenBackupMediaEntry.Kind, owner: String) {
            guard let data, !data.isEmpty else { return }
            media.append(KitchenBackupMediaEntry(kind: kind, ownerID: owner,
                byteCount: data.count, checksum: checksum(data),
                logicalPath: "media/\(kind.rawValue)/\(owner)"))
        }
        snapshot.inventoryItems.forEach { addMedia($0.imageData, kind: .inventoryPhoto, owner: $0.id.uuidString) }
        snapshot.pastMeals.forEach { addMedia($0.platePhotoData, kind: .platePhoto, owner: $0.id.uuidString) }
        (snapshot.userRecipes ?? []).forEach { addMedia($0.imageData, kind: .userRecipeImage, owner: $0.id.uuidString) }
        (snapshot.generatedRecipes ?? []).forEach { addMedia($0.imageData, kind: .generatedRecipeImage, owner: $0.id.uuidString) }
        media.sort { $0.logicalPath < $1.logicalPath }

        let keyID = keyIdentifier(for: key)
        return KitchenBackupManifest(snapshotSchemaVersion: snapshot.schemaVersion,
            createdAt: createdAt, displayName: snapshot.displayName, keyID: keyID,
            payloadByteCount: payload.count, payloadChecksum: checksum(payload),
            ciphertextChecksum: "", sections: sections, media: media)
    }

    private static func featureCount(_ value: KitchenFeatureSnapshot?) -> Int {
        guard let value else { return 0 }
        return value.leftovers.count + value.familyProfiles.count + value.events.count
            + value.sharedExpenses.count + value.splitPeople.count + value.storeLayouts.count
            + value.gardenHarvests.count + value.containerLabels.count + value.takeoutLog.count
            + (value.scheduledMeals?.count ?? 0) + (value.mealPlanRules?.count ?? 0)
            + (value.mealPlanTemplates?.count ?? 0) + (value.smartCookbooks?.count ?? 0)
    }
}

// MARK: - Secure key owner

/// Synchronizable key ring. `primary` remains the current write key while key-id aliases retain
/// every historical/recovered key, so importing one old backup never invalidates another.
nonisolated enum KitchenBackupKeyStore {
    private static let service = "com.sowens.Stocked.kitchenBackupKey.v1"
    private static let primaryAccount = "primary"

    static func loadOrCreate() throws -> SymmetricKey {
        if let data = try load(account: primaryAccount) {
            let key = SymmetricKey(data: data)
            try saveAliasIfNeeded(data, keyID: KitchenBackupCodec.keyIdentifier(for: key))
            return key
        }
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        try save(bytes, account: primaryAccount)
        try saveAliasIfNeeded(bytes, keyID: KitchenBackupCodec.keyIdentifier(for: key))
        return key
    }

    static func key(matching keyID: String) throws -> SymmetricKey? {
        if let data = try load(account: keyID) {
            let key = SymmetricKey(data: data)
            // A key-id alias is only authoritative when its bytes still hash to that id.
            // Treat a damaged/stale alias as absent so CloudKit's encrypted recovery field
            // can repair it instead of making an otherwise valid backup unrestorable.
            if KitchenBackupCodec.keyIdentifier(for: key) == keyID { return key }
        }
        // Migration for packages made before key-id aliases existed.
        if let primary = try load(account: primaryAccount) {
            let key = SymmetricKey(data: primary)
            if KitchenBackupCodec.keyIdentifier(for: key) == keyID {
                try saveAliasIfNeeded(primary, keyID: keyID)
                return key
            }
        }
        return nil
    }

    static func rawKeyData(matching keyID: String) throws -> Data? {
        guard let key = try key(matching: keyID) else { return nil }
        return key.withUnsafeBytes { Data($0) }
    }

    @discardableResult
    static func importRecoveryKey(_ data: Data, keyID: String) throws -> SymmetricKey {
        guard data.count == 32 else { throw KitchenBackupError.decryptionFailed }
        let key = SymmetricKey(data: data)
        guard KitchenBackupCodec.keyIdentifier(for: key) == keyID else {
            throw KitchenBackupError.integrityCheckFailed
        }
        try saveAliasIfNeeded(data, keyID: keyID)
        return key
    }

    private static func saveAliasIfNeeded(_ data: Data, keyID: String) throws {
        if let existing = try load(account: keyID) {
            let existingKey = SymmetricKey(data: existing)
            if KitchenBackupCodec.keyIdentifier(for: existingKey) == keyID { return }
            try update(data, account: keyID)
        } else {
            try save(data, account: keyID)
        }
    }

    private static func update(_ data: Data, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else { throw KitchenBackupError.keychain(status) }
    }

    private static func save(_ data: Data, account: String) throws {
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanTrue as Any,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: data,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem { return }
        throw KitchenBackupError.keychain(status)
    }

    private static func load(account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KitchenBackupError.keychain(status) }
        return result as? Data
    }
}

// MARK: - Transfer Manager
@Observable
@MainActor
class KitchenTransferManager {
    // Explicit container ID — must match the single entry in Stocked.entitlements
    private let cloudContainer = CKContainer(identifier: "iCloud.Stocked")

    // #5: Normalized dedup key — trims, lowercases, and collapses internal whitespace so
    // "Whole Milk", "whole milk ", and "whole  milk" all dedupe as the same item.
    private func normKey(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // Set by the presenting view so backups can include + restore app preferences
    // (theme, colors, preferred store, etc.) which live on AppSession, not the store.
    weak var session: AppSession?

    var isExporting      = false
    var isImporting      = false
    var isBacking        = false
    var statusMessage    = ""
    var errorMessage     = ""

    /// True while the first-launch iCloud restore check is running. RootView watches this so a
    /// returning user briefly sees the splash instead of the onboarding quiz, until we know
    /// whether their Apple ID has an existing Stocked backup to restore.
    var isCheckingForExistingAccount = false
    var qrCodeImage:     UIImage?
    var shareURL:        URL?
    var exportedFileURL: URL?
    var iCloudStatus     = "Not checked"

    @discardableResult
    private func requirePermission(_ permission: HouseholdPermission) -> Bool {
        guard HouseholdSync.shared.can(permission) else {
            let error = KitchenBackupError.permissionDenied(permission)
            errorMessage = error.localizedDescription
            statusMessage = ""
            return false
        }
        return true
    }

    private func requirePermissionOrThrow(_ permission: HouseholdPermission) throws {
        guard requirePermission(permission) else { throw KitchenBackupError.permissionDenied(permission) }
    }

    // MARK: - Snapshot builder (always on main thread via caller)
    private func makeSnapshot(store: GuestDataStore) -> KitchenSnapshot {
        KitchenSnapshot(
            displayName:    store.displayName,
            inventoryItems: store.inventoryItems,
            groceryItems:   store.groceryItems,
            pastMeals:      store.pastMeals,
            userRecipes:    store.userRecipes,
            generatedRecipes: store.savedGeneratedRecipes,
            plannedMeals: store.plannedMeals,
            preferences:    session?.capturePreferences(),
            features: FeatureSync.shared.backupSnapshot()
        )
    }

    /// Produce the durable `.stocked` representation. JSON/CSV/Text exports intentionally remain
    /// readable interoperability formats; backups and `.stocked` files use this package.
    private func makeBackupData(store: GuestDataStore) throws -> Data {
        let key = try KitchenBackupKeyStore.loadOrCreate()
        return try KitchenBackupCodec.seal(makeSnapshot(store: store), using: key)
    }

    // MARK: - Export to JSON file
    func exportToFile(store: GuestDataStore, completion: @escaping (URL?) -> Void) {
        guard requirePermission(.backupExport) else { completion(nil); return }
        isExporting = true; statusMessage = ""; errorMessage = ""
        let data: Data
        do { data = try makeBackupData(store: store) }
        catch {
            isExporting = false; errorMessage = "Export failed: \(error.localizedDescription)"
            completion(nil); return
        }
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            .replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stocked-Kitchen-\(dateStr).stocked")
        Task(priority: .userInitiated) {
            do {
                try data.write(to: url)
                Task { @MainActor in
                    self.isExporting = false; self.exportedFileURL = url
                    self.statusMessage = "Kitchen exported successfully!"
                    completion(url)
                }
            } catch {
                Task { @MainActor in
                    self.isExporting = false
                    self.errorMessage = "Export failed: \(error.localizedDescription)"
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Export as .json (same data, .json extension)
    func exportToJSON(store: GuestDataStore, completion: @escaping (URL?) -> Void) {
        guard requirePermission(.backupExport) else { completion(nil); return }
        isExporting = true; statusMessage = ""; errorMessage = ""
        let snapshot = makeSnapshot(store: store)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else {
            isExporting = false; errorMessage = "Export failed: encode error"
            completion(nil); return
        }
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            .replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stocked-Kitchen-\(dateStr).json")
        Task(priority: .userInitiated) {
            do {
                try data.write(to: url)
                Task { @MainActor in
                    self.isExporting = false; self.exportedFileURL = url
                    self.statusMessage = "Kitchen exported as JSON!"
                    completion(url)
                }
            } catch {
                Task { @MainActor in
                    self.isExporting = false
                    self.errorMessage = "Export failed: \(error.localizedDescription)"
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Export: CSV (inventory + grocery), plain text, PDF
    // These are human-friendly / interoperable formats. CSV and TXT round-trip back via
    // importFromData; PDF is a printable snapshot (export-only).

    private func writeTempFile(_ string: String, name: String, completion: @escaping (URL?) -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try string.data(using: .utf8)?.write(to: url, options: .atomic)
            exportedFileURL = url
            completion(url)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
            completion(nil)
        }
    }

    private func csvEscape(_ s: String) -> String {
        // Quote fields containing comma, quote, or newline; double internal quotes.
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }

    func exportToCSV(store: GuestDataStore, completion: @escaping (URL?) -> Void) {
        guard requirePermission(.backupExport) else { completion(nil); return }
        isExporting = true; statusMessage = ""; errorMessage = ""
        let inv = store.inventoryItems
        let gro = store.groceryItems
        var lines: [String] = []
        // A single CSV with a "Section" column so inventory + grocery both round-trip.
        lines.append("Section,Name,Quantity,ContainerType,SizeAmount,SizeUnit,Zone,ExpirationDate,Brand,Checked")
        let iso = ISO8601DateFormatter()
        for i in inv {
            let exp = i.expirationDate.map { iso.string(from: $0) } ?? ""
            lines.append([
                "Inventory", csvEscape(i.name), String(i.quantity), csvEscape(i.containerType),
                i.sizeAmount.map { String($0) } ?? "", csvEscape(i.sizeUnit ?? ""),
                csvEscape(i.zone), exp, csvEscape(i.brand ?? ""), ""
            ].joined(separator: ","))
        }
        for g in gro {
            lines.append([
                "Grocery", csvEscape(g.name), String(g.quantity), "", "", "", "", "", "",
                g.isChecked ? "yes" : "no"
            ].joined(separator: ","))
        }
        isExporting = false
        statusMessage = "Exported as CSV"
        Log.transfer.notice("Exported CSV: \(inv.count, privacy: .public) inventory, \(gro.count, privacy: .public) grocery")
        let dateStr = dateStamp()
        writeTempFile(lines.joined(separator: "\n"), name: "Stocked-Kitchen-\(dateStr).csv", completion: completion)
    }

    func exportToText(store: GuestDataStore, completion: @escaping (URL?) -> Void) {
        guard requirePermission(.backupExport) else { completion(nil); return }
        isExporting = true; statusMessage = ""; errorMessage = ""
        var out = "STOCKED KITCHEN — \(store.displayName)\nExported \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))\n"
        out += "\n== PANTRY (\(store.inventoryItems.count)) ==\n"
        for i in store.inventoryItems {
            var line = "• \(i.name)"
            if let amt = i.sizeAmount, let unit = i.sizeUnit { line += " — \(i.quantity) × \(amt.clean) \(unit)" }
            else if i.quantity != 1 { line += " ×\(i.quantity)" }
            line += "  [\(i.zone)]"
            out += line + "\n"
        }
        out += "\n== GROCERY LIST (\(store.groceryItems.count)) ==\n"
        for g in store.groceryItems {
            out += "\(g.isChecked ? "[x]" : "[ ]") \(g.name)\(g.quantity != 1 ? " ×\(g.quantity)" : "")\n"
        }
        isExporting = false
        statusMessage = "Exported as text"
        writeTempFile(out, name: "Stocked-Kitchen-\(dateStamp()).txt", completion: completion)
    }

    func exportToPDF(store: GuestDataStore, completion: @escaping (URL?) -> Void) {
        guard requirePermission(.backupExport) else { completion(nil); return }
        isExporting = true; statusMessage = ""; errorMessage = ""
        // US Letter, simple typeset list with pagination.
        let pageW: CGFloat = 612, pageH: CGFloat = 792, margin: CGFloat = 48
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Stocked-Kitchen-\(dateStamp()).pdf")
        let titleAttr: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: StockedType.scaled(22))]
        let headAttr:  [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: StockedType.scaled(14))]
        let bodyAttr:  [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: StockedType.scaled(12))]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageW, height: pageH))
        do {
            try renderer.writePDF(to: url) { ctx in
                ctx.beginPage()
                var y: CGFloat = margin
                func draw(_ s: String, _ attr: [NSAttributedString.Key: Any], indent: CGFloat = 0) {
                    if y > pageH - margin { ctx.beginPage(); y = margin }
                    (s as NSString).draw(at: CGPoint(x: margin + indent, y: y), withAttributes: attr)
                    y += (attr[.font] as? UIFont).map { $0.lineHeight + 4 } ?? 18
                }
                draw("Stocked Kitchen — \(store.displayName)", titleAttr); y += 6
                draw("Pantry (\(store.inventoryItems.count))", headAttr)
                for i in store.inventoryItems {
                    var line = i.name
                    if let amt = i.sizeAmount, let unit = i.sizeUnit { line += " — \(i.quantity) × \(amt.clean) \(unit)" }
                    else if i.quantity != 1 { line += " ×\(i.quantity)" }
                    line += "  [\(i.zone)]"
                    draw(line, bodyAttr, indent: 12)
                }
                y += 8
                draw("Grocery List (\(store.groceryItems.count))", headAttr)
                for g in store.groceryItems {
                    draw("\(g.isChecked ? "☑" : "☐") \(g.name)\(g.quantity != 1 ? " ×\(g.quantity)" : "")", bodyAttr, indent: 12)
                }
            }
            exportedFileURL = url
            isExporting = false
            statusMessage = "Exported as PDF"
            completion(url)
        } catch {
            isExporting = false
            errorMessage = "PDF export failed: \(error.localizedDescription)"
            completion(nil)
        }
    }

    private func dateStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - Import from data (auto-detects format)
    func importFromData(_ data: Data, into store: GuestDataStore, merge: Bool = false) -> Bool {
        guard requirePermission(.backupRestore) else { return false }
        // CSV/plain-text first (content sniff), else JSON formats.
        if let text = String(data: data, encoding: .utf8) {
            let head = text.prefix(2000).lowercased()
            let looksJSON = head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                         || head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
            if !looksJSON {
                // Our CSV starts with "section,name,..."; generic CSV has commas + line breaks.
                if head.contains("section,name") || head.hasPrefix("name,") || head.contains("\"name\"") {
                    return importCSV(text, into: store, merge: merge)
                }
                if text.contains(",") && text.contains("\n") {
                    return importCSV(text, into: store, merge: merge)   // best-effort generic CSV
                }
                if text.contains("\n") {
                    return importPlainText(text, into: store, merge: merge)
                }
            }
        }
        let format = ImportFormat.detect(from: data)
        switch format {
        case .stocked:   return importStocked(data, into: store, merge: merge)
        case .anyList:   return importAnyList(data, into: store, merge: merge)
        case .paprika:   return importPaprika(data, into: store, merge: merge)
        case .mealime:   return importMealime(data, into: store, merge: merge)
        case .unknown:   return importStocked(data, into: store, merge: merge) // try native anyway
        }
    }

    // MARK: CSV import (round-trips our export; tolerant of generic name/quantity CSVs)
    private func importCSV(_ text: String, into store: GuestDataStore, merge: Bool) -> Bool {
        let rows = parseCSVRows(text)
        guard !rows.isEmpty else { errorMessage = "Could not read CSV file."; return false }

        // Map header → column index (case-insensitive). Supports our export schema and
        // simple "Name,Quantity[,Zone]" files.
        let header = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ names: [String]) -> Int? { for n in names { if let i = header.firstIndex(of: n) { return i } }; return nil }
        let secIdx  = col(["section"])
        let nameIdx = col(["name", "item", "product"])
        let qtyIdx  = col(["quantity", "qty", "count"])
        let contIdx = col(["containertype", "container"])
        let sizeAIdx = col(["sizeamount", "size", "amount"])
        let sizeUIdx = col(["sizeunit", "unit"])
        let zoneIdx = col(["zone", "storage", "category", "location"])
        let expIdx  = col(["expirationdate", "expires", "expiry"])
        let brandIdx = col(["brand"])
        let checkIdx = col(["checked", "ischecked", "done"])
        guard nameIdx != nil else { errorMessage = "CSV needs at least a Name column."; return false }

        var inv: [LocalInventoryItem] = []
        var gro: [LocalGroceryItem] = []
        let iso = ISO8601DateFormatter()
        for r in rows.dropFirst() {
            func cell(_ i: Int?) -> String { guard let i, i < r.count else { return "" }; return r[i].trimmingCharacters(in: .whitespaces) }
            let name = cell(nameIdx); if name.isEmpty { continue }
            let section = cell(secIdx).lowercased()
            if section == "grocery" {
                var g = LocalGroceryItem(name: name, isChecked: ["yes","true","1","x"].contains(cell(checkIdx).lowercased()))
                g.quantity = Int(cell(qtyIdx)) ?? 1
                gro.append(g)
            } else {
                var item = LocalInventoryItem(
                    name: name,
                    zone: cell(zoneIdx).isEmpty ? "Pantry" : cell(zoneIdx),
                    quantity: Int(cell(qtyIdx)) ?? 1,
                    containerType: cell(contIdx).isEmpty ? "item" : cell(contIdx),
                    sizeAmount: Double(cell(sizeAIdx)),
                    sizeUnit: cell(sizeUIdx).isEmpty ? nil : cell(sizeUIdx)
                )
                let exp = cell(expIdx)
                if !exp.isEmpty { item.expirationDate = iso.date(from: exp) }
                let brand = cell(brandIdx); if !brand.isEmpty { item.brand = brand }
                inv.append(item)
            }
        }

        Task { @MainActor in
            if merge {
                let existing = Set(store.inventoryItems.map { self.normKey($0.name) })
                store.inventoryItems += inv.filter { !existing.contains(self.normKey($0.name)) }
                let existingG = Set(store.groceryItems.map { self.normKey($0.name) })
                store.groceryItems += gro.filter { !existingG.contains(self.normKey($0.name)) }
            } else {
                if !inv.isEmpty { store.inventoryItems = inv }
                if !gro.isEmpty { store.groceryItems = gro }
            }
            self.statusMessage = "Imported \(inv.count) items, \(gro.count) grocery from CSV."
            Log.transfer.notice("CSV import: \(inv.count, privacy: .public) inventory, \(gro.count, privacy: .public) grocery")
        }
        return true
    }

    // Minimal RFC-4180-ish CSV parser (handles quoted fields, embedded commas/newlines).
    private func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []; var field = ""; var row: [String] = []
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r":
                    if c == "\r" && i + 1 < chars.count && chars[i+1] == "\n" { i += 1 }
                    row.append(field); field = ""
                    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) } }
        return rows
    }

    // MARK: Plain-text import (one item per line; checkbox + ×qty + [zone] tolerated)
    private func importPlainText(_ text: String, into store: GuestDataStore, merge: Bool) -> Bool {
        var inv: [LocalInventoryItem] = []
        for raw in text.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Skip headers / section markers.
            let lower = line.lowercased()
            if lower.hasPrefix("==") || lower.hasPrefix("stocked kitchen") || lower.hasPrefix("exported") { continue }
            // Strip leading bullets/checkboxes.
            for prefix in ["• ", "- ", "[ ] ", "[x] ", "[X] ", "☐ ", "☑ ", "* "] {
                if line.hasPrefix(prefix) { line = String(line.dropFirst(prefix.count)); break }
            }
            // Pull a trailing [zone] if present.
            var zone = "Pantry"
            if let open = line.lastIndex(of: "["), let close = line.lastIndex(of: "]"), open < close {
                zone = String(line[line.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                line = String(line[..<open]).trimmingCharacters(in: .whitespaces)
            }
            // Pull a trailing ×N quantity.
            var qty = 1
            if let r = line.range(of: #"[×x]\s*(\d+)\s*$"#, options: .regularExpression) {
                qty = Int(line[r].filter(\.isNumber)) ?? 1
                line = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            // Drop a trailing " — size" descriptor for the name.
            if let dash = line.range(of: " — ") { line = String(line[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            guard !line.isEmpty else { continue }
            inv.append(LocalInventoryItem(name: line, zone: ["fridge","freezer","pantry","staples"].contains(zone.lowercased()) ? zone.capitalized : "Pantry", quantity: qty))
        }
        guard !inv.isEmpty else { errorMessage = "No items found in text file."; return false }
        Task { @MainActor in
            if merge {
                let existing = Set(store.inventoryItems.map { self.normKey($0.name) })
                store.inventoryItems += inv.filter { !existing.contains(self.normKey($0.name)) }
            } else {
                store.inventoryItems = inv
            }
            self.statusMessage = "Imported \(inv.count) items from text."
            Log.transfer.notice("Text import: \(inv.count, privacy: .public) items")
        }
        return true
    }


    // MARK: Native .stocked / .json
    func previewBackup(_ data: Data) throws -> KitchenBackupPreview {
        try requirePermissionOrThrow(.backupRestore)
        let decoded = try decodeBackup(data)
        return KitchenBackupPreview(
            manifest: decoded.manifest,
            counts: Self.counts(in: decoded.snapshot),
            isEncrypted: decoded.encrypted,
            checksumVerified: decoded.encrypted,
            warnings: decoded.encrypted ? [] : [
                "Legacy plaintext backup: identity and checksums cannot be authenticated until it is re-exported."
            ]
        )
    }

    /// Validate and decode the complete package before mutation, then persist an encrypted
    /// pre-restore snapshot synchronously. A failed validation or rollback write changes nothing.
    @discardableResult
    func restoreBackup(_ data: Data, into store: GuestDataStore,
                       selection: KitchenRestoreSelection = .all) throws -> KitchenRestoreReceipt {
        try requirePermissionOrThrow(.backupRestore)
        let decoded = try decodeBackup(data)
        return try restoreValidatedSnapshot(decoded.snapshot, into: store, selection: selection)
    }

    private func restoreValidatedSnapshot(_ snapshot: KitchenSnapshot, into store: GuestDataStore,
                                          selection: KitchenRestoreSelection) throws -> KitchenRestoreReceipt {
        let rollbackPackage = try makeBackupData(store: store)
        let journal = KitchenRestoreRollbackJournal(createdAt: Date(), package: rollbackPackage)
        let journalData = try JSONEncoder().encode(journal)
        try LocalDatabase.shared.saveDataDurably(journalData, key: DBKey.kitchenRestoreRollback.rawValue)

        apply(snapshot, into: store, selection: selection)
        let allCounts = Self.counts(in: snapshot)
        return KitchenRestoreReceipt(
            restoredAt: Date(), sections: selection.sections,
            counts: allCounts.filter { selection.sections.contains($0.key) },
            merged: selection.merge, rollbackAvailable: true
        )
    }

    var hasRestoreRollback: Bool {
        LocalDatabase.shared.load(KitchenRestoreRollbackJournal.self,
                                  key: DBKey.kitchenRestoreRollback.rawValue) != nil
    }

    /// Reapply the durable pre-restore recovery point. It is consumed only after the rollback
    /// succeeds, so an interrupted or undecryptable attempt remains available for retry.
    @discardableResult
    func rollbackLastRestore(into store: GuestDataStore) throws -> KitchenRestoreReceipt {
        try requirePermissionOrThrow(.backupRestore)
        guard let journal = LocalDatabase.shared.load(
            KitchenRestoreRollbackJournal.self, key: DBKey.kitchenRestoreRollback.rawValue
        ) else { throw KitchenBackupError.rollbackUnavailable }
        let decoded = try decodeBackup(journal.package)
        apply(decoded.snapshot, into: store, selection: .all)
        LocalDatabase.shared.delete(key: DBKey.kitchenRestoreRollback.rawValue)
        return KitchenRestoreReceipt(restoredAt: Date(), sections: Set(KitchenRestoreSection.allCases),
            counts: Self.counts(in: decoded.snapshot), merged: false, rollbackAvailable: false)
    }

    private func importStocked(_ data: Data, into store: GuestDataStore, merge: Bool) -> Bool {
        let snapshot: KitchenSnapshot
        do {
            snapshot = try decodeBackup(data).snapshot
            _ = try restoreValidatedSnapshot(snapshot, into: store,
                                             selection: KitchenRestoreSelection(merge: merge))
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
            isImporting = false
            Log.transfer.error("Backup import failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let total = snapshot.inventoryItems.count
        statusMessage = merge ? "Kitchen backup merged (\(total) pantry items in source)."
                              : "Imported \(total) item\(total == 1 ? "" : "s")."
        isImporting = false
        Log.transfer.notice("Backup imported: source=\(total, privacy: .public), merge=\(merge, privacy: .public)")
        return true
    }

    private func decodeBackup(_ data: Data) throws
        -> (snapshot: KitchenSnapshot, manifest: KitchenBackupManifest, encrypted: Bool) {
        if KitchenBackupCodec.isEncryptedPackage(data) {
            guard let manifest = KitchenBackupCodec.manifest(in: data),
                  let key = try KitchenBackupKeyStore.key(matching: manifest.keyID) else {
                throw KitchenBackupError.decryptionFailed
            }
            let opened = try KitchenBackupCodec.open(data, using: key)
            return (opened.snapshot, opened.manifest, true)
        }

        // If it advertises itself as an envelope, never let a corrupt/tampered envelope fall
        // through to the permissive legacy decoder as an empty kitchen.
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["manifest"] != nil || root["sealedPayload"] != nil {
            throw KitchenBackupError.malformedPackage
        }

        let snapshot: KitchenSnapshot
        if let strict = try? JSONDecoder().decode(KitchenSnapshot.self, from: data) {
            snapshot = strict
        } else if let lenient = Self.lenientSnapshot(from: data) {
            Log.transfer.notice("Backup restored via lenient decoder (older format)")
            snapshot = lenient
        } else {
            throw KitchenBackupError.malformedPackage
        }
        return (snapshot, Self.legacyManifest(snapshot: snapshot, data: data), false)
    }

    private func apply(_ snapshot: KitchenSnapshot, into store: GuestDataStore,
                       selection: KitchenRestoreSelection) {
        let wasApplyingRemote = store.isApplyingHouseholdRemote
        store.isApplyingHouseholdRemote = true
        defer { store.isApplyingHouseholdRemote = wasApplyingRemote }

        if selection.sections.contains(.profile), !selection.merge || store.displayName.isEmpty {
            store.displayName = snapshot.displayName
        }
        if selection.sections.contains(.inventory) {
            if selection.merge {
                let existing = Set(store.inventoryItems.map { normKey($0.name) })
                store.inventoryItems += snapshot.inventoryItems.filter { !existing.contains(normKey($0.name)) }
            } else { store.inventoryItems = snapshot.inventoryItems }
        }
        if selection.sections.contains(.grocery) {
            if selection.merge {
                let existing = Set(store.groceryItems.map { normKey($0.name) })
                store.groceryItems += snapshot.groceryItems.filter { !existing.contains(normKey($0.name)) }
            } else { store.groceryItems = snapshot.groceryItems }
        }
        if selection.sections.contains(.mealHistory) {
            if selection.merge {
                let existing = Set(store.pastMeals.map(\.id))
                store.pastMeals += snapshot.pastMeals.filter { !existing.contains($0.id) }
            } else { store.pastMeals = snapshot.pastMeals }
        }
        if selection.sections.contains(.recipes) {
            if let recipes = snapshot.userRecipes {
                if selection.merge {
                    let existing = Set(store.userRecipes.map { normKey($0.title) })
                    store.userRecipes += recipes.filter { !existing.contains(normKey($0.title)) }
                } else { store.userRecipes = recipes }
            }
            if let recipes = snapshot.generatedRecipes {
                if selection.merge {
                    let existing = Set(store.savedGeneratedRecipes.map { normKey($0.title) })
                    store.savedGeneratedRecipes += recipes.filter { !existing.contains(normKey($0.title)) }
                } else { store.savedGeneratedRecipes = recipes }
            }
        }
        if selection.sections.contains(.mealPlans), let meals = snapshot.plannedMeals {
            if selection.merge {
                let existing = Set(store.plannedMeals.map(\.id))
                store.plannedMeals += meals.filter { !existing.contains($0.id) }
            } else { store.plannedMeals = meals }
        }
        if selection.sections.contains(.preferences), let preferences = snapshot.preferences {
            session?.applyPreferences(preferences)
        }
        if selection.sections.contains(.features), let features = snapshot.features {
            FeatureSync.shared.restoreBackupSnapshot(features, merge: selection.merge)
        }
        store.flushPendingSaves()
    }

    private nonisolated static func counts(in snapshot: KitchenSnapshot) -> [KitchenRestoreSection: Int] {
        let features = snapshot.features
        let featureCount = (features?.leftovers.count ?? 0) + (features?.familyProfiles.count ?? 0)
            + (features?.events.count ?? 0) + (features?.sharedExpenses.count ?? 0)
            + (features?.splitPeople.count ?? 0) + (features?.storeLayouts.count ?? 0)
            + (features?.gardenHarvests.count ?? 0) + (features?.containerLabels.count ?? 0)
            + (features?.takeoutLog.count ?? 0)
            + (features?.scheduledMeals?.count ?? 0) + (features?.mealPlanRules?.count ?? 0)
            + (features?.mealPlanTemplates?.count ?? 0) + (features?.smartCookbooks?.count ?? 0)
        return [
            .profile: 1,
            .inventory: snapshot.inventoryItems.count,
            .grocery: snapshot.groceryItems.count,
            .mealHistory: snapshot.pastMeals.count,
            .recipes: snapshot.savedRecipes.count + (snapshot.userRecipes?.count ?? 0)
                + (snapshot.generatedRecipes?.count ?? 0),
            .mealPlans: snapshot.plannedMeals?.count ?? 0,
            .preferences: snapshot.preferences == nil ? 0 : 1,
            .features: featureCount,
        ]
    }

    private nonisolated static func legacyManifest(snapshot: KitchenSnapshot, data: Data) -> KitchenBackupManifest {
        let sections = counts(in: snapshot).map {
            KitchenBackupSectionManifest(section: $0.key, recordCount: $0.value, checksum: "")
        }.sorted { $0.section.rawValue < $1.section.rawValue }
        return KitchenBackupManifest(snapshotSchemaVersion: snapshot.schemaVersion,
            createdAt: ISO8601DateFormatter().date(from: snapshot.exportedAt) ?? .distantPast,
            displayName: snapshot.displayName, encrypted: false, algorithm: "none", keyID: "legacy",
            payloadByteCount: data.count, payloadChecksum: KitchenBackupCodec.checksum(data),
            ciphertextChecksum: "", sections: sections, media: [])
    }

    // MARK: AnyList JSON export
    // AnyList exports { "categories": [...], "items": [{ "name", "category", "quantity" }] }
    private func importAnyList(_ data: Data, into store: GuestDataStore, merge: Bool) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else { errorMessage = "Could not read AnyList file."; return false }

        let newItems = items.compactMap { obj -> LocalInventoryItem? in
            guard let name = obj["name"] as? String, !name.isEmpty else { return nil }
            let qty = obj["quantity"] as? Int ?? 1
            var item = LocalInventoryItem(name: name, quantity: qty)
            // AnyList stores category name — map to zone
            if let cat = obj["category"] as? String {
                item.storageCategory = ZoneClassifier.classify(cat)
            }
            return item
        }

        Task { @MainActor in
            if merge {
                let existing = Set(store.inventoryItems.map { self.normKey($0.name) })
                store.inventoryItems += newItems.filter { !existing.contains(self.normKey($0.name)) }
            } else {
                store.inventoryItems = newItems
            }
            self.statusMessage = "Imported \(newItems.count) items from AnyList."
        }
        return true
    }

    // MARK: Paprika Recipe Manager export
    // Third-party recipes use the reviewed migration flow, never backup replacement semantics.
    private func importPaprika(_ data: Data, into store: GuestDataStore, merge: Bool) -> Bool {
        errorMessage = "Paprika recipes need review before importing. Open Recipes → Add Recipe → Import or export recipe files → Bring recipes from another app. Your current collection is unchanged."
        return false
    }

    // MARK: Mealime meal plan export
    // Mealime exports { "mealPlan": [{ "title", "ingredients": [{ "name", "quantity" }] }] }
    private func importMealime(_ data: Data, into store: GuestDataStore, merge: Bool) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = (json["mealPlan"] ?? json["meal_plan"]) as? [[String: Any]]
        else { errorMessage = "Could not read Mealime file."; return false }

        var groceryItems: [LocalGroceryItem] = []
        var recipes: [UserRecipe] = []

        for meal in meals {
            let title = meal["title"] as? String ?? "Imported Meal"
            let ings  = meal["ingredients"] as? [[String: Any]] ?? []
            let ingredientItems = ings.compactMap { i -> RecipeIngredient? in
                guard let name = i["name"] as? String, !name.isEmpty else { return nil }
                let qty = i["quantity"] as? String ?? ""
                return RecipeIngredient(name: name, amount: qty)
            }
            // Add missing ingredients to grocery list
            let pantry = Set(store.inventoryItems.map { self.normKey($0.name) })
            for ing in ingredientItems where !pantry.contains(self.normKey(ing.name)) {
                groceryItems.append(LocalGroceryItem(name: ing.name, isChecked: false, recipeSource: title))
            }
            var recipe = UserRecipe(title: title)
            recipe.ingredients = ingredientItems
            recipes.append(recipe)
        }

        Task { @MainActor in
            if merge {
                let existing = Set(store.groceryItems.map { self.normKey($0.name) })
                store.groceryItems += groceryItems.filter { !existing.contains(self.normKey($0.name)) }
                let existingR = Set(store.userRecipes.map { self.normKey($0.title) })
                store.userRecipes += recipes.filter { !existingR.contains(self.normKey($0.title)) }
            } else {
                store.groceryItems = groceryItems
                store.userRecipes  = recipes
            }
            self.statusMessage = "Imported \(recipes.count) meals from Mealime. \(groceryItems.count) items added to grocery list."
        }
        return true
    }

    @discardableResult
    func importFromURL(_ url: URL, into store: GuestDataStore, merge: Bool = false) -> Bool {
        // Files picked from iCloud Drive / Files are security-scoped, and an iCloud file
        // saved on another day or device may still be a non-downloaded placeholder. The
        // download-wait + read can block, so we do it on a background task and apply the
        // result on the main actor. Returns true (work scheduled); status/errors surface
        // via statusMessage / errorMessage like the other importers.
        isImporting = true; errorMessage = ""
        let captured = url
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let scoped = captured.startAccessingSecurityScopedResource()
            defer { if scoped { captured.stopAccessingSecurityScopedResource() } }

            await self.ensureDownloaded(captured)

            var readData: Data?
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: captured, options: [], error: &coordError) { readURL in
                readData = try? Data(contentsOf: readURL)
            }

            guard let data = readData, !data.isEmpty else {
                let reason = coordError?.localizedDescription ?? "the file may still be downloading from iCloud"
                Log.transfer.error("Could not read backup file: \(reason, privacy: .public)")
                await MainActor.run {
                    self.isImporting = false
                    self.errorMessage = "Could not read file — \(reason). Try again once it finishes downloading."
                }
                return
            }
            await MainActor.run {
                self.isImporting = false
                _ = self.importFromData(data, into: store, merge: merge)
            }
        }
        return true
    }

    // Ask the system to download an iCloud file if it's only a placeholder locally,
    // then wait briefly (bounded) for it to materialize. Runs off the main thread.
    private nonisolated func ensureDownloaded(_ url: URL) async {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if let status = values?.ubiquitousItemDownloadingStatus, status == .current { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if v?.ubiquitousItemDownloadingStatus == .current { return }
            if v?.ubiquitousItemDownloadingStatus == nil,
               FileManager.default.fileExists(atPath: url.path) { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    // Import from a stocked://import?data=<base64url> deep link (Share Link feature).
    @discardableResult
    func importFromDeepLink(_ url: URL, into store: GuestDataStore, merge: Bool = false) -> Bool {
        guard url.scheme == "stocked",
              url.host == "import",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw   = comps.queryItems?.first(where: { $0.name == "data" })?.value else {
            errorMessage = "Invalid share link."; return false
        }
        // Reverse URL-safe base64 (base64url) and restore = padding.
        var b64 = raw.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        let pad = b64.count % 4
        if pad > 0 { b64 += String(repeating: "=", count: 4 - pad) }
        guard let data = Data(base64Encoded: b64) else {
            errorMessage = "Invalid share link."; return false
        }
        return importFromData(data, into: store, merge: merge)
    }

    // MARK: - QR Code Generation
    func generateQRCode(for store: GuestDataStore) {
        guard requirePermission(.backupExport) else { return }
        statusMessage = "Generating QR code…"; qrCodeImage = nil
        let snapshot = makeSnapshot(store: store)
        let encodedData = try? JSONEncoder().encode(snapshot)
        Task(priority: .userInitiated) {
            var jsonData: Data?
            if let data = encodedData, data.count < 2900 { jsonData = data }
            let qrString: String
            if let data = jsonData, let str = String(data: data, encoding: .utf8) {
                qrString = str
            } else {
                let items = snapshot.inventoryItems.prefix(20)
                    .map { "\($0.name):\(Int($0.level*100))%:\($0.zone)" }.joined(separator: "|")
                qrString = "STOCKED-KITCHEN|v1|\(snapshot.displayName)|\(items)"
            }
            let context = CIContext(); let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(qrString.utf8); filter.correctionLevel = "M"
            if let out = filter.outputImage {
                let scaled = out.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
                if let cg = context.createCGImage(scaled, from: scaled.extent) {
                    Task { @MainActor in
                        self.qrCodeImage   = UIImage(cgImage: cg)
                        self.statusMessage = "QR code ready"
                    }
                    return
                }
            }
            Task { @MainActor in self.errorMessage = "QR generation failed." }
        }
    }

    // MARK: - Share Link
    func generateShareLink(for store: GuestDataStore) -> URL? {
        guard requirePermission(.backupExport) else { return nil }
        let snapshot = makeSnapshot(store: store)
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        // URL-safe base64 (base64url): +→-, /→_, drop = padding. Reversed on import.
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "stocked://import?data=\(b64)")
    }

    // MARK: - iCloud Backup (MainActor — all state access is on main thread)
    func backupToiCloud(store: GuestDataStore) {
        guard requirePermission(.backupExport) else { return }
        guard !isBacking else { return }
        isBacking = true; statusMessage = "Backing up to iCloud…"; errorMessage = ""

        let name       = store.displayName
        let deviceName = UIDevice.current.name
        let data: Data
        do { data = try makeBackupData(store: store) }
        catch {
            isBacking = false; errorMessage = "Backup encode failed: \(error.localizedDescription)"; return
        }
        guard let manifest = KitchenBackupCodec.manifest(in: data) else {
            isBacking = false; errorMessage = "Backup encode failed: missing manifest."; return
        }
        let recoveryKey: Data
        do {
            guard let bytes = try KitchenBackupKeyStore.rawKeyData(matching: manifest.keyID) else {
                throw KitchenBackupError.decryptionFailed
            }
            recoveryKey = bytes
        } catch {
            isBacking = false; errorMessage = "Backup key unavailable: \(error.localizedDescription)"; return
        }

        Task { @MainActor in
            do {
                // Check iCloud availability before attempting save
                let status = try await cloudContainer.accountStatus()
                guard status == .available else {
                    isBacking = false
                    errorMessage = status == .noAccount
                        ? "No iCloud account signed in. Go to Settings → Sign in to your Apple ID."
                        : "iCloud not available."
                    return
                }
                // Build and save the record (stays on MainActor — record never crosses actors)
                let assetURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Stocked-iCloud-\(UUID().uuidString).stocked")
                try data.write(to: assetURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: assetURL) }
                let record = CKRecord(recordType: "KitchenBackup")
                record["displayName"] = name       as CKRecordValue
                // CKAsset avoids the CloudKit inline-Bytes ceiling once a kitchen contains photos.
                // Restore still reads legacy `backupData` records for full compatibility.
                record["backupAsset"] = CKAsset(fileURL: assetURL)
                record["backedUpAt"]  = Date()      as CKRecordValue
                record["deviceName"]  = deviceName  as CKRecordValue
                record["formatVersion"] = KitchenBackupManifest.currentFormatVersion as CKRecordValue
                record["encrypted"] = true as CKRecordValue
                record["backupKeyID"] = manifest.keyID as CKRecordValue
                // CloudKit encrypts this field end-to-end for the account. It is intentionally
                // absent from ordinary fields/manifests/logs and recovers a package when the
                // synchronizable Keychain item has not arrived on a new device.
                record.encryptedValues["backupRecoveryKey"] = recoveryKey as CKRecordValue

                _ = try await cloudContainer.privateCloudDatabase.save(record)
                isBacking = false
                statusMessage = "Backed up to iCloud ✓"
                iCloudStatus  = "Backed up \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
                UserDefaults.standard.set(Date(), forKey: "lastICloudBackup")
                // This device clearly holds current data — suppress the one-time new-device
                // auto-restore here so it won't re-pull what we just sent.
                UserDefaults.standard.set(true, forKey: "didAutoRestoreFromiCloud_v1")
            } catch {
                isBacking = false
                errorMessage = "iCloud backup failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - iCloud Restore
    func restoreFromiCloud(into store: GuestDataStore, merge: Bool = false) {
        guard requirePermission(.backupRestore) else { return }
        statusMessage = "Fetching from iCloud…"; errorMessage = ""

        Task { @MainActor in
            // Confirm the account is available first — a fresh device may not have finished
            // signing into iCloud yet, which otherwise looks like "no backup found."
            if let status = try? await cloudContainer.accountStatus(), status != .available {
                errorMessage = status == .noAccount
                    ? "No iCloud account signed in. Sign in to iCloud to restore your kitchen."
                    : "iCloud not available yet — try again in a moment."
                Log.transfer.notice("iCloud restore skipped: account not available")
                return
            }
            switch await fetchLatestICloudBackupResult() {
            case .failure(let error):
                let ck = error as? CKError
                errorMessage = ck?.code == .networkUnavailable || ck?.code == .networkFailure
                    ? "Network unavailable — connect to the internet and try again."
                    : "iCloud restore couldn't read your backups: \(error.localizedDescription)"
                Log.transfer.notice("iCloud restore: query FAILED — \(error.localizedDescription, privacy: .public)")
                return
            case .success(nil):
                errorMessage = "No iCloud backup found yet. Make a backup on your other device first, then try again here."
                Log.transfer.notice("iCloud restore: query succeeded but zero backups in this account/environment")
                return
            case .success(.some(let payload)):
                do { try installRecoveryKeyIfNeeded(payload) }
                catch {
                    errorMessage = "iCloud restore couldn't unlock this backup: \(error.localizedDescription)"
                    return
                }
                let ok = importFromData(payload.package, into: store, merge: merge)
                // FR-03 FIX: a successful restore means this user already has a set-up kitchen —
                // mark onboarding complete so the consent-prompt "Restore" path skips the quiz and
                // lands in the app. (Matches the old auto-restore behavior; harmless when the
                // caller is an already-onboarded user restoring from Settings.)
                if ok { store.quizCompleted = true }
                statusMessage = ok ? "Restored from iCloud ✓" : statusMessage
                Log.transfer.notice("iCloud restore \(ok ? "succeeded" : "failed", privacy: .public)")
            }
        }
    }

    /// Most-recent KitchenBackup data, resilient to CloudKit schema/sort limitations.
    /// Returns .success(data?) on a clean query (data may be nil = genuinely no backups),
    /// or .failure(error) when CloudKit itself errored — so callers can tell "no backups
    /// exist" apart from "the query failed", which previously both looked identical.
    private func fetchLatestICloudBackupResult() async -> Result<KitchenICloudBackupPayload?, Error> {
        let db = cloudContainer.privateCloudDatabase

        // Attempt 1: sorted query (fast path when the field is sortable).
        let sorted = CKQuery(recordType: "KitchenBackup", predicate: NSPredicate(value: true))
        sorted.sortDescriptors = [NSSortDescriptor(key: "backedUpAt", ascending: false)]
        do {
            let (results, _) = try await db.records(matching: sorted, inZoneWith: nil,
                                                    desiredKeys: ["backupData", "backupAsset", "backupRecoveryKey", "backupKeyID"], resultsLimit: 1)
            if let first = results.first, case .success(let record) = first.1,
               let payload = backupPayload(from: record) {
                return .success(payload)
            }
            // Sorted query succeeded but returned nothing — fall through to the broad fetch
            // before concluding there are genuinely no backups.
        } catch {
            // Sorted query errored (often: field not sortable in this environment). Don't
            // give up — try the unsorted fetch, and only report THIS error if that fails too.
            Log.transfer.notice("iCloud restore: sorted query failed (\(error.localizedDescription, privacy: .public)) — trying unsorted")
        }

        // Attempt 2: unsorted fetch, choose newest by backedUpAt in code.
        let plain = CKQuery(recordType: "KitchenBackup", predicate: NSPredicate(value: true))
        do {
            let desiredKeys = ["backupData", "backupAsset", "backupRecoveryKey",
                               "backupKeyID", "backedUpAt"]
            let first = try await db.records(matching: plain, inZoneWith: nil,
                                             desiredKeys: desiredKeys, resultsLimit: 200)
            var newestDate = Date.distantPast
            var newestPayload: KitchenICloudBackupPayload?

            func consider(_ results: [(CKRecord.ID, Result<CKRecord, Error>)]) {
                for (_, result) in results {
                    guard case .success(let record) = result,
                          let payload = backupPayload(from: record) else { continue }
                    let when = (record["backedUpAt"] as? Date) ?? Date.distantPast
                    if newestPayload == nil || when >= newestDate {
                        newestDate = when
                        newestPayload = payload
                    }
                }
            }

            consider(first.matchResults)
            var cursor = first.queryCursor
            var pageCount = 1
            var recordCount = first.matchResults.count
            let maximumPages = 100
            let maximumRecords = 20_000
            while let current = cursor {
                try Task.checkCancellation()
                guard pageCount < maximumPages, recordCount < maximumRecords else {
                    Log.transfer.notice("iCloud latest-backup scan reached its safety cap after \(recordCount) records")
                    break
                }
                let page = try await db.records(continuingMatchFrom: current,
                                                desiredKeys: desiredKeys,
                                                resultsLimit: min(200, maximumRecords - recordCount))
                consider(page.matchResults)
                pageCount += 1
                recordCount += page.matchResults.count
                cursor = page.queryCursor
            }
            return .success(newestPayload)   // nil ⇒ genuinely no backups
        } catch {
            return .failure(error)        // a real CloudKit failure — surface it
        }
    }

    private func backupPayload(from record: CKRecord) -> KitchenICloudBackupPayload? {
        let package: Data?
        if let data = record["backupData"] as? Data {
            package = data
        } else if let asset = record["backupAsset"] as? CKAsset, let url = asset.fileURL {
            package = try? Data(contentsOf: url)
        } else {
            package = nil
        }
        guard let package else { return nil }
        return KitchenICloudBackupPayload(
            package: package,
            recoveryKey: record.encryptedValues["backupRecoveryKey"] as? Data,
            keyID: record["backupKeyID"] as? String)
    }

    private func installRecoveryKeyIfNeeded(_ payload: KitchenICloudBackupPayload) throws {
        guard let manifest = KitchenBackupCodec.manifest(in: payload.package) else { return }
        if let recordKeyID = payload.keyID, recordKeyID != manifest.keyID {
            throw KitchenBackupError.integrityCheckFailed
        }
        if try KitchenBackupKeyStore.key(matching: manifest.keyID) != nil { return }
        guard let recoveryKey = payload.recoveryKey else { throw KitchenBackupError.decryptionFailed }
        try KitchenBackupKeyStore.importRecoveryKey(recoveryKey, keyID: manifest.keyID)
    }

    /// FR-01 FIX (point 4): does the signed-in Apple ID have a restorable iCloud backup?
    /// Used to decide whether to OFFER a restore after sign-in — we never pull without consent.
    /// Returns false on any error / no iCloud, so a hiccup silently means "don't offer."
    func latestBackupExists() async -> Bool {
        guard let status = try? await cloudContainer.accountStatus(), status == .available else { return false }
        if case .success(.some) = await fetchLatestICloudBackupResult() { return true }
        return false
    }

    /// FR-01 FIX (point 5): delete EVERY KitchenBackup record from the private database, so
    /// "Erase All Data" / account deletion truly wipes the cloud copy too — otherwise the next
    /// sign-in or explicit restore would bring the erased kitchen back. Best-effort and silent.
    func deleteAlliCloudBackups() async {
        guard let status = try? await cloudContainer.accountStatus(), status == .available else { return }
        let db = cloudContainer.privateCloudDatabase
        let query = CKQuery(recordType: "KitchenBackup", predicate: NSPredicate(value: true))
        func deleteIDs(_ ids: [CKRecord.ID]) async -> Int {
            guard !ids.isEmpty, !Task.isCancelled else { return 0 }
            do {
                _ = try await db.modifyRecords(saving: [], deleting: ids)
                return ids.count
            } catch {
                // A partial batch failure must not prevent later pages from being erased. Retry
                // records individually as a bounded best-effort fallback.
                var removed = 0
                for id in ids {
                    guard !Task.isCancelled else { break }
                    if (try? await db.deleteRecord(withID: id)) != nil { removed += 1 }
                }
                return removed
            }
        }
        do {
            let first = try await db.records(matching: query, inZoneWith: nil,
                                             desiredKeys: [], resultsLimit: 200)
            var ids = first.matchResults.compactMap { (id, res) -> CKRecord.ID? in
                if case .success = res { return id }
                return nil
            }
            var removed = await deleteIDs(ids)
            var cursor = first.queryCursor
            var pageCount = 1
            var recordCount = first.matchResults.count
            let maximumPages = 250
            let maximumRecords = 50_000
            while let current = cursor {
                guard !Task.isCancelled else {
                    Log.transfer.notice("iCloud backup erase cancelled after \(removed) record(s)")
                    break
                }
                guard pageCount < maximumPages, recordCount < maximumRecords else {
                    Log.transfer.notice("iCloud backup erase reached its safety cap after scanning \(recordCount) records")
                    break
                }
                let page = try await db.records(continuingMatchFrom: current,
                                                desiredKeys: [],
                                                resultsLimit: min(200, maximumRecords - recordCount))
                ids = page.matchResults.compactMap { (id, res) -> CKRecord.ID? in
                    if case .success = res { return id }
                    return nil
                }
                removed += await deleteIDs(ids)
                pageCount += 1
                recordCount += page.matchResults.count
                cursor = page.queryCursor
            }
            Log.transfer.notice("Erased \(removed) iCloud KitchenBackup record(s)")
        } catch {
            Log.transfer.notice("iCloud backup erase failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - New-device auto-restore (once per install)
    // Called on launch. If this install has never auto-restored AND iCloud is available,
    // pull the latest backup in MERGE mode so a fresh device repopulates inventory +
    // preferences without wiping local data. Sign-in restore still covers Apple auth.
    @MainActor
    static func autoRestoreOnNewDeviceIfNeeded(into session: AppSession) {
        let flagKey = "didAutoRestoreFromiCloud_v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let store = session.guestStore
        let hasLocalKitchenState = store.quizCompleted
            || !store.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !store.inventoryItems.isEmpty
            || !store.groceryItems.isEmpty
            || !store.pastMeals.isEmpty
            || !store.userRecipes.isEmpty
            || UserDefaults.standard.bool(forKey: "wasGuest")
            || !session.appleUserID.isEmpty

        // This is a new-device recovery feature, not an app-update migration. Earlier builds
        // ran it whenever the marker was absent, including after installing over an existing
        // app. That launched a large CloudKit merge + synchronous save on the main actor and
        // reapplied notification preferences before the first window was ready. Skip and seal
        // the marker whenever a usable local kitchen already exists.
        guard !hasLocalKitchenState else {
            UserDefaults.standard.set(true, forKey: flagKey)
            Log.transfer.notice("Auto-restore skipped: existing local kitchen detected")
            return
        }

        let mgr = session.transferManager   // retained — async task won't be orphaned
        mgr.isCheckingForExistingAccount = true
        Task { @MainActor in
            defer { mgr.isCheckingForExistingAccount = false }
            guard let status = try? await mgr.cloudContainer.accountStatus(),
                  status == .available else {
                Log.transfer.notice("Auto-restore deferred: iCloud not available yet")
                return   // leave flag unset so a genuinely empty install can retry later
            }
            switch await mgr.fetchLatestICloudBackupResult() {
            case .success(.some(let payload)):
                do { try mgr.installRecoveryKeyIfNeeded(payload) }
                catch {
                    mgr.errorMessage = "iCloud restore couldn't unlock this backup: \(error.localizedDescription)"
                    Log.transfer.notice("Auto-restore recovery key unavailable")
                    return
                }
                let ok = mgr.importFromData(payload.package, into: store, merge: true)
                UserDefaults.standard.set(true, forKey: flagKey)
                Log.transfer.notice("Auto-restored kitchen from iCloud on new device")
                if ok { store.quizCompleted = true }
            case .success(nil):
                Log.transfer.notice("Auto-restore: no iCloud backup to restore")
                UserDefaults.standard.set(true, forKey: flagKey)
            case .failure(let error):
                Log.transfer.notice("Auto-restore query failed — \(error.localizedDescription, privacy: .public); will retry next launch")
            }
        }
    }

    // MARK: - Device Backup (saves .stocked file to Files app)
    func backupToDevice(store: GuestDataStore, completion: @escaping (URL?) -> Void) {
        guard requirePermission(.backupExport) else { completion(nil); return }
        let data: Data
        do { data = try makeBackupData(store: store) }
        catch {
            errorMessage = "Device backup failed: \(error.localizedDescription)"
            completion(nil); return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "Stocked_Backup_\(formatter.string(from: Date())).stocked"
        let url  = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            exportedFileURL = url
            statusMessage   = "Ready to save to Files"
            completion(url)
        } catch {
            errorMessage = "Device backup failed: \(error.localizedDescription)"
            completion(nil)
        }
    }

    var lastBackupDate: String {
        guard let date = UserDefaults.standard.object(forKey: "lastICloudBackup") as? Date else {
            return "Never"
        }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
}

// MARK: - Lenient backup decoding (backward compatibility)
// Reconstructs a KitchenSnapshot from ANY older/partial backup JSON. Each field is read
// with a safe default, and per-element decoding so one bad record can't fail the whole
// restore. Used only when the strict Codable decode throws.
extension KitchenTransferManager {

    nonisolated static func lenientSnapshot(from data: Data) -> KitchenSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let displayName = (root["displayName"] as? String) ?? "My Kitchen"
        let invArr      = (root["inventoryItems"] as? [[String: Any]]) ?? []
        let groArr      = (root["groceryItems"]   as? [[String: Any]]) ?? []
        let mealArr     = (root["pastMeals"]      as? [[String: Any]]) ?? []
        let recArr      = (root["userRecipes"]    as? [[String: Any]]) ?? []

        let inventory = invArr.compactMap { lenientInventoryItem($0) }
        let grocery   = groArr.compactMap { lenientGroceryItem($0) }
        let meals     = mealArr.compactMap { lenientPastMeal($0) }
        let recipes   = recArr.compactMap { lenientUserRecipe($0) }

        // Preferences: try strict decode of just that sub-object; default if absent.
        var prefs: KitchenPreferences? = nil
        if let prefDict = root["preferences"] as? [String: Any],
           let pData = try? JSONSerialization.data(withJSONObject: prefDict) {
            prefs = try? JSONDecoder().decode(KitchenPreferences.self, from: pData)
        }

        var snap = KitchenSnapshot(displayName: displayName, inventoryItems: inventory,
                                   groceryItems: grocery, pastMeals: meals,
                                   userRecipes: recipes.isEmpty ? nil : recipes,
                                   preferences: prefs)
        snap.pastMeals = meals
        return snap
    }

    private nonisolated static func lenientInventoryItem(_ d: [String: Any]) -> LocalInventoryItem? {
        guard let name = d["name"] as? String, !name.isEmpty else { return nil }
        let zone = (d["storageCategory"] as? String) ?? (d["zone"] as? String) ?? "Pantry"
        var item = LocalInventoryItem(
            name: name,
            level: (d["level"] as? Double) ?? 1.0,
            zone: zone,
            quantity: (d["quantity"] as? Int) ?? 1,
            containerType: (d["containerType"] as? String) ?? "item",
            sizeAmount: d["sizeAmount"] as? Double,
            sizeUnit: d["sizeUnit"] as? String
        )
        item.quantityUsed = d["quantityUsed"] as? Double
        item.brand        = d["brand"] as? String
        item.price        = d["price"] as? Double
        item.storePurchasedAt = d["storePurchasedAt"] as? String
        item.isLeftover   = (d["isLeftover"] as? Bool) ?? false
        item.leftoverMeal = d["leftoverMeal"] as? String
        item.hasStash     = (d["hasStash"] as? Bool) ?? false
        // expirationDate may be ISO string or epoch number depending on backup age.
        if let iso = d["expirationDate"] as? String {
            item.expirationDate = ISO8601DateFormatter().date(from: iso)
        } else if let epoch = d["expirationDate"] as? Double {
            item.expirationDate = Date(timeIntervalSinceReferenceDate: epoch)
        }
        return item
    }

    private nonisolated static func lenientGroceryItem(_ d: [String: Any]) -> LocalGroceryItem? {
        guard let name = d["name"] as? String, !name.isEmpty else { return nil }
        var item = LocalGroceryItem(name: name, isChecked: (d["isChecked"] as? Bool) ?? false)
        item.quantity      = (d["quantity"] as? Int) ?? 1
        item.isRecommended = (d["isRecommended"] as? Bool) ?? false
        item.recipeSource  = (d["recipeSource"] as? String) ?? ""
        return item
    }

    private nonisolated static func lenientPastMeal(_ d: [String: Any]) -> LocalPastMeal? {
        guard let title = d["title"] as? String, !title.isEmpty else { return nil }
        let date = (d["date"] as? String) ?? ""
        var meal = LocalPastMeal(title: title, date: date)
        meal.rating  = (d["rating"] as? Int) ?? 0
        meal.thumbUp = (d["thumbUp"] as? Bool) ?? true
        meal.notes   = (d["notes"] as? String) ?? ""
        return meal
    }

    private nonisolated static func lenientUserRecipe(_ d: [String: Any]) -> UserRecipe? {
        guard let title = d["title"] as? String, !title.isEmpty else { return nil }
        var r = UserRecipe(title: title)
        r.description  = (d["description"] as? String) ?? ""
        r.cookTime     = (d["cookTime"] as? String) ?? ""
        r.prepTime     = (d["prepTime"] as? String) ?? ""
        r.servings     = (d["servings"] as? Int) ?? 4
        r.difficulty   = (d["difficulty"] as? String) ?? "Medium"
        r.cuisine      = (d["cuisine"] as? String) ?? ""
        r.tags         = (d["tags"] as? [String]) ?? []
        r.instructions = (d["instructions"] as? [String]) ?? []
        r.notes        = (d["notes"] as? String) ?? ""
        r.imageURL     = d["imageURL"] as? String
        r.isFavorited  = (d["isFavorited"] as? Bool) ?? false
        // Ingredients: re-encode the sub-array and decode strictly (it's small + low-risk).
        if let ingArr = d["ingredients"] as? [[String: Any]],
           let iData = try? JSONSerialization.data(withJSONObject: ingArr),
           let ings = try? JSONDecoder().decode([RecipeIngredient].self, from: iData) {
            r.ingredients = ings
        } else if let names = d["ingredients"] as? [String] {
            // Very old backups may store ingredients as plain strings.
            r.ingredients = names.map { RecipeIngredient(name: $0, amount: "") }
        }
        return r
    }
}
