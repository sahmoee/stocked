// CostSplitting.swift — Feature 7: shared households, honest math.
//
// Roommates and couples who share a kitchen but not a bank account currently do this in a notes app
// or a spreadsheet. This records who paid, who it was for, and reduces the whole tangle to the
// smallest set of "A pays B $X" transfers — which is the only output anyone actually wants.

import SwiftUI

// MARK: - Model

nonisolated struct SharedExpense: Codable, Identifiable, Hashable, Sendable, HouseholdSyncable {
    // ── Household sync (launch readiness 1.4) ────────────────────────────────
    // Defaulted so entries saved before sync existed still decode. Same epoch-ms
    // last-write-wins convention as LocalInventoryItem.
    var updatedAt: Double = 0
    var lastWriterID: String = ""

    var id: UUID = UUID()
    var label: String
    var amount: Double
    var paidBy: String
    /// Who this was for. Empty means "everyone in the household".
    var sharedWith: [String] = []
    var date: Date = Date()
    var store: String = ""

    init(updatedAt: Double = 0, lastWriterID: String = "", id: UUID = UUID(), label: String,
         amount: Double, paidBy: String, sharedWith: [String] = [], date: Date = Date(), store: String = "") {
        self.updatedAt = updatedAt; self.lastWriterID = lastWriterID; self.id = id; self.label = label
        self.amount = amount; self.paidBy = paidBy; self.sharedWith = sharedWith; self.date = date; self.store = store
    }

    private enum CodingKeys: String, CodingKey {
        case updatedAt, lastWriterID, id, label, amount, paidBy, sharedWith, date, store
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        lastWriterID = try c.decodeIfPresent(String.self, forKey: .lastWriterID) ?? ""
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Expense"
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        paidBy = try c.decodeIfPresent(String.self, forKey: .paidBy) ?? ""
        sharedWith = try c.decodeIfPresent([String].self, forKey: .sharedWith) ?? []
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        store = try c.decodeIfPresent(String.self, forKey: .store) ?? ""
    }

    func participants(all: [String]) -> [String] {
        let list = sharedWith.isEmpty ? all : sharedWith
        return list.isEmpty ? [paidBy] : list
    }
    func share(all: [String]) -> Double {
        let p = participants(all: all)
        return p.isEmpty ? 0 : amount / Double(p.count)
    }
}

nonisolated struct Settlement: Identifiable, Sendable {
    var id: String { from + "->" + to }
    let from: String
    let to: String
    let amount: Double
}

// MARK: - Engine (pure)

nonisolated enum SplitMath {

    /// Net position per person: positive = they are owed, negative = they owe.
    static func balances(_ expenses: [SharedExpense], people: [String]) -> [String: Double] {
        var net: [String: Double] = [:]
        people.forEach { net[$0] = 0 }
        for e in expenses {
            net[e.paidBy, default: 0] += e.amount
            let share = e.share(all: people)
            for p in e.participants(all: people) { net[p, default: 0] -= share }
        }
        return net
    }

    /// Greedy settle-up: repeatedly match the biggest debtor to the biggest creditor.
    /// Produces at most (people − 1) transfers, which is the minimum in the general case.
    static func settlements(_ expenses: [SharedExpense], people: [String]) -> [Settlement] {
        var net = balances(expenses, people: people)
        var out: [Settlement] = []
        let epsilon = 0.01

        while true {
            guard let debtor = net.min(by: { $0.value < $1.value }),
                  let creditor = net.max(by: { $0.value < $1.value }),
                  debtor.value < -epsilon, creditor.value > epsilon else { break }
            let amount = min(-debtor.value, creditor.value)
            out.append(Settlement(from: debtor.key, to: creditor.key, amount: amount))
            net[debtor.key] = debtor.value + amount
            net[creditor.key] = creditor.value - amount
            if out.count > 64 { break }   // safety valve against float drift
        }
        return out
    }

    static func total(_ expenses: [SharedExpense]) -> Double { expenses.reduce(0) { $0 + $1.amount } }

    static func thisMonth(_ expenses: [SharedExpense]) -> [SharedExpense] {
        let cal = Calendar.current
        return expenses.filter { cal.isDate($0.date, equalTo: Date(), toGranularity: .month) }
    }
}

// MARK: - Store

@MainActor
@Observable
final class SplitStore {
    static let shared = SplitStore()
    /// Improvement #6 — the ledger is file-backed and debounced (it grows without bound, and a
    /// money record is the last thing that should live in a UserDefaults blob). The roster stays
    /// in UserDefaults: it's a handful of short strings and never grows.
    private let persistence = FeatureStore<SharedExpense>(key: FeatureStoreKeys.sharedExpenses)
    /// Re-entrancy guard for the sync stamping pass (see the didSet). Not observed.
    @ObservationIgnored private var _stamping = false
    private let peopleKey = "splitPeople_v1"

    var expenses: [SharedExpense] = [] { didSet {
        persistence.save(expenses)
        // CRASH FIX (build 65): assign the stamped array once, guarded, so the
        // follow-up didSet is a no-op instead of recursing forever (see FeatureSync).
        guard !_stamping else { return }
        _stamping = true
        let _stamped = FeatureSync.shared.stampMutation(FeatureSync.Keys.sharedExpenses, old: oldValue, current: expenses)
        if _stamped != expenses { expenses = _stamped }
        _stamping = false
    } }
    var people: [String] = [] { didSet { UserDefaults.standard.set(people, forKey: peopleKey) } }

    private init() {
        _stamping = true
        expenses = persistence.load()
        _stamping = false
        people = UserDefaults.standard.stringArray(forKey: peopleKey) ?? []
    }

    /// Push any pending write to disk immediately (call before backgrounding).
    func flush() { persistence.flush() }

    var recent: [SharedExpense] { expenses.sorted { $0.date > $1.date } }
    var settlements: [Settlement] { SplitMath.settlements(expenses, people: people) }

    func add(_ e: SharedExpense) { expenses.append(e) }
    /// #5 — every removal here is money data; all of them are undoable.
    func remove(_ e: SharedExpense) {
        expenses.removeAll { $0.id == e.id }
        ToastCenter.shared.undo("Removed \(e.label)") { [weak self] in
            self?.expenses.append(e)
        }
    }

    /// Clearing the ledger after everyone has paid up — the balances go back to zero.
    /// This wipes the entire history in one tap, so it is the single most destructive action in
    /// any of the new features and absolutely needs a way back.
    func settleUp() {
        let snapshot = expenses
        expenses.removeAll()
        ToastCenter.shared.undo("Ledger settled — \(snapshot.count) purchases cleared",
                                title: "Restore") { [weak self] in
            self?.expenses = snapshot
        }
    }

    /// Seed the roster from the family profiles so the user isn't typing names twice.
    func seedPeopleIfEmpty(from names: [String]) {
        guard people.isEmpty else { return }
        people = names.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

// MARK: - UI

struct CostSplittingView: View {
    @Environment(AppSession.self) private var session
    private let store = SplitStore.shared
    private let family = FamilyProfileStore.shared
    @State private var showAdd = false
    @State private var newPerson = ""

    private var monthTotal: Double { SplitMath.total(SplitMath.thisMonth(store.expenses)) }

    var body: some View {
        List {
            Section("Who's splitting") {
                ForEach(store.people, id: \.self) { Text($0) }
                    .onDelete { idx in store.people.remove(atOffsets: idx) }
                HStack {
                    TextField("Add a person", text: $newPerson)
                    Button("Add") {
                        store.people.append(newPerson.trimmingCharacters(in: .whitespaces)); newPerson = ""
                    }.disabled(newPerson.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if store.people.count >= 2 {
                Section {
                    if store.settlements.isEmpty {
                        Text("Everyone's square.").scaledFont(14).foregroundStyle(.green)
                    } else {
                        ForEach(store.settlements) { s in
                            HStack {
                                Text("\(s.from) pays \(s.to)")
                                    .scaledFont(14, weight: .medium)
                                Spacer()
                                Text(s.amount, format: .currency(code: currencyCode))
                                    .scaledFont(15, weight: .bold)
                                    .foregroundStyle(session.accentColor)
                            }
                        }
                        Button(role: .destructive) {
                            HapticManager.success(); store.settleUp()
                        } label: { Label("Mark all settled", systemImage: "checkmark.circle") }
                    }
                } header: { Text("Settle up") } footer: {
                    Text("The fewest transfers that clear every balance. Marking settled clears the ledger and starts fresh.")
                }
            }

            Section {
                if store.expenses.isEmpty {
                    Text("No shared purchases yet.").scaledFont(14).foregroundStyle(.secondary)
                } else {
                    ForEach(store.recent) { e in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(e.label).scaledFont(14, weight: .semibold)
                                Spacer()
                                Text(e.amount, format: .currency(code: currencyCode))
                                    .scaledFont(14, weight: .semibold)
                            }
                            Text("\(e.paidBy) paid · split \(e.sharedWith.isEmpty ? "evenly" : e.sharedWith.joined(separator: ", ")) · \(e.date.formatted(date: .abbreviated, time: .omitted))")
                                .scaledFont(11).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in idx.map { store.recent[$0] }.forEach { store.remove($0) } }
                }
            } header: {
                HStack {
                    Text("Purchases")
                    Spacer()
                    Text("this month \(monthTotal.formatted(.currency(code: currencyCode)))")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stockedScreen()
        .navigationTitle("Shared Costs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showAdd) { AddSharedExpenseSheet() }
        .onAppear { store.seedPeopleIfEmpty(from: family.profiles.map(\.name)) }
    }

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }
}

private struct AddSharedExpenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let store = SplitStore.shared
    @State private var label = ""
    @State private var amount = ""
    @State private var paidBy = ""
    @State private var splitWith: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                TextField("What was it? (e.g. Costco run)", text: $label)
                TextField("Amount", text: $amount).keyboardType(.decimalPad)
                Picker("Paid by", selection: $paidBy) {
                    ForEach(store.people, id: \.self) { Text($0).tag($0) }
                }
                Section {
                    ForEach(store.people, id: \.self) { p in
                        Button {
                            if splitWith.contains(p) { splitWith.remove(p) } else { splitWith.insert(p) }
                        } label: {
                            HStack {
                                Text(p).foregroundStyle(.primary)
                                Spacer()
                                if splitWith.contains(p) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                } header: { Text("Split between") } footer: {
                    Text(splitWith.isEmpty ? "Nobody selected — this will split evenly across everyone."
                                           : "Split \(splitWith.count) ways.")
                }
            }
            .navigationTitle("Add purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        store.add(SharedExpense(label: label.trimmingCharacters(in: .whitespaces),
                                                amount: Double(amount) ?? 0,
                                                paidBy: paidBy.isEmpty ? (store.people.first ?? "Me") : paidBy,
                                                sharedWith: splitWith.count == store.people.count ? [] : Array(splitWith)))
                        dismiss()
                    }
                    .font(.stocked(.body).bold())
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || (Double(amount) ?? 0) <= 0)
                }
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
            .onAppear { if paidBy.isEmpty { paidBy = store.people.first ?? "" } }
        }
        .stockedPresentationSurface(width: .form)
    }
}
