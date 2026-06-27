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
            .task { refreshCounts() }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
        }
        .environment(session)
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
        Text(t).font(.system(size: 10, weight: .bold)).tracking(1)
            .foregroundStyle(session.themeTextColor.opacity(0.35))
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
