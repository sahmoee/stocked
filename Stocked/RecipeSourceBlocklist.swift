// RecipeSourceBlocklist.swift — the one place that decides a recipe source is not welcome,
// and the sweep that removes anything already stored from one.
//
// Two sources are retired: the bundled Kaggle food dataset and the "Sowens" curated feed.
// Neither should appear in a library again, which is two separate jobs:
//
//   1. NOTHING NEW GETS IN. `RecipeDatabase.upsertNoPersist` asks this file before it
//      stores anything. That is the single chokepoint every ingestion path funnels
//      through — the bundled-JSON importer, the Kaggle seeder, the web catalogue merge,
//      the offline cache merge — so blocking it here blocks all of them at once, including
//      any path added later that nobody remembers to update.
//   2. WHAT IS ALREADY THERE COMES OUT. `RecipePurge.run` sweeps the recipe database, the
//      user's own recipes and the saved generated recipes on every launch, and empties the
//      curated feed's disk cache.
//
// Matching is deliberately narrow. It reads `sourceName`, `sourceURL`, the recipe's tags
// and the derived id prefix — never the title, the description or the steps. A recipe
// called "Sowens Farmhouse Loaf" that the user typed themselves is theirs and stays.
// `BuildConfig.company` is "Sowens Studios"; that is a brand string, not a recipe source,
// and nothing here reads it.
//
// THE THING NOT TO REFACTOR: the sweep assigns `userRecipes` and `savedGeneratedRecipes`
// exactly once each. Those two arrays record household tombstones inside their `didSet`
// observers, so building the new array and assigning it in one shot is what makes a
// removal here stay removed on the phone's other devices. Mutating in place, or looping
// `deleteUserRecipe(id:)`, either skips the tombstones entirely — and the next household
// pull puts every one of them back — or fires N separate household pushes for one sweep.

import Foundation
import os

// MARK: - The blocklist

nonisolated enum RecipeSourceBlocklist {

    /// Matched as a substring of a lowercased `sourceName`. "Kaggle Food Dataset",
    /// "kaggle", "Sowens" and "sowens-curated" all match; nothing else does.
    static let blockedSourceFragments: [String] = ["kaggle", "sowens"]

    /// Matched as a substring of a lowercased `sourceURL`, so a recipe that kept the
    /// dataset link but lost its source name is still caught.
    static let blockedURLFragments: [String] = ["kaggle.com", "kaggle.io"]

    /// Derived ids the retired sources stamped onto their rows.
    static let blockedIDPrefixes: [String] = ["sowens-", "kaggle-"]

    /// Bundled JSON filenames to skip outright, so an 8 MB seed file is not parsed at
    /// launch only to have every row rejected one at a time.
    static let blockedFileFragments: [String] = ["kaggle", "sowens"]

    private static func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The primitive every other check is built on.
    static func isBlocked(sourceName: String, sourceURL: String = "", tags: [String] = [],
                          id: String = "") -> Bool {
        let name = norm(sourceName)
        if !name.isEmpty, blockedSourceFragments.contains(where: { name.contains($0) }) { return true }

        let url = norm(sourceURL)
        if !url.isEmpty, blockedURLFragments.contains(where: { url.contains($0) }) { return true }

        let ident = norm(id)
        if !ident.isEmpty, blockedIDPrefixes.contains(where: { ident.hasPrefix($0) }) { return true }

        // Tags are checked by whole-tag equality, not substring. `RecipeAdapter` copies a
        // curated recipe's source name straight into its tags, which is the only marker
        // that survives the conversion into a `UserRecipe` — but a tag is user-visible
        // free text, so "kaggle-style" should not condemn a recipe somebody typed.
        for tag in tags {
            let t = norm(tag)
            if blockedSourceFragments.contains(t) { return true }
        }
        return false
    }

    static func isBlocked(_ entry: RecipeDatabaseEntry) -> Bool {
        isBlocked(sourceName: entry.sourceName, sourceURL: entry.sourceURL, tags: entry.tags)
    }

    /// A recipe the user has in their own library. Only the tags carry provenance here;
    /// `UserRecipe` has no source field, which is why `RecipeAdapter` writes the source
    /// name into the tag list when it converts a browsed recipe into a saved one.
    static func isBlocked(_ recipe: UserRecipe) -> Bool {
        isBlocked(sourceName: "", sourceURL: recipe.imageURL ?? "", tags: recipe.tags)
    }

    /// A saved AI-generated recipe. These are produced on-device and can only be blocked
    /// if a retired source's category was carried into `mealCategory`.
    static func isBlocked(_ recipe: GeneratedRecipe) -> Bool {
        isBlocked(sourceName: "", sourceURL: recipe.imageURL ?? "",
                  tags: recipe.mealCategory.isEmpty ? [] : [recipe.mealCategory])
    }

    /// Bundled resource filter, used by `BundleDataImporter` before it reads a file.
    static func isBlockedFilename(_ name: String) -> Bool {
        let n = norm(name)
        return blockedFileFragments.contains { n.contains($0) }
    }
}

// MARK: - The sweep

nonisolated struct RecipePurgeReport: Sendable {
    var databaseEntries = 0
    var userRecipes     = 0
    var savedRecipes    = 0
    var cachesCleared   = 0

    var total: Int { databaseEntries + userRecipes + savedRecipes }
    var isEmpty: Bool { total == 0 && cachesCleared == 0 }

    var summary: String {
        guard !isEmpty else { return "Nothing to remove." }
        var parts: [String] = []
        if databaseEntries > 0 { parts.append("\(databaseEntries) from the recipe database") }
        if userRecipes > 0     { parts.append("\(userRecipes) from your recipes") }
        if savedRecipes > 0    { parts.append("\(savedRecipes) saved") }
        if cachesCleared > 0   { parts.append("\(cachesCleared) cached file\(cachesCleared == 1 ? "" : "s") cleared") }
        return parts.joined(separator: ", ") + "."
    }
}

@MainActor
enum RecipePurge {

    /// Bumped whenever the blocklist grows. Only used for the one-time log line — the
    /// sweep itself runs every launch, because it is cheap and because a household pull
    /// from a device still on an older build is the one way blocked recipes can arrive
    /// after the chokepoint is in place.
    private static let versionKey = "recipeSourcePurgeVersion"
    private static let currentVersion = 1

    /// Also clear the seed marker the Kaggle importer used, so a downgrade-then-upgrade
    /// cannot make an old build think it has already seeded and a new one think it hasn't.
    private static let kaggleSeedVersionKey = "kaggleSeedVersion"

    @discardableResult
    static func run(store: GuestDataStore) async -> RecipePurgeReport {
        var report = RecipePurgeReport()

        // 1. The recipe database. One pass, one write, done off the main actor inside the
        //    actor that owns it.
        report.databaseEntries = await RecipeDatabase.shared.purgeBlockedSources()

        // 2. The user's own recipes. Filter first, compare, assign once — and only if the
        //    count actually moved, because an unchanged assignment still fires `didSet`
        //    and would push an empty household batch on every single launch.
        let keptUser = store.userRecipes.filter { !RecipeSourceBlocklist.isBlocked($0) }
        if keptUser.count != store.userRecipes.count {
            report.userRecipes = store.userRecipes.count - keptUser.count
            store.userRecipes = keptUser
        }

        // 3. Saved generated recipes, same rule.
        let keptSaved = store.savedGeneratedRecipes.filter { !RecipeSourceBlocklist.isBlocked($0) }
        if keptSaved.count != store.savedGeneratedRecipes.count {
            report.savedRecipes = store.savedGeneratedRecipes.count - keptSaved.count
            store.savedGeneratedRecipes = keptSaved
        }

        // 4. The curated feed's disk cache and its ETag. Left in place, the next launch
        //    would decode it and hand the rows straight back to the Discover feed.
        report.cachesCleared = clearCuratedCache()

        // 5. Retire the seeder's marker.
        UserDefaults.standard.removeObject(forKey: kaggleSeedVersionKey)

        let seen = UserDefaults.standard.integer(forKey: versionKey)
        if seen < currentVersion {
            UserDefaults.standard.set(currentVersion, forKey: versionKey)
            Log.data.notice("Recipe source purge v\(currentVersion, privacy: .public): \(report.summary, privacy: .public)")
        } else if !report.isEmpty {
            Log.data.notice("Recipe source purge: \(report.summary, privacy: .public)")
        }
        return report
    }

    /// Deletes the curated-feed cache written by `RemoteContentClient`. Returns how many
    /// files actually went, so a report can distinguish "cleared" from "was never there".
    @discardableResult
    static func clearCuratedCache() -> Int {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
        let names = ["sowens_recipes.json", "sowens_recipes.json.etag"]
        var cleared = 0
        for name in names {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            if (try? fm.removeItem(at: url)) != nil { cleared += 1 }
        }
        return cleared
    }
}
