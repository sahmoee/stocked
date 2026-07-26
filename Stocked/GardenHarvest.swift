// GardenHarvest.swift — Feature 14: food that arrives from the garden, not the store.
//
// Home growers have the opposite problem to shoppers: supply arrives all at once, unplanned, and
// rots while they're deciding what to do with it. This logs harvests, pushes them straight into the
// pantry with a realistic shelf life, shows what the season actually produced, and hands gluts off
// to the preservation planner.

import SwiftUI

// MARK: - Model

nonisolated struct HarvestEntry: Codable, Identifiable, Hashable, Sendable, HouseholdSyncable {
    // ── Household sync (launch readiness 1.4) ────────────────────────────────
    // Defaulted so entries saved before sync existed still decode. Same epoch-ms
    // last-write-wins convention as LocalInventoryItem.
    var updatedAt: Double = 0
    var lastWriterID: String = ""

    var id: UUID = UUID()
    var crop: String
    var amount: Double
    var unit: String = "lb"
    var date: Date = Date()
    var note: String = ""
    /// Market price per unit, so the season total means something.
    var valuePerUnit: Double = 0

    var value: Double { amount * valuePerUnit }
    static let units = ["lb", "oz", "kg", "g", "each", "bunch", "pint"]
}

nonisolated struct CropTotal: Identifiable, Sendable {
    var id: String { crop }
    let crop: String
    let amount: Double
    let unit: String
    let value: Double
    let harvests: Int
    let lastHarvest: Date
}

// MARK: - Engine (pure)

nonisolated enum HarvestMath {

    static func totals(_ entries: [HarvestEntry]) -> [CropTotal] {
        Dictionary(grouping: entries) { $0.crop.lowercased() }
            .map { _, list in
                CropTotal(crop: list[0].crop,
                          amount: list.reduce(0) { $0 + $1.amount },
                          unit: list[0].unit,
                          value: list.reduce(0) { $0 + $1.value },
                          harvests: list.count,
                          lastHarvest: list.map(\.date).max() ?? Date())
            }
            .sorted { $0.value == $1.value ? $0.amount > $1.amount : $0.value > $1.value }
    }

    static func inSeason(_ entries: [HarvestEntry], year: Int? = nil) -> [HarvestEntry] {
        let y = year ?? Calendar.current.component(.year, from: Date())
        return entries.filter { Calendar.current.component(.year, from: $0.date) == y }
    }

    static func totalValue(_ entries: [HarvestEntry]) -> Double { entries.reduce(0) { $0 + $1.value } }

    /// A glut is a crop you've harvested a lot of recently — the case for preserving rather than
    /// hoping to eat it all.
    static func gluts(_ entries: [HarvestEntry]) -> [CropTotal] {
        let recent = entries.filter { $0.date > Date().addingTimeInterval(-14 * 86_400) }
        return totals(recent).filter { $0.harvests >= 2 || $0.amount >= 5 }
    }

    /// Typical days a fresh-picked crop keeps at room temperature or in the fridge. Home-grown
    /// produce has no post-harvest treatment, so it moves faster than store stock.
    static func freshDays(for crop: String) -> Int {
        let c = crop.lowercased()
        func has(_ w: [String]) -> Bool { w.contains { c.contains($0) } }
        if has(["lettuce", "spinach", "arugula", "herb", "basil", "cilantro", "greens"]) { return 5 }
        if has(["tomato", "cucumber", "pepper", "zucchini", "squash", "bean", "pea", "corn"]) { return 7 }
        if has(["berry", "strawberry", "raspberry", "fig"]) { return 3 }
        if has(["carrot", "beet", "radish", "turnip", "cabbage"]) { return 21 }
        if has(["potato", "onion", "garlic", "winter squash", "pumpkin"]) { return 60 }
        if has(["apple", "pear"]) { return 30 }
        return 10
    }
}

// MARK: - Store

@MainActor
@Observable
final class HarvestStore {
    static let shared = HarvestStore()
    /// Improvement #6 — file-backed, debounced, and migrated automatically from the old
    /// UserDefaults blob on first load. See FeatureStore.swift for why.
    private let store = FeatureStore<HarvestEntry>(key: FeatureStoreKeys.gardenHarvests)
    /// Re-entrancy guard for the sync stamping pass (see the didSet). Not observed.
    @ObservationIgnored private var _stamping = false

    var entries: [HarvestEntry] = [] { didSet {
        store.save(entries)
        // CRASH FIX (build 65): assign the stamped array once, guarded, so the
        // follow-up didSet is a no-op instead of recursing forever (see FeatureSync).
        guard !_stamping else { return }
        _stamping = true
        let _stamped = FeatureSync.shared.stampMutation(FeatureSync.Keys.gardenHarvests, old: oldValue, current: entries)
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

    var recent: [HarvestEntry] { entries.sorted { $0.date > $1.date } }
    var thisSeason: [HarvestEntry] { HarvestMath.inSeason(entries) }

    func add(_ e: HarvestEntry) { entries.append(e) }
    /// #5 — undoable: a season's harvest log is not something to lose to a stray swipe.
    func remove(_ e: HarvestEntry) {
        entries.removeAll { $0.id == e.id }
        ToastCenter.shared.undo("Removed \(e.crop) harvest") { [weak self] in
            self?.entries.append(e)
        }
    }

    /// Crops seen before, so logging the same tomato variety twice doesn't mean typing it twice.
    var knownCrops: [String] {
        Array(Set(entries.map(\.crop))).sorted()
    }
}

// MARK: - UI

struct GardenHarvestView: View {
    @Environment(AppSession.self) private var session
    private let store = HarvestStore.shared
    @State private var showAdd = false

    private var currency: String { Locale.current.currency?.identifier ?? "USD" }
    private var totals: [CropTotal] { HarvestMath.totals(store.thisSeason) }
    private var gluts: [CropTotal] { HarvestMath.gluts(store.entries) }

    var body: some View {
        Group {
            if store.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "leaf.circle").font(.system(size: 34))
                        .foregroundStyle(session.themeTextColor.opacity(0.25))
                    Text("No harvests logged").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                    Text("Log what you pick and it goes straight into your pantry with a realistic shelf life — plus you get a running total of what the garden actually produced this year.")
                        .font(.system(size: 13)).multilineTextAlignment(.center)
                        .foregroundStyle(session.themeTextColor.opacity(0.55)).padding(.horizontal, 36)
                    Button { showAdd = true } label: {
                        Text("Log a harvest").font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(session.accentColor).foregroundStyle(.white).clipShape(Capsule())
                    }.buttonStyle(.plain).padding(.top, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        HStack {
                            stat("Harvests", "\(store.thisSeason.count)")
                            Divider()
                            stat("Crops", "\(totals.count)")
                            Divider()
                            stat("Value", HarvestMath.totalValue(store.thisSeason).formatted(.currency(code: currency)))
                        }.padding(.vertical, 4)
                    } header: { Text("This season") }

                    if !gluts.isEmpty {
                        Section {
                            ForEach(gluts) { g in
                                NavigationLink {
                                    PreservationDetailView(itemName: g.crop,
                                                           method: PreservationGuide.methods(for: g.crop)[0])
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(g.crop).font(.system(size: 14, weight: .semibold))
                                        Text("\(fmt(g.amount)) \(g.unit) in two weeks · keeps about \(HarvestMath.freshDays(for: g.crop)) days fresh")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: { Text("More than you'll eat") } footer: {
                            Text("Tap for the best way to preserve it before it turns.")
                        }
                    }

                    Section("By crop") {
                        ForEach(totals) { t in
                            HStack {
                                Text(t.crop).font(.system(size: 14))
                                Spacer()
                                Text("\(fmt(t.amount)) \(t.unit)")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(session.accentColor)
                                if t.value > 0 {
                                    Text(t.value, format: .currency(code: currency))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Section("Log") {
                        ForEach(store.recent) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(e.crop).font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    Text("\(fmt(e.amount)) \(e.unit)").font(.system(size: 13))
                                }
                                Text(e.date.formatted(date: .abbreviated, time: .omitted)
                                     + (e.note.isEmpty ? "" : " · \(e.note)"))
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
        .navigationTitle("Garden")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showAdd) { AddHarvestSheet() }
    }

    private func fmt(_ d: Double) -> String {
        String(format: d == d.rounded() ? "%.0f" : "%.1f", d)
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 15, weight: .bold)).foregroundStyle(session.accentColor)
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

private struct AddHarvestSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session
    private let store = HarvestStore.shared

    @State private var crop = ""
    @State private var amountText = ""
    @State private var unit = "lb"
    @State private var date = Date()
    @State private var valueText = ""
    @State private var addToPantry = true

    var body: some View {
        NavigationStack {
            Form {
                TextField("What did you pick?", text: $crop)
                if !store.knownCrops.isEmpty && crop.isEmpty {
                    Section("Grown before") {
                        ForEach(store.knownCrops, id: \.self) { c in Button(c) { crop = c } }
                    }
                }
                HStack {
                    TextField("Amount", text: $amountText).keyboardType(.decimalPad)
                    Picker("", selection: $unit) {
                        ForEach(HarvestEntry.units, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                TextField("Value per \(unit) (optional)", text: $valueText).keyboardType(.decimalPad)
                DatePicker("Picked", selection: $date, displayedComponents: .date)
                Section {
                    Toggle("Add to my pantry", isOn: $addToPantry)
                } footer: {
                    Text(crop.isEmpty ? "Fresh-picked produce keeps a shorter time than store stock — Stocked sets the date accordingly."
                                      : "Goes in with about \(HarvestMath.freshDays(for: crop)) days of shelf life, since home-grown produce has no post-harvest treatment.")
                }
            }
            .navigationTitle("Log a harvest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .font(.body.bold())
                        .disabled(crop.trimmingCharacters(in: .whitespaces).isEmpty || (Double(amountText) ?? 0) <= 0)
                }
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func save() {
        let name = crop.trimmingCharacters(in: .whitespaces)
        let amount = Double(amountText) ?? 0
        store.add(HarvestEntry(crop: name, amount: amount, unit: unit, date: date,
                               valuePerUnit: Double(valueText) ?? 0))
        if addToPantry {
            var item = LocalInventoryItem(name: name)
            item.quantity = max(1, Int(amount.rounded()))
            item.sizeAmount = amount
            item.sizeUnit = unit
            item.storageCategory = .fridge
            item.purchaseDate = date
            item.expirationDate = Calendar.current.date(byAdding: .day,
                                                        value: HarvestMath.freshDays(for: name), to: date)
            session.guestStore.inventoryItems.append(item)
        }
        HapticManager.success()
        dismiss()
    }
}
