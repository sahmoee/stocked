// LeftoversLifecycle.swift — Feature 4: cooked meals become tracked items with their own clock.
//
// Most household food waste isn't spoiled produce — it's the container of chili nobody remembered.
// This gives every cooked meal a portion count, a short expiry (4 days fridge / 90 freezer by
// default, refined by ShelfLifeEstimator), and a visible "eat me next" queue.
//
// Self-contained storage so it never risks the synced inventory model; `LeftoverEntry` is Codable
// and can be folded into household sync later.

import SwiftUI

// MARK: - Model

nonisolated struct LeftoverEntry: Codable, Identifiable, Hashable, Sendable, HouseholdSyncable {
    // ── Household sync (launch readiness 1.4) ────────────────────────────────
    // Defaulted so entries saved before sync existed still decode. Same epoch-ms
    // last-write-wins convention as LocalInventoryItem.
    var updatedAt: Double = 0
    var lastWriterID: String = ""

    var id: UUID = UUID()
    var title: String
    var portions: Int
    var cookedAt: Date
    var storage: String          // "Fridge" | "Freezer"
    var expiresAt: Date
    var note: String = ""

    var isFrozen: Bool { storage == "Freezer" }
    var daysLeft: Int { Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0 }
    var isExpired: Bool { expiresAt < Date() }

    init(updatedAt: Double = 0, lastWriterID: String = "", id: UUID = UUID(), title: String,
         portions: Int, cookedAt: Date, storage: String, expiresAt: Date, note: String = "") {
        self.updatedAt = updatedAt; self.lastWriterID = lastWriterID; self.id = id; self.title = title
        self.portions = portions; self.cookedAt = cookedAt; self.storage = storage
        self.expiresAt = expiresAt; self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case updatedAt, lastWriterID, id, title, portions, cookedAt, storage, expiresAt, note
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        lastWriterID = try c.decodeIfPresent(String.self, forKey: .lastWriterID) ?? ""
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Leftovers"
        portions = try c.decodeIfPresent(Int.self, forKey: .portions) ?? 1
        cookedAt = try c.decodeIfPresent(Date.self, forKey: .cookedAt) ?? Date()
        storage = try c.decodeIfPresent(String.self, forKey: .storage) ?? "Fridge"
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
            ?? Self.defaultExpiry(from: cookedAt, storage: storage)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    /// Default shelf life for a cooked dish. Deliberately conservative — food safety, not optimism.
    static func defaultExpiry(from date: Date, storage: String) -> Date {
        let days = storage == "Freezer" ? 90 : 4
        return Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }
}

// MARK: - Store

@MainActor
@Observable
final class LeftoversStore {
    static let shared = LeftoversStore()
    /// Improvement #6 — file-backed, debounced, and migrated automatically from the old
    /// UserDefaults blob on first load. See FeatureStore.swift for why.
    private let store = FeatureStore<LeftoverEntry>(key: FeatureStoreKeys.leftovers)
    /// Re-entrancy guard for the sync stamping pass (see the didSet). Not observed.
    @ObservationIgnored private var _stamping = false

    var entries: [LeftoverEntry] = [] { didSet {
        store.save(entries)
        // CRASH FIX (build 65): assign the stamped array once, guarded, so the
        // follow-up didSet is a no-op instead of recursing forever (see FeatureSync).
        guard !_stamping else { return }
        _stamping = true
        let _stamped = FeatureSync.shared.stampMutation(FeatureSync.Keys.leftovers, old: oldValue, current: entries)
        if _stamped != entries { entries = _stamped }
        _stamping = false
    } }

    private init() {
        _stamping = true                 // don't stamp/enqueue migrated rows on launch
        entries = store.load()
        _stamping = false
    }

    /// Push any pending write to disk immediately (call before backgrounding).
    func flush() { store.flush() }

    /// Soonest-to-expire first — this is the "eat me next" order.
    var queue: [LeftoverEntry] { entries.sorted { $0.expiresAt < $1.expiresAt } }
    var expiringSoon: [LeftoverEntry] { queue.filter { !$0.isFrozen && $0.daysLeft <= 1 } }

    func add(title: String, portions: Int, storage: String, cookedAt: Date = Date()) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        let entry = LeftoverEntry(title: cleanTitle, portions: max(1, portions), cookedAt: cookedAt,
                                  storage: storage,
                                  expiresAt: LeftoverEntry.defaultExpiry(from: cookedAt, storage: storage))
        entries.append(entry)
    }
    /// Eat one portion; the entry disappears when it's gone.
    func eatPortion(_ entry: LeftoverEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].portions -= 1
        if entries[i].portions <= 0 { entries.remove(at: i) }
    }
    /// #5 — tossing food is destructive and easy to mis-tap. The row comes back if the user
    /// says so within the toast window.
    func toss(_ entry: LeftoverEntry) {
        guard entries.contains(where: { $0.id == entry.id }) else { return }
        entries.removeAll { $0.id == entry.id }
        ToastCenter.shared.undo("Tossed \(entry.title)") { [weak self] in
            guard let self, !self.entries.contains(where: { $0.id == entry.id }) else { return }
            self.entries.append(entry)
        }
    }
    /// Moving to the freezer resets the clock — that's the whole point of freezing it.
    func freeze(_ entry: LeftoverEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        guard !entries[i].isFrozen else { return }
        entries[i].storage = "Freezer"
        entries[i].expiresAt = LeftoverEntry.defaultExpiry(from: Date(), storage: "Freezer")
    }
}

// MARK: - UI

struct LeftoversView: View {
    @Environment(AppSession.self) private var session
    private let store = LeftoversStore.shared
    @State private var showAdd = false

    var body: some View {
        StockedShell(showBack: true, trailingIcon: "plus", trailingLabel: "Add leftovers",
                     onTrailing: { showAdd = true }, canvasColor: session.inventoryCanvas) {
            InventoryEditorialHeading(title: "Leftovers", subtitle: "Good food, ready for another moment.", artwork: 5)
                .padding(.horizontal, 20)
            if store.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "takeoutbag.and.cup.and.straw")
                        .scaledFont(34).foregroundStyle(session.themeTextColor.opacity(0.25))
                    Text("No leftovers tracked").scaledFont(16, weight: .semibold)
                        .foregroundStyle(session.themeTextColor)
                    Text("Save a portion after cooking and it'll show up here with its own clock, so it gets eaten instead of forgotten.")
                        .scaledFont(13).multilineTextAlignment(.center)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .padding(.horizontal, 40)
                    Button { showAdd = true } label: {
                        Text("Add leftovers").scaledFont(14, weight: .semibold)
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(session.inventoryGold)
                            .foregroundStyle(session.isDarkMode ? Color.stockedCharcoal : .stockedWhite)
                            .clipShape(Capsule())
                    }.buttonStyle(.plain).padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(store.queue) { e in
                        VStack(alignment: .leading, spacing: 6) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(e.title).font(.stockedSerif(19, weight: .semibold, relativeTo: .headline))
                                    .foregroundStyle(session.themeTextColor)
                                    .fixedSize(horizontal: false, vertical: true)
                                Label(status(e), systemImage: e.isExpired ? "exclamationmark.triangle" : "clock")
                                    .scaledFont(12, weight: .semibold).foregroundStyle(color(e))
                            }
                            Text("\(e.portions) portion\(e.portions == 1 ? "" : "s") · \(e.storage)")
                                .scaledFont(13).foregroundStyle(session.themeSecondaryText)
                            Text("Cooked \(e.cookedAt.formatted(date: .abbreviated, time: .omitted))")
                                .scaledFont(12).foregroundStyle(session.themeSecondaryText)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) {
                                action("Ate one", "fork.knife") { store.eatPortion(e) }
                                if !e.isFrozen { action("Freeze", "snowflake") { store.freeze(e) } }
                                action("Toss", "trash", destructive: true) { store.toss(e) }
                            }
                            .padding(.top, 2)
                        }
                        .modifier(InventoryEditorialCard())
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .stockedScreen()
        .sheet(isPresented: $showAdd) { AddLeftoverSheet() }
    }

    private func status(_ e: LeftoverEntry) -> String {
        if e.isExpired { return "past date" }
        if e.daysLeft == 0 { return "eat today" }
        return "\(e.daysLeft)d left"
    }
    private func color(_ e: LeftoverEntry) -> Color {
        if e.isExpired { return .red }
        if e.daysLeft <= 1 { return .orange }
        return session.themeSecondaryText
    }
    private func action(_ label: String, _ icon: String, destructive: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil) { HapticManager.light(); run() } label: {
            HStack(spacing: 4) { Image(systemName: icon); Text(label) }
                .font(.stockedSerif(13, weight: .semibold, relativeTo: .subheadline))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(session.themeCardColor)
                .foregroundStyle(destructive ? Color.stockedError : session.inventoryGold)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

private struct AddLeftoverSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    private let store = LeftoversStore.shared
    @State private var title = ""
    @State private var portions = 2
    @State private var storage = "Fridge"
    @State private var cookedAt = Date()
    @State private var confirmDiscard = false
    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasDraft: Bool { !cleanTitle.isEmpty || portions != 2 || storage != "Fridge" || !Calendar.current.isDateInToday(cookedAt) }

    var body: some View {
        NavigationStack {
            Form {
                InventoryEditorialHeading(title: "Save a portion", subtitle: "Make tomorrow a little easier.", artwork: 5)
                    .listRowBackground(Color.clear)
                Group {
                TextField("What is it? (e.g. Chicken chili)", text: $title)
                    .textInputAutocapitalization(.sentences)
                Stepper("\(portions) portion\(portions == 1 ? "" : "s")", value: $portions, in: 1...20)
                DatePicker("Cooked on", selection: $cookedAt, in: ...Date(), displayedComponents: .date)
                Picker("Storage", selection: $storage) {
                    Text("Fridge").tag("Fridge"); Text("Freezer").tag("Freezer")
                }.pickerStyle(.menu)
                }
                .listRowBackground(session.themeCardColor)
                Section {
                    Text("Reminder date: \(LeftoverEntry.defaultExpiry(from: cookedAt, storage: storage).formatted(date: .abbreviated, time: .omitted))")
                        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    Text("Dates are estimates based on when this was cooked and where it is stored; check the food before using it.")
                        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                }
                .listRowBackground(session.themeCardColor)
            }
            .navigationTitle("Add leftovers")
            .scrollContentBackground(.hidden)
            .background(session.inventoryCanvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        store.add(title: cleanTitle, portions: portions, storage: storage, cookedAt: cookedAt)
                        dismiss()
                    }
                    .font(.stocked(.body).bold())
                    .disabled(cleanTitle.isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { if hasDraft { confirmDiscard = true } else { dismiss() } }
                }
            }
        }
        .stockedPresentationSurface(width: .form, canvasColor: session.inventoryCanvas)
        .interactiveDismissDisabled(hasDraft)
        .confirmationDialog("Discard these leftovers?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard draft", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) { }
        }
    }
}
