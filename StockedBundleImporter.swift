// StockedBundleImporter.swift
// ═══════════════════════════════════════════════════════════════════════════
// Drag-and-drop JSON import system for Stocked.
//
// HOW TO ADD A NEW RECIPE JSON:
//   1. Generate a JSON using recipenlg_to_stocked.py (or any tool that
//      produces the standard Stocked recipe schema — see StockedRecipeBundle below).
//   2. Drag the .json file into Xcode → Stocked group.
//      Check "Add to targets: Stocked" ✅
//   3. Name the file anything you like — the importer finds ALL bundle JSONs
//      that match the schema automatically.
//   4. Build and run. New recipes import once on first launch.
//      Duplicates (matched by title) are silently skipped.
//      No code changes needed.
//
// HOW IT WORKS:
//   - On launch, scans the app bundle for every .json file.
//   - Tries to decode each as a StockedRecipeBundle.
//   - Tracks which files have already been imported using a set of
//     "file fingerprints" (filename + recipe count) stored in UserDefaults.
//   - Only unprocessed files are imported; existing ones are skipped.
//   - RecipeDatabase.upsert() handles all deduplication (title-keyed).
//   - Large files (>500 recipes) are imported in background batches
//     to avoid blocking launch.
//
// SUPPORTED JSON SCHEMA:
//   {
//     "version":  Int,           // schema version (currently 1)
//     "source":   String,        // e.g. "RecipeNLG", "MyRecipes"
//     "license":  String,        // optional, e.g. "CC BY 4.0"
//     "count":    Int,           // number of recipes in this file
//     "recipes":  [StockedBundleRecipe]
//   }
//
// You can also drop in ingredient-only JSONs:
//   {
//     "version":    Int,
//     "source":     String,
//     "food_items": [String],    // plain list of ingredient names
//     "brands":     [String]     // optional brand names
//   }
// ═══════════════════════════════════════════════════════════════════════════

import Foundation
import os

// MARK: - Schema models

struct StockedRecipeBundle: Decodable {
    let version:  Int
    let source:   String
    let license:  String?
    let count:    Int?
    let recipes:  [StockedBundleRecipe]
}

struct StockedBundleRecipe: Decodable {
    let title:        String
    let description:  String?
    let sourceURL:    String?
    let sourceName:   String?
    let prepTime:     String?
    let cookTime:     String?
    let totalTime:    String?
    let servings:     String?
    let category:     String?
    let cuisine:      String?
    let tags:         [String]?
    let ingredients:  [String]
    let steps:        [String]
    let imageName:    String?
    let imageURL:     String?
}

struct StockedIngredientBundle: Decodable {
    let version:    Int
    let source:     String
    let food_items: [String]?
    let brands:     [String]?
}

// MARK: - Bundle file fingerprint (tracks what's been imported)

private struct BundleFingerprint: Codable, Hashable {
    let filename: String
    let count:    Int
    var key:      String { "\(filename):\(count)" }
}

// MARK: - Importer

@MainActor
final class StockedBundleImporter {

    static let shared = StockedBundleImporter()
    private init() {}

    private let fingerprintsKey = "importedBundleFingerprints_v1"
    private let batchSize       = 250   // recipes per batch for large files

    // MARK: - Main entry point

    /// Call once from AppSession or RecipeDatabaseManager on launch.
    /// Scans the bundle, imports any new JSON files, skips already-imported ones.
    func importNewBundlesIfNeeded() {
        Task {
            await self.runImport()
        }
    }

    /// Force re-import of ALL bundle JSONs (e.g. after clearing app data).
    func resetAndReimportAll() {
        UserDefaults.standard.removeObject(forKey: fingerprintsKey)
        importNewBundlesIfNeeded()
    }

    // MARK: - Core import logic

    private func runImport() async {
        let processed = loadFingerprints()
        var newFingerprints = processed

        // Find all JSON files in the main bundle
        let jsonURLs = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []

        for url in jsonURLs {
            let filename = url.lastPathComponent

            // ── Try as recipe bundle ──────────────────────────────
            if let bundle = tryDecodeRecipeBundle(at: url) {
                let fp = BundleFingerprint(filename: filename, count: bundle.recipes.count)
                guard !processed.contains(fp.key) else { continue }

                let imported = await importRecipeBundle(bundle, filename: filename)
                if imported > 0 {
                    newFingerprints.insert(fp.key)
                    saveFingerprints(newFingerprints)
                }
                continue
            }

            // ── Try as ingredient bundle ──────────────────────────
            if let bundle = tryDecodeIngredientBundle(at: url) {
                let count = (bundle.food_items?.count ?? 0) + (bundle.brands?.count ?? 0)
                let fp = BundleFingerprint(filename: filename, count: count)
                guard !processed.contains(fp.key) else { continue }

                await importIngredientBundle(bundle)
                newFingerprints.insert(fp.key)
                saveFingerprints(newFingerprints)
            }
        }
    }

    // MARK: - Recipe import (batched for large files)

    private func importRecipeBundle(_ bundle: StockedRecipeBundle, filename: String) async -> Int {
        let entries = bundle.recipes.compactMap { makeEntry($0, source: bundle.source) }
        guard !entries.isEmpty else { return 0 }

        // Split into batches and yield between them so launch isn't blocked
        let batches = stride(from: 0, to: entries.count, by: batchSize).map {
            Array(entries[$0 ..< min($0 + batchSize, entries.count)])
        }

        var total = 0
        for batch in batches {
            await RecipeDatabase.shared.upsertAll(batch)
            total += batch.count
            // Yield so background thread doesn't monopolise CPU
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }

        // Feed into knowledge base so predictive text learns from new recipes
        await MainActor.run {
            for entry in entries {
                for ing in entry.ingredients {
                    StockedKnowledgeBase.shared.learnFromInventoryItem(name: ing)
                }
            }
        }

        return total
    }

    // MARK: - Ingredient import

    private func importIngredientBundle(_ bundle: StockedIngredientBundle) async {
        await MainActor.run {
            let kb = StockedKnowledgeBase.shared
            for name in bundle.food_items ?? [] {
                kb.learnFromInventoryItem(name: name)
            }
        }
    }

    // MARK: - Model conversion

    private func makeEntry(_ r: StockedBundleRecipe, source: String) -> RecipeDatabaseEntry? {
        guard !r.title.trimmingCharacters(in: .whitespaces).isEmpty,
              !r.ingredients.isEmpty else { return nil }

        return RecipeDatabaseEntry(
            title:       r.title,
            description: r.description ?? "",
            sourceURL:   r.sourceURL   ?? "",
            sourceName:  (r.sourceName ?? source).isEmpty ? source : (r.sourceName ?? source),
            prepTime:    r.prepTime    ?? "",
            cookTime:    r.cookTime    ?? "",
            totalTime:   r.totalTime   ?? "",
            servings:    r.servings    ?? "",
            category:    r.category    ?? "",
            cuisine:     r.cuisine     ?? "",
            tags:        r.tags        ?? [],
            ingredients: r.ingredients,
            steps:       r.steps,
            imageURL:    r.imageURL    ?? "",
            cachedAt:    Date()
        )
    }

    // MARK: - Decode helpers

    private func tryDecodeRecipeBundle(at url: URL) -> StockedRecipeBundle? {
        guard isInlineSized(url) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StockedRecipeBundle.self, from: data)
    }

    private func tryDecodeIngredientBundle(at url: URL) -> StockedIngredientBundle? {
        guard isInlineSized(url) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let b = try? JSONDecoder().decode(StockedIngredientBundle.self, from: data)
        // Must have at least one of food_items/brands to count as an ingredient bundle
        guard let b, (b.food_items != nil || b.brands != nil) else { return nil }
        return b
    }

    /// #4: the bulk recipe corpus is now a prebuilt SQLite database (RecipeStore),
    /// not bundled JSON. Refuse to whole-file-decode anything large here — that old
    /// path cost ~326 MB peak RSS + seconds of CPU at launch. Hand-authored drop-in
    /// JSONs (well under 8 MB) still import exactly as documented.
    private func isInlineSized(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sz = attrs[.size] as? Int else { return false }
        if sz > 8 * 1024 * 1024 {
            Log.app.error("StockedBundleImporter skipping oversized JSON \(url.lastPathComponent, privacy: .public) (\(sz) bytes); use build_recipe_db.py → SQLite instead.")
            return false
        }
        return true
    }

    // MARK: - Fingerprint persistence

    private func loadFingerprints() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: fingerprintsKey) ?? []
        return Set(arr)
    }

    private func saveFingerprints(_ fps: Set<String>) {
        UserDefaults.standard.set(Array(fps), forKey: fingerprintsKey)
    }
}
