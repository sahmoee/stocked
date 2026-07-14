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
// The vault resolves this: identity details are stored KEYED BY the hashed Apple user ID.
// Sign-out clears every active profile field, but the vault entry survives; it is only
// read back after a successful re-authorization of that same Apple ID, at which point the
// name, full name, and email are restored and synced into the session.
import Foundation
import CryptoKit

nonisolated enum AppleProfileVault {

    struct Profile: Codable {
        var firstName: String = ""
        var fullName:  String = ""
        var email:     String = ""
    }

    private static let key = "apple_profile_vault_v1"

    /// Stable, non-reversible storage key for an Apple user ID (avoids persisting the raw
    /// identifier alongside the profile details).
    private static func hashed(_ userID: String) -> String {
        let digest = SHA256.hash(data: Data(userID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func loadAll() -> [String: Profile] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Profile].self, from: data) else { return [:] }
        return decoded
    }

    private static func saveAll(_ vault: [String: Profile]) {
        if let data = try? JSONEncoder().encode(vault) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Merge fresh Apple-provided details into the vault entry for this Apple ID. Empty fields
    /// never overwrite previously-captured values (Apple sends them only once).
    static func remember(userID: String, firstName: String, fullName: String, email: String) {
        var vault = loadAll()
        var p = vault[hashed(userID)] ?? Profile()
        if !firstName.isEmpty { p.firstName = firstName }
        if !fullName.isEmpty  { p.fullName  = fullName }
        if !email.isEmpty     { p.email     = email }
        vault[hashed(userID)] = p
        saveAll(vault)
    }

    /// The remembered identity for this Apple ID, if any.
    static func profile(for userID: String) -> Profile? {
        loadAll()[hashed(userID)]
    }

    /// Remove the vault entry for one Apple ID (used by full account deletion).
    static func forget(userID: String) {
        var vault = loadAll()
        vault.removeValue(forKey: hashed(userID))
        saveAll(vault)
    }
}
