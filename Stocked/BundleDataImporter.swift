// BundleDataImporter.swift
// ========================
// Drop-in recipe/ingredient JSON importer for Stocked.
//
// HOW TO ADD NEW DATA
// -------------------
// 1. Prepare a JSON file in ANY of these formats:
//      a) RecipeNLG export  { "version":1, "recipes": [...] }
//      b) Top-100 export    { "recipes": [...], "food_items": [...] }
//      c) Flat recipe array [ { "title": "...", "ingredients": [...] } ]
//      d) DeepSeek export   { "food_items_common": [...] }
//
// 2. Name the file with one of these prefixes:
//      stocked_*.json   |  recipes_*.json  |  ingredients_*.json
//      food_*.json      |  data_*.json     |  import_*.json
//
// 3. Drag it into Xcode → check "Add to targets: Stocked" → Build.
//
// That's it. BundleDataImporter detects new files automatically on the
// next launch using a SHA-256 content hash. Already-imported files are
// never re-processed. No code changes needed.
//
// DEDUPLICATION
// -------------
// Recipes are deduplicated by lowercased title via RecipeDatabase.upsert().
// Ingredients are deduplicated by lowercased name in StockedKnowledgeBase.
//
// RESETTING
// ---------
// Call BundleDataImporter.shared.resetAll() to force a full re-import.
// Useful during development when you replace a JSON with updated content.

import Foundation
import CryptoKit
import os

// MARK: - Public entry point

@MainActor
final class BundleDataImporter {

    static let shared = BundleDataImporter()
    private init() {}

    private let manifestKey = "bundleImportManifest_v2"
    private let kb = StockedKnowledgeBase.shared

    // Supported file prefixes — add more here if needed
    private let supportedPrefixes = [
        "stocked_", "recipes_", "ingredients_", "food_", "data_", "import_"
    ]

    // MARK: - Main import call (called from RecipeDatabaseManager.mergeAllSources)

    func importNewBundledFiles() async {
        let manifest = loadManifest()
        var updated  = manifest

        let candidates = discoverBundledJSONs()

        for url in candidates {
            // Quick size check before expensive hash.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sz = attrs[.size] as? Int, sz > 0 else { continue }

            // #4: the large recipe corpus is no longer shipped as JSON — it lives in
            // the prebuilt, read-only SQLite database queried on demand by RecipeStore.
            // Guard against ever whole-file-parsing a very large JSON here (the old
            // path cost ~326 MB peak RSS + seconds of CPU at launch). Small drop-in
            // JSONs still work exactly as documented above.
            guard sz <= Self.maxInlineJSONBytes else {
                Log.app.error("Skipping oversized bundle JSON \(url.lastPathComponent, privacy: .public) (\(sz) bytes). Convert large corpora to SQLite via build_recipe_db.py instead.")
                continue
            }

        let hash = contentHash(of: url)
            guard manifest[url.lastPathComponent] != hash else { continue } // already imported

            let imported = await importFile(at: url)
            if imported {
                updated[url.lastPathComponent] = hash
                saveManifest(updated)
            }
        }
    }

    /// Files larger than this are assumed to be a bulk corpus that belongs in the
    /// prebuilt SQLite database (RecipeStore), not parsed into memory at launch.
    /// 8 MB comfortably covers any hand-authored drop-in JSON while excluding the
    /// 98 MB RecipeNLG export that used to be loaded here.
    private static let maxInlineJSONBytes = 8 * 1024 * 1024

    // MARK: - File discovery

    private func discoverBundledJSONs() -> [URL] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil)
        else { return [] }

        return urls.filter { url in
            let name = url.lastPathComponent.lowercased()
            return supportedPrefixes.contains { name.hasPrefix($0) }
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Per-file import

    @discardableResult
    private func importFile(at url: URL) async -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        guard let raw  = try? JSONSerialization.jsonObject(with: data) else { return false }

        var recipesImported = 0
        var ingredientsImported = 0

        // ── Schema A: RecipeNLG / Stocked export { "version":1, "recipes":[...] } ──
        if let dict = raw as? [String: Any], let recipeArray = dict["recipes"] as? [[String: Any]] {
            let entries = recipeArray.compactMap { parseRecipeDict($0) }
            for entry in entries { await RecipeDatabase.shared.upsert(entry) }
            recipesImported = entries.count

            // Also pick up food_items / food_items_common / food_items_expanded
            for key in ["food_items", "food_items_common", "food_items_expanded", "ingredients"] {
                if let items = dict[key] as? [String] {
                    let added = mergeIngredients(items)
                    ingredientsImported += added
                }
            }
        }

        // ── Schema B: Flat array [ { "title": "...", ... } ] ──────────────────────
        else if let recipeArray = raw as? [[String: Any]] {
            let entries = recipeArray.compactMap { parseRecipeDict($0) }
            for entry in entries { await RecipeDatabase.shared.upsert(entry) }
            recipesImported = entries.count
        }

        // ── Schema C: Pure ingredient list { "food_items_common":[...] } ──────────
        else if let dict = raw as? [String: Any] {
            for key in ["food_items", "food_items_common", "food_items_expanded", "ingredients", "brands"] {
                if let items = dict[key] as? [String] {
                    let added = mergeIngredients(items)
                    ingredientsImported += added
                }
            }
        }

        return recipesImported > 0 || ingredientsImported > 0
    }

    // MARK: - Recipe parser (handles both RecipeNLG and generic schemas)

    private func parseRecipeDict(_ d: [String: Any]) -> RecipeDatabaseEntry? {
        // Support both "title" and "name" keys
        let title = (d["title"] as? String ?? d["name"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let ingredients: [String]
        if let arr = d["ingredients"] as? [String] {
            ingredients = arr
        } else if let arr = d["ingredients"] as? [[String: Any]] {
            // Handle {item, quantity} dicts from top100 format
            ingredients = arr.compactMap { item in
                let name = item["item"] as? String ?? item["name"] as? String ?? ""
                let qty  = item["quantity"] as? String ?? item["amount"] as? String ?? ""
                let combined = [qty, name].filter { !$0.isEmpty }.joined(separator: " ")
                return combined.isEmpty ? nil : combined
            }
        } else {
            ingredients = []
        }

        let steps: [String]
        if let arr = d["steps"] as? [String]        { steps = arr }
        else if let arr = d["directions"] as? [String] { steps = arr }
        else if let arr = d["instructions"] as? [String] { steps = arr }
        else { steps = [] }

        guard ingredients.count >= 2 else { return nil }

        let ct = d["cooking_time"] as? [String: String]

        return RecipeDatabaseEntry(
            title:       title,
            description: d["description"] as? String ?? "",
            sourceURL:   d["sourceURL"] as? String ?? d["source_url"] as? String ?? "",
            sourceName:  d["sourceName"] as? String ?? d["source"] as? String ?? "Bundled",
            prepTime:    d["prepTime"] as? String ?? ct?["prep"] ?? "",
            cookTime:    d["cookTime"] as? String ?? ct?["cook"] ?? "",
            totalTime:   d["totalTime"] as? String ?? ct?["total"] ?? "",
            servings:    stringify(d["servings"]),
            category:    d["category"] as? String ?? "",
            cuisine:     d["cuisine"] as? String ?? "",
            tags:        d["tags"] as? [String] ?? [],
            ingredients: ingredients,
            steps:       steps,
            imageURL:    d["imageURL"] as? String ?? d["imageName"] as? String ?? ""
        )
    }

    // MARK: - Ingredient merger

    @discardableResult
    private func mergeIngredients(_ names: [String]) -> Int {
        let known = Set(kb.ingredients.map { $0.name.lowercased() })
        let newItems = names
            .filter { !known.contains($0.lowercased()) && !$0.isEmpty }
            .map { KnowledgeIngredient(name: $0, category: "Pantry", emoji: "🛒") }
        kb.ingredients.append(contentsOf: newItems)
        if !newItems.isEmpty { kb.saveIngredients() }
        return newItems.count
    }

    // MARK: - Manifest (tracks which files have been imported by content hash)

    private func loadManifest() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: manifestKey) as? [String: String] ?? [:]
    }

    private func saveManifest(_ manifest: [String: String]) {
        UserDefaults.standard.set(manifest, forKey: manifestKey)
    }

    private func contentHash(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Dev helper

    /// Force re-import of all bundled JSONs on next launch.
    func resetAll() {
        UserDefaults.standard.removeObject(forKey: manifestKey)
    }

    // MARK: - Utility

    private func stringify(_ val: Any?) -> String {
        switch val {
        case let s as String: return s
        case let n as Int:    return "\(n)"
        case let n as Double: return "\(Int(n))"
        default:              return ""
        }
    }
}
