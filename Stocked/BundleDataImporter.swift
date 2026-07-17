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

    private nonisolated struct ParsedBundle: Sendable {
        let recipes: [RecipeDatabaseEntry]
        let ingredients: [String]

        var isEmpty: Bool { recipes.isEmpty && ingredients.isEmpty }
    }

    private nonisolated enum PreparedBundle: Sendable {
        case unreadable
        case oversized(Int)
        case parsed(hash: String, payload: ParsedBundle)
    }

    private let manifestKey = "bundleImportManifest_v2"
    private let kb = StockedKnowledgeBase.shared

    // Supported file prefixes — add more here if needed
    private let supportedPrefixes = [
        "stocked_", "recipes_", "ingredients_", "food_", "data_", "import_"
    ]

    // MARK: - Main import call (called from RecipeDatabaseManager.mergeAllSources)

    func importNewBundledFiles() async {
        let manifest = loadManifest()
        var updated = manifest
        var manifestChanged = false
        let candidates = discoverBundledJSONs()

        for url in candidates {
            let prepared = await Task.detached(priority: .utility) {
                Self.prepareBundle(at: url)
            }.value
            guard !Task.isCancelled else { return }

            switch prepared {
            case .unreadable:
                continue

            case .oversized(let size):
                Log.app.error("Skipping oversized bundle JSON \(url.lastPathComponent, privacy: .public) (\(size) bytes). Convert large corpora to SQLite via build_recipe_db.py instead.")

            case .parsed(let hash, let payload):
                guard manifest[url.lastPathComponent] != hash else { continue }
                guard !payload.isEmpty else { continue }

                // One actor hop and one coalesced persistence write per file. The old path
                // upserted each recipe separately, repeatedly rebuilding and writing the store.
                await RecipeDatabase.shared.upsertAll(payload.recipes)
                _ = mergeIngredients(payload.ingredients)
                updated[url.lastPathComponent] = hash
                manifestChanged = true
            }
        }

        if manifestChanged { saveManifest(updated) }
    }

    /// Files larger than this are assumed to be a bulk corpus that belongs in the
    /// prebuilt SQLite database (RecipeStore), not parsed into memory at launch.
    /// 8 MB comfortably covers any hand-authored drop-in JSON while excluding the
    /// 98 MB RecipeNLG export that used to be loaded here.
    private nonisolated static let maxInlineJSONBytes = 8 * 1024 * 1024

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

    // MARK: - Background parsing

    private nonisolated static func prepareBundle(at url: URL) -> PreparedBundle {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size > 0 else { return .unreadable }
        guard size <= maxInlineJSONBytes else { return .oversized(size) }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }

        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            return .unreadable
        }
        return .parsed(hash: hash, payload: parseBundle(raw))
    }

    private nonisolated static func parseBundle(_ raw: Any) -> ParsedBundle {
        var recipes: [RecipeDatabaseEntry] = []
        var ingredients: [String] = []

        // ── Schema A: RecipeNLG / Stocked export { "version":1, "recipes":[...] } ──
        if let dict = raw as? [String: Any],
           let recipeArray = dict["recipes"] as? [[String: Any]] {
            recipes = recipeArray.compactMap(parseRecipeDict)
            for key in ["food_items", "food_items_common", "food_items_expanded", "ingredients"] {
                if let items = dict[key] as? [String] { ingredients.append(contentsOf: items) }
            }
        }

        // ── Schema B: Flat array [ { "title": "...", ... } ] ──────────────────────
        else if let recipeArray = raw as? [[String: Any]] {
            recipes = recipeArray.compactMap(parseRecipeDict)
        }

        // ── Schema C: Pure ingredient list { "food_items_common":[...] } ──────────
        else if let dict = raw as? [String: Any] {
            for key in ["food_items", "food_items_common", "food_items_expanded", "ingredients", "brands"] {
                if let items = dict[key] as? [String] { ingredients.append(contentsOf: items) }
            }
        }

        return ParsedBundle(recipes: recipes, ingredients: ingredients)
    }

    // MARK: - Recipe parser (handles both RecipeNLG and generic schemas)

    private nonisolated static func parseRecipeDict(_ d: [String: Any]) -> RecipeDatabaseEntry? {
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
        if let arr = d["steps"] as? [String] { steps = arr }
        else if let arr = d["directions"] as? [String] { steps = arr }
        else if let arr = d["instructions"] as? [String] { steps = arr }
        else { steps = [] }

        guard ingredients.count >= 2 else { return nil }

        let cookingTime = d["cooking_time"] as? [String: String]

        return RecipeDatabaseEntry(
            title:       title,
            description: d["description"] as? String ?? "",
            sourceURL:   d["sourceURL"] as? String ?? d["source_url"] as? String ?? "",
            sourceName:  d["sourceName"] as? String ?? d["source"] as? String ?? "Bundled",
            prepTime:    d["prepTime"] as? String ?? cookingTime?["prep"] ?? "",
            cookTime:    d["cookTime"] as? String ?? cookingTime?["cook"] ?? "",
            totalTime:   d["totalTime"] as? String ?? cookingTime?["total"] ?? "",
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
        var known = Set(kb.ingredients.map { $0.name.lowercased() })
        var newItems: [KnowledgeIngredient] = []
        for rawName in names {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard known.insert(key).inserted else { continue }
            newItems.append(KnowledgeIngredient(name: name, category: "Pantry", emoji: "🛒"))
        }
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

    // MARK: - Dev helper

    /// Force re-import of all bundled JSONs on next launch.
    func resetAll() {
        UserDefaults.standard.removeObject(forKey: manifestKey)
    }

    // MARK: - Utility

    private nonisolated static func stringify(_ val: Any?) -> String {
        switch val {
        case let s as String: return s
        case let n as Int:    return "\(n)"
        case let n as Double: return "\(Int(n))"
        default:              return ""
        }
    }
}
