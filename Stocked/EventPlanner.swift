// EventPlanner.swift — Feature 6: cooking for a crowd is a different problem than cooking dinner.
//
// Scaling one recipe is easy. Scaling four recipes to 14 people, checking every dish against every
// guest's allergies, and getting one consolidated shopping list is the part people do badly on paper.
//
// Reuses FamilyProfileStore for the household, and adds one-off guests on top.

import SwiftUI

// MARK: - Model

nonisolated struct EventDish: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var baseServings: Int = 4
    var ingredients: [String] = []
}

nonisolated struct EventGuest: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var allergies: [String] = []
    var diet: String = "None"
}

nonisolated struct KitchenEvent: Codable, Identifiable, Hashable, Sendable, HouseholdSyncable {
    // ── Household sync (launch readiness 1.4) ────────────────────────────────
    // Defaulted so entries saved before sync existed still decode. Same epoch-ms
    // last-write-wins convention as LocalInventoryItem.
    var updatedAt: Double = 0
    var lastWriterID: String = ""

    var id: UUID = UUID()
    var name: String = "Dinner party"
    var date: Date = Date()
    var extraGuests: [EventGuest] = []
    var includeHousehold = true
    var dishes: [EventDish] = []
}

nonisolated struct DishConflict: Identifiable, Sendable {
    var id: String { dish + "|" + guest + "|" + ingredient }
    let dish: String
    let guest: String
    let ingredient: String
}

// MARK: - Engine (pure)

nonisolated enum EventMath {

    /// How many times each dish must be multiplied to feed everyone.
    static func scale(dish: EventDish, headcount: Int) -> Double {
        guard dish.baseServings > 0 else { return 1 }
        return max(1, (Double(headcount) / Double(dish.baseServings)).rounded(.up))
    }

    /// One consolidated list: every ingredient across every dish, scaled, deduped, with a "×N" note
    /// when the same thing appears in more than one dish.
    static func shoppingList(dishes: [EventDish], headcount: Int) -> [String] {
        var counts: [String: Double] = [:]
        var display: [String: String] = [:]
        for dish in dishes {
            let factor = scale(dish: dish, headcount: headcount)
            for raw in dish.ingredients {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                let key = line.lowercased()
                counts[key, default: 0] += factor
                display[key] = line
            }
        }
        return counts.keys.sorted().map { key in
            let n = counts[key] ?? 1
            let name = display[key] ?? key
            return n > 1 ? "\(name)  ×\(String(format: n == n.rounded() ? "%.0f" : "%.1f", n))" : name
        }
    }

    /// Every place a dish collides with a guest's allergy or diet. This is the whole reason the
    /// feature exists — a missed allergen at a dinner party is the worst-case outcome.
    static func conflicts(dishes: [EventDish], guests: [EventGuest]) -> [DishConflict] {
        var out: [DishConflict] = []
        for dish in dishes {
            for guest in guests {
                for allergen in guest.allergies where !allergen.trimmingCharacters(in: .whitespaces).isEmpty {
                    let a = allergen.lowercased()
                    if let hit = dish.ingredients.first(where: { $0.lowercased().contains(a) }) {
                        out.append(DishConflict(dish: dish.title, guest: guest.name, ingredient: hit))
                    }
                }
                if let restricted = dietRestriction(guest.diet, in: dish.ingredients) {
                    out.append(DishConflict(dish: dish.title, guest: "\(guest.name) (\(guest.diet))", ingredient: restricted))
                }
            }
        }
        return out
    }

    private static let dietBlocks: [String: [String]] = [
        "Vegetarian":  ["beef", "chicken", "pork", "bacon", "lamb", "turkey", "fish", "shrimp", "anchovy", "gelatin"],
        "Vegan":       ["beef", "chicken", "pork", "bacon", "lamb", "turkey", "fish", "shrimp", "egg", "milk", "butter", "cheese", "cream", "honey", "yogurt"],
        "Pescatarian": ["beef", "chicken", "pork", "bacon", "lamb", "turkey"],
        "Gluten-free": ["flour", "wheat", "bread", "pasta", "barley", "rye", "soy sauce", "breadcrumb", "cracker"],
        "Dairy-free":  ["milk", "butter", "cheese", "cream", "yogurt", "ghee"],
    ]

    static func dietRestriction(_ diet: String, in ingredients: [String]) -> String? {
        guard let blocked = dietBlocks[diet] else { return nil }
        for line in ingredients {
            let l = line.lowercased()
            if blocked.contains(where: { l.contains($0) }) { return line }
        }
        return nil
    }
}

// MARK: - Store

@MainActor
@Observable
final class EventStore {
    static let shared = EventStore()
    /// Improvement #6 — file-backed, debounced, and migrated automatically from the old
    /// UserDefaults blob on first load. See FeatureStore.swift for why.
    private let store = FeatureStore<KitchenEvent>(key: FeatureStoreKeys.events)
    /// Re-entrancy guard for the sync stamping pass (see the didSet). Not observed.
    @ObservationIgnored private var _stamping = false

    var events: [KitchenEvent] = [] { didSet {
        store.save(events)
        // CRASH FIX (build 65): assign the stamped array once, guarded, so the
        // follow-up didSet is a no-op instead of recursing forever (see FeatureSync).
        guard !_stamping else { return }
        _stamping = true
        let _stamped = FeatureSync.shared.stampMutation(FeatureSync.Keys.events, old: oldValue, current: events)
        if _stamped != events { events = _stamped }
        _stamping = false
    } }

    private init() {
        _stamping = true
        events = store.load()
        _stamping = false
    }

    /// Push any pending write to disk immediately (call before backgrounding).
    func flush() { store.flush() }

    var upcoming: [KitchenEvent] { events.sorted { $0.date < $1.date } }

    func add(_ e: KitchenEvent) { events.append(e) }
    func update(_ e: KitchenEvent) {
        if let i = events.firstIndex(where: { $0.id == e.id }) { events[i] = e }
    }
    /// #5 — undoable: an event carries its whole menu and guest list with it.
    func remove(_ e: KitchenEvent) {
        events.removeAll { $0.id == e.id }
        ToastCenter.shared.undo("Deleted \(e.name)") { [weak self] in
            self?.events.append(e)
        }
    }
}

// MARK: - UI

struct EventPlannerView: View {
    @Environment(AppSession.self) private var session
    private let store = EventStore.shared
    @State private var showNew = false

    var body: some View {
        Group {
            if store.events.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "party.popper").font(.system(size: 34))
                        .foregroundStyle(session.themeTextColor.opacity(0.25))
                    Text("No events planned").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                    Text("Plan a dinner party or holiday meal — Stocked scales every dish to the headcount, checks it against your guests' allergies, and builds one shopping list.")
                        .font(.system(size: 13)).multilineTextAlignment(.center)
                        .foregroundStyle(session.themeTextColor.opacity(0.55)).padding(.horizontal, 36)
                    Button { showNew = true } label: {
                        Text("Plan an event").font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(session.accentColor).foregroundStyle(.white).clipShape(Capsule())
                    }.buttonStyle(.plain).padding(.top, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.upcoming) { e in
                        NavigationLink { EventDetailView(eventID: e.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(e.name).font(.system(size: 15, weight: .semibold))
                                Text("\(e.date.formatted(date: .abbreviated, time: .shortened)) · \(e.dishes.count) dishes")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in
                        let targets = idx.map { store.upcoming[$0] }
                        targets.forEach { store.remove($0) }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .stockedScreen()
        .navigationTitle("Events")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showNew = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showNew) { NewEventSheet() }
    }
}

private struct NewEventSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let store = EventStore.shared
    @State private var name = "Dinner party"
    @State private var date = Date().addingTimeInterval(86_400)

    var body: some View {
        NavigationStack {
            Form {
                TextField("Event name", text: $name)
                DatePicker("When", selection: $date)
            }
            .navigationTitle("New event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        store.add(KitchenEvent(name: name.trimmingCharacters(in: .whitespaces), date: date))
                        dismiss()
                    }.font(.body.bold()).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

struct EventDetailView: View {
    @Environment(AppSession.self) private var session
    private let store = EventStore.shared
    private let family = FamilyProfileStore.shared
    let eventID: UUID

    @State private var showAddDish = false
    @State private var guestName = ""

    private var event: KitchenEvent { store.events.first { $0.id == eventID } ?? KitchenEvent() }

    private var allGuests: [EventGuest] {
        var out = event.extraGuests
        if event.includeHousehold {
            out += family.profiles.filter(\.isPresent).map {
                EventGuest(name: $0.name, allergies: $0.allergies, diet: $0.diet)
            }
        }
        return out
    }
    private var headcount: Int { max(1, allGuests.count) }
    private var conflicts: [DishConflict] { EventMath.conflicts(dishes: event.dishes, guests: allGuests) }

    var body: some View {
        List {
            Section("Guests") {
                Toggle("Include my household", isOn: Binding(
                    get: { event.includeHousehold },
                    set: { var e = event; e.includeHousehold = $0; store.update(e) }))
                ForEach(allGuests) { g in
                    HStack {
                        Text(g.name)
                        Spacer()
                        if !g.allergies.isEmpty {
                            Text(g.allergies.joined(separator: ", "))
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        } else if g.diet != "None" {
                            Text(g.diet).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    TextField("Add a guest", text: $guestName)
                    Button("Add") {
                        var e = event
                        e.extraGuests.append(EventGuest(name: guestName.trimmingCharacters(in: .whitespaces)))
                        store.update(e); guestName = ""
                    }.disabled(guestName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Cooking for \(headcount)").font(.footnote).foregroundStyle(.secondary)
            }

            if !conflicts.isEmpty {
                Section {
                    ForEach(conflicts) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(c.guest) can't eat \(c.dish)")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.red)
                            Text("contains \(c.ingredient)").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label("Check before serving", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Menu") {
                ForEach(event.dishes) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.title).font(.system(size: 15, weight: .semibold))
                        Text("serves \(d.baseServings) → make ×\(String(format: "%.0f", EventMath.scale(dish: d, headcount: headcount)))")
                            .font(.system(size: 12)).foregroundStyle(session.accentColor)
                    }
                }
                .onDelete { idx in var e = event; e.dishes.remove(atOffsets: idx); store.update(e) }
                Button { showAddDish = true } label: { Label("Add a dish", systemImage: "plus") }
            }

            let list = EventMath.shoppingList(dishes: event.dishes, headcount: headcount)
            if !list.isEmpty {
                Section {
                    ForEach(list, id: \.self) { Text($0).font(.system(size: 14)) }
                    Button {
                        HapticManager.success()
                        for line in list { session.guestStore.addGroceryItem(name: line) }
                    } label: { Label("Add all to grocery list", systemImage: "cart.badge.plus") }
                } header: { Text("Shopping list (scaled)") }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stockedScreen()
        .navigationTitle(event.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddDish) {
            AddEventDishSheet { dish in var e = event; e.dishes.append(dish); store.update(e) }
        }
    }
}

private struct AddEventDishSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (EventDish) -> Void
    @State private var title = ""
    @State private var servings = 4
    @State private var ingredientsText = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Dish name", text: $title)
                Stepper("Recipe serves \(servings)", value: $servings, in: 1...50)
                Section {
                    TextField("One ingredient per line", text: $ingredientsText, axis: .vertical)
                        .lineLimit(4...14)
                } header: { Text("Ingredients") } footer: {
                    Text("These are checked against every guest's allergies and diet, and rolled into the scaled shopping list.")
                }
            }
            .navigationTitle("Add a dish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        let ing = ingredientsText.split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        onAdd(EventDish(title: title.trimmingCharacters(in: .whitespaces),
                                        baseServings: servings, ingredients: ing))
                        dismiss()
                    }.font(.body.bold()).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
