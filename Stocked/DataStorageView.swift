//
//  DataStorageView.swift
//  Stocked.
//
//  CHECKPOINT 1 — verification & backup screen.
//
//  Lets the user:
//    • see that their data copied into the new SwiftData store (row counts side-by-side
//      with what's currently in the app), so the migration is *verifiable*, not blind;
//    • export a full JSON backup (the safety net before any cutover);
//    • restore from a backup file.
//
//  Reachable from the menu (Data & Account). Touches only the new additive store + the
//  existing GuestDataStore — current persistence is unaffected.
//

import SwiftUI
import UniformTypeIdentifiers

struct DataStorageView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var sdCounts: [String: Int] = [:]
    @State private var showImporter = false
    @State private var backupURL: URL?
    @State private var message: String?
    @State private var working = false
    @State private var cacheUsage = AppCacheManager.Usage.empty
    @State private var showClearCacheAlert = false

    private var store: GuestDataStore { session.guestStore }

    // Live counts from the app's current (UserDefaults-backed) collections.
    private var liveCounts: [(label: String, live: Int, key: String)] {
        [
            ("Inventory",   store.inventoryItems.count,        "Inventory"),
            ("Grocery",     store.groceryItems.count,          "Grocery"),
            ("My Recipes",  store.userRecipes.count,           "My Recipes"),
            ("Generated",   store.savedGeneratedRecipes.count, "Generated"),
            ("Past Meals",  store.pastMeals.count,             "Past Meals"),
            ("Planned",     store.plannedMeals.count,          "Planned"),
            ("Prices",      store.priceHistory.count,          "Prices"),
            ("Consumption", store.consumptionLog.count,        "Consumption"),
            ("Subs",        store.userSubstitutions.count,     "Subs")
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(liveCounts, id: \.label) { row in
                        HStack {
                            Text(row.label)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(session.themeTextColor)
                            Spacer()
                            // app count → migrated count
                            Text("\(row.live)")
                                .foregroundStyle(session.themeTextColor.opacity(0.6))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10))
                                .foregroundStyle(session.themeTextColor.opacity(0.3))
                            migratedBadge(for: row.key, live: row.live)
                        }
                        .font(.system(size: 14))
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    drawerHeaderText("Migration check  (app → new store)")
                } footer: {
                    Text("Both numbers should match once the new store has copied your data. Your existing data is untouched either way.")
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                }

                Section {
                    HStack {
                        Label("Cached files", systemImage: "internaldrive")
                            .foregroundStyle(session.themeTextColor)
                        Spacer()
                        Text(cacheUsage.totalString)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(cacheUsage.isLarge ? Color.stockedGold : session.themeSecondaryText)
                    }
                    .listRowBackground(Color.clear)

                    cacheRow("Recipe and data responses", value: cacheUsage.dataString)
                    cacheRow("Nutrition API responses", value: cacheUsage.apiString)
                    cacheRow("Recipe and product images", value: cacheUsage.imageString)
                    cacheRow("System network cache", value: cacheUsage.networkString)

                    if cacheUsage.isLarge {
                        Label("Cache is getting large. Deleting it frees space; Stocked will download needed content again.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.stockedGold)
                            .listRowBackground(Color.clear)
                    }

                    Button(role: .destructive) {
                        showClearCacheAlert = true
                    } label: {
                        HStack {
                            Label(working ? "Deleting Cached Files…" : "Delete Cached Files", systemImage: "trash")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working || cacheUsage.totalBytes == 0)
                    .listRowBackground(Color.clear)
                } header: {
                    drawerHeaderText("Cache")
                } footer: {
                    Text("Downloaded recipes, nutrition responses, product metadata, and images are cached for faster loading and offline reuse. Your pantry, grocery list, saved recipes, and account data are never deleted here.")
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                }

                Section {
                    Button {
                        backupURL = DataExport.writeBackupFile(from: store)
                        message = backupURL == nil ? "Couldn't create the backup file." : nil
                    } label: {
                        Label("Create Backup File", systemImage: "square.and.arrow.up")
                            .foregroundStyle(Color.stockedGold)
                    }
                    .listRowBackground(Color.clear)

                    if let url = backupURL {
                        ShareLink(item: url) {
                            Label("Share / Save Backup", systemImage: "tray.and.arrow.up")
                                .foregroundStyle(session.themeTextColor)
                        }
                        .listRowBackground(Color.clear)
                    }

                    Button {
                        showImporter = true
                    } label: {
                        Label("Restore from Backup…", systemImage: "tray.and.arrow.down")
                            .foregroundStyle(session.themeTextColor)
                    }
                    .listRowBackground(Color.clear)
                } header: {
                    drawerHeaderText("Backup")
                } footer: {
                    Text("A backup is a single JSON file with all your data. Keep one before any big update.")
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(message.contains("ouldn't") || message.contains("rror")
                                             ? Color.red : Color.stockedGreen)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Data & Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.stockedGold)
                }
            }
            .task {
                refreshCounts()
                await refreshCacheUsage()
            }
            .alert("Delete cached files?", isPresented: $showClearCacheAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Cache", role: .destructive) {
                    Task { await clearCache() }
                }
            } message: {
                Text("This removes downloaded copies only. Stocked will rebuild the cache as you use the app.")
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
        }
        .environment(session)
    }

    private func cacheRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(session.themeTextColor.opacity(0.72))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(session.themeSecondaryText)
        }
        .listRowBackground(Color.clear)
    }

    private func refreshCacheUsage() async {
        cacheUsage = await AppCacheManager.usage()
    }

    private func clearCache() async {
        working = true
        await AppCacheManager.clearAll()
        cacheUsage = await AppCacheManager.usage()
        working = false
        message = "Cached files deleted."
    }

    @ViewBuilder
    private func migratedBadge(for key: String, live: Int) -> some View {
        let migrated = sdCounts[key] ?? -1
        let ok = migrated >= live && migrated >= 0
        Text(migrated < 0 ? "—" : "\(migrated)")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(ok ? Color.stockedGreen : Color.stockedGold)
    }

    private func drawerHeaderText(_ t: String) -> some View {
        SectionHeader(text: t, padded: false)
    }

    private func refreshCounts() {
        sdCounts = StockedDataStore.shared.counts()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            message = "Import failed: \(err.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            // Security-scoped resource for files outside the sandbox.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                try DataExport.restore(from: data, into: store, mode: .merge)
                message = "Backup restored."
            } catch {
                message = "Restore failed: \(error.localizedDescription)"
            }
        }
    }
}


@MainActor
private enum AppCacheManager {
    struct Usage: Sendable {
        let dataBytes: Int
        let apiBytes: Int
        let imageBytes: Int
        let networkBytes: Int

        static let empty = Usage(dataBytes: 0, apiBytes: 0, imageBytes: 0, networkBytes: 0)
        var totalBytes: Int { dataBytes + apiBytes + imageBytes + networkBytes }
        var isLarge: Bool { totalBytes >= 300 * 1_048_576 }
        var dataString: String { Self.format(dataBytes) }
        var apiString: String { Self.format(apiBytes) }
        var imageString: String { Self.format(imageBytes) }
        var networkString: String { Self.format(networkBytes) }
        var totalString: String { Self.format(totalBytes) }

        private static func format(_ bytes: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    static func usage() async -> Usage {
        let apiBytes = await APIResponseCache.shared.diskSizeBytes()
        let dataBytes = LocalDatabase.shared.dataCacheSizeBytes
            + BarcodeCache.shared.sizeBytes
        return Usage(
            dataBytes: dataBytes,
            apiBytes: apiBytes,
            imageBytes: ImageCache.shared.diskCacheSizeBytes,
            networkBytes: URLCache.shared.currentDiskUsage
        )
    }

    static func clearAll() async {
        await WebRecipeCatalogue.shared.clear()
        OfflineRecipeCache.shared.clear()
        SpoonacularCache.shared.clear()
        BarcodeCache.shared.clear()
        LocalDatabase.shared.clearDataCache()
        ImageCache.shared.clearAll()
        await APIResponseCache.shared.clear()
        URLCache.shared.removeAllCachedResponses()
        UserDefaults.standard.removeObject(forKey: "onlineRecipesCache_v3")
        UserDefaults.standard.removeObject(forKey: "onlineRecipesCacheTimestamp_v3")
        UserDefaults.standard.removeObject(forKey: "webRecipeCatalogue_v1")
    }
}
