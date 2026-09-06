// InventorySpatialView.swift — Swipeable kitchen zones with realistic item display
import SwiftUI
import Combine

// Demo items shown when zone is empty — realistic per-zone defaults
private let demoItems: [String: [(emoji: String, name: String)]] = [
    "Fridge":  [("🥛","Milk"),("🧀","Cheese"),("🥚","Eggs"),("🥬","Lettuce"),
                ("🧈","Butter"),("🍋","Lemon"),("🫙","Yogurt"),("🥩","Chicken")],
    "Freezer": [("🍦","Ice Cream"),("🧊","Ice"),("🫕","Frozen Meal"),("🍗","Frozen Chicken"),
                ("🥦","Frozen Broccoli"),("🍟","Fries"),("🫐","Frozen Berries"),("🐟","Fish")],
    "Pantry":  [("🍝","Pasta"),("🍚","Rice"),("🥫","Canned Beans"),("🫙","Olive Oil"),
                ("🧂","Salt"),("🍞","Bread"),("🥜","Peanut Butter"),("🍪","Cookies")],
    "Staples": [("🧄","Garlic Powder"),("🌶️","Paprika"),("🌿","Basil"),("🫚","Cumin"),
                ("🧂","Black Pepper"),("🌰","Cinnamon"),("🫛","Oregano"),("🍵","Bay Leaves")],
]

private let zoneIcons: [String: String] = [
    "Fridge": "❄️", "Freezer": "🧊", "Pantry": "🏺", "Staples": "🧂"
]

struct InventorySpatialView: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedMotion) private var motion
    @State private var currentZoneIndex = 0

    private var store: GuestDataStore { session.guestStore }
    private let zones = ["Fridge", "Freezer", "Pantry", "Staples"]

    private func stockPct(for zone: String) -> Int {
        let items = store.inventoryItems.filter { $0.zone == zone }
        guard !items.isEmpty else { return 0 }
        return Int(finite: safeDivide(items.map(\.effectiveLevel).reduce(0,+), by: Double(items.count)) * 100)
    }
    private func stockColor(_ pct: Int) -> Color {
        pct > 60 ? Color.stockedGreen : pct > 30 ? Color.stockedGold : .red
    }

    var body: some View {
        VStack(spacing: 0) {
            // Zone tab pills
            HStack(spacing: 8) {
                ForEach(Array(zones.enumerated()), id: \.offset) { i, zone in
                    Button {
                        motion.animate(.navigation, intent: .spatial) { currentZoneIndex = i }
                    } label: {
                        HStack(spacing: 5) {
                            Text(zoneIcons[zone] ?? "📦").scaledFont(13)
                            Text(zone).font(.stockedSystem(size: 12, weight: currentZoneIndex == i ? .bold : .medium, design: .serif))
                                .foregroundStyle(currentZoneIndex == i ? Color.stockedWhite : session.themeTextColor.opacity(0.55))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(currentZoneIndex == i ? Color.stockedCharcoal : Color.stockedWhite.opacity(0.25))
                        .clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 12)

            // Swipeable zone cards
            TabView(selection: $currentZoneIndex) {
                ForEach(Array(zones.enumerated()), id: \.offset) { i, zone in
                    zoneCard(zone: zone)
                        .tag(i)
                        .padding(.horizontal, 20)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 320)
            .stockedAnimation(.navigation, intent: .spatial, value: currentZoneIndex)

            // Swipe hint
            HStack(spacing: 6) {
                ForEach(0..<zones.count, id: \.self) { i in
                    Circle()
                        .fill(i == currentZoneIndex ? Color.stockedGold : Color.stockedCharcoal.opacity(0.2))
                        .frame(width: i == currentZoneIndex ? 16 : 6, height: 6)
                        .stockedAnimation(.standard, intent: .spatial, value: currentZoneIndex)
                }
            }
            .padding(.top, 10)
        }
    }

    private func zoneCard(zone: String) -> some View {
        let realItems = store.inventoryItems.filter { $0.zone == zone }
        let pct = stockPct(for: zone)
        let demos = demoItems[zone] ?? []
        let isEmpty = realItems.isEmpty

        return VStack(alignment: .leading, spacing: 0) {
            // Zone header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(zoneIcons[zone] ?? "📦").scaledFont(22)
                        Text(zone)
                            .scaledFont(20, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(isEmpty ? Color.stockedCharcoal.opacity(0.3) : stockColor(pct))
                            .frame(width: 7, height: 7)
                        Text(isEmpty ? "Empty — sample items shown" : "\(pct)% Stocked · \(realItems.count) items")
                            .scaledFont(11, weight: .semibold)
                            .foregroundStyle(isEmpty ? session.themeTextColor.opacity(0.4) : stockColor(pct))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)

            // Items grid
            let displayItems: [(emoji: String, name: String)] = isEmpty
                ? demos
                : realItems.prefix(8).map { item in
                    let emoji = demos.first(where: { $0.name.lowercased() == item.name.lowercased() })?.emoji ?? itemEmoji(item.name)
                    return (emoji: emoji, name: item.name)
                }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                 GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(displayItems.prefix(8), id: \.name) { item in
                    VStack(spacing: 5) {
                        ZStack {
                            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                                .fill(isEmpty
                                    ? Color.stockedCharcoal.opacity(0.06)
                                    : Color.stockedWhite.opacity(0.5))
                                .frame(width: 52, height: 52)
                            Text(item.emoji).scaledFont(26)
                                .opacity(isEmpty ? 0.4 : 1)
                        }
                        Text(item.name)
                            .scaledFont(9, weight: .medium)
                            .foregroundStyle(isEmpty ? session.themeTextColor.opacity(0.35) : session.themeTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 60)
                    }
                }

                // Overflow badge
                if !isEmpty && realItems.count > 8 {
                    VStack(spacing: 5) {
                        ZStack {
                            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                                .fill(Color.stockedGold.opacity(0.15))
                                .frame(width: 52, height: 52)
                            Text("+\(realItems.count - 8)")
                                .scaledFont(14, weight: .bold)
                                .foregroundStyle(Color.stockedGold)
                        }
                        Text("more").scaledFont(9).foregroundStyle(session.themeTextColor.opacity(0.4))
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .background(session.themeCardColor.opacity(isEmpty ? 0.72 : 1))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    private func itemEmoji(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("milk") || n.contains("dairy") { return "🥛" }
        if n.contains("egg") { return "🥚" }
        if n.contains("cheese") { return "🧀" }
        if n.contains("butter") { return "🧈" }
        if n.contains("chicken") || n.contains("poultry") { return "🍗" }
        if n.contains("beef") || n.contains("steak") { return "🥩" }
        if n.contains("fish") || n.contains("salmon") { return "🐟" }
        if n.contains("pasta") || n.contains("noodle") { return "🍝" }
        if n.contains("rice") { return "🍚" }
        if n.contains("bread") { return "🍞" }
        if n.contains("apple") { return "🍎" }
        if n.contains("banana") { return "🍌" }
        if n.contains("tomato") { return "🍅" }
        if n.contains("lettuce") || n.contains("salad") { return "🥬" }
        if n.contains("onion") { return "🧅" }
        if n.contains("garlic") { return "🧄" }
        if n.contains("pepper") { return "🌶️" }
        if n.contains("oil") { return "🫚" }
        if n.contains("juice") { return "🧃" }
        if n.contains("water") { return "💧" }
        if n.contains("salt") { return "🧂" }
        return "🥘"
    }
}

#Preview {
    InventorySpatialView().environment(AppSession()).padding()
}
