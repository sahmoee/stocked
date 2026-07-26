// PreservationPlanner.swift — Feature 9: the answer to "I bought too much of this."
//
// Bulk buying and garden gluts both end the same way: something good goes off before it's eaten.
// This looks at what's actually about to expire, and gives the concrete preservation move — with
// how much shelf life it buys you and the real steps.
//
// Everything here is offline reference data; no network, no AI guess.

import SwiftUI

// MARK: - Reference data

nonisolated struct PreservationMethod: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    /// Days of shelf life this buys, replacing the current expiry.
    let daysGained: Int
    let effort: String          // "5 min" etc — the honest cost
    let steps: [String]
    let note: String

    var readableGain: String {
        if daysGained >= 365 { return "about a year" }
        if daysGained >= 30 { return "about \(daysGained / 30) month\(daysGained / 30 == 1 ? "" : "s")" }
        return "about \(daysGained) days"
    }
}

nonisolated enum PreservationGuide {

    static let freeze = PreservationMethod(
        name: "Freeze", daysGained: 180, effort: "10 min",
        steps: ["Portion into meal-sized amounts", "Press out the air and seal flat",
                "Label with the item and today's date", "Freeze flat, then stack once solid"],
        note: "Best all-purpose move. Texture softens on thaw, so plan it for cooked dishes rather than salads.")

    static let blanchFreeze = PreservationMethod(
        name: "Blanch and freeze", daysGained: 300, effort: "20 min",
        steps: ["Boil 2–3 minutes", "Plunge into ice water to stop cooking", "Drain and dry well",
                "Freeze on a tray, then bag"],
        note: "The blanch step kills the enzymes that turn frozen vegetables grey and bitter. Skipping it is why frozen home vegetables often disappoint.")

    static let quickPickle = PreservationMethod(
        name: "Quick pickle", daysGained: 30, effort: "15 min",
        steps: ["Slice thin", "Heat 1:1 vinegar and water with 1 tbsp salt and 1 tbsp sugar per cup",
                "Pour hot brine over, cool", "Refrigerate — ready in 24 hours"],
        note: "Fridge pickles only. This is not shelf-stable canning and shouldn't be stored at room temperature.")

    static let dehydrate = PreservationMethod(
        name: "Dry", daysGained: 365, effort: "6+ hrs, mostly waiting",
        steps: ["Slice evenly, about 1/4 inch", "Dry at 135°F until leathery and brittle",
                "Cool completely", "Store airtight, away from light"],
        note: "Any trapped moisture invites mould. If pieces feel cool and pliable, dry them longer.")

    static let cookAndFreeze = PreservationMethod(
        name: "Cook, then freeze", daysGained: 120, effort: "30 min",
        steps: ["Cook it into a sauce, soup or braise", "Cool fast — shallow container, not the pot",
                "Portion and freeze"],
        note: "Turns a rescue job into a future dinner. Usually beats freezing the raw ingredient.")

    static let butter = PreservationMethod(
        name: "Herb butter or oil cubes", daysGained: 180, effort: "10 min",
        steps: ["Chop fine", "Pack into an ice cube tray", "Top with olive oil or softened butter",
                "Freeze, then bag the cubes"],
        note: "Drop a cube straight into a hot pan. Far better than watching herbs blacken in the fridge.")

    static let refrigerate = PreservationMethod(
        name: "Move to the fridge", daysGained: 14, effort: "1 min",
        steps: ["Move it out of the pantry", "Keep it dry and covered"],
        note: "Smallest possible intervention. Sometimes it's enough.")

    /// Best moves for an item, most useful first.
    static func methods(for name: String) -> [PreservationMethod] {
        let n = name.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }

        if has(["basil", "cilantro", "parsley", "mint", "thyme", "rosemary", "sage", "dill", "herb"]) {
            return [butter, dehydrate, freeze]
        }
        if has(["cucumber", "radish", "onion", "cabbage", "carrot", "jalapeno", "pepper", "beet"]) {
            return [quickPickle, blanchFreeze, freeze]
        }
        if has(["broccoli", "green bean", "pea", "corn", "spinach", "kale", "asparagus", "brussels", "zucchini", "squash"]) {
            return [blanchFreeze, cookAndFreeze, freeze]
        }
        if has(["tomato", "mushroom", "eggplant"]) {
            return [cookAndFreeze, dehydrate, freeze]
        }
        if has(["banana", "berry", "strawberry", "blueberry", "peach", "mango", "grape", "cherry"]) {
            return [freeze, dehydrate]
        }
        if has(["apple", "pear", "plum"]) {
            return [cookAndFreeze, dehydrate, refrigerate]
        }
        if has(["chicken", "beef", "pork", "turkey", "fish", "shrimp", "meat", "sausage", "bacon"]) {
            return [freeze, cookAndFreeze]
        }
        if has(["milk", "cream", "yogurt", "cheese"]) {
            return [freeze, cookAndFreeze]
        }
        if has(["bread", "bagel", "tortilla", "roll"]) {
            return [freeze, dehydrate]
        }
        if has(["rice", "flour", "sugar", "pasta", "bean", "oat", "cereal"]) {
            return [refrigerate, freeze]
        }
        return [freeze, cookAndFreeze, refrigerate]
    }

    /// Rough per-unit value saved — used to make the case for spending 10 minutes on it.
    static func valueSaved(_ item: LocalInventoryItem) -> Double? {
        guard let price = item.price, price > 0 else { return nil }
        return price * Double(max(1, item.quantity))
    }
}

// MARK: - UI

struct PreservationPlannerView: View {
    @Environment(AppSession.self) private var session
    @State private var horizon = 7

    /// Items with a real expiry inside the window, soonest first.
    /// Improvement #9 — `expiring(within:)` walks a presorted index and stops early, instead of
    /// filtering and re-sorting the entire pantry on every render.
    private var atRisk: [LocalInventoryItem] {
        InventoryIndex.shared
            .expiring(within: horizon)
            .filter { $0.storageCategory != .freezer }
    }

    private var totalAtRisk: Double {
        atRisk.compactMap { PreservationGuide.valueSaved($0) }.reduce(0, +)
    }

    var body: some View {
        Group {
            if atRisk.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "archivebox").font(.system(size: 34))
                        .foregroundStyle(session.themeTextColor.opacity(0.25))
                    Text("Nothing at risk").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                    Text("When something is about to turn, it shows up here with the specific way to save it — freeze, blanch, pickle, dry — and how much time that buys.")
                        .font(.system(size: 13)).multilineTextAlignment(.center)
                        .foregroundStyle(session.themeTextColor.opacity(0.55)).padding(.horizontal, 36)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        Picker("Window", selection: $horizon) {
                            Text("3 days").tag(3); Text("1 week").tag(7); Text("2 weeks").tag(14)
                        }.pickerStyle(.segmented)
                        if totalAtRisk > 0 {
                            HStack {
                                Text("At risk")
                                Spacer()
                                Text(totalAtRisk, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.orange)
                            }
                        }
                    }
                    ForEach(atRisk, id: \.id) { item in
                        Section {
                            ForEach(PreservationGuide.methods(for: item.name).prefix(2)) { m in
                                NavigationLink {
                                    PreservationDetailView(itemName: item.name, method: m)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(m.name).font(.system(size: 14, weight: .semibold))
                                            Spacer()
                                            Text("+\(m.readableGain)").font(.system(size: 12, weight: .bold))
                                                .foregroundStyle(session.accentColor)
                                        }
                                        Text(m.effort).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(item.name)
                                Spacer()
                                Text(expiryLabel(item)).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .stockedScreen()
        .navigationTitle("Save It")
        .navigationBarTitleDisplayMode(.inline)
        .withInventoryIndex(session.guestStore)
    }

    private func expiryLabel(_ item: LocalInventoryItem) -> String {
        guard let exp = item.expirationDate else { return "" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? 0
        if days < 0 { return "past date" }
        if days == 0 { return "today" }
        return "\(days)d"
    }
}

struct PreservationDetailView: View {
    @Environment(AppSession.self) private var session
    let itemName: String
    let method: PreservationMethod

    var body: some View {
        List {
            Section {
                Text("\(method.name) \(itemName.lowercased())")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(session.themeTextColor)
                HStack {
                    Label(method.readableGain, systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Label(method.effort, systemImage: "hourglass")
                }
                .font(.system(size: 12)).foregroundStyle(session.accentColor)
            }
            Section("Steps") {
                ForEach(Array(method.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1)").font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(session.accentColor).frame(width: 18, alignment: .leading)
                        Text(step).font(.system(size: 14))
                    }
                }
            }
            Section("Worth knowing") { Text(method.note).font(.system(size: 13)) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stockedScreen()
        .navigationTitle(method.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
