// DailyBriefView.swift — Daily Brief overlay triggered from the Home card (#246).
// Styled to the "Daily Brief (Expanded)" mockup: charcoal sheet, gold "Good Evening,
// Chef" greeting, cream stats card with the kitchen-report link, then At a Glance
// and Household Activity columns.
import SwiftUI

struct DailyBriefOverlay: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedDevice) private var device
    @Binding var isPresented: Bool

    var onScanReceipt:   () -> Void = {}
    var onScanBarcode:   () -> Void = {}
    var onShoppingList:  () -> Void = {}
    var onPreferences:   () -> Void = {}
    var onMealBuilder:   () -> Void = {}
    var onKitchenReport: () -> Void = {}   // #246 — cream card footer

    var store: GuestDataStore { session.guestStore }


    // "Recommended in 2 Days (Sat, May 24)" — exact mockup string for the cream card.
    private var nextRunValue: String {
        let days = store.groceryRunDays
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) else { return "Soon" }
        let f = DateFormatter(); f.dateFormat = "E, MMM d"
        switch days {
        case 0:  return "Recommended Today"
        case 1:  return "Recommended Tomorrow (\(f.string(from: date)))"
        default: return "Recommended in \(days) Days (\(f.string(from: date)))"
        }
    }

    private var expiringCount: Int { store.metrics.expiringSoonCount }
    private var lowStockCount: Int { store.metrics.lowStockCount }
    private var toBuyCount:    Int { store.groceryItems.filter { !$0.isChecked }.count }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { close() }

            mainCard
                .padding(.horizontal, 16)
                .padding(.top, max(StockedScreen.safeTopInset + 24, 78))
        }
    }

    // MARK: - Main card (mockup "Daily Brief (Expanded)")
    @ViewBuilder private var mainCard: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Greeting header + close ───────────────────────────────
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    // The Home screen behind this already greets the user, so the brief leads with
                    // its own title instead of repeating "Good Evening, Chef".
                    Text("Today's Brief")
                        .font(.system(size: 23, weight: .bold, design: .serif))
                        .foregroundStyle(Color.stockedGoldDark)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text("Here is where your kitchen stands today.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.stockedWhite.opacity(0.55))
                }
                Spacer(minLength: 8)
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.stockedWhite.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.stockedWhite.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .a11yButton("Close")
            }
            .padding(.bottom, 16)

            // ── Stats card | At a Glance + Household Activity ─────────
            ScrollView(showsIndicators: false) {
                if device == .tablet {
                    HStack(alignment: .top, spacing: 16) {
                        statsCard.frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 18) {
                            atAGlance
                            householdActivity
                        }
                        .frame(width: 230, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        statsCard
                        atAGlance
                        householdActivity
                    }
                }
            }
            .frame(maxHeight: StockedScreen.height * 0.62)
        }
        .padding(18)
        .background(Color.stockedCharcoal.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
    }

    // ── Cream stats card (mockup left column) ─────────────────────────
    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            statRow(icon: "fork.knife", label: "Available Meals",
                    value: "\(store.metrics.mealsReady) makeable meal\(store.metrics.mealsReady == 1 ? "" : "s")")
            statRow(icon: "refrigerator", label: "Inventory Status",
                    value: "\(store.metrics.stockPercent)% Stocked")
            statRow(icon: "clock.badge.exclamationmark", label: "Items Expiring Soon",
                    value: "\(store.metrics.expiringSoonCount) item\(store.metrics.expiringSoonCount == 1 ? "" : "s")")
            statRow(icon: "cart", label: "Next Grocery Run",
                    value: nextRunValue)

            Divider().background((session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal).opacity(0.12)).padding(.top, 4)

            Button {
                close()
                onKitchenReport()
            } label: {
                HStack(spacing: 6) {
                    Text("View full kitchen report")
                        .font(.system(size: 13.5, weight: .semibold))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(session.accentColor)
                .padding(.top, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .a11yButton("View full kitchen report")
        }
        .padding(16)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite)
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg - 4))
    }

    private func statRow(icon: String, label: String, value: String) -> some View {
        // Text/icon sit on the brief card, which is white in light mode and dark in dark mode,
        // so the ink color flips with it to stay legible.
        let ink = session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(ink.opacity(0.6))
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(ink.opacity(0.55))
                Text(value)
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(ink)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    // ── At a Glance (mockup right column) ─────────────────────────────
    private var atAGlance: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("At a Glance")
                .font(.system(size: 14, weight: .bold, design: .serif))
                .foregroundStyle(Color.stockedGoldDark)
            glanceLine(expiringCount, "expiring", "clock.badge.exclamationmark")
            glanceLine(lowStockCount, "low stock", "chart.bar")
            glanceLine(toBuyCount, "to buy", "cart")
        }
    }

    private func glanceLine(_ value: Int, _ label: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.stockedGold.opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: icon).font(.system(size: 12))
                    .foregroundStyle(Color.stockedGoldDark)
            }
            Text("\(value)")
                .font(.system(size: 16, weight: .heavy, design: .serif))
                .foregroundStyle(Color.stockedWhite)
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.stockedWhite.opacity(0.6))
            Spacer(minLength: 0)
        }
    }

    // ── Household Activity (mockup) ───────────────────────────────────
    private struct BriefActivityRow: Identifiable {
        let id = UUID(); let text: String; let when: Date
    }
    private var activityRows: [BriefActivityRow] {
        var rows: [BriefActivityRow] = []
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let added = store.inventoryItems.filter { ($0.purchaseDate ?? .distantPast) > cutoff }
        if !added.isEmpty {
            let newest = added.compactMap(\.purchaseDate).max() ?? Date()
            rows.append(BriefActivityRow(
                text: "\(session.userName) added \(added.count) item\(added.count == 1 ? "" : "s")",
                when: newest))
        }
        let recent = Array(store.consumptionLog.suffix(4)).sorted { $0.depletedAt > $1.depletedAt }
        let used = recent.filter { !$0.wasted }
        if used.count > 1, let newest = used.first {
            rows.append(BriefActivityRow(text: "\(used.count) items were used", when: newest.depletedAt))
        } else if let one = used.first {
            rows.append(BriefActivityRow(text: "\(one.itemName.displayNormalized) was used", when: one.depletedAt))
        }
        return Array(rows.sorted { $0.when > $1.when }.prefix(3))
    }
    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
    private var householdActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Household Activity")
                .font(.system(size: 14, weight: .bold, design: .serif))
                .foregroundStyle(Color.stockedGoldDark)
            let rows = activityRows
            if rows.isEmpty {
                Text("No activity yet")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.stockedWhite.opacity(0.5))
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Text(row.text)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color.stockedWhite.opacity(0.9))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 6)
                        Text(relative(row.when))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.stockedWhite.opacity(0.45))
                    }
                }
            }
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { isPresented = false }
    }
}

#Preview {
    ZStack {
        Color.stockedBg.ignoresSafeArea()
        DailyBriefOverlay(isPresented: .constant(true)).environment(AppSession())
    }
}

// MARK: - Expiring Soon Detail Page
struct ExpiringItemsView: View {
    @Environment(AppSession.self) var session
    enum Mode { case expiring, lowStock }
    let mode: Mode
    var store: GuestDataStore { session.guestStore }

    var items: [LocalInventoryItem] {
        switch mode {
        case .expiring:
            return store.inventoryItems.filter { item in
                guard let exp = item.expirationDate else { return false }
                return exp.timeIntervalSinceNow < 86400 * 5
            }.sorted { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }
        case .lowStock:
            return store.inventoryItems.filter { $0.level < 0.2 }
                .sorted { $0.level < $1.level }
        }
    }

    var grouped: [String: [LocalInventoryItem]] {
        Dictionary(grouping: items) { $0.storageCategory.rawValue }
    }

    var title: String { mode == .expiring ? "Expiring Soon" : "Low Stock" }
    var icon:  String { mode == .expiring ? "clock.badge.exclamationmark" : "chart.bar.fill" }
    var tint:  Color  { mode == .expiring ? .orange : Color.stockedGold }

    @State private var addedToList: Set<UUID> = []
    @State private var selectedItem: LocalInventoryItem?
    @State private var selectedRecipe: OnlineRecipe?
    // Closing the loop: recipes that use the expiring items, so they don't go to waste.
    @State private var useUpRecipes: [RecipeDatabaseEntry] = []
    @State private var loadingUseUp = false

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {

                    // Header
                    HStack(spacing: 12) {
                        Image(systemName: icon).font(.system(size: 22)).foregroundStyle(tint)
                        Text(title)
                            .font(.system(size: 26, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Spacer()
                        Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                            .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    }
                    .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 6)

                    if mode == .expiring {
                        Text("These items need to be used or added to your shopping list.")
                            .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))
                            .padding(.horizontal, 24).padding(.bottom, 18)

                        // #6 — YOUR saved recipes first: cooking something you've already
                        // saved beats a random online suggestion. NavigationLink works here
                        // because this view lives inside the sheet's NavigationStack.
                        let savedUseUp = session.guestStore.recipesUsingExpiringItems(within: 3, limit: 3)
                        if !savedUseUp.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "book.fill").font(.system(size: 12)).foregroundStyle(Color.stockedGold)
                                Text("From your collection")
                                    .font(.system(size: 12, weight: .bold)).tracking(0.5)
                                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                            }
                            .padding(.horizontal, 24).padding(.bottom, 8)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(savedUseUp) { r in
                                        NavigationLink(destination: UserRecipeDetailView(recipe: r).environment(session)) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(r.title)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(session.themeTextColor)
                                                    .lineLimit(2).multilineTextAlignment(.leading)
                                                let match = session.guestStore.stockMatch(for: r)
                                                if match.total > 0 {
                                                    Text("\(match.have)/\(match.total) in stock")
                                                        .font(.system(size: 10)).foregroundStyle(Color.stockedGreen)
                                                }
                                            }
                                            .frame(width: 130, alignment: .leading)
                                            .padding(12)
                                            .background(Color.stockedGold.opacity(0.12))
                                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                            .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd).stroke(Color.stockedGold.opacity(0.3), lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                        .a11yButton("Your recipe: \(r.title)", hint: "Uses an item that's expiring soon")
                                    }
                                }
                                .padding(.horizontal, 24)
                            }
                            .padding(.bottom, 14)
                        }

                        // Closing the loop: recipe ideas that use these expiring items.
                        if !useUpRecipes.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "leaf.fill").font(.system(size: 12)).foregroundStyle(Color.stockedGreen)
                                Text("Cook these to use them up")
                                    .font(.system(size: 12, weight: .bold)).tracking(0.5)
                                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                            }
                            .padding(.horizontal, 24).padding(.bottom, 8)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(useUpRecipes) { r in
                                        Button {
                                            selectedRecipe = OnlineRecipe(
                                                id: r.id.uuidString,
                                                title: r.title,
                                                category: r.category,
                                                area: r.cuisine,
                                                instructions: r.steps.joined(separator: "\n"),
                                                imageURL: r.imageURL,
                                                ingredients: r.ingredients,
                                                measures: Array(repeating: "", count: r.ingredients.count),
                                                source: r.sourceName.isEmpty ? "Stocked." : r.sourceName)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(r.title)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(session.themeTextColor)
                                                    .lineLimit(2).multilineTextAlignment(.leading)
                                                if !r.totalTime.isEmpty {
                                                    Text(r.totalTime)
                                                        .font(.system(size: 10)).foregroundStyle(session.themeTextColor.opacity(0.45))
                                                }
                                            }
                                            .frame(width: 130, alignment: .leading)
                                            .padding(12)
                                            .background(Color.stockedWhite.opacity(0.3))
                                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                        }
                                        .buttonStyle(.plain)
                                        .a11yButton("Recipe: \(r.title)", hint: "Uses an item that's expiring soon")
                                    }
                                }
                                .padding(.horizontal, 24)
                            }
                            .padding(.bottom, 18)
                        }
                    } else {
                        Text("Items below 20% — restock or plan a meal around them.")
                            .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))
                            .padding(.horizontal, 24).padding(.bottom, 18)
                    }

                    if items.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 44)).foregroundStyle(Color.stockedGold)
                            Text(mode == .expiring ? "Nothing expiring soon!" : "All items well stocked!")
                                .font(.system(size: 17, weight: .semibold, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else {
                        // Grouped by storage zone
                        ForEach(grouped.keys.sorted(), id: \.self) { zone in
                            let zoneItems = grouped[zone] ?? []
                            VStack(alignment: .leading, spacing: 0) {
                                Text(zone.uppercased())
                                    .font(.system(size: 10, weight: .bold)).tracking(1.5)
                                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                                    .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)

                                ForEach(zoneItems) { item in
                                    itemRow(item)
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 40)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadUseUpRecipes() }
        .sheet(item: $selectedItem) { _ in
            NavigationStack {
                ServingSizeView(isCookNow: false)
                    .environment(session)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $selectedRecipe) { recipe in
            OnlineRecipeDetailView(recipe: recipe).environment(session)
        }
    }

    private func loadUseUpRecipes() async {
        guard mode == .expiring, !items.isEmpty, useUpRecipes.isEmpty, !loadingUseUp else { return }
        loadingUseUp = true
        let snapshot = await RecipeDatabaseManager.shared.loadSnapshot()
        var seen = Set<UUID>()
        var results: [RecipeDatabaseEntry] = []
        for item in items.prefix(5) {
            let matches = RecipeDatabaseManager.shared.suggestions(for: item.name, in: snapshot, limit: 4)
            for m in matches where seen.insert(m.id).inserted {
                results.append(m)
                if results.count >= 8 { break }
            }
            if results.count >= 8 { break }
        }
        useUpRecipes = results
        loadingUseUp = false
    }

    private func itemRow(_ item: LocalInventoryItem) -> some View {
        HStack(spacing: 14) {
            // Level indicator
            ZStack {
                Circle().fill(session.themeTextColor.opacity(0.06)).frame(width: 40, height: 40)
                if mode == .expiring {
                    Text("⏰").font(.system(size: 18))
                } else {
                    VStack(spacing: 2) {
                        Text("\(Int(item.level * 100))%")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(item.level < 0.1 ? .red : tint)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                if mode == .expiring, let exp = item.expirationDate {
                    let days = Int(exp.timeIntervalSinceNow / 86400)
                    Text(days <= 0 ? "Expired" : "Expires in \(days) day\(days == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(days <= 0 ? .red : tint)
                } else {
                    Text(item.displayText).font(.system(size: 11))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                }
            }

            Spacer()

            // Action buttons
            VStack(spacing: 6) {
                // #23 — one tap: logs consumption, zeroes the item, and (with the
                // auto-add setting on) drops it straight onto the grocery list.
                if mode == .expiring && item.level > 0 {
                    Button {
                        store.updateInventoryLevel(id: item.id, level: 0)
                        HapticManager.light()
                    } label: {
                        Label("Used It Up", systemImage: "checkmark.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.stockedGreen)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.stockedGreen.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    store.addGroceryItem(name: item.name)
                    withAnimation { _ = addedToList.insert(item.id) }
                } label: {
                    Label(addedToList.contains(item.id) ? "Added ✓" : "Add to List",
                          systemImage: addedToList.contains(item.id) ? "checkmark" : "cart.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(addedToList.contains(item.id) ? Color.stockedGold : session.themeTextColor)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.stockedWhite.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                }
                .buttonStyle(.plain)

                Button {
                    selectedItem = item
                } label: {
                    Label("Build Meal", systemImage: "fork.knife")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.stockedWhite.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.stockedWhite.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .padding(.horizontal, 16).padding(.bottom, 6)
    }
}
