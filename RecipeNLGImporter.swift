// RecipeNLGImporter.swift
// -----------------------
// Legacy entry point — now delegates to BundleDataImporter.
// BundleDataImporter handles all JSON discovery, deduplication,
// and multi-schema support automatically.
//
// To add new data: drag any stocked_*.json / recipes_*.json into
// Xcode, add to target, build. No code changes needed.

import Foundation

@MainActor
final class RecipeNLGImporter {
    static let shared = RecipeNLGImporter()
    private init() {}

    /// Legacy call site — now handled by BundleDataImporter via mergeAllSources.
    func importIfNeeded() async {
        await BundleDataImporter.shared.importNewBundledFiles()
    }

    /// Force re-import of all bundled JSONs.
    func resetAndReimport() async {
        BundleDataImporter.shared.resetAll()
        await BundleDataImporter.shared.importNewBundledFiles()
    }
}
