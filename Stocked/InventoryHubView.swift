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
    @State private var showAIAssistant = false
    // Weekly plan strip (mirrors the full Inventory list) — tap opens the day's planner.
    @State private var plannerDayIndex: Int? = nil
    @State private var planToast: String? = nil
    @State private var showStatusDetails = false   // #FB — Inventory Status → View details

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
                    // #FB — the drag-to-plan calendar strip was removed from THIS landing
                    // page; it still lives on "View all inventory" (the full item list),
                    // where items can actually be dragged onto days.
                    statusCard
                        .coachmarkAnchor("inv.status")
                    // RL-003 — surface Available vs Reserved where people look first.
                    reservedSummaryRow
                    // AI assistant: change inventory in plain language (use/remove/clear items).
                    Button { showAIAssistant = true } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8).fill(Color.stockedGold.opacity(0.15)).frame(width: 34, height: 34)
                                Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(Color.stockedGold)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Inventory Assistant").font(.system(size: 13.5, weight: .bold)).foregroundStyle(session.themeTextColor)
                                Text("Update, remove, or clear items by asking").font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.5))
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.35))
                        }
                        .padding(10)
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.40))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    }
                    .buttonStyle(.plain)
                    .coachmarkAnchor("inv.assistant")
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
        .sheet(isPresented: $showAIAssistant) {
            AIInventoryAssistantView().environment(session)
        }
        .sheet(isPresented: $showStatusDetails) {
            InventoryDetailsSheet().environment(session)
        }
        .sheet(item: Binding(get: { plannerDayIndex.map { PlannerDay(id: $0) } },
                             set: { plannerDayIndex = $0?.id })) { day in
            NavigationStack {
                CookLaterWorkspaceView(context: .direct(day: day.id, source: .inventory))
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
        // RL-006 — reservations are derived: re-check whenever the plan or the
        // inventory moves. refreshIfNeeded is revision-keyed, so this is free
        // when nothing changed and idempotent when it did.
        .task { ReservationLedger.shared.refreshIfNeeded(store: session.guestStore) }
        .onChange(of: session.guestStore.inventoryRevision) { _, _ in
            ReservationLedger.shared.refreshIfNeeded(store: session.guestStore)
        }
        .onChange(of: session.guestStore.planRevision) { _, _ in
            ReservationLedger.shared.refreshIfNeeded(store: session.guestStore)
        }
    }

    // ── RL-003 — Available vs Reserved at a glance ───────────────────
    // Compact strip under the status card: how many items the meal plan has
    // claims on, and whether any future meal is projected short. Tapping opens
    // the details sheet, where every reservation is labeled with its meal.
    @ViewBuilder
    private var reservedSummaryRow: some View {
        let snap = ReservationLedger.shared.snapshot
        if !snap.breakdowns.isEmpty {
            Button { showStatusDetails = true } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(Color.stockedGold.opacity(0.15)).frame(width: 34, height: 34)
                        Image(systemName: "calendar.badge.clock").font(.system(size: 14)).foregroundStyle(Color.stockedGold)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(snap.breakdowns.count) item\(snap.breakdowns.count == 1 ? "" : "s") reserved for planned meals")
                            .font(.system(size: 13.5, weight: .bold)).foregroundStyle(session.themeTextColor)
                        Text(snap.conflicts.isEmpty
                             ? "Everything else is available to cook"
                             : "\(snap.conflicts.count) future meal\(snap.conflicts.count == 1 ? "" : "s") short — tap to review")
                            .font(.system(size: 11))
                            .foregroundStyle(snap.conflicts.isEmpty
                                             ? session.themeTextColor.opacity(0.5)
                                             : Color.stockedError.opacity(0.85))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.35))
                }
                .padding(10)
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.40))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            }
            .buttonStyle(.plain)
            .a11yButton("\(snap.breakdowns.count) inventory items reserved for planned meals, view details")
        }
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
                .fill(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
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
                // #FB — "View details" now actually shows details (per-zone breakdown,
                // low, out-of-stock, and expiring items) instead of firing a drawer
                // action that had no listener on this screen.
                showStatusDetails = true
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
                .fill(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
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

            // #3 — classify each item ONCE into a count map, then hand each card its
            // number. Previously every card re-filtered allItems through the heavy
            // classifier, i.e. O(items × categories) per render.
            let counts = categoryCountMap()
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(MockCategory.allCases) { cat in
                    categoryCard(cat, count: counts[cat] ?? 0)
                }
            }
        }
    }

    /// #3 — classify each item once into a count map (heavy classifier runs O(items),
    /// not O(items × categories) per render).
    private func categoryCountMap() -> [MockCategory: Int] {
        var counts: [MockCategory: Int] = [:]
        for item in allItems { counts[MockCategory.classify(item), default: 0] += 1 }
        return counts
    }

    private func categoryCard(_ cat: MockCategory, count: Int) -> some View {
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
                    .fill(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
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
                    .fill(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
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
                        .fill(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
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
                        FoodIconView(name: item.name, size: 34, emojiSize: 19)
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
    case produce, dairy, meatSeafood, pantry, frozen, beverages, leftovers
    var id: String { rawValue }

    var title: String {
        switch self {
        case .produce:     return "Produce"
        case .dairy:       return "Dairy"
        case .meatSeafood: return "Meat & Seafood"
        case .pantry:      return "Pantry"
        case .frozen:      return "Frozen"
        case .beverages:   return "Beverages"
        case .leftovers:   return "Leftovers"
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
        case .leftovers:   return "takeoutbag.and.cup.and.straw.fill"
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
        case .leftovers:   return .stockedGreen
        }
    }

    /// Maps an inventory item into one of the mockup categories.
    /// Leftovers win outright, then zone wins for Frozen; otherwise name keywords
    /// decide, falling back to Pantry.
    static func classify(_ item: LocalInventoryItem) -> MockCategory {
        let n = item.name.lowercased()

        // #FB — leftovers were unfindable: they now have their own category, no
        // matter which zone (Fridge or Freezer) they were saved to.
        if item.isLeftover || n.contains("leftover") { return .leftovers }

        // Frozen: zone first, then obvious frozen keywords.
        if item.zone == "Freezer" { return .frozen }
        if ["frozen", "ice cream", "popsicle", "sorbet"].contains(where: { n.contains($0) }) { return .frozen }

        // Snacks & dried seasonings BEFORE dairy/produce — otherwise substring matches
        // misfile them: "cheddar chips" would hit the dairy "cheddar" rule and "cayenne
        // pepper" would hit the produce "pepper" rule. These are shelf-stable and belong in
        // Pantry. Mirrors the guard order in StockedIntelligence.classify so the two
        // classifiers agree.
        let shelfStableSnacksAndSpices = [
            "chip", "chips", "cracker", "pretzel", "popcorn", "tortilla chip", "puffs",
            "seasoning", "spice", "cayenne", "paprika", "chili powder", "chili flakes",
            "black pepper", "white pepper", "lemon pepper", "garlic powder", "onion powder",
            "cumin", "oregano", "basil dried", "dried basil", "turmeric", "curry powder",
            "cinnamon", "nutmeg"
        ]
        if shelfStableSnacksAndSpices.contains(where: { n.contains($0) }) { return .pantry }

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

    // #FB — view options like the Calendar app: Detail list / Compact list / Icon grid.
    enum CategoryViewMode: String, CaseIterable {
        case detail, compact, icons
        var icon: String {
            switch self {
            case .detail:  return "list.bullet.rectangle"
            case .compact: return "list.dash"
            case .icons:   return "square.grid.3x3"
            }
        }
        var label: String {
            switch self {
            case .detail:  return "Detail list"
            case .compact: return "Compact list"
            case .icons:   return "Icon grid"
            }
        }
    }
    @State private var viewMode: CategoryViewMode = CategoryViewMode(
        rawValue: UserDefaults.standard.string(forKey: "stocked.categoryViewMode") ?? "detail") ?? .detail
    @State private var editItemID: UUID? = nil

    private struct EditTarget: Identifiable { let id: UUID }

    private var items: [LocalInventoryItem] {
        session.guestStore.inventoryItems
            .filter { MockCategory.classify($0) == category }
            .sorted { ($0.daysUntilExpiry ?? 999) < ($1.daysUntilExpiry ?? 999) }
    }

    // #FB — subcategory grouping within each category.
    private func subcategory(for item: LocalInventoryItem) -> String {
        let n = item.name.lowercased()
        func hit(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        switch category {
        case .produce:
            if hit(["apple","banana","orange","grape","berry","strawberry","blueberry","raspberry",
                    "mango","pineapple","peach","plum","pear","cherry","melon","lemon","lime",
                    "kiwi","papaya","pomegranate","grapefruit","fig","avocado"]) { return "Fruits" }
            if hit(["basil","parsley","cilantro","thyme","rosemary","mint","dill","oregano","sage","chive"]) { return "Herbs" }
            return "Vegetables"
        case .dairy:
            if hit(["cheese","cheddar","mozzarella","parmesan","brie","feta","ricotta","swiss","jack"]) { return "Cheese" }
            if hit(["yogurt","kefir"]) { return "Yogurt & Cultured" }
            if hit(["egg"]) { return "Eggs" }
            if hit(["milk","cream","half and half"]) { return "Milk & Cream" }
            return "Other Dairy"
        case .meatSeafood:
            if hit(["chicken","turkey","duck","wings","drumstick"]) { return "Poultry" }
            if hit(["salmon","tuna","shrimp","fish","cod","tilapia","crab","lobster","scallop","squid","catfish","mahi","mussel"]) { return "Seafood" }
            if hit(["tofu","tempeh"]) { return "Plant Protein" }
            return "Meat"
        case .pantry:
            if hit(["salt","pepper","cumin","paprika","cinnamon","oregano","chili powder","turmeric",
                    "seasoning","spice","garlic powder","onion powder","nutmeg","cayenne"]) { return "Spices & Seasonings" }
            if hit(["rice","pasta","spaghetti","penne","macaroni","quinoa","oat","noodle","flour","bread","tortilla","cereal","grain"]) { return "Grains & Pasta" }
            if hit(["can","canned","beans","chickpea","broth","stock","soup","tomato paste","tomato sauce"]) { return "Canned & Jarred" }
            if hit(["sauce","ketchup","mustard","mayo","dressing","vinegar","oil","soy","salsa","syrup","honey"]) { return "Oils, Sauces & Condiments" }
            if hit(["sugar","baking","yeast","vanilla","cocoa","chocolate chip","cornmeal"]) { return "Baking" }
            if hit(["chip","cracker","cookie","popcorn","pretzel","granola","snack","nut","jerky"]) { return "Snacks" }
            return "Other Pantry"
        case .frozen:
            if hit(["pizza","burrito","dumpling","meatball","waffle","sandwich","meal","entree"]) { return "Frozen Meals" }
            if hit(["vegetable","veg","broccoli","corn","pea","fries","hashbrown","fruit"]) { return "Frozen Produce & Sides" }
            if hit(["ice cream","sorbet","popsicle","dessert"]) { return "Frozen Desserts" }
            return "Other Frozen"
        case .beverages:
            if hit(["coffee","tea","cold brew"]) { return "Coffee & Tea" }
            if hit(["soda","cola","sprite","seltzer","sparkling","tonic","olipop","poppi"]) { return "Sodas & Sparkling" }
            if hit(["juice","lemonade","smoothie"]) { return "Juices" }
            if hit(["wine","beer","cider"]) { return "Alcohol" }
            return "Other Drinks"
        case .leftovers:
            return item.zone == "Freezer" ? "Frozen Leftovers" : "Fridge Leftovers"
        }
    }

    private var grouped: [(String, [LocalInventoryItem])] {
        var buckets: [String: [LocalInventoryItem]] = [:]
        for item in items { buckets[subcategory(for: item), default: []].append(item) }
        return buckets.sorted { $0.value.count > $1.value.count }
    }

    let iconCols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)]

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
                    // #FB — view options menu (detail / compact / icon grid).
                    Menu {
                        ForEach(CategoryViewMode.allCases, id: \.self) { mode in
                            Button {
                                viewMode = mode
                                UserDefaults.standard.set(mode.rawValue, forKey: "stocked.categoryViewMode")
                            } label: {
                                Label(mode.label, systemImage: mode.icon)
                            }
                        }
                    } label: {
                        Image(systemName: viewMode.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.stockedGold)
                            .padding(8)
                            .background(Color.stockedGold.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                    }
                    .accessibilityLabel("Change view: \(viewMode.label)")
                }
                .padding(.top, 4)

                if items.isEmpty {
                    StockedEmptyState(icon: category.icon,
                                      title: "Nothing here yet",
                                      subtitle: "Items you add that fit \(category.title) will show up here.")
                        .padding(.top, 40)
                } else {
                    // #FB — grouped under subcategory headers.
                    ForEach(grouped, id: \.0) { name, groupItems in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(name)
                                    .font(.system(size: 15, weight: .bold, design: .serif))
                                    .foregroundStyle(session.themeTextColor.opacity(0.8))
                                Text("\(groupItems.count)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(category.tint)
                            }
                            switch viewMode {
                            case .detail:
                                VStack(spacing: 10) {
                                    ForEach(groupItems) { item in InventoryItemRow(item: item) }
                                }
                            case .compact:
                                VStack(spacing: 0) {
                                    ForEach(Array(groupItems.enumerated()), id: \.element.id) { idx, item in
                                        compactRow(item)
                                        if idx < groupItems.count - 1 {
                                            Divider().overlay(session.themeTextColor.opacity(0.08))
                                                .padding(.leading, 14)
                                        }
                                    }
                                }
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            case .icons:
                                LazyVGrid(columns: iconCols, spacing: 12) {
                                    ForEach(groupItems) { item in iconTile(item) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        .sheet(item: Binding(get: { editItemID.map { EditTarget(id: $0) } },
                             set: { editItemID = $0?.id })) { target in
            if let item = session.guestStore.inventoryItems.first(where: { $0.id == target.id }) {
                EditItemSheet(item: item).environment(session)
            }
        }
    }

    // Compact list row — one dense line per item.
    private func compactRow(_ item: LocalInventoryItem) -> some View {
        Button { editItemID = item.id } label: {
            HStack(spacing: 10) {
                FoodIconView(name: item.name, size: 24, emojiSize: 15)
                Text(item.name.displayNormalized)
                    .font(.system(size: 13.5))
                    .foregroundStyle(session.themeTextColor)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                if let d = item.daysUntilExpiry, d <= 3 {
                    Text(d < 0 ? "Expired" : d == 0 ? "Today" : "\(d)d")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(d <= 1 ? Color.red.opacity(0.8) : Color.orange)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(item.level >= 0.66 ? "Full" : item.level >= 0.33 ? "Half" : "Low")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(item.level >= 0.33 ? Color.stockedGreen : Color.stockedGold)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Icon grid tile — big icon, name below.
    private func iconTile(_ item: LocalInventoryItem) -> some View {
        Button { editItemID = item.id } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm)
                        .fill(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.55))
                        .frame(height: 62)
                    FoodIconView(name: item.name, size: 44, emojiSize: 26)
                    if let d = item.daysUntilExpiry, d <= 3 {
                        VStack { HStack { Spacer()
                            Circle().fill(d <= 1 ? Color.red : Color.orange)
                                .frame(width: 8, height: 8).padding(5)
                        }; Spacer() }
                    }
                }
                Text(item.name.displayNormalized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(session.themeTextColor)
                    .lineLimit(1)
                Text(item.level >= 0.66 ? "Full" : item.level >= 0.33 ? "Half" : "Low")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(item.level >= 0.33 ? Color.stockedGreen : Color.stockedGold)
            }
        }
        .buttonStyle(.plain)
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
