// EmergencyPantry.swift — Feature 10: how many days could you actually eat without shopping?
//
// This is a question almost nobody can answer about their own kitchen, and Stocked already has the
// data to answer it. Counts shelf-stable calories and water against household size, flags the gaps,
// and — the part most preparedness advice misses — nudges you to ROTATE stock before it expires,
// so the emergency supply isn't quietly worthless when you need it.

import SwiftUI

// MARK: - Model

nonisolated struct ReadinessResult: Sendable {
    let daysOfFood: Double
    let daysOfWater: Double
    let totalCalories: Double
    let waterLiters: Double
    let people: Int
    let expiringSoon: [String]
    let missingStaples: [String]

    var days: Double { min(daysOfFood, daysOfWater) }

    var rating: String {
        switch days {
        case ..<1:  return "Under a day"
        case ..<3:  return "1–3 days"
        case ..<7:  return "About a week"
        case ..<14: return "1–2 weeks"
        default:    return "Two weeks or more"
        }
    }
    var ratingColor: Color {
        switch days {
        case ..<3:  return .red
        case ..<7:  return .orange
        case ..<14: return .yellow
        default:    return .green
        }
    }
}

// MARK: - Engine (pure)

nonisolated enum ReadinessCalculator {

    /// Calories per person per day. FEMA-style planning uses ~2,000; we use 1,800 as the survival
    /// baseline so the estimate isn't falsely pessimistic.
    static let caloriesPerPersonPerDay: Double = 1800
    /// Litres of drinking + basic sanitation water per person per day (~1 gallon).
    static let litersPerPersonPerDay: Double = 3.8

    /// Rough calorie density per unit for shelf-stable staples. Deliberately conservative — this is a
    /// planning number, not a nutrition label.
    static let calorieTable: [(match: String, kcalPerUnit: Double)] = [
        ("rice", 1600), ("bean", 1200), ("lentil", 1300), ("pasta", 1600), ("flour", 1600),
        ("oat", 1500), ("cereal", 1100), ("sugar", 1900), ("oil", 4000), ("peanut butter", 2800),
        ("nut", 2600), ("canned", 400), ("soup", 300), ("tuna", 200), ("chicken", 400),
        ("bar", 250), ("cracker", 500), ("jerky", 400), ("honey", 1300), ("powdered milk", 1500),
        ("tortilla", 900), ("bread", 1200), ("corn", 400), ("tomato", 200), ("sauce", 300),
    ]

    static func calories(for item: LocalInventoryItem) -> Double {
        let n = item.name.lowercased()
        let qty = Double(max(1, item.quantity))
        if let hit = calorieTable.first(where: { n.contains($0.match) }) {
            return hit.kcalPerUnit * qty
        }
        // Unknown shelf-stable item — assume a modest 300 kcal so it counts for something.
        return 300 * qty
    }

    static func isShelfStable(_ item: LocalInventoryItem) -> Bool {
        item.storageCategory == .pantry || item.storageCategory == .staples
    }

    static func waterLiters(in items: [LocalInventoryItem]) -> Double {
        items.filter { $0.name.lowercased().contains("water") }.reduce(0) { sum, item in
            let qty = Double(max(1, item.quantity))
            if let amount = item.sizeAmount, let unit = item.sizeUnit?.lowercased() {
                if unit.contains("gal") { return sum + amount * 3.785 * qty }
                if unit.contains("ml") { return sum + (amount / 1000) * qty }
                if unit.contains("oz") { return sum + (amount * 0.0296) * qty }
                if unit == "l" || unit.contains("liter") || unit.contains("litre") { return sum + amount * qty }
            }
            return sum + 1.0 * qty   // assume a 1 L bottle
        }
    }

    static let recommendedStaples = [
        "Water", "Rice or pasta", "Canned beans", "Canned protein", "Peanut butter",
        "Cooking oil", "Salt", "Shelf-stable milk", "Manual can opener",
    ]

    static func missing(from items: [LocalInventoryItem]) -> [String] {
        let names = items.map { $0.name.lowercased() }
        return recommendedStaples.filter { staple in
            let words = staple.lowercased().split(separator: " ").map(String.init)
                .filter { $0 != "or" && $0.count > 2 }
            return !words.contains { w in names.contains { $0.contains(w) } }
        }
    }

    static func assess(items: [LocalInventoryItem], people: Int) -> ReadinessResult {
        let heads = max(1, people)
        let stable = items.filter(isShelfStable)
        let kcal = stable.reduce(0) { $0 + calories(for: $1) }
        let water = waterLiters(in: items)

        let cutoff = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
        let expiring = stable
            .filter { ($0.expirationDate ?? .distantFuture) <= cutoff }
            .sorted { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }
            .map(\.name)

        return ReadinessResult(
            daysOfFood: kcal / (caloriesPerPersonPerDay * Double(heads)),
            daysOfWater: water / (litersPerPersonPerDay * Double(heads)),
            totalCalories: kcal,
            waterLiters: water,
            people: heads,
            expiringSoon: Array(expiring.prefix(8)),
            missingStaples: missing(from: items))
    }
}

// MARK: - UI

struct EmergencyPantryView: View {
    @Environment(AppSession.self) private var session
    private let family = FamilyProfileStore.shared
    @State private var overridePeople: Int?

    private var people: Int {
        overridePeople ?? max(1, family.profiles.filter(\.isPresent).count)
    }
    private var result: ReadinessResult {
        ReadinessCalculator.assess(items: session.guestStore.inventoryItems, people: people)
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Text(result.rating)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(result.ratingColor)
                    Text("of food and water for \(people) \(people == 1 ? "person" : "people")")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                Stepper("Planning for \(people) \(people == 1 ? "person" : "people")",
                        value: Binding(get: { people }, set: { overridePeople = $0 }), in: 1...20)
            } footer: {
                Text("Based on \(Int(ReadinessCalculator.caloriesPerPersonPerDay)) calories and about a gallon of water per person per day — the standard planning figures.")
            }

            Section("The numbers") {
                row("Shelf-stable food", String(format: "%.1f days", result.daysOfFood),
                    color: result.daysOfFood < 3 ? .red : .primary)
                row("Stored water", String(format: "%.1f days", result.daysOfWater),
                    color: result.daysOfWater < 3 ? .red : .primary)
                row("Total calories on hand", "\(Int(result.totalCalories).formatted())")
                row("Water", String(format: "%.1f L", result.waterLiters))
            }

            if !result.missingStaples.isEmpty {
                Section {
                    ForEach(result.missingStaples, id: \.self) { staple in
                        HStack {
                            Text(staple)
                            Spacer()
                            Button("Add") {
                                HapticManager.light()
                                session.guestStore.addGroceryItem(name: staple)
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .buttonStyle(.borderless)
                        }
                    }
                } header: { Text("Gaps") } footer: {
                    Text("A manual can opener is the one people always forget — an electric one is useless in an outage.")
                }
            }

            if !result.expiringSoon.isEmpty {
                Section {
                    ForEach(result.expiringSoon, id: \.self) { Text($0).font(.system(size: 14)) }
                } header: { Text("Rotate these") } footer: {
                    Text("Emergency supplies fail quietly — they expire while you're not looking. Eat these now and replace them, so the shelf stays live.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stockedScreen()
        .navigationTitle("Readiness")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label).font(.system(size: 14))
            Spacer()
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
        }
    }
}
