// UserCorrections.swift — Let the household fix bad source data, and remember it (#10 source).
//
// When a source gets something wrong — a barcode that resolves to the wrong product name, a
// nutrition value that's off, a mis-parsed receipt line — the user should be able to correct it
// once and have the app remember, so Stocked gets smarter for that household instead of repeating
// the mistake. This stores those corrections locally, keyed by what was wrong.
//
// Follows the singleton-persisted-to-UserDefaults pattern. Pairs with IngredientMatcher (lookups
// canonicalize first) and AppAnalytics (logging a .dataCorrected event is the caller's choice).
// Additive: callers consult corrections before trusting a source, and record new ones on edit.

import Foundation
import Observation

@Observable
final class UserCorrections {
    static let shared = UserCorrections()

    /// The kinds of data a correction can apply to.
    enum Kind: String, Codable, CaseIterable {
        case productName     // barcode/product lookup returned the wrong name
        case itemCategory    // wrong storage category / aisle
        case nutrition       // a nutrition value was wrong
        case recipeField     // a recipe field needed fixing
    }

    private struct Correction: Codable {
        var kind: String
        var corrected: String
        var updatedAt: Date
    }

    /// Keyed by "kind|canonical-original". Value is the user's corrected string.
    private var corrections: [String: Correction]
    private let storeKey = "user_corrections_v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let decoded = try? JSONDecoder().decode([String: Correction].self, from: data) {
            corrections = decoded
        } else {
            corrections = [:]
        }
    }

    // MARK: - Key

    private func key(_ kind: Kind, _ original: String) -> String {
        "\(kind.rawValue)|\(IngredientMatcher.canonical(original))"
    }

    // MARK: - Record / apply

    /// Save a correction: "for this original value, the user says it should be this".
    func record(_ kind: Kind, original: String, corrected: String) {
        let trimmed = corrected.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        corrections[key(kind, original)] = Correction(kind: kind.rawValue, corrected: trimmed, updatedAt: Date())
        persist()
    }

    /// Return the user's corrected value for an original, if one exists.
    func correction(_ kind: Kind, for original: String) -> String? {
        corrections[key(kind, original)]?.corrected
    }

    /// Apply any correction to a value, returning the corrected value or the original unchanged.
    /// This is the one-line call sites use: `let name = UserCorrections.shared.apply(.productName, to: raw)`.
    func apply(_ kind: Kind, to original: String) -> String {
        correction(kind, for: original) ?? original
    }

    /// True if the user has ever corrected this value.
    func hasCorrection(_ kind: Kind, for original: String) -> Bool {
        correction(kind, for: original) != nil
    }

    /// How many corrections the household has made — a small "Stocked is learning" signal.
    var totalCorrections: Int { corrections.count }

    /// Remove a specific correction (user reverts).
    func remove(_ kind: Kind, original: String) {
        corrections[key(kind, original)] = nil
        persist()
    }

    /// Clear all corrections.
    func reset() { corrections.removeAll(); persist() }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(corrections) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}
