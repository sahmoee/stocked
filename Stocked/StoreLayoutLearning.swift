// StoreLayoutLearning.swift — Feature 8: your list, in the order you actually walk the store.
//
// Generic "sort by category" ordering is wrong in every specific store — produce is at the front in
// one and the back in another. Instead of shipping a guess, this LEARNS: you shop a trip in the
// order you find things, and Stocked keeps a running average position per item per store.
//
// After two or three trips the list orders itself, and it keeps adapting when the store resets.

import SwiftUI

// MARK: - Model

nonisolated struct StoreLayout: Codable, Hashable, Sendable {
    // ── Household sync (launch readiness 1.4) ────────────────────────────────
    // Defaulted so entries saved before sync existed still decode. Same epoch-ms
    // last-write-wins convention as LocalInventoryItem.
    var updatedAt: Double = 0
    var lastWriterID: String = ""

    var store: String
    /// normalized item name -> average position (0…1 through the store)
    var positions: [String: Double] = [:]
    var trips: Int = 0

    /// Exponential moving average: recent trips matter more, so a store remodel is absorbed in
    /// a couple of visits instead of being outvoted by a year of history.
    mutating func learn(order: [String]) {
        guard order.count > 1 else { return }
        let alpha = 0.4
        for (i, raw) in order.enumerated() {
            let key = StoreLayout.normalize(raw)
            guard !key.isEmpty else { continue }
            let pos = Double(i) / Double(order.count - 1)
            positions[key] = positions[key].map { $0 * (1 - alpha) + pos * alpha } ?? pos
        }
        trips += 1
    }

    /// Known position, or nil if we've never seen this item here.
    func position(of name: String) -> Double? { positions[StoreLayout.normalize(name)] }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^\d+(\.\d+)?\s*\w*\s+"#, with: "", options: .regularExpression)
    }
}

// MARK: - Engine (pure)

nonisolated enum StoreRouting {
    /// Sort a list into walking order. Learned positions always win. Unknown items remain grouped
    /// after learned items, but use the common department database instead of an arbitrary order.
    static func sort(_ items: [String], layout: StoreLayout) -> [String] {
        items.enumerated().sorted { a, b in
            let pa = layout.position(of: a.element)
            let pb = layout.position(of: b.element)
            switch (pa, pb) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:
                let aa = GroceryKnowledgeBase.inferAisle(for: a.element).defaultOrder
                let ab = GroceryKnowledgeBase.inferAisle(for: b.element).defaultOrder
                return aa == ab ? a.offset < b.offset : aa < ab
            }
        }.map(\.element)
    }

    static func knownCount(_ items: [String], layout: StoreLayout) -> Int {
        items.filter { layout.position(of: $0) != nil }.count
    }

    /// How much to trust the ordering yet — drives the "still learning" copy.
    static func confidence(_ items: [String], layout: StoreLayout) -> Double {
        guard !items.isEmpty, layout.trips > 0 else { return 0 }
        let coverage = Double(knownCount(items, layout: layout)) / Double(items.count)
        let maturity = min(1, Double(layout.trips) / 3)
        return coverage * maturity
    }
}

// MARK: - Store

@MainActor
@Observable
final class StoreLayoutStore {
    static let shared = StoreLayoutStore()
    /// Improvement #6 — file-backed, debounced, and migrated automatically from the old
    /// UserDefaults blob on first load. See FeatureStore.swift for why.
    /// Named `persistence`, not `store`, because this type's own methods take a `store: String`
    /// parameter — the shadowing would be a trap for the next edit.
    private let persistence = FeatureStore<StoreLayout>(key: FeatureStoreKeys.storeLayouts)

    var layouts: [StoreLayout] = [] { didSet { persistence.save(layouts) } }
    var activeStore: String = UserDefaults.standard.string(forKey: "activeStoreName") ?? "" {
        didSet { UserDefaults.standard.set(activeStore, forKey: "activeStoreName") }
    }

    private init() { layouts = persistence.load() }

    /// Push any pending write to disk immediately (call before backgrounding).
    func flush() { persistence.flush() }

    func layout(for store: String) -> StoreLayout {
        layouts.first { $0.store.caseInsensitiveCompare(store) == .orderedSame } ?? StoreLayout(store: store)
    }

    /// Record a completed trip. This is the only way layouts get smarter.
    func record(store: String, order: [String]) {
        guard !store.isEmpty, order.count > 1 else { return }
        var l = layout(for: store)
        l.learn(order: order)
        // Launch readiness 1.4 — stamp for household sync (layouts are shared: same store,
        // same aisles, everyone's trips make everyone's list smarter).
        l.updatedAt = Date().timeIntervalSince1970 * 1000
        l.lastWriterID = UserDefaults.standard.string(forKey: "hh_member_id") ?? ""
        if let i = layouts.firstIndex(where: { $0.store.caseInsensitiveCompare(store) == .orderedSame }) {
            layouts[i] = l
        } else {
            layouts.append(l)
        }
    }

    func forget(_ store: String) {
        layouts.removeAll { $0.store == store }
        FeatureSync.shared.recordDeleteName(collection: FeatureSync.Keys.storeLayouts, name: store)
    }
    var storeNames: [String] { layouts.map(\.store).sorted() }
}

// MARK: - UI

struct StoreLayoutView: View {
    @Environment(AppSession.self) private var session
    private let store = StoreLayoutStore.shared

    @State private var storeName = StoreLayoutStore.shared.activeStore
    @State private var tripOrder: [String] = []
    @State private var inTrip = false

    private var listItems: [String] {
        session.guestStore.groceryItems.filter { !$0.isChecked }.map(\.name)
    }
    private var layout: StoreLayout { store.layout(for: storeName) }
    private var sorted: [String] { StoreRouting.sort(listItems, layout: layout) }
    private var remaining: [String] { sorted.filter { !tripOrder.contains($0) } }

    var body: some View {
        List {
            Section {
                TextField("Store name (e.g. H-E-B on Main)", text: $storeName)
                    .onChange(of: storeName) { _, new in store.activeStore = new }
                if layout.trips > 0 {
                    HStack {
                        Text("Learned from \(layout.trips) trip\(layout.trips == 1 ? "" : "s")")
                        Spacer()
                        Text("\(Int(StoreRouting.confidence(listItems, layout: layout) * 100))% confident")
                            .foregroundStyle(session.accentColor)
                    }
                    .font(.system(size: 12))
                }
            } footer: {
                Text(layout.trips == 0
                     ? "Start a trip and tap items in the order you find them. After a couple of trips your list sorts itself into walking order for this store."
                     : "Your list below is already sorted for this store. Run another trip any time the store moves things.")
            }

            if listItems.isEmpty {
                Section { Text("Nothing on your grocery list.").foregroundStyle(.secondary) }
            } else if inTrip {
                Section("Tap in the order you find them") {
                    ForEach(remaining, id: \.self) { item in
                        Button {
                            HapticManager.light(); tripOrder.append(item)
                        } label: {
                            HStack {
                                Image(systemName: "circle").foregroundStyle(.secondary)
                                Text(item).foregroundStyle(session.themeTextColor)
                            }
                        }
                    }
                }
                if !tripOrder.isEmpty {
                    Section("Picked up (\(tripOrder.count))") {
                        ForEach(Array(tripOrder.enumerated()), id: \.offset) { i, item in
                            HStack {
                                Text("\(i + 1)").font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(session.accentColor).frame(width: 22, alignment: .leading)
                                Text(item).strikethrough().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        HapticManager.success()
                        store.record(store: storeName, order: tripOrder)
                        tripOrder = []; inTrip = false
                    } label: { Label("Finish trip and learn", systemImage: "checkmark.circle.fill") }
                        .disabled(tripOrder.count < 2)
                    Button(role: .destructive) { tripOrder = []; inTrip = false } label: { Text("Cancel trip") }
                }
            } else {
                Section("Your list, in walking order") {
                    ForEach(Array(sorted.enumerated()), id: \.offset) { i, item in
                        HStack {
                            Text("\(i + 1)").font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(layout.position(of: item) == nil ? .secondary : session.accentColor)
                                .frame(width: 22, alignment: .leading)
                            Text(item).foregroundStyle(session.themeTextColor)
                            Spacer()
                            if layout.position(of: item) == nil {
                                Text("new here").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        HapticManager.light(); inTrip = true
                    } label: {
                        Label(layout.trips == 0 ? "Start first trip" : "Start a trip", systemImage: "figure.walk")
                    }
                    .disabled(storeName.trimmingCharacters(in: .whitespaces).isEmpty || listItems.count < 2)
                }
            }

            if !store.storeNames.isEmpty {
                Section("Stores you've mapped") {
                    ForEach(store.storeNames, id: \.self) { name in
                        Button {
                            storeName = name; store.activeStore = name
                        } label: {
                            HStack {
                                Text(name).foregroundStyle(session.themeTextColor)
                                Spacer()
                                Text("\(store.layout(for: name).trips) trips")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in idx.map { store.storeNames[$0] }.forEach { store.forget($0) } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stockedScreen()
        .navigationTitle("Store Layout")
        .navigationBarTitleDisplayMode(.inline)
    }
}
