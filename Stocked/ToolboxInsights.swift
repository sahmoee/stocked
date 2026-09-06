// ToolboxInsights.swift — Insight tools for the Kitchen Toolbox.
// Pantry Value • Waste Insights • Weekly Review • Low Stock Report • Price Lookup • Meal Cost
//
// Perf: every screen computes its payload in .task (off the render path) into @State,
// recomputes via .refreshable (pull-to-refresh, UI/UX), and iterates with LazyVStack.
import SwiftUI

// MARK: - Pantry Value

struct PantryValueView: View {
    @Environment(AppSession.self) private var session
    @State private var snapshot = ToolboxKitchenSnapshot()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                HStack(spacing: 10) {
                    ToolboxStatTile(value: ToolboxFormatters.dollars(snapshot.totalValue), label: "Estimated value")
                    ToolboxStatTile(value: "\(snapshot.pricedItems)/\(snapshot.totalItems)", label: "Items with a price")
                }
                if snapshot.expiredValue > 0 {
                    ToolboxCard {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("\(ToolboxFormatters.dollars(snapshot.expiredValue)) of that is expired")
                                .scaledFont(14, weight: .medium)
                                .foregroundStyle(session.themeTextColor)
                        }
                    }
                }
                ToolboxSectionLabel(text: "By location")
                ForEach(StorageCategory.allCases, id: \.rawValue) { zone in
                    let value = snapshot.valueByZone[zone.rawValue] ?? 0
                    let count = snapshot.countByZone[zone.rawValue] ?? 0
                    ToolboxCard {
                        HStack {
                            Text("\(zone.icon) \(zone.displayName)")
                                .scaledFont(15, weight: .semibold)
                                .foregroundStyle(session.themeTextColor)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(ToolboxFormatters.dollars(value))
                                    .scaledFont(15, weight: .bold, design: .rounded)
                                    .foregroundStyle(session.accentColor)
                                Text("\(count) item\(count == 1 ? "" : "s")")
                                    .scaledFont(11)
                                    .foregroundStyle(session.themeSecondaryText)
                            }
                        }
                    }
                }
                if snapshot.pricedItems < snapshot.totalItems {
                    Text("Tip: add prices to items (or scan receipts) to make this more accurate. \(snapshot.totalItems - snapshot.pricedItems) item\(snapshot.totalItems - snapshot.pricedItems == 1 ? " has" : "s have") no price yet.")
                        .scaledFont(12)
                        .foregroundStyle(session.themeSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Pantry Value")
        .navigationBarTitleDisplayMode(.inline)
        .task { snapshot = ToolboxKitchenSnapshot.compute(from: session.guestStore.inventoryItems) }
        .refreshable { snapshot = ToolboxKitchenSnapshot.compute(from: session.guestStore.inventoryItems) }
    }
}

// MARK: - Waste Insights

struct WasteInsightsView: View {
    @Environment(AppSession.self) private var session

    private struct Payload: Equatable {
        var wastedCount = 0
        var usedCount = 0
        var wastedValue: Double = 0
        var topWasted: [(name: String, count: Int)] = []
        static func == (a: Payload, b: Payload) -> Bool {
            a.wastedCount == b.wastedCount && a.usedCount == b.usedCount && a.wastedValue == b.wastedValue
        }
    }
    @State private var payload = Payload()

    private func compute() {
        let log = session.guestStore.consumptionLog
        var p = Payload()
        var counts: [String: Int] = [:]
        for record in log {
            if record.wasted {
                p.wastedCount += 1
                p.wastedValue += record.estimatedValue ?? 0
                counts[record.itemName, default: 0] += 1
            } else {
                p.usedCount += 1
            }
        }
        p.topWasted = counts.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) }
        payload = p
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if payload.wastedCount == 0 && payload.usedCount == 0 {
                    ToolboxEmptyState(icon: "trash.slash",
                                      title: "No history yet",
                                      message: "As items get used up or thrown out, Stocked keeps a private log here so you can see what goes to waste.")
                } else {
                    HStack(spacing: 10) {
                        ToolboxStatTile(value: "\(payload.wastedCount)", label: "Thrown out", tint: .orange)
                        ToolboxStatTile(value: "\(payload.usedCount)", label: "Used up", tint: .green)
                        ToolboxStatTile(value: ToolboxFormatters.dollars(payload.wastedValue), label: "Value wasted")
                    }
                    if payload.usedCount + payload.wastedCount > 0 {
                        let pct = Double(payload.usedCount) / Double(payload.usedCount + payload.wastedCount)
                        ToolboxCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(Int(pct * 100))% of tracked items were used, not wasted")
                                    .scaledFont(14, weight: .semibold)
                                    .foregroundStyle(session.themeTextColor)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.orange.opacity(0.25))
                                        Capsule().fill(Color.green)
                                            .frame(width: max(6, geo.size.width * pct))
                                    }
                                }
                                .frame(height: 8)
                                .accessibilityLabel("\(Int(pct * 100)) percent used")
                            }
                        }
                    }
                    if !payload.topWasted.isEmpty {
                        ToolboxSectionLabel(text: "Most often wasted")
                        ForEach(payload.topWasted, id: \.name) { entry in
                            ToolboxCard {
                                HStack {
                                    Text(entry.name.capitalized)
                                        .scaledFont(14, weight: .medium)
                                        .foregroundStyle(session.themeTextColor)
                                    Spacer()
                                    Text("\(entry.count)×")
                                        .scaledFont(13, weight: .bold, design: .rounded)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        Text("Buying smaller amounts of your most-wasted items is the fastest way to cut food waste.")
                            .scaledFont(12)
                            .foregroundStyle(session.themeSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Waste Insights")
        .navigationBarTitleDisplayMode(.inline)
        .task { compute() }
        .refreshable { compute() }
    }
}

// MARK: - Weekly Review

struct WeeklyReviewView: View {
    @Environment(AppSession.self) private var session

    private struct Payload: Equatable {
        var added = 0
        var cooked = 0
        var wasted = 0
        var expiringNextWeek: [LocalInventoryItem] = []
        var shareText = ""
    }
    @State private var payload = Payload()

    private func compute() {
        let store = session.guestStore
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        let weekAgoMs = weekAgo.timeIntervalSince1970 * 1000
        var p = Payload()
        // Single pass over inventory: additions + upcoming expiries together (perf).
        for item in store.inventoryItems {
            if let bought = item.purchaseDate, bought >= weekAgo { p.added += 1 }
            else if item.purchaseDate == nil && item.updatedAt >= weekAgoMs { p.added += 1 }
            if let days = item.daysUntilExpiry, days >= 0 && days <= 7 {
                p.expiringNextWeek.append(item)
            }
        }
        p.expiringNextWeek.sort { ($0.daysUntilExpiry ?? 99) < ($1.daysUntilExpiry ?? 99) }
        for recipe in store.userRecipes {
            if let last = recipe.lastCooked, last >= weekAgo { p.cooked += 1 }
        }
        for record in store.consumptionLog where record.wasted && record.depletedAt >= weekAgo {
            p.wasted += 1
        }
        p.shareText = """
        My kitchen week (Stocked):
        • \(p.added) item\(p.added == 1 ? "" : "s") added
        • \(p.cooked) recipe\(p.cooked == 1 ? "" : "s") cooked
        • \(p.wasted) item\(p.wasted == 1 ? "" : "s") wasted
        • \(p.expiringNextWeek.count) expiring in the next 7 days
        """
        payload = p
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                HStack(spacing: 10) {
                    ToolboxStatTile(value: "\(payload.added)", label: "Items added")
                    ToolboxStatTile(value: "\(payload.cooked)", label: "Recipes cooked", tint: .green)
                    ToolboxStatTile(value: "\(payload.wasted)", label: "Items wasted", tint: payload.wasted > 0 ? .orange : nil)
                }
                if session.cookStreak > 0 {
                    ToolboxCard {
                        HStack {
                            Image(systemName: "flame.fill").foregroundStyle(.orange)
                            Text("You're on a \(session.cookStreak)-day cooking streak")
                                .scaledFont(14, weight: .semibold)
                                .foregroundStyle(session.themeTextColor)
                        }
                    }
                }
                ToolboxSectionLabel(text: "Use these in the next 7 days")
                if payload.expiringNextWeek.isEmpty {
                    ToolboxEmptyState(icon: "checkmark.seal",
                                      title: "Nothing expiring",
                                      message: "No items are set to expire in the next week. Nicely stocked.")
                } else {
                    ForEach(payload.expiringNextWeek.prefix(12)) { item in
                        ToolboxCard {
                            HStack {
                                Text(item.name)
                                    .scaledFont(14, weight: .medium)
                                    .foregroundStyle(session.themeTextColor)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                ExpiryUrgencyChip(daysLeft: item.daysUntilExpiry ?? 0)
                            }
                        }
                    }
                }
                ShareLink(item: payload.shareText) {
                    Label("Share weekly review", systemImage: "square.and.arrow.up")
                        .scaledFont(15, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(session.accentColor.opacity(0.14)))
                        .foregroundStyle(session.accentColor)
                }
                .simultaneousGesture(TapGesture().onEnded { HapticManager.light() })
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Weekly Review")
        .navigationBarTitleDisplayMode(.inline)
        .task { compute() }
        .refreshable { compute() }
    }
}

// MARK: - Low Stock Report

struct LowStockReportView: View {
    @Environment(AppSession.self) private var session
    @State private var lowItems: [LocalInventoryItem] = []
    @State private var selectedItem: LocalInventoryItem?
    private var missingFromGrocery: [LocalInventoryItem] {
        let names = session.guestStore.groceryItems.map(\.name)
        var seen = names
        return lowItems.filter { item in
            guard !GroceryDedup.isDuplicate(item.name, in: seen) else { return false }
            seen.append(item.name)
            return true
        }
    }

    private func compute() {
        lowItems = session.guestStore.inventoryItems
            .filter { $0.isLow }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addAllToGrocery() {
        guard HouseholdSync.shared.myCanAdd else {
            ToastCenter.shared.warning("Your household access does not allow adding items")
            return
        }
        let store = session.guestStore
        var added = 0
        for item in missingFromGrocery {
            let result = GroceryMutationService.apply(.init(name: item.name, quantity: 0,
                recommended: true, reason: .lowStock, dependencyIDs: [item.id.uuidString]), to: store)
            if case .added = result { added += 1 }
        }
        HapticManager.success()
        ToastCenter.shared.success(added == 0 ? "Everything is already on your list"
                                              : "Added \(added) item\(added == 1 ? "" : "s") to grocery list")
    }

    var body: some View {
        StockedShell(showBack: true, canvasColor: session.inventoryCanvas) {
            LazyVStack(spacing: 12) {
                InventoryEditorialHeading(title: "Running Low", subtitle: "A little restock keeps your kitchen ready.", artwork: 3)
                if lowItems.isEmpty {
                    ToolboxEmptyState(icon: "checkmark.circle",
                                      title: "Nothing running low",
                                      message: "Items drop in here when their fill level gets low or they fall below the par quantity you set.")
                } else {
                    let missingCount = missingFromGrocery.count
                    Button {
                        if missingCount == 0 { InterHubCoordinator.shared.open(.tab(.grocery)) }
                        else { addAllToGrocery() }
                    } label: {
                        Label(missingCount == 0 ? "Open grocery list" : "Add \(missingCount) to grocery list",
                              systemImage: missingCount == 0 ? "cart" : "cart.badge.plus")
                            .font(.stockedSerif(15, weight: .semibold, relativeTo: .body))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(session.themeButtonColor))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    ForEach(lowItems) { item in
                        Button { selectedItem = item } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                        .font(.stockedSerif(17, weight: .semibold, relativeTo: .headline))
                                        .foregroundStyle(session.themeTextColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("\(item.zone) · \(item.displayText)")
                                        .scaledFont(12)
                                        .foregroundStyle(session.themeSecondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(item.parQuantity.map { item.quantity < $0 ? "Below minimum: \(item.quantity) of \($0)" : "Running low" } ?? "Running low")
                                        .scaledFont(12, weight: .semibold)
                                        .foregroundStyle(session.inventoryGold)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").foregroundStyle(session.inventoryGold)
                                    .accessibilityHidden(true)
                            }
                            .modifier(InventoryEditorialCard())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Review quantity and restock settings")
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .task { compute() }
        .onChange(of: session.guestStore.inventoryRevision) { _, _ in compute() }
        .refreshable { compute() }
        .sheet(item: $selectedItem) { item in
            NavigationStack { EditItemSheet(item: item).environment(session) }
        }
    }
}

// MARK: - Price Lookup

struct PriceLookupView: View {
    @Environment(AppSession.self) private var session
    @State private var search = ""
    @State private var debouncedSearch = ""
    @State private var debounceTask: Task<Void, Never>? = nil

    private struct PriceGroup: Identifiable {
        var id: String { name }
        let name: String
        let best: PriceRecord
        let latest: PriceRecord
        let count: Int
    }

    private var groups: [PriceGroup] {
        let history = session.guestStore.priceHistory
        let q = debouncedSearch.trimmingCharacters(in: .whitespaces)
        var byName: [String: [PriceRecord]] = [:]
        for record in history {
            let key = record.itemName.lowercased()
            if q.isEmpty || FuzzyMatch.matches(q, record.itemName) {
                byName[key, default: []].append(record)
            }
        }
        return byName.compactMap { _, records -> PriceGroup? in
            guard let best = records.min(by: { $0.price < $1.price }),
                  let latest = records.max(by: { $0.date < $1.date }) else { return nil }
            return PriceGroup(name: latest.itemName, best: best, latest: latest, count: records.count)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                NavigationLink {
                    CommunityPricesView()
                } label: {
                    Label("Look up free community prices", systemImage: "barcode.viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                NavigationLink {
                    CommunityPriceWatchesView()
                } label: {
                    Label("Saved community price checks", systemImage: "tag.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                let items = groups
                if items.isEmpty {
                    ToolboxEmptyState(icon: "tag",
                                      title: debouncedSearch.isEmpty ? "No price history yet" : "No matches",
                                      message: debouncedSearch.isEmpty
                                        ? "Scan receipts or add prices to items and Stocked will remember what you paid, where."
                                        : "No recorded prices match that search.")
                } else {
                    ForEach(items) { group in
                        ToolboxCard {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(group.name.capitalized)
                                        .scaledFont(14, weight: .semibold)
                                        .foregroundStyle(session.themeTextColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    Text("\(group.count) record\(group.count == 1 ? "" : "s")")
                                        .scaledFont(11)
                                        .foregroundStyle(session.themeSecondaryText)
                                }
                                HStack(spacing: 12) {
                                    Label("\(group.best.formattedPrice) at \(group.best.store)", systemImage: "arrow.down.circle")
                                        .scaledFont(12, weight: .medium)
                                        .foregroundStyle(.green)
                                    if group.latest.id != group.best.id {
                                        Text("Latest: \(group.latest.formattedPrice)")
                                            .scaledFont(12)
                                            .foregroundStyle(session.themeSecondaryText)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Price Lookup")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search an item")
        // Debounced search (perf): typing doesn't re-group the full history per keystroke.
        // Uses .onChange + an untethered Task — .task(id:) that mutates its trigger self-cancels.
        .onChange(of: search) { _, newValue in
            debounceTask?.cancel()
            debounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                debouncedSearch = newValue
            }
        }
    }
}

// MARK: - Meal Cost

struct MealCostView: View {
    @Environment(AppSession.self) private var session
    @State private var selected: UserRecipe? = nil

    private struct CostBreakdown {
        var lines: [(name: String, price: Double?)] = []
        var known: Double = 0
        var unknownCount = 0
    }

    private func breakdown(for recipe: UserRecipe) -> CostBreakdown {
        let store = session.guestStore
        var result = CostBreakdown()
        for ingredient in recipe.ingredients {
            let price = store.bestPrice(for: ingredient.name)?.price
            result.lines.append((ingredient.name, price))
            if let p = price { result.known += p } else { result.unknownCount += 1 }
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if session.guestStore.userRecipes.isEmpty {
                    ToolboxEmptyState(icon: "fork.knife.circle",
                                      title: "No recipes yet",
                                      message: "Save a recipe first, then come back to see roughly what it costs to make.")
                } else if let recipe = selected {
                    let cost = breakdown(for: recipe)
                    HStack(spacing: 10) {
                        ToolboxStatTile(value: "~\(ToolboxFormatters.dollars(cost.known))", label: "Estimated total")
                        ToolboxStatTile(value: "~\(ToolboxFormatters.dollars(cost.known / Double(max(1, recipe.servings))))",
                                        label: "Per serving (\(recipe.servings))", tint: .green)
                    }
                    if cost.unknownCount > 0 {
                        Text("\(cost.unknownCount) ingredient\(cost.unknownCount == 1 ? " has" : "s have") no recorded price, so the real cost is a bit higher. Prices come from your receipts and item prices.")
                            .scaledFont(12)
                            .foregroundStyle(session.themeSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ToolboxSectionLabel(text: "Ingredients")
                    ForEach(Array(cost.lines.enumerated()), id: \.offset) { _, line in
                        ToolboxCard {
                            HStack {
                                Text(line.name.capitalized)
                                    .scaledFont(14)
                                    .foregroundStyle(session.themeTextColor)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Text(line.price.map { ToolboxFormatters.dollars($0) } ?? "—")
                                    .scaledFont(13, weight: .semibold, design: .rounded)
                                    .foregroundStyle(line.price == nil ? session.themeSecondaryText : session.accentColor)
                            }
                        }
                    }
                    Button {
                        HapticManager.light()
                        selected = nil
                    } label: {
                        Text("Pick a different recipe")
                            .scaledFont(14, weight: .semibold)
                            .foregroundStyle(session.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                } else {
                    ToolboxSectionLabel(text: "Pick a recipe")
                    ForEach(session.guestStore.userRecipes) { recipe in
                        Button {
                            HapticManager.light()
                            selected = recipe
                        } label: {
                            ToolboxCard {
                                HStack {
                                    Text(recipe.title)
                                        .scaledFont(14, weight: .medium)
                                        .foregroundStyle(session.themeTextColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    Text("\(recipe.ingredients.count) ingredients")
                                        .scaledFont(11)
                                        .foregroundStyle(session.themeSecondaryText)
                                    Image(systemName: "chevron.right")
                                        .scaledFont(12, weight: .semibold)
                                        .foregroundStyle(session.themeSecondaryText.opacity(0.6))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Meal Cost")
        .navigationBarTitleDisplayMode(.inline)
    }
}
