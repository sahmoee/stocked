// KaggleRecipeImporter.swift
//
// RETIRED — Build 89. This used to read stocked_kaggle_recipes.json out of the app bundle
// and seed up to 1500 rows into RecipeDatabase. That dataset is no longer shipped and no
// longer wanted: the rows were machine-scored and thinly written, and they buried the
// recipes people actually cook from under a library nobody asked for.
//
// The type is kept rather than deleted so that any call site left in the tree — or added
// back by a merge from an older branch — still compiles and still does nothing. Both
// entry points now clear the seed marker and hand off to the purge, so calling the old
// importer removes Kaggle recipes instead of adding them. That is the safest possible
// behaviour for a method somebody might call by accident.
//
// The real enforcement is elsewhere and does not depend on this file:
//   • RecipeSourceBlocklist          — decides what a retired source is
//   • RecipeDatabase.upsertNoPersist — refuses to store one, from any path
//   • BundleDataImporter             — skips the seed file by name before reading it
//   • RecipePurge.run                — sweeps what is already stored, every launch
//
// If the app bundle still contains stocked_kaggle_recipes.json, remove it from the Xcode
// target. Nothing reads it any more, but it is dead weight in the download.

import Foundation
import os

@MainActor
final class KaggleRecipeImporter {
    static let shared = KaggleRecipeImporter()
    private init() {}

    /// Was: seed the bundled dataset. Now: make sure none of it is left.
    func importIfNeeded() async {
        UserDefaults.standard.removeObject(forKey: "kaggleSeedVersion")
        let removed = await RecipeDatabase.shared.purgeBlockedSources()
        if removed > 0 {
            Log.data.notice("Kaggle seeding is retired; removed \(removed, privacy: .public) leftover rows")
        } else {
            Log.data.debug("Kaggle seeding is retired; nothing left to remove")
        }
    }

    /// Was: force a re-import. Now: identical to `importIfNeeded()`. There is nothing to
    /// re-import, and a method named "reimport" that quietly reseeded a retired dataset
    /// would be the one way all of this could come back.
    func resetAndReimport() async {
        await importIfNeeded()
    }
}
