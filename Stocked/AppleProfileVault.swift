// AppleProfileVault.swift — remembers Apple sign-in identity per Apple ID.
//
// Two requirements pull in opposite directions:
//   • Signing out must remove the previous profile's memory from the active app state
//     (name, cached Apple name, avatar photo) so the next person at the login screen
//     never sees or inherits it.
//   • Apple only delivers fullName and email on the FIRST authorization ever for an
//     Apple ID — if we simply deleted the cached name at sign-out, the same user signing
//     back in would be greeted as their email prefix or "Chef" forever.
//
// FR-03 FIX: this is now KEYCHAIN-backed, not UserDefaults-backed. The old UserDefaults
// vault was wiped by a fresh install and by "Erase All Data" (removePersistentDomain), so a
// returning Apple user on a reinstalled app got "Chef" — Apple won't re-send the name, and the
// only copy was gone. Keychain survives app deletion and the UserDefaults wipe, so the real name
// comes back on re-sign-in. It's still keyed by the hashed Apple user ID and is only read after a
// successful re-authorization of that same ID. Full account deletion explicitly forgets it.
import Foundation
import CryptoKit
import Security

nonisolated enum AppleProfileVault {

    struct Profile: Codable {
        var firstName: String = ""
        var fullName:  String = ""
        var email:     String = ""
    }

    private static let service = "com.sowens.Stocked.appleProfileVault"

    /// Stable, non-reversible account key for an Apple user ID (avoids persisting the raw
    /// identifier alongside the profile details).
    private static func hashed(_ userID: String) -> String {
        let digest = SHA256.hash(data: Data(userID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Keychain primitives

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Survives reinstall; available after first unlock; NOT synced to iCloud Keychain so a
            // wiped device is genuinely clean until this device re-authorizes.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }

    private static func read(_ account: String) -> Data? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func write(_ account: String, _ data: Data) {
        let q = baseQuery(account)
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    // MARK: - API (unchanged from the UserDefaults version)

    /// Merge fresh Apple-provided details into the vault entry for this Apple ID. Empty fields
    /// never overwrite previously-captured values (Apple sends them only once).
    static func remember(userID: String, firstName: String, fullName: String, email: String) {
        let account = hashed(userID)
        var p: Profile = read(account).flatMap { try? JSONDecoder().decode(Profile.self, from: $0) } ?? Profile()
        if !firstName.isEmpty { p.firstName = firstName }
        if !fullName.isEmpty  { p.fullName  = fullName }
        if !email.isEmpty     { p.email     = email }
        if let data = try? JSONEncoder().encode(p) { write(account, data) }
    }

    /// The remembered identity for this Apple ID, if any.
    static func profile(for userID: String) -> Profile? {
        read(hashed(userID)).flatMap { try? JSONDecoder().decode(Profile.self, from: $0) }
    }

    /// Remove the vault entry for one Apple ID (used by full account deletion only — sign-out and
    /// Erase keep it, so a returning user still gets their real name back).
    static func forget(userID: String) {
        delete(hashed(userID))
    }

    /// One-time migration from the legacy UserDefaults vault, so users who signed in before this
    /// change don't lose their remembered name. Reads the old blob, writes each entry to Keychain,
    /// then removes the old key. Safe to call repeatedly.
    static func migrateFromUserDefaultsIfNeeded() {
        let legacyKey = "apple_profile_vault_v1"
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let decoded = try? JSONDecoder().decode([String: Profile].self, from: data) else { return }
        for (account, profile) in decoded {
            // The legacy dict was already keyed by the hashed id, so write straight through.
            if read(account) == nil, let d = try? JSONEncoder().encode(profile) { write(account, d) }
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }
}
