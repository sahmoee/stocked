// Localization.swift — #7 Localization scaffold.
//
// Stocked currently hardcodes English strings. Full localization means migrating every literal
// to a String Catalog (.xcstrings) — a large, view-by-view change. This file lays the FOUNDATION
// without touching existing views, so the migration can happen incrementally:
//   • An `L` helper for fetching localized strings by key (falls back to the key itself).
//   • A starter Localizable.xcstrings is included in this delivery with a handful of common
//     strings; add to it as you migrate each screen.
//
// How to migrate a screen later (incremental, safe): replace `Text("Grocery List")` with
// `Text(L("grocery.title"))` and add "grocery.title" → "Grocery List" to the catalog. Until a
// key is added, `L` returns the key's default, so nothing breaks mid-migration.
//
// Add Localizable.xcstrings to the Stocked target. Xcode auto-generates translations UI from it.

import Foundation
import SwiftUI

/// Localized-string lookup. `key` is the catalog key; `fallback` (default = key) is shown if the
/// key isn't in the catalog yet, so partial migration is always safe.
func L(_ key: String, _ fallback: String? = nil) -> String {
    let value = NSLocalizedString(key, comment: "")
    // NSLocalizedString returns the key itself when there's no entry; in that case use fallback.
    if value == key { return fallback ?? key }
    return value
}

extension Text {
    /// Convenience: `Text(localized: "grocery.title", "Grocery List")`.
    init(localized key: String, _ fallback: String? = nil) {
        self.init(L(key, fallback))
    }
}
