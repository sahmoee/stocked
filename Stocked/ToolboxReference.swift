// ToolboxReference.swift — Reference tools for the Kitchen Toolbox.
// Seasonal Produce • Storage Tips • Shelf Life Lookup • Pantry Snapshot
import SwiftUI

// MARK: - Seasonal Produce

struct SeasonalProduceView: View {
    @Environment(AppSession.self) private var session
    @State private var month = Calendar.current.component(.month, from: Date())

    // US-seasonal produce by month (1–12). Compact and static — no allocation churn.
    private static let byMonth: [Int: [String]] = [
        1:  ["Oranges", "Grapefruit", "Kale", "Brussels sprouts", "Cabbage", "Leeks", "Sweet potatoes", "Turnips"],
        2:  ["Oranges", "Grapefruit", "Kale", "Cauliflower", "Broccoli", "Carrots", "Beets", "Lemons"],
        3:  ["Asparagus", "Artichokes", "Spinach", "Peas", "Radishes", "Spring onions", "Strawberries", "Lettuce"],
        4:  ["Asparagus", "Artichokes", "Peas", "Radishes", "Rhubarb", "Spinach", "Strawberries", "Spring greens"],
        5:  ["Strawberries", "Asparagus", "Peas", "Rhubarb", "Cherries", "Apricots", "Lettuce", "New potatoes"],
        6:  ["Cherries", "Strawberries", "Blueberries", "Zucchini", "Tomatoes", "Corn", "Peaches", "Green beans"],
        7:  ["Tomatoes", "Corn", "Peaches", "Blueberries", "Blackberries", "Zucchini", "Cucumbers", "Melons", "Bell peppers"],
        8:  ["Tomatoes", "Corn", "Peaches", "Melons", "Eggplant", "Okra", "Figs", "Plums", "Bell peppers"],
        9:  ["Apples", "Pears", "Grapes", "Tomatoes", "Winter squash", "Pumpkins", "Figs", "Sweet potatoes"],
        10: ["Apples", "Pears", "Pumpkins", "Winter squash", "Cranberries", "Brussels sprouts", "Cauliflower", "Sweet potatoes"],
        11: ["Cranberries", "Pumpkins", "Winter squash", "Brussels sprouts", "Sweet potatoes", "Pears", "Pomegranates", "Kale"],
        12: ["Oranges", "Grapefruit", "Pomegranates", "Kale", "Brussels sprouts", "Winter squash", "Sweet potatoes", "Pears"],
    ]

    private static let monthNames = Calendar.current.monthSymbols

    private var inStockNames: Set<String> {
        Set(session.guestStore.inventoryItems.map { $0.name.lowercased() })
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ToolboxCard {
                    HStack {
                        Text("Month")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(session.themeSecondaryText)
                        Spacer()
                        Picker("Month", selection: $month) {
                            ForEach(1...12, id: \.self) { m in
                                Text(Self.monthNames[m - 1]).tag(m)
                            }
                        }
                        .tint(session.accentColor)
                        .onChange(of: month) { _, _ in HapticManager.select() }
                    }
                }
                ToolboxSectionLabel(text: "In season in \(Self.monthNames[month - 1])")
                let stocked = inStockNames
                ForEach(Self.byMonth[month] ?? [], id: \.self) { produce in
                    let have = stocked.contains { $0.contains(produce.lowercased()) || produce.lowercased().contains($0) }
                    ToolboxCard {
                        HStack {
                            Text("🥬 \(produce)")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(session.themeTextColor)
                            Spacer()
                            if have {
                                Label("In your kitchen", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.green)
                            } else {
                                Button {
                                    session.guestStore.addToGroceryIfMissing(produce, recommended: true)
                                    HapticManager.success()
                                    ToastCenter.shared.success("Added \(produce) to grocery list")
                                } label: {
                                    Image(systemName: "cart.badge.plus")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(session.accentColor)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Add \(produce) to grocery list")
                            }
                        }
                    }
                }
                Text("In-season produce is usually cheaper, fresher, and lasts longer at home.")
                    .font(.system(size: 12))
                    .foregroundStyle(session.themeSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Seasonal Produce")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Storage Tips

private struct StorageTip: Identifiable {
    var id: String { food }
    let food: String
    let where_: String
    let tip: String
}

struct StorageTipsView: View {
    @Environment(AppSession.self) private var session
    @State private var search = ""

    private static let tips: [StorageTip] = [
        StorageTip(food: "Tomatoes", where_: "Counter", tip: "Never refrigerate — the cold turns them mealy and kills flavor. Stem side down on the counter."),
        StorageTip(food: "Potatoes", where_: "Pantry", tip: "Cool, dark, and dry. Keep away from onions — together they both spoil faster."),
        StorageTip(food: "Onions", where_: "Pantry", tip: "Cool and dry with airflow. Once cut, refrigerate in a sealed container."),
        StorageTip(food: "Bananas", where_: "Counter", tip: "Separate from other fruit — they release ethylene that ripens everything nearby. Wrap stems to slow ripening."),
        StorageTip(food: "Bread", where_: "Counter / Freezer", tip: "Counter for a few days, freezer for longer. The fridge actually stales bread faster."),
        StorageTip(food: "Berries", where_: "Fridge", tip: "Don't wash until you eat them — moisture speeds mold. A quick vinegar rinse then a thorough dry extends life."),
        StorageTip(food: "Herbs (soft)", where_: "Fridge", tip: "Cilantro, parsley: trim stems, stand in a jar of water like flowers, loosely cover with a bag."),
        StorageTip(food: "Herbs (woody)", where_: "Fridge", tip: "Rosemary, thyme: wrap in a barely-damp paper towel inside a bag in the crisper."),
        StorageTip(food: "Lettuce & greens", where_: "Fridge", tip: "Wash, dry very well, store with a paper towel to absorb moisture."),
        StorageTip(food: "Avocados", where_: "Counter → Fridge", tip: "Ripen on the counter, then refrigerate to hold them at peak for several extra days."),
        StorageTip(food: "Apples", where_: "Fridge", tip: "Crisper drawer — they last weeks refrigerated versus days on the counter."),
        StorageTip(food: "Citrus", where_: "Fridge", tip: "Fine on the counter for a week; the crisper drawer roughly doubles that."),
        StorageTip(food: "Garlic", where_: "Pantry", tip: "Whole heads in a cool, dark, airy spot. Refrigeration makes it sprout."),
        StorageTip(food: "Mushrooms", where_: "Fridge", tip: "Paper bag, not plastic — they need to breathe or they slime."),
        StorageTip(food: "Cheese", where_: "Fridge", tip: "Wrap in parchment or wax paper, then loosely in plastic. Airtight plastic alone suffocates it."),
        StorageTip(food: "Eggs", where_: "Fridge", tip: "In their carton, on a shelf — not the door, where temperature swings most."),
        StorageTip(food: "Milk", where_: "Fridge", tip: "Back of the fridge where it's coldest, never the door."),
        StorageTip(food: "Butter", where_: "Fridge / Counter", tip: "A few days in a covered dish on the counter is fine for spreading; the rest stays refrigerated."),
        StorageTip(food: "Coffee", where_: "Pantry", tip: "Airtight, opaque, room temperature. The fridge introduces moisture and odors."),
        StorageTip(food: "Olive oil", where_: "Pantry", tip: "Cool and dark, away from the stove — heat and light turn it rancid."),
        StorageTip(food: "Honey", where_: "Pantry", tip: "Room temperature forever. If it crystallizes, warm the jar in water — never refrigerate."),
        StorageTip(food: "Nuts", where_: "Freezer", tip: "Their oils go rancid at room temperature within months. Freezer keeps them fresh for a year."),
        StorageTip(food: "Flour", where_: "Pantry / Freezer", tip: "Airtight container. Whole-grain flours belong in the freezer — their oils spoil."),
        StorageTip(food: "Brown sugar", where_: "Pantry", tip: "Airtight with a slice of bread or a terracotta disk to keep it soft."),
        StorageTip(food: "Ginger", where_: "Freezer", tip: "Freeze it whole and grate from frozen — no peeling needed and it never goes bad on you."),
        StorageTip(food: "Celery", where_: "Fridge", tip: "Wrap in foil, not plastic — it stays crisp for weeks."),
        StorageTip(food: "Carrots", where_: "Fridge", tip: "Remove the green tops (they pull moisture out), store in the crisper."),
        StorageTip(food: "Cucumbers", where_: "Fridge front", tip: "They dislike deep cold — the warmer front of the fridge, wrapped to hold moisture."),
        StorageTip(food: "Peppers", where_: "Fridge", tip: "Whole and dry in the crisper. Cut peppers go in a sealed container with a paper towel."),
        StorageTip(food: "Meat (raw)", where_: "Fridge bottom", tip: "Bottom shelf, coldest spot, so drips can't touch anything below. Freeze if not cooking within 2 days."),
        StorageTip(food: "Fish (raw)", where_: "Fridge bottom", tip: "Coldest shelf, on ice if possible, and cook within a day of buying."),
        StorageTip(food: "Rice (cooked)", where_: "Fridge", tip: "Cool it quickly and refrigerate within an hour; eat within 3–4 days."),
        StorageTip(food: "Leftovers", where_: "Fridge", tip: "Shallow containers cool faster and safer. Label with the date — 3–4 days is the rule."),
    ]

    private var filtered: [StorageTip] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Self.tips }
        return Self.tips.filter { FuzzyMatch.matches(q, $0.food) || $0.tip.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if filtered.isEmpty {
                    ToolboxEmptyState(icon: "snowflake", title: "No matches",
                                      message: "No storage tips match that search.")
                }
                ForEach(filtered) { tip in
                    ToolboxCard {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(tip.food)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(session.themeTextColor)
                                Spacer()
                                Text(tip.where_)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(session.accentColor)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(session.accentColor.opacity(0.14)))
                            }
                            Text(tip.tip)
                                .font(.system(size: 13))
                                .foregroundStyle(session.themeSecondaryText)
                        }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Storage Tips")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search a food")
    }
}

// MARK: - Shelf Life Lookup

private struct ShelfLifeEntry: Identifiable {
    var id: String { food }
    let food: String
    let pantryDays: Int?
    let fridgeDays: Int?
    let freezerDays: Int?
}

struct ShelfLifeLookupView: View {
    @Environment(AppSession.self) private var session
    @State private var search = ""

    private static let entries: [ShelfLifeEntry] = [
        ShelfLifeEntry(food: "Milk (opened)",        pantryDays: nil, fridgeDays: 7,   freezerDays: 90),
        ShelfLifeEntry(food: "Eggs",                 pantryDays: nil, fridgeDays: 35,  freezerDays: nil),
        ShelfLifeEntry(food: "Butter",               pantryDays: 2,   fridgeDays: 90,  freezerDays: 270),
        ShelfLifeEntry(food: "Hard cheese",          pantryDays: nil, fridgeDays: 42,  freezerDays: 180),
        ShelfLifeEntry(food: "Soft cheese",          pantryDays: nil, fridgeDays: 14,  freezerDays: nil),
        ShelfLifeEntry(food: "Yogurt",               pantryDays: nil, fridgeDays: 14,  freezerDays: 60),
        ShelfLifeEntry(food: "Chicken (raw)",        pantryDays: nil, fridgeDays: 2,   freezerDays: 270),
        ShelfLifeEntry(food: "Ground beef (raw)",    pantryDays: nil, fridgeDays: 2,   freezerDays: 120),
        ShelfLifeEntry(food: "Steak (raw)",          pantryDays: nil, fridgeDays: 4,   freezerDays: 270),
        ShelfLifeEntry(food: "Pork (raw)",           pantryDays: nil, fridgeDays: 4,   freezerDays: 180),
        ShelfLifeEntry(food: "Fish (raw)",           pantryDays: nil, fridgeDays: 1,   freezerDays: 180),
        ShelfLifeEntry(food: "Bacon (opened)",       pantryDays: nil, fridgeDays: 7,   freezerDays: 30),
        ShelfLifeEntry(food: "Deli meat (opened)",   pantryDays: nil, fridgeDays: 4,   freezerDays: 60),
        ShelfLifeEntry(food: "Cooked leftovers",     pantryDays: nil, fridgeDays: 4,   freezerDays: 90),
        ShelfLifeEntry(food: "Bread",                pantryDays: 5,   fridgeDays: nil, freezerDays: 90),
        ShelfLifeEntry(food: "Tortillas",            pantryDays: 7,   fridgeDays: 30,  freezerDays: 180),
        ShelfLifeEntry(food: "Apples",               pantryDays: 7,   fridgeDays: 42,  freezerDays: nil),
        ShelfLifeEntry(food: "Bananas",              pantryDays: 5,   fridgeDays: nil, freezerDays: 60),
        ShelfLifeEntry(food: "Berries",              pantryDays: 1,   fridgeDays: 5,   freezerDays: 270),
        ShelfLifeEntry(food: "Lettuce",              pantryDays: nil, fridgeDays: 7,   freezerDays: nil),
        ShelfLifeEntry(food: "Tomatoes",             pantryDays: 5,   fridgeDays: 10,  freezerDays: nil),
        ShelfLifeEntry(food: "Potatoes",             pantryDays: 30,  fridgeDays: nil, freezerDays: nil),
        ShelfLifeEntry(food: "Onions",               pantryDays: 40,  fridgeDays: nil, freezerDays: nil),
        ShelfLifeEntry(food: "Garlic",               pantryDays: 120, fridgeDays: nil, freezerDays: nil),
        ShelfLifeEntry(food: "Carrots",              pantryDays: nil, fridgeDays: 28,  freezerDays: 270),
        ShelfLifeEntry(food: "Rice (dry)",           pantryDays: 720, fridgeDays: nil, freezerDays: nil),
        ShelfLifeEntry(food: "Pasta (dry)",          pantryDays: 720, fridgeDays: nil, freezerDays: nil),
        ShelfLifeEntry(food: "Canned goods",         pantryDays: 720, fridgeDays: nil, freezerDays: nil),
        ShelfLifeEntry(food: "Peanut butter (opened)", pantryDays: 90, fridgeDays: 180, freezerDays: nil),
        ShelfLifeEntry(food: "Ketchup (opened)",     pantryDays: 30,  fridgeDays: 180, freezerDays: nil),
        ShelfLifeEntry(food: "Salsa (opened)",       pantryDays: nil, fridgeDays: 14,  freezerDays: nil),
        ShelfLifeEntry(food: "Orange juice (opened)", pantryDays: nil, fridgeDays: 8,  freezerDays: nil),
    ]

    private var filtered: [ShelfLifeEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Self.entries }
        return Self.entries.filter { FuzzyMatch.matches(q, $0.food) }
    }

    private func days(_ value: Int?) -> String {
        guard let value else { return "—" }
        if value >= 60 { return "\(value / 30) mo" }
        if value >= 14 { return "\(value / 7) wk" }
        return "\(value) d"
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // Column key
                HStack {
                    Spacer()
                    ForEach(["🏺 Pantry", "❄️ Fridge", "🧊 Freezer"], id: \.self) { label in
                        Text(label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(session.themeSecondaryText)
                            .frame(width: 62)
                    }
                }
                if filtered.isEmpty {
                    ToolboxEmptyState(icon: "hourglass", title: "No matches",
                                      message: "No shelf-life entries match that search.")
                }
                ForEach(filtered) { entry in
                    ToolboxCard {
                        HStack {
                            Text(entry.food)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(session.themeTextColor)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach([entry.pantryDays, entry.fridgeDays, entry.freezerDays].indices, id: \.self) { i in
                                Text(days([entry.pantryDays, entry.fridgeDays, entry.freezerDays][i]))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(session.accentColor)
                                    .frame(width: 62)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(entry.food): pantry \(days(entry.pantryDays)), fridge \(days(entry.fridgeDays)), freezer \(days(entry.freezerDays))")
                    }
                }
                Text("Typical times for quality and safety — always trust your eyes and nose first.")
                    .font(.system(size: 12))
                    .foregroundStyle(session.themeSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Shelf Life")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search a food")
    }
}

// MARK: - Pantry Snapshot

struct PantrySnapshotView: View {
    @Environment(AppSession.self) private var session
    @State private var snapshotText = ""

    private func build() {
        let items = session.guestStore.inventoryItems
        guard !items.isEmpty else { snapshotText = ""; return }
        var lines: [String] = ["My kitchen (\(items.count) items) — from Stocked", ""]
        for zone in StorageCategory.allCases {
            let zoneItems = items.filter { $0.storageCategory == zone }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !zoneItems.isEmpty else { continue }
            lines.append("\(zone.icon) \(zone.displayName.uppercased())")
            for item in zoneItems {
                var line = "• \(item.name) — \(item.displayText)"
                if let days = item.daysUntilExpiry {
                    line += days < 0 ? " (expired)" : " (expires in \(days)d)"
                }
                lines.append(line)
            }
            lines.append("")
        }
        snapshotText = lines.joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if snapshotText.isEmpty {
                    ToolboxEmptyState(icon: "square.and.arrow.up",
                                      title: "Nothing to snapshot",
                                      message: "Add items to your inventory and this tool will turn it into a shareable text list.")
                } else {
                    ShareLink(item: snapshotText) {
                        Label("Share snapshot", systemImage: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 14).fill(session.accentColor))
                            .foregroundStyle(.white)
                    }
                    .simultaneousGesture(TapGesture().onEnded { HapticManager.light() })
                    Button {
                        UIPasteboard.general.string = snapshotText
                        HapticManager.success()
                        ToastCenter.shared.success("Copied to clipboard")
                    } label: {
                        Label("Copy to clipboard", systemImage: "doc.on.doc")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 14).fill(session.accentColor.opacity(0.14)))
                            .foregroundStyle(session.accentColor)
                    }
                    .buttonStyle(.plain)
                    ToolboxCard {
                        Text(snapshotText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(session.themeSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Pantry Snapshot")
        .navigationBarTitleDisplayMode(.inline)
        .task { build() }
        .refreshable { build() }
    }
}
