import SwiftUI
import os

// ─────────────────────────────────────────────────────────────────────
// Build 246 — Inventory hub (mockup screen 3).
//
// The Inventory tab's new root: an at-a-glance dashboard instead of the
// raw item list. Inventory Status card → category grid → "View all
// inventory" → Expiring Soon preview. The full list (InventoryView)
// is pushed from "View all inventory", from a category card (filtered),
// or from the header magnifier (search pre-opened).
// ─────────────────────────────────────────────────────────────────────

struct InventoryHubView: View {
    @Environment(AppSession.self) var session

    @State private var showSearchField = false
    @State private var searchText = ""
    @State private var showSortDialog = false
    @State private var goAllInventory = false
    @State private var goExpiringList = false
    @State private var selectedCategory: MockCategory? = nil
    // #251 — empty-state seed flow
    @State private var seeding = false
    @State private var showAddItem = false
    // Weekly plan strip (mirrors the full Inventory list) — tap opens the day's planner.
    @State private var plannerDayIndex: Int? = nil
    @State private var planToast: String? = nil

    private var allItems: [LocalInventoryItem] { session.guestStore.inventoryItems }

    // Identifiable wrapper so the day index can drive an .sheet(item:).
    private struct PlannerDay: Identifiable { let id: Int }

    // Drag-to-build: dropping an inventory item on a day adds it to that day's
    // "building" meal (creating one if needed) — mirrors the full Inventory list so
    // planning works the same from the hub.
    private func addToBuildingMeal(itemName: String, dayIndex: Int) {
        let name = itemName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var meals = session.guestStore.plannedMeals
        if let idx = meals.firstIndex(where: { $0.dayIndex == dayIndex && $0.isBuilding }) {
            if !meals[idx].ingredients.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                meals[idx].ingredients.append(name)
            }
            planToast = "Added \(name.displayNormalized) — \(meals[idx].ingredients.count) items"
        } else {
            let meal = PlannedMeal(
                dayIndex:    dayIndex,
                title:       "New Recipe",
                servings:    session.guestStore.cookingProfile.householdSize > 0 ? session.guestStore.cookingProfile.householdSize : 2,
                ingredients: [name],
                mealType:    "Dinner",
                isBuilding:  true
            )
            meals.append(meal)
            planToast = "Started a recipe with \(name.displayNormalized)"
        }
        session.guestStore.plannedMeals = meals
        HapticManager.success()
    }

    var body: some View {
        StockedShell(scrollDisabled: false,
                     titleText: "Inventory",
                     leadingTitle: true,
                     trailingIcon: "magnifyingglass", trailingLabel: "Search",
                     onTrailing: { withAnimation(.easeInOut(duration: 0.2)) { showSearchField.toggle(); if !showSearchField { searchText = "" } } },
                     trailingIcon2: "line.3.horizontal.decrease", trailingLabel2: "Sort",
                     onTrailing2: { showSortDialog = true }) {
            VStack(alignment: .leading, spacing: 22) {

                if showSearchField { inlineSearchField }

                if showSearchField && !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults
                } else if allItems.isEmpty {
                    emptyKitchenCard
                } else {
                    // Drag-to-plan week strip, same as the full Inventory list.
                    WeeklyPlanStrip(
                        onDrop: { itemName, dayIndex in
                            addToBuildingMeal(itemName: itemName, dayIndex: dayIndex)
                        },
                        onTap: { dayIndex in
                            plannerDayIndex = dayIndex
                        }
                    )
                    statusCard
                        .coachmarkAnchor("inv.status")
                    categoriesSection
                        .coachmarkAnchor("inv.categories")
                    viewAllRow
                    expiringSoonSection
                        .coachmarkAnchor("inv.expiring")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 110)
        }
        .navigationDestination(isPresented: $goAllInventory) { InventoryView() }
        .navigationDestination(isPresented: $goExpiringList) { ExpiringSoonListView() }
        .navigationDestination(item: $selectedCategory) { cat in
            CategoryItemsView(category: cat)
        }
        .sheet(isPresented: $showAddItem) {
            AddItemSheet(defaultZone: "Fridge").environment(session)
        }
        .sheet(item: Binding(get: { plannerDayIndex.map { PlannerDay(id: $0) } },
                             set: { plannerDayIndex = $0?.id })) { day in
            NavigationStack {
                MealPlannerView(servings: 2, initialItemName: "", initialDayIndex: day.id)
                    .environment(session)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = planToast {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(Color.stockedCharcoal))
                    .padding(.bottom, 124)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        withAnimation { planToast = nil }
                    }
            }
        }
        .confirmationDialog("Sort by", isPresented: $showSortDialog, titleVisibility: .visible) {
            ForEach(["Use first", "Name", "Quantity", "Low first", "Recent"], id: \.self) { mode in
                Button(mode) {
                    UserDefaults.standard.set(mode, forKey: "stocked.invSort")
                    goAllInventory = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            goAllInventory = false; goExpiringList = false
            selectedCategory = nil
            showSearchField = false; searchText = ""
        }
        .coachmarks(page: .inventory, steps: InventoryCoachmarks.steps)
    }

    // ── #251 Empty-kitchen seed (App #3) ─────────────────────────────
    // Shown when the pantry is empty: one tap drops in a starter set of common
    // staples so the Cook catalog and Discover badges light up immediately,
    // plus a manual "add by hand" path.
    private var emptyKitchenCard: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.stockedGold.opacity(0.14)).frame(width: 76, height: 76)
                    Image(systemName: "refrigerator")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(Color.stockedGold)
                }
                .padding(.top, 8)

                Text("Your kitchen is empty")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Text("Add a few staples to get started — we'll instantly show meals you can cook and recipes worth a look.")
                    .font(.system(size: 14))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                // Preview of what gets added.
                FlowLayout(items: Array(StarterStaples.all.prefix(8).map(\.name))) { name in
                    Text(name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(session.themeTextColor.opacity(0.7))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(session.themeTextColor.opacity(0.07))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 18)

                Button {
                    guard !seeding else { return }
                    seeding = true
                    HapticManager.success()
                    let added = session.guestStore.seedStarterStaples()
                    UsageMetrics.shared.record(.staplesSeeded, detail: "\(added)")
                    ToastCenter.shared.success(added == 1 ? "Added 1 staple" : "Added \(added) staples")
                    seeding = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold))
                        Text("Stock \(StarterStaples.all.count) common staples")
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                    }
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.stockedCharcoal)
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)

                Button { showAddItem = true } label: {
                    Text("Add an item by hand")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
            }
            .padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                .fill(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
        )
        .padding(.top, 10)
    }

    // ── Inline search ────────────────────────────────────────────────

    private var inlineSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(session.themeTextColor.opacity(0.45))
            TextField("Search inventory", text: $searchText)
                .font(.system(size: 15))
                .foregroundStyle(session.themeTextColor)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(session.themeTextColor.opacity(0.35))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                .fill(Color.stockedWhite.opacity(0.6))
        )
    }

    private var searchResults: some View {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = allItems.filter {
            $0.name.lowercased().contains(q)
            || ($0.brand?.lowercased().contains(q) ?? false)
            || ($0.customCategory?.lowercased().contains(q) ?? false)
        }
        return VStack(alignment: .leading, spacing: 10) {
            if hits.isEmpty {
                StockedEmptyState(icon: "magnifyingglass",
                                  title: "No matches",
                                  subtitle: "Nothing in your inventory matches \"\(searchText)\".")
                    .padding(.top, 30)
            } else {
                ForEach(hits) { item in
                    InventoryItemRow(item: item)
                }
            }
        }
    }

    // ── Inventory Status card ────────────────────────────────────────

    private func zonePercent(_ zones: [String]) -> String {
        let zoneItems = allItems.filter { zones.contains($0.zone) }
        guard !zoneItems.isEmpty else { return "—" }
        let avg = zoneItems.map(\.effectiveLevel).reduce(0, +) / Double(zoneItems.count)
        return "\(Int((avg * 100).rounded()))%"
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Inventory Status")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                Text("\(session.guestStore.stockPercent)% Stocked")
                    .font(.system(size: 26, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)

                GeometryProxyFreeBar(fraction: Double(session.guestStore.stockPercent) / 100.0)
                    .padding(.top, 4)

                HStack(spacing: 0) {
                    statusColumn("Fresh",  zonePercent(["Fridge"]))
                    statusColumn("Pantry", zonePercent(["Pantry", "Staples"]))
                    statusColumn("Frozen", zonePercent(["Freezer"]))
                }
                .padding(.top, 10)
            }
            .padding(18)

            Divider().overlay(session.themeTextColor.opacity(0.12))

            Button {
                NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.stats)
            } label: {
                HStack {
                    Text("View details")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View inventory details")
        }
        .background(
            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                .fill(Color.stockedWhite.opacity(0.6))
        )
    }

    private func statusColumn(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(session.themeTextColor.opacity(0.55))
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(session.themeTextColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ── Categories grid ──────────────────────────────────────────────

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Categories")
                .font(.system(size: 17, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(MockCategory.allCases) { cat in
                    categoryCard(cat)
                }
            }
        }
    }

    private func categoryCard(_ cat: MockCategory) -> some View {
        let count = allItems.filter { MockCategory.classify($0) == cat }.count
        return Button { selectedCategory = cat } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(cat.tint.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: cat.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(cat.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(cat.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("\(count) item\(count == 1 ? "" : "s")")
                        .font(.system(size: 12.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                    .fill(Color.stockedWhite.opacity(0.6))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(cat.title), \(count) items")
    }

    // ── View all inventory ───────────────────────────────────────────

    private var viewAllRow: some View {
        Button { goAllInventory = true } label: {
            HStack {
                Text("View all inventory")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.45))
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                    .fill(Color.stockedWhite.opacity(0.6))
            )
        }
        .buttonStyle(.plain)
    }

    // ── Expiring Soon preview ────────────────────────────────────────

    private var expiringItems: [LocalInventoryItem] { session.guestStore.expiringSoonItems }

    private var expiringSoonSection: some View {
        let preview = Array(expiringItems.prefix(3))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Expiring Soon")
                    .font(.system(size: 17, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                if !expiringItems.isEmpty {
                    Button("View All") { goExpiringList = true }
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                }
            }

            if preview.isEmpty {
                Text("Nothing expiring in the next few days. Your kitchen's in good shape.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(preview.enumerated()), id: \.element.id) { idx, item in
                        ExpiringPreviewRow(item: item)
                        if idx < preview.count - 1 {
                            Divider().overlay(session.themeTextColor.opacity(0.08))
                                .padding(.leading, 64)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                        .fill(Color.stockedWhite.opacity(0.6))
                )
            }
        }
    }
}

// ── Expiring preview row (emoji thumb · name · expiry text) ─────────

private struct ExpiringPreviewRow: View {
    @Environment(AppSession.self) var session
    let item: LocalInventoryItem
    @State private var showEdit = false

    private var expiryText: String {
        guard let d = item.daysUntilExpiry else { return "" }
        if d <= 0 { return "Expires today" }
        if d == 1 { return "Expires tomorrow" }
        return "Expires in \(d) days"
    }

    var body: some View {
        Button { showEdit = true } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.stockedBg.opacity(0.8))
                        .frame(width: 38, height: 38)
                    if let data = item.imageData, let ui = UIImage(data: data) {
                        Image(uiImage: ui)
                            .resizable().scaledToFill()
                            .frame(width: 38, height: 38)
                            .clipShape(Circle())
                    } else {
                        Text(ImageFallbackService.emoji(for: item.name))
                            .font(.system(size: 19))
                    }
                }
                Text(item.name.displayNormalized)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                    .lineLimit(1)
                Spacer()
                Text(expiryText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showEdit) { EditItemSheet(item: item) }
    }
}

// ── Category model + classifier ──────────────────────────────────────

enum MockCategory: String, CaseIterable, Identifiable, Hashable {
    case produce, dairy, meatSeafood, pantry, frozen, beverages
    var id: String { rawValue }

    var title: String {
        switch self {
        case .produce:     return "Produce"
        case .dairy:       return "Dairy"
        case .meatSeafood: return "Meat & Seafood"
        case .pantry:      return "Pantry"
        case .frozen:      return "Frozen"
        case .beverages:   return "Beverages"
        }
    }

    var icon: String {
        switch self {
        case .produce:     return "leaf"
        case .dairy:       return "waterbottle"
        case .meatSeafood: return "fish"
        case .pantry:      return "cabinet"
        case .frozen:      return "snowflake"
        case .beverages:   return "cup.and.saucer.fill"
        }
    }

    var tint: Color {
        switch self {
        case .produce:     return .stockedGreen
        case .dairy:       return .stockedGold
        case .meatSeafood: return .stockedError
        case .pantry:      return .stockedGoldDark
        case .frozen:      return .stockedInfo
        case .beverages:   return .stockedGold
        }
    }

    /// Maps an inventory item into one of the six mockup categories.
    /// Zone wins for Frozen; otherwise name keywords decide, falling back to Pantry.
    static func classify(_ item: LocalInventoryItem) -> MockCategory {
        let n = item.name.lowercased()

        // Frozen: zone first, then obvious frozen keywords.
        if item.zone == "Freezer" { return .frozen }
        if ["frozen", "ice cream", "popsicle", "sorbet"].contains(where: { n.contains($0) }) { return .frozen }

        // Beverages BEFORE produce — drink names often contain fruit words.
        let beverages = ["juice", "water", "soda", "cola", "pepsi", "sprite", "coffee", "tea", "wine", "beer",
                         "drink", "lemonade", "smoothie", "kombucha", "seltzer", "tonic", "gatorade",
                         "powerade", "cold brew", "cider", "lacroix", "la croix", "perrier", "snapple",
                         "red bull", "monster", "capri sun", "sunny d", "vitamin water", "vitaminwater"]
        if beverages.contains(where: { n.contains($0) }) { return .beverages }

        // Dairy (kefir + eggs live here per the mockup grouping).
        let dairy = ["milk", "cheese", "yogurt", "butter", "cream", "cheddar", "mozzarella", "parmesan",
                     "brie", "feta", "ricotta", "sour cream", "half and half", "kefir", "ghee", "egg"]
        if dairy.contains(where: { n.contains($0) }) { return .dairy }

        // Meat & Seafood (plus tofu/tempeh as protein stand-ins).
        let meat = ["chicken", "beef", "pork", "steak", "turkey", "lamb", "salmon", "tuna", "shrimp",
                    "fish", "bacon", "sausage", "ground", "chorizo", "ham", "veal", "bison", "cod",
                    "tilapia", "crab", "lobster", "scallop", "squid", "tofu", "tempeh"]
        if meat.contains(where: { n.contains($0) }) { return .meatSeafood }

        // Produce: vegetables + fruits.
        let produce = ["carrot", "broccoli", "spinach", "lettuce", "kale", "cabbage", "onion", "garlic",
                       "tomato", "pepper", "celery", "zucchini", "squash", "mushroom", "corn", "pea",
                       "asparagus", "cucumber", "eggplant", "leek", "beet", "radish", "artichoke",
                       "fennel", "chard", "arugula", "bok choy", "brussels", "cauliflower", "potato",
                       "apple", "banana", "orange", "grape", "strawberry", "blueberry", "raspberry",
                       "mango", "pineapple", "peach", "plum", "pear", "cherry", "watermelon", "melon",
                       "lemon", "lime", "avocado", "fig", "kiwi", "papaya", "pomegranate", "grapefruit"]
        if produce.contains(where: { n.contains($0) }) { return .produce }

        return .pantry
    }
}

// ── Category item list (pushed from a grid card) ─────────────────────

struct CategoryItemsView: View {
    @Environment(AppSession.self) var session
    let category: MockCategory

    private var items: [LocalInventoryItem] {
        session.guestStore.inventoryItems
            .filter { MockCategory.classify($0) == category }
            .sorted { ($0.daysUntilExpiry ?? 999) < ($1.daysUntilExpiry ?? 999) }
    }

    var body: some View {
        StockedShell(showBack: true, scrollDisabled: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: category.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(category.tint)
                    Text(category.title)
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                .padding(.top, 4)

                if items.isEmpty {
                    StockedEmptyState(icon: category.icon,
                                      title: "Nothing here yet",
                                      subtitle: "Items you add that fit \(category.title) will show up here.")
                        .padding(.top, 40)
                } else {
                    VStack(spacing: 10) {
                        ForEach(items) { item in
                            InventoryItemRow(item: item)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
    }
}

// ── Expiring Soon full list (shared — Home "Use It Soon" View All also lands here) ──

struct ExpiringSoonListView: View {
    @Environment(AppSession.self) var session

    private var items: [LocalInventoryItem] {
        session.guestStore.inventoryItems
            .filter { $0.isExpiringSoonOrExpired }
            .sorted { ($0.daysUntilExpiry ?? 999) < ($1.daysUntilExpiry ?? 999) }
    }

    var body: some View {
        StockedShell(showBack: true, scrollDisabled: false) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Expiring Soon")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Use these first to avoid waste.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                .padding(.top, 4)

                if items.isEmpty {
                    StockedEmptyState(icon: "checkmark.seal",
                                      title: "All clear",
                                      subtitle: "Nothing is expiring in the next week.")
                        .padding(.top, 40)
                } else {
                    VStack(spacing: 10) {
                        ForEach(items) { item in
                            InventoryItemRow(item: item)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        // Diagnostic instrumentation (T2): confirms the view mounted and how many items it
        // computed, so the log shows whether a crash happens before mount (navigation) or during
        // row rendering. Remove once the root cause is confirmed.
        .onAppear {
            Log.app.notice("ExpiringSoonListView appeared: items=\(items.count, privacy: .public) totalInventory=\(session.guestStore.inventoryItems.count, privacy: .public)")
        }
    }
}

// ── Tiny dependency-free progress bar (no GeometryReader) ────────────

private struct GeometryProxyFreeBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Color.stockedCharcoal.opacity(0.12))
            .frame(height: 7)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.stockedGold)
                    .scaleEffect(x: min(1, max(0.02, fraction)), y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
    }
}
