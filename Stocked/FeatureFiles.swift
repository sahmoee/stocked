// FeatureFiles.swift — URL Import, Calendar, Smart Restock, OCR Confirm, Prep Timer, Protocols
// App Better: 2,4,5,6,8,9,11  |  Code Professional: 11,14
import SwiftUI
import Combine
import EventKit

// MARK: - Protocol-based store (Code Professional #11)
protocol InventoryStoring {
    var inventoryItems: [LocalInventoryItem] { get set }
    func addInventoryItem(_ item: LocalInventoryItem)
}
protocol GroceryStoring {
    var groceryItems: [LocalGroceryItem] { get set }
    func addGroceryItem(name: String)
}
protocol RecipeStoring {
    var userRecipes: [UserRecipe] { get set }
    var pastMeals: [LocalPastMeal] { get set }
}
extension GuestDataStore: InventoryStoring, GroceryStoring, RecipeStoring {}

// MARK: - App Better #2 — Recipe URL Import
struct RecipeURLImportView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @State private var urlText = ""; @State private var loading = false
    @State private var result: CachedRecipe?; @State private var showError = false
    @State private var errorMsg = ""; @State private var showSaved = false

    var body: some View {
        ZStack { session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.15)).frame(width: 40, height: 4).padding(.top, 12)
                HStack {
                    Text("Import Recipe").stocked(.headline).foregroundStyle(session.themeTextColor)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").scaledFont(26)
                            .foregroundStyle(session.themeTextColor.opacity(0.25))
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 24).padding(.vertical, 14)

                VStack(spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "link").foregroundStyle(session.themeTextColor.opacity(0.4))
                        TextField("Paste a recipe URL…", text: $urlText)
                            .stocked(.body).foregroundStyle(session.themeTextColor)
                            .keyboardType(.URL).autocorrectionDisabled()
                    }
                    .padding(14).background(session.themeCardColor).clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 24)

                    Text("Paste any recipe URL — we'll extract the title, ingredients and steps automatically.")
                        .stocked(.caption).foregroundStyle(session.themeTextColor.opacity(0.45))
                        .multilineTextAlignment(.center).padding(.horizontal, 32)

                    if loading { ProgressView("Fetching…").tint(Color.stockedGold) }

                    if let r = result {
                        HStack(spacing: 12) {
                            if let url = URL(string: r.imageURL) {
                                CachedAsyncImage(url: url.absoluteString, imageData: nil, height: 64)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.title).stocked(.callout).foregroundStyle(session.themeTextColor).fixedSize(horizontal: false, vertical: true)
                                Text("\(r.ingredients.count) ingredients · \(r.source)")
                                    .stocked(.caption).foregroundStyle(session.themeTextColor.opacity(0.5))
                            }
                            Spacer()
                            Button {
                                saveToCollection(r); showSaved = true
                                Task {
                                    try? await Task.sleep(nanoseconds: 1500000000)
                                    dismiss()
                                }
                            } label: {
                                Image(systemName: showSaved ? "checkmark.circle.fill" : "plus.circle.fill")
                                    .scaledFont(28)
                                    .foregroundStyle(showSaved ? Color.stockedGreen : Color.stockedGold)
                            }.buttonStyle(.plain)
                        }
                        .padding(14).background(session.themeCardColor).clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 24)
                    }
                    if showError { Text(errorMsg).stocked(.caption).foregroundStyle(.red).padding(.horizontal, 24) }
                }
                Spacer()
                Button("Import Recipe") { Task { await doImport() } }
                    .disabled(urlText.isEmpty || loading)
                    .padding(.horizontal, 24).padding(.bottom, 32).stockedPrimary()
            }
        }.presentationDetents([.medium, .large])
    }

    private func saveToCollection(_ r: CachedRecipe) {
        let recipe = UserRecipe(title: r.title, description: "Imported from \(r.source)",
            ingredients: r.ingredients.map { RecipeIngredient(name: $0, amount: "") },
            instructions: r.steps, imageURL: r.imageURL)
        session.guestStore.userRecipes.insert(recipe, at: 0)
        HapticManager.success()
    }

    @MainActor private func doImport() async {
        loading = true; showError = false
        do { result = try await RecipeAPIClient.shared.importFromURL(urlText) }
        catch { errorMsg = (error as? StockedError)?.errorDescription ?? "Couldn't import recipe."; showError = true }
        loading = false
    }
}

// MARK: - App Better #5 — Calendar Sync
class CalendarSyncManager {
    static let shared = CalendarSyncManager()
    private let store = EKEventStore()

    func requestAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await store.requestWriteOnlyAccessToEvents()
        } else {
            return try await withCheckedThrowingContinuation { cont in
                store.requestAccess(to: .event) { granted, err in
                    if let e = err { cont.resume(throwing: e) } else { cont.resume(returning: granted) }
                }
            }
        }
    }

    func addMealEvent(title: String, date: Date, cookMinutes: Int = 30) async throws {
        let granted = try await requestAccess()
        guard granted else { throw StockedError.calendarAccessDenied }
        let event = EKEvent(eventStore: store)
        event.title = "🍳 Cook: \(title)"
        event.startDate = date
        event.endDate = date.addingTimeInterval(TimeInterval(cookMinutes * 60))
        event.calendar = store.defaultCalendarForNewEvents
        event.addAlarm(EKAlarm(relativeOffset: -1800))
        do { try store.save(event, span: .thisEvent) }
        catch { throw StockedError.calendarSaveFailed }
    }
}

// MARK: - App Better #6 — Smart Restocking
class UsageTracker {
    static let shared = UsageTracker()
    private(set) var usageMap: [String: Int] = [:]  // [weak self] pattern via value types
    private let key = StockedKeys.usageTracking
    init() { load() }

    func record(_ item: String) {
        usageMap[item.lowercased(), default: 0] += 1; persist()
    }
    func count(for item: String) -> Int { usageMap[item.lowercased()] ?? 0 }
    func shouldRestock(_ item: String) -> Bool { count(for: item) >= 3 }
    func topItems(limit: Int = 10) -> [(String, Int)] {
        usageMap.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key.capitalized, $0.value) }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(usageMap) { UserDefaults.standard.set(data, forKey: key) }
    }
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        usageMap = decoded
    }
}

// MARK: - App Better #8 — OCR Confirmation Screen
struct OCRConfirmationView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @Binding var rawLines: [String]
    @State private var included: [String: Bool] = [:]
    @State private var edited:   [String: String] = [:]

    var body: some View {
        ZStack { session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.15)).frame(width: 40, height: 4).padding(.top, 12)
                HStack {
                    Text("Confirm Receipt Items").stocked(.headline).foregroundStyle(session.themeTextColor)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").scaledFont(26)
                            .foregroundStyle(session.themeTextColor.opacity(0.25))
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 24).padding(.vertical, 14)

                Text("Toggle off any items you don't want. Edit names if the scanner misread them.")
                    .stocked(.caption).foregroundStyle(session.themeTextColor.opacity(0.5))
                    .padding(.horizontal, 24).padding(.bottom, 14)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(rawLines, id: \.self) { line in
                            let translated = session.guestStore.translateOCR(line) ?? line
                            let inc = included[line] ?? true
                            HStack(spacing: 12) {
                                Toggle("", isOn: Binding(get: { included[line] ?? true }, set: { included[line] = $0 }))
                                    .labelsHidden().tint(Color.stockedGold)
                                TextField(translated, text: Binding(
                                    get: { edited[line] ?? translated },
                                    set: { edited[line] = $0 }
                                ))
                                .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                                .stocked(.body).foregroundStyle(inc ? session.themeTextColor : session.themeSecondaryText)
                                .strikethrough(!inc)
                                Spacer()
                            }
                            .padding(12).background(session.themeCardColor).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        }
                    }.padding(.horizontal, 20)
                }

                let count = rawLines.filter { included[$0] ?? true }.count
                Button("Add \(count) Item\(count == 1 ? "" : "s") to Pantry") {
                    rawLines.filter { included[$0] ?? true }.forEach { line in
                        let name = (edited[line] ?? session.guestStore.translateOCR(line) ?? line).trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        session.guestStore.addInventoryItem(LocalInventoryItem(name: name.capitalized, level: 1.0, zone: "Pantry"))
                    }
                    dismiss()
                }
                .disabled(count == 0).padding(.horizontal, 24).padding(.vertical, 16).stockedPrimary()
            }
        }.presentationDetents([.large])
    }
}

// MARK: - App Better #9 — Barcode → Grocery (optional)

// MARK: - App Better #11 — Prep Timer
