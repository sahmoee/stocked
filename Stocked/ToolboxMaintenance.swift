// ToolboxMaintenance.swift — Housekeeping tools for the Kitchen Toolbox.
// Duplicate Finder (fuzzy merge with Undo) • Achievements
import SwiftUI

// MARK: - Duplicate Finder

struct DuplicateFinderView: View {
    @Environment(AppSession.self) private var session

    private struct DupeGroup: Identifiable {
        let id = UUID()
        let items: [LocalInventoryItem]
        var displayName: String { items.first?.name ?? "" }
    }
    @State private var groups: [DupeGroup] = []
    @State private var scanned = false

    /// Fuzzy grouping: exact case/whitespace-insensitive matches plus near-misses
    /// (Levenshtein distance ≤ 1 for short names, ≤ 2 for longer). Single pass with a
    /// union of resolved keys — no O(n²) rescans on every render (computed once in .task).
    private func scan() {
        let items = session.guestStore.inventoryItems
        var buckets: [[LocalInventoryItem]] = []
        var keys: [String] = []
        for item in items {
            let name = item.name.lowercased().trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let threshold = name.count <= 5 ? 1 : 2
            if let index = keys.firstIndex(where: { $0 == name || FuzzyMatch.levenshtein($0, name) <= threshold }) {
                buckets[index].append(item)
            } else {
                keys.append(name)
                buckets.append([item])
            }
        }
        groups = buckets.filter { $0.count > 1 }.map { DupeGroup(items: $0) }
        scanned = true
    }

    private func merge(_ group: DupeGroup) {
        let store = session.guestStore
        let ids = Set(group.items.map { $0.id })
        // Snapshot for Undo (UI/UX: destructive actions are reversible).
        let before = store.inventoryItems

        // Keep the item with the most information; combine quantities; keep earliest expiry.
        guard var keeper = group.items.max(by: { score($0) < score($1) }) else { return }
        keeper.quantity = group.items.reduce(0) { $0 + max(1, $1.quantity) }
        let expirations = group.items.compactMap { $0.expirationDate }
        if let earliest = expirations.min() { keeper.expirationDate = earliest }
        if keeper.price == nil { keeper.price = group.items.compactMap { $0.price }.first }
        if keeper.brand == nil { keeper.brand = group.items.compactMap { $0.brand }.first }

        var next = store.inventoryItems.filter { !ids.contains($0.id) }
        next.append(keeper)
        store.inventoryItems = next

        groups.removeAll { $0.id == group.id }
        HapticManager.success()
        ToastCenter.shared.undo("Merged \(group.items.count) × \(keeper.name)") {
            session.guestStore.inventoryItems = before
        }
    }

    private func score(_ item: LocalInventoryItem) -> Int {
        var s = 0
        if item.expirationDate != nil { s += 2 }
        if item.price != nil { s += 1 }
        if item.brand != nil { s += 1 }
        if item.imageData != nil { s += 2 }
        if item.nutrition != nil { s += 1 }
        return s
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if !scanned {
                    SkeletonListView(count: 3)
                } else if groups.isEmpty {
                    ToolboxEmptyState(icon: "checkmark.seal",
                                      title: "No duplicates found",
                                      message: "Your inventory looks clean — no items with the same or nearly-the-same name.")
                } else {
                    Text("\(groups.count) possible duplicate group\(groups.count == 1 ? "" : "s"). Merging combines quantities and keeps the most complete item. Every merge can be undone.")
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(groups) { group in
                        ToolboxCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.displayName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(session.themeTextColor)
                                ForEach(group.items) { item in
                                    HStack {
                                        Text("• \(item.name)")
                                            .font(.system(size: 13))
                                            .foregroundStyle(session.themeSecondaryText)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(item.storageCategory.icon) \(item.displayText)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(session.themeSecondaryText.opacity(0.8))
                                    }
                                }
                                Button { merge(group) } label: {
                                    Label("Merge \(group.items.count) items", systemImage: "arrow.triangle.merge")
                                        .font(.system(size: 13, weight: .semibold))
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(Capsule().fill(session.accentColor))
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Duplicate Finder")
        .navigationBarTitleDisplayMode(.inline)
        .task { scan() }
        .refreshable { scan() }
    }
}

// MARK: - Achievements

private struct KitchenBadge: Identifiable {
    var id: String { title }
    let icon: String
    let title: String
    let detail: String
    let earned: Bool
}

struct AchievementsView: View {
    @Environment(AppSession.self) private var session
    @State private var badges: [KitchenBadge] = []

    private func compute() {
        let store = session.guestStore
        // Aggregate once (perf): counts gathered in one place, not per badge.
        let itemCount = store.inventoryItems.count
        let recipeCount = store.userRecipes.count
        let totalCooks = store.userRecipes.reduce(0) { $0 + $1.cookCount }
        let expiredCount = store.inventoryItems.filter { $0.isExpired }.count
        let wastedCount = store.consumptionLog.filter { $0.wasted }.count
        let usedCount = store.consumptionLog.count - wastedCount
        let streak = session.cookStreak
        let templateCount = GroceryTemplateStore.shared.templates.count
        let pricedCount = store.priceHistory.count

        badges = [
            KitchenBadge(icon: "shippingbox", title: "Getting Stocked",
                         detail: "Add your first inventory item", earned: itemCount >= 1),
            KitchenBadge(icon: "shippingbox.fill", title: "Fully Stocked",
                         detail: "Track 25 items at once", earned: itemCount >= 25),
            KitchenBadge(icon: "building.columns", title: "Warehouse",
                         detail: "Track 75 items at once", earned: itemCount >= 75),
            KitchenBadge(icon: "book", title: "First Recipe",
                         detail: "Save your first recipe", earned: recipeCount >= 1),
            KitchenBadge(icon: "books.vertical", title: "Cookbook",
                         detail: "Save 10 recipes", earned: recipeCount >= 10),
            KitchenBadge(icon: "frying.pan", title: "First Cook",
                         detail: "Cook a saved recipe", earned: totalCooks >= 1),
            KitchenBadge(icon: "flame", title: "Home Chef",
                         detail: "Cook recipes 10 times", earned: totalCooks >= 10),
            KitchenBadge(icon: "flame.fill", title: "Head Chef",
                         detail: "Cook recipes 50 times", earned: totalCooks >= 50),
            KitchenBadge(icon: "calendar", title: "On a Roll",
                         detail: "3-day cooking streak", earned: streak >= 3),
            KitchenBadge(icon: "calendar.badge.checkmark", title: "Week of Cooking",
                         detail: "7-day cooking streak", earned: streak >= 7),
            KitchenBadge(icon: "sparkles", title: "Nothing Expired",
                         detail: "Have items tracked with zero expired", earned: itemCount > 0 && expiredCount == 0),
            KitchenBadge(icon: "leaf", title: "Waste Watcher",
                         detail: "Use up 10 items without wasting them", earned: usedCount >= 10),
            KitchenBadge(icon: "list.bullet.rectangle", title: "Planner",
                         detail: "Save a grocery list template", earned: templateCount >= 1),
            KitchenBadge(icon: "tag", title: "Price Aware",
                         detail: "Record 10 prices (receipts count)", earned: pricedCount >= 10),
        ]
    }

    private var earnedCount: Int { badges.filter { $0.earned }.count }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ToolboxStatTile(value: "\(earnedCount)/\(badges.count)", label: "Badges earned", tint: session.accentColor)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(badges) { badge in
                        VStack(spacing: 8) {
                            Image(systemName: badge.icon)
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(badge.earned ? session.accentColor : session.themeSecondaryText.opacity(0.4))
                                .frame(width: 46, height: 46)
                                .background(Circle().fill(badge.earned
                                    ? session.accentColor.opacity(session.isDarkMode ? 0.18 : 0.12)
                                    : session.themeBgColor))
                            Text(badge.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(badge.earned ? session.themeTextColor : session.themeSecondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(badge.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(session.themeSecondaryText)
                                .multilineTextAlignment(.center)
                                .lineLimit(2, reservesSpace: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(session.themeCardColor))
                        .opacity(badge.earned ? 1 : 0.75)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(badge.title), \(badge.earned ? "earned" : "not yet earned"). \(badge.detail)")
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Achievements")
        .navigationBarTitleDisplayMode(.inline)
        .task { compute() }
        .refreshable { compute() }
    }
}
