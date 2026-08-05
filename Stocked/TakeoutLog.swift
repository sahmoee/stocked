// TakeoutLog.swift — Feature 13: the meals that don't come from your kitchen still shape it.
//
// A pantry app that only knows about groceries has a blind spot: the food budget and the meal plan
// both break on takeout, and neither the user nor the app can see why. Logging it takes seconds and
// closes the loop — you finally get the true cost-per-meal picture, and the plan stops assuming you
// cooked on Thursday when you didn't.

import SwiftUI

// MARK: - Model

nonisolated struct TakeoutEntry: Codable, Identifiable, Hashable, Sendable, HouseholdSyncable {
    // ── Household sync (launch readiness 1.4) ────────────────────────────────
    // Defaulted so entries saved before sync existed still decode. Same epoch-ms
    // last-write-wins convention as LocalInventoryItem.
    var updatedAt: Double = 0
    var lastWriterID: String = ""

    var id: UUID = UUID()
    var place: String
    var dish: String = ""
    var cost: Double
    var date: Date = Date()
    var mealType: String = "Dinner"          // Breakfast / Lunch / Dinner / Snack
    var kind: String = "Takeout"             // Takeout / Delivery / Restaurant
    var people: Int = 1
    var rating: Int = 0                      // 0 = unrated, 1…5
    var wouldReorder: Bool = true
    var note: String = ""

    var costPerPerson: Double { cost / Double(max(1, people)) }

    static let mealTypes = RecipeTaxonomy.categories.filter { ["Breakfast", "Lunch", "Dinner", "Snack"].contains($0) }
    static let kinds = ["Takeout", "Delivery", "Restaurant"]
}

nonisolated struct EatingOutSummary: Sendable {
    let count: Int
    let total: Double
    let perMeal: Double
    let topPlace: String?
    /// What the same number of meals would have cost cooked at home, at a typical per-serving figure.
    let homeCookedEquivalent: Double
    var difference: Double { total - homeCookedEquivalent }
}

// MARK: - Engine (pure)

nonisolated enum TakeoutMath {
    /// Typical cost of a home-cooked serving. Used only for a like-for-like comparison, and stated
    /// as an estimate in the UI rather than presented as fact.
    static let homeCostPerServing: Double = 4.50

    static func summary(_ entries: [TakeoutEntry]) -> EatingOutSummary {
        let total = entries.reduce(0) { $0 + $1.cost }
        let servings = entries.reduce(0) { $0 + max(1, $1.people) }
        let places = Dictionary(grouping: entries, by: \.place)
            .mapValues { $0.count }
            .max { $0.value < $1.value }?.key

        return EatingOutSummary(
            count: entries.count,
            total: total,
            perMeal: entries.isEmpty ? 0 : total / Double(entries.count),
            topPlace: places,
            homeCookedEquivalent: Double(servings) * homeCostPerServing)
    }

    static func inMonth(_ entries: [TakeoutEntry], _ date: Date = Date()) -> [TakeoutEntry] {
        entries.filter { Calendar.current.isDate($0.date, equalTo: date, toGranularity: .month) }
    }

    /// Which weekday you order most — the actionable insight, because that's the night to prep ahead.
    static func busiestWeekday(_ entries: [TakeoutEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        let counts = Dictionary(grouping: entries) {
            Calendar.current.component(.weekday, from: $0.date)
        }.mapValues(\.count)
        guard let top = counts.max(by: { $0.value < $1.value }), top.value >= 2 else { return nil }
        return Calendar.current.weekdaySymbols[safe: top.key - 1]
    }

    /// Places worth reordering from, best-rated first.
    static func favorites(_ entries: [TakeoutEntry]) -> [(place: String, rating: Double, visits: Int)] {
        Dictionary(grouping: entries.filter { $0.rating > 0 }, by: \.place)
            .map { place, list in
                (place, list.reduce(0.0) { $0 + Double($1.rating) } / Double(list.count), list.count)
            }
            .sorted { $0.rating > $1.rating }
    }
}

// (`[safe:]` above comes from CrashSafety.swift — bounds-proof element access.)

// MARK: - Store

@MainActor
@Observable
final class TakeoutStore {
    static let shared = TakeoutStore()
    /// Improvement #6 — file-backed, debounced, and migrated automatically from the old
    /// UserDefaults blob on first load. See FeatureStore.swift for why.
    private let store = FeatureStore<TakeoutEntry>(key: FeatureStoreKeys.takeoutLog)
    /// Re-entrancy guard for the sync stamping pass (see the didSet). Not observed.
    @ObservationIgnored private var _stamping = false

    var entries: [TakeoutEntry] = [] { didSet {
        store.save(entries)
        // CRASH FIX (build 65): assign the stamped array once, guarded, so the
        // follow-up didSet is a no-op instead of recursing forever (see FeatureSync).
        guard !_stamping else { return }
        _stamping = true
        let _stamped = FeatureSync.shared.stampMutation(FeatureSync.Keys.takeoutLog, old: oldValue, current: entries)
        if _stamped != entries { entries = _stamped }
        _stamping = false
    } }

    private init() {
        _stamping = true
        entries = store.load()
        _stamping = false
    }

    /// Push any pending write to disk immediately (call before backgrounding).
    func flush() { store.flush() }

    var recent: [TakeoutEntry] { entries.sorted { $0.date > $1.date } }
    var thisMonth: [TakeoutEntry] { TakeoutMath.inMonth(entries) }

    func add(_ e: TakeoutEntry) { entries.append(e) }
    /// #5 — undoable.
    func remove(_ e: TakeoutEntry) {
        entries.removeAll { $0.id == e.id }
        ToastCenter.shared.undo("Removed \(e.place)") { [weak self] in
            self?.entries.append(e)
        }
    }
}

// MARK: - UI

struct TakeoutLogView: View {
    @Environment(AppSession.self) private var session
    private let store = TakeoutStore.shared
    @State private var showAdd = false

    private var summary: EatingOutSummary { TakeoutMath.summary(store.thisMonth) }
    private var currency: String { Locale.current.currency?.identifier ?? "USD" }

    var body: some View {
        Group {
            if store.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bag").font(.system(size: 34))
                        .foregroundStyle(session.themeTextColor.opacity(0.25))
                    Text("Nothing logged yet").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                    Text("Log takeout and restaurant meals and your real food spend finally adds up — plus you build a list of what was worth reordering.")
                        .font(.system(size: 13)).multilineTextAlignment(.center)
                        .foregroundStyle(session.themeTextColor.opacity(0.55)).padding(.horizontal, 36)
                    Button { showAdd = true } label: {
                        Text("Log a meal").font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(session.accentColor).foregroundStyle(.white).clipShape(Capsule())
                    }.buttonStyle(.plain).padding(.top, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        HStack {
                            stat("This month", summary.total.formatted(.currency(code: currency)))
                            Divider()
                            stat("Meals", "\(summary.count)")
                            Divider()
                            stat("Average", summary.perMeal.formatted(.currency(code: currency)))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }

                    if summary.count > 0 {
                        Section {
                            HStack {
                                Text("Cooking the same meals at home")
                                Spacer()
                                Text(summary.homeCookedEquivalent, format: .currency(code: currency))
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            if summary.difference > 0 {
                                Text("About \(summary.difference.formatted(.currency(code: currency))) more this month than cooking would have cost.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            if let day = TakeoutMath.busiestWeekday(store.entries) {
                                Text("\(day) is your most common order-out night — worth prepping something ahead for.")
                                    .font(.system(size: 12)).foregroundStyle(session.accentColor)
                            }
                        } header: { Text("For comparison") } footer: {
                            Text("Home cost is estimated at \(TakeoutMath.homeCostPerServing.formatted(.currency(code: currency))) per serving. It's a rough benchmark, not your actual grocery spend.")
                        }
                    }

                    let favs = TakeoutMath.favorites(store.entries)
                    if !favs.isEmpty {
                        Section("Worth reordering") {
                            ForEach(favs.prefix(5), id: \.place) { f in
                                HStack {
                                    Text(f.place).font(.system(size: 14))
                                    Spacer()
                                    Text(String(repeating: "★", count: Int(f.rating.rounded())))
                                        .font(.system(size: 12)).foregroundStyle(.orange)
                                    Text("×\(f.visits)").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Section("History") {
                        ForEach(store.recent) { e in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(e.place).font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    Text(e.cost, format: .currency(code: currency))
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                Text("\(e.kind) · \(e.mealType) · \(e.date.formatted(date: .abbreviated, time: .omitted))"
                                     + (e.dish.isEmpty ? "" : " · \(e.dish)"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { idx in idx.map { store.recent[$0] }.forEach { store.remove($0) } }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .stockedScreen()
        .navigationTitle("Eating Out")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showAdd) { AddTakeoutSheet() }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .bold)).foregroundStyle(session.accentColor)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

private struct AddTakeoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let store = TakeoutStore.shared
    @State private var entry = TakeoutEntry(place: "", cost: 0)
    @State private var costText = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Place", text: $entry.place)
                TextField("What did you get? (optional)", text: $entry.dish)
                TextField("Cost", text: $costText).keyboardType(.decimalPad)
                Picker("Kind", selection: $entry.kind) {
                    ForEach(TakeoutEntry.kinds, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Meal", selection: $entry.mealType) {
                    ForEach(TakeoutEntry.mealTypes, id: \.self) { Text($0).tag($0) }
                }
                Stepper("\(entry.people) \(entry.people == 1 ? "person" : "people")", value: $entry.people, in: 1...20)
                DatePicker("When", selection: $entry.date, displayedComponents: .date)
                Section("Was it good?") {
                    HStack(spacing: 6) {
                        ForEach(1...5, id: \.self) { star in
                            Button {
                                entry.rating = star; HapticManager.light()
                            } label: {
                                Image(systemName: star <= entry.rating ? "star.fill" : "star")
                                    .foregroundStyle(.orange)
                            }.buttonStyle(.plain)
                        }
                    }
                    Toggle("Would order again", isOn: $entry.wouldReorder)
                }
            }
            .navigationTitle("Log a meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        var e = entry
                        e.place = e.place.trimmingCharacters(in: .whitespaces)
                        e.cost = Double(costText) ?? 0
                        store.add(e)
                        dismiss()
                    }
                    .font(.body.bold())
                    .disabled(entry.place.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
