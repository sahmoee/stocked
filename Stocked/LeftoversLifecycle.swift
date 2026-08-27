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
        let entry = LeftoverEntry(title: title, portions: max(1, portions), cookedAt: cookedAt,
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
        entries.removeAll { $0.id == entry.id }
        ToastCenter.shared.undo("Tossed \(entry.title)") { [weak self] in
            self?.entries.append(entry)
        }
    }
    /// Moving to the freezer resets the clock — that's the whole point of freezing it.
    func freeze(_ entry: LeftoverEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
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
        Group {
            if store.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "takeoutbag.and.cup.and.straw")
                        .font(.system(size: 34)).foregroundStyle(session.themeTextColor.opacity(0.25))
                    Text("No leftovers tracked").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                    Text("Save a portion after cooking and it'll show up here with its own clock, so it gets eaten instead of forgotten.")
                        .font(.system(size: 13)).multilineTextAlignment(.center)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .padding(.horizontal, 40)
                    Button { showAdd = true } label: {
                        Text("Add leftovers").font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(session.accentColor).foregroundStyle(.white)
                            .clipShape(Capsule())
                    }.buttonStyle(.plain).padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.queue) { e in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(e.title).font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(session.themeTextColor)
                                Spacer()
                                Text(status(e)).font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(color(e))
                            }
                            Text("\(e.portions) portion\(e.portions == 1 ? "" : "s") · \(e.storage)")
                                .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.55))
                            HStack(spacing: 8) {
                                action("Ate one", "fork.knife") { store.eatPortion(e) }
                                if !e.isFrozen { action("Freeze", "snowflake") { store.freeze(e) } }
                                action("Tossed", "trash") { store.toss(e) }
                            }
                            .padding(.top, 2)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .stockedScreen()
        .navigationTitle("Leftovers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
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
        return session.themeTextColor.opacity(0.45)
    }
    private func action(_ label: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button { HapticManager.light(); run() } label: {
            HStack(spacing: 4) { Image(systemName: icon); Text(label) }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(session.themeTextColor.opacity(0.07))
                .foregroundStyle(session.themeTextColor.opacity(0.8))
                .clipShape(Capsule())
        }.buttonStyle(.plain)
    }
}

private struct AddLeftoverSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let store = LeftoversStore.shared
    @State private var title = ""
    @State private var portions = 2
    @State private var storage = "Fridge"

    var body: some View {
        NavigationStack {
            Form {
                TextField("What is it? (e.g. Chicken chili)", text: $title)
                Stepper("\(portions) portion\(portions == 1 ? "" : "s")", value: $portions, in: 1...20)
                Picker("Storage", selection: $storage) {
                    Text("Fridge").tag("Fridge"); Text("Freezer").tag("Freezer")
                }.pickerStyle(.segmented)
                Section {
                    Text(storage == "Freezer"
                         ? "Good for about 90 days frozen."
                         : "Good for about 4 days in the fridge — you'll get a nudge before then.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add leftovers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        store.add(title: title.trimmingCharacters(in: .whitespaces), portions: portions, storage: storage)
                        dismiss()
                    }
                    .font(.body.bold())
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
