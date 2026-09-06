import SwiftUI
import os

/// Reference roles use the SAME cutout family and renderer as Home.
struct InventoryReferenceArtwork: View {
    let cell: Int
    private var asset: String {
        switch cell {
        case 0: return "inventory_kitchen_board_reference"
        case 1: return "inventory_refrigerator_hero"
        case 2: return KitchenArtworkCatalog.inventoryActions[0]
        case 3: return KitchenArtworkCatalog.inventoryActions[1]
        case 5: return "kitchen_leftovers_reference"
        case 6: return "inventory_category_freezer"
        case 7: return "inventory_category_pantry"
        default: return KitchenArtworkCatalog.inventoryActions[2]
        }
    }
    var body: some View {
        StockedKitchenArtwork(asset: asset)
    }
}

// Shared editorial language for the Inventory landing and its destinations.
extension AppSession {
    var inventoryCanvas: Color { isDarkMode ? themeBgColor : Color(red: 0.89, green: 0.76, blue: 0.57) }
    var inventoryGold: Color { isDarkMode ? .stockedGoldDark : Color(red: 0.57, green: 0.32, blue: 0.025) }
}

struct InventoryEditorialHeading: View {
    @Environment(AppSession.self) private var session
    let title: String
    let subtitle: String
    var artwork: Int = 0
    var artworkLeading = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if artworkLeading { headingArtwork }
            VStack(alignment: .leading, spacing: 7) {
                Text("Your Kitchen")
                    .font(.stockedSerif(12, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(session.inventoryGold)
                Text(title)
                    .font(.stockedSerif(28, weight: .bold, relativeTo: .title))
                    .foregroundStyle(session.themeTextColor)
                Text(subtitle)
                    .font(.stockedSerif(14, relativeTo: .body))
                    .foregroundStyle(session.themeSecondaryText)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !artworkLeading { headingArtwork }
        }
        .padding(.vertical, 12)
    }

    private var headingArtwork: some View {
        InventoryReferenceArtwork(cell: artwork)
            .frame(width: 88, height: 88)
            .clipped()
            .accessibilityHidden(true)
    }
}

struct InventoryEditorialCard: ViewModifier {
    @Environment(AppSession.self) private var session
    func body(content: Content) -> some View {
        content.padding(16)
            .background(session.isDarkMode ? session.themeCardColor : session.inventoryCanvas.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(session.inventoryGold.opacity(0.25), lineWidth: 0.7))
    }
}

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
    @Environment(\.stockedLayout) private var layoutMetrics
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var showSearchField = false
    @State private var searchText = ""
    @State private var showSortDialog = false
    @State private var goAllInventory = false
    @State private var referenceZone: String?
    @State private var showLowStock = false
    @State private var showLeftovers = false
    @State private var goExpiringList = false
    @State private var goCookFromInventory = false
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
        StockedShell(trailingIcon: "magnifyingglass", trailingLabel: "Search inventory",
                     onTrailing: { withAnimation { showSearchField.toggle() } },
                     canvasColor: session.isDarkMode ? session.themeBgColor : Color(red: 0.89, green: 0.76, blue: 0.57)) {
            VStack(alignment: .leading, spacing: 10) {
                referenceHero

                if showSearchField { inlineSearchField }

                if showSearchField && !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults
                } else {
                    referenceKitchen
                    referenceActions
                    referenceAI
                }
            }
            .stockedSnapTargetLayout()
            .frame(maxWidth: layoutMetrics.readableContentWidth)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .navigationDestination(isPresented: $goAllInventory) { InventoryView(initialZone: "All") }
        .navigationDestination(item: $referenceZone) { zone in InventoryView(initialZone: zone) }
        .navigationDestination(isPresented: $showLowStock) { LowStockReportView().stockedScreen() }
        .navigationDestination(isPresented: $showLeftovers) { LeftoversView().stockedScreen() }
        .navigationDestination(isPresented: $goExpiringList) { ExpiringSoonListView() }
        .navigationDestination(isPresented: $goCookFromInventory) {
            CookNowResultsView(focus: .readyFirst)
        }
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
                    .scaledFont(13, weight: .semibold)
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
            goAllInventory = false; goExpiringList = false; goCookFromInventory = false
            selectedCategory = nil
            referenceZone = nil; showLowStock = false; showLeftovers = false
            showSearchField = false; searchText = ""
        }
        .coachmarks(page: .inventory, steps: InventoryCoachmarks.steps)
        // RL-006 — reservations are derived: re-check whenever the plan or the
        // inventory moves. refreshIfNeeded is revision-keyed, so this is free
        // when nothing changed and idempotent when it did.
        .task(id: "\(session.guestStore.inventoryRevision):\(session.guestStore.planRevision)") {
            // Present Inventory's first frame before reconciling meal-plan reservations.
            // Large restored kitchens previously performed this synchronous revision
            // pass during tab construction and could trip the main-thread watchdog.
            await Task.yield()
            await ReservationLedger.shared.refreshForPresentation(store: session.guestStore)
        }
    }

    // MARK: - Editorial inventory landing

    private var referenceScale: CGFloat { min(1.65, max(0.8, (layoutMetrics.contentWidth - 28) / 365)) }
    private var referenceGold: Color { session.isDarkMode ? .stockedGoldDark : Color(red: 0.57, green: 0.32, blue: 0.025) }
    private var referenceBorder: Color { referenceGold.opacity(session.isDarkMode ? 0.35 : 0.23) }

    private var referenceHero: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("\(StockedFormatters.timeOfDayGreeting), \(session.effectiveName)")
                .font(.stockedSerif(12, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(referenceGold)
            // Allocate distinct bounds: an offset overlay let the plant paint over
            // the heading. Text now wraps/grows while art owns the trailing column.
            let narrow = min(layoutMetrics.contentWidth, layoutMetrics.readableContentWidth) < 350
            let heroLayout = narrow
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
            heroLayout {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Here’s everything in your kitchen.")
                        .font(.stockedSerif(25 * referenceScale, weight: .bold, relativeTo: .largeTitle))
                        .tracking(-0.3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Browse, stay organized, and always know what you have.")
                        .font(.stockedSerif(13 * referenceScale, relativeTo: .body))
                        .foregroundStyle(session.themeSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                InventoryReferenceArtwork(cell: 0)
                    .frame(width: min(138, 120 * referenceScale), height: min(154, 134 * referenceScale))
                    .clipped()
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(session.themeTextColor)
        .padding(.horizontal, 9)
        .padding(.top, 14)
    }

    private var referenceKitchen: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your Kitchen").font(.stockedSerif(16 * referenceScale, weight: .bold, relativeTo: .title2))
                Spacer(minLength: 4)
                Button { goAllInventory = true } label: {
                    HStack(spacing: 7) {
                        Text("View All Inventory")
                        Image(systemName: "chevron.right")
                    }.font(.stockedSerif(12 * referenceScale, weight: .semibold, relativeTo: .subheadline))
                        .foregroundStyle(referenceGold)
                }.buttonStyle(.plain).frame(minHeight: 44)
            }.padding(.horizontal, 9)
            HStack(spacing: 0) {
                InventoryReferenceArtwork(cell: 1)
                    .frame(maxWidth: .infinity, minHeight: 282 * referenceScale, alignment: .center)
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    referenceZoneRow("Fridge", count: allItems.filter { $0.zone == "Fridge" }.count) { referenceZone = "Fridge" }
                    Divider().overlay(referenceBorder)
                    referenceZoneRow("Freezer", count: allItems.filter { $0.zone == "Freezer" }.count) { referenceZone = "Freezer" }
                    Divider().overlay(referenceBorder)
                    referenceZoneRow("Pantry", count: allItems.filter { $0.zone == "Pantry" }.count) { referenceZone = "Pantry" }
                    Divider().overlay(referenceBorder)
                    referenceZoneRow("Leftovers", count: LeftoversStore.shared.entries.count) { showLeftovers = true }
                }
                .padding(.horizontal, 16 * referenceScale)
                .frame(maxWidth: .infinity)
            }
            .background(session.themeBgColor.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(referenceBorder, lineWidth: 0.6))
            .coachmarkAnchor("inv.categories")
        }
    }

    private func referenceZoneRow(_ title: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.stockedSerif(17 * referenceScale, weight: .semibold, relativeTo: .headline))
                        .foregroundStyle(session.themeTextColor)
                    Text("\(count) items").font(.stockedSerif(12 * referenceScale, relativeTo: .subheadline))
                        .foregroundStyle(referenceGold)
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                referenceArrow
            }.frame(maxWidth: .infinity, minHeight: 68 * referenceScale, alignment: .leading)
        }.buttonStyle(.plain)
            .accessibilityLabel("\(title), \(count) items")
    }

    private var referenceArrow: some View {
        Image(systemName: "chevron.right")
            .font(.stockedSans(12, weight: .bold))
            .foregroundStyle(session.isDarkMode ? Color.stockedCharcoal : .stockedWhite)
            .frame(width: 24 * referenceScale, height: 24 * referenceScale)
            .background(referenceGold, in: Circle())
            .accessibilityHidden(true)
    }

    private var referenceActions: some View {
        let layout = layoutMetrics.contentWidth < 350
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(StockedEqualHeightRow(spacing: 4))
        return layout {
            referenceAction("Expiring Soon", detail: expiringItems.count == 1 ? "1 item needs\nattention." : "\(expiringItems.count) items need\nattention.", cell: 2) { goExpiringList = true }
            referenceAction("Running Low", detail: allItems.filter(\.isLow).count == 1 ? "1 item is\nrunning low." : "\(allItems.filter(\.isLow).count) items are\nrunning low.", cell: 3) { showLowStock = true }
            referenceAction("Add Items", detail: "Quickly add items\nto your inventory.", cell: 4) { showAddItem = true }
        }.coachmarkAnchor("inv.expiring")
    }

    private func referenceAction(_ title: String, detail: String, cell: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                InventoryReferenceArtwork(cell: cell)
                    .aspectRatio(1.25, contentMode: .fit)
                    .accessibilityHidden(true)
                Text(title).font(.stockedSerif(13 * referenceScale, weight: .semibold, relativeTo: .headline))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .bottom, spacing: 2) {
                    Text(detail).font(.stockedSerif(10.5 * referenceScale, relativeTo: .caption))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    referenceArrow
                }
            }
            .foregroundStyle(session.themeTextColor)
            .padding(10 * referenceScale)
            .frame(maxWidth: .infinity, minHeight: 143 * referenceScale, maxHeight: .infinity, alignment: .topLeading)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(referenceBorder, lineWidth: 0.6))
        }.buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(detail.replacingOccurrences(of: "\n", with: " "))
            .accessibilityHint(cell == 4 ? "Opens the add item form" : "Opens the matching inventory list")
    }

    private var referenceAI: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.stocked(.title2))
                .foregroundStyle(referenceGold)
                .frame(width: 34, height: 34)
                .overlay(Circle().stroke(referenceGold, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text("Organize with Stocked AI").font(.stockedSerif(14 * referenceScale, weight: .semibold, relativeTo: .headline))
                Text("Coming Soon").font(.stockedSerif(11 * referenceScale, relativeTo: .caption))
            }
            Spacer(minLength: 0)
            Text("Coming Soon").font(.stockedSerif(12 * referenceScale, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(session.isDarkMode ? Color.stockedCharcoal : .stockedWhite)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(referenceGold, in: Capsule())
        }
        .foregroundStyle(Color.stockedWhite)
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 49 * referenceScale)
        .background(Color.stockedCharcoal, in: RoundedRectangle(cornerRadius: 15))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var inventoryHero: some View {
        if dynamicTypeSize.isAccessibilitySize || layoutMetrics.contentWidth < 350 {
            VStack(alignment: .leading, spacing: 8) {
                inventoryHeroCopy
                inventoryHeroArtwork(width: min(230, layoutMetrics.contentWidth), height: 230)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            ZStack(alignment: .bottomTrailing) {
                inventoryHeroArtwork(
                    width: layoutMetrics.contentWidth >= 700 ? 320 : 218,
                    height: layoutMetrics.contentWidth >= 700 ? 370 : 270
                )
                .offset(x: layoutMetrics.contentWidth >= 700 ? 0 : 14)

                inventoryHeroCopy
                    .frame(maxWidth: layoutMetrics.contentWidth >= 700 ? 470 : 242,
                           alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, layoutMetrics.contentWidth >= 700 ? 38 : 8)
            }
            .frame(height: layoutMetrics.contentWidth >= 700 ? 360 : 270)
        }
    }

    private var inventoryHeroCopy: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.guestStore.stockPercent >= 65
                 ? "Your kitchen is\nin good shape."
                 : "Let’s refresh\nyour kitchen.")
                .font(.stockedSerif(36, weight: .bold, relativeTo: .largeTitle))
                .foregroundStyle(session.themeTextColor)
                .fixedSize(horizontal: false, vertical: true)
            Text(session.guestStore.stockPercent >= 65
                 ? "Everything you need is already inside your kitchen."
                 : "A few smart additions will unlock more meals and keep the week moving.")
                .font(.stocked(.body))
                .foregroundStyle(session.themeSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 390, alignment: .leading)
        .layoutPriority(1)
    }

    private func inventoryHeroArtwork(width: CGFloat, height: CGFloat) -> some View {
        Image("inventory_refrigerator_hero")
            .resizable()
            .scaledToFit()
            .frame(width: width, height: height, alignment: .bottomTrailing)
            .accessibilityHidden(true)
    }

    private var kitchenOverviewCard: some View {
        Button { showStatusDetails = true } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Kitchen overview")
                        .font(.stockedSerif(19, weight: .bold, relativeTo: .headline))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.stocked(.caption).weight(.semibold))
                        .foregroundStyle(session.themeSecondaryText)
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    overviewMetric("\(session.guestStore.stockPercent)%", label: "stocked", tint: .stockedGreen)
                    overviewDivider
                    overviewMetric("\(allItems.count)", label: "items", tint: session.themeTextColor)
                    overviewDivider
                    overviewMetric("\(expiringItems.count)", label: "use soon", tint: .stockedGoldDark)
                }
                GeometryProxyFreeBar(fraction: Double(session.guestStore.stockPercent) / 100)
            }
            .foregroundStyle(session.themeTextColor)
            .padding(20)
            .background(session.themeCardColor,
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(session.themeTextColor.opacity(0.07), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .a11yButton("Kitchen overview, \(session.guestStore.stockPercent) percent stocked, \(allItems.count) items, \(expiringItems.count) use soon")
    }

    private func overviewMetric(_ value: String, label: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.stockedSerif(31, weight: .semibold, relativeTo: .title))
                .foregroundStyle(tint)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.stocked(.subheadline))
                .foregroundStyle(session.themeSecondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var overviewDivider: some View {
        Rectangle()
            .fill(session.themeTextColor.opacity(0.12))
            .frame(width: 1, height: 50)
    }

    private var useFirstSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                editorialSectionTitle("Use First")
                Spacer()
                if !expiringItems.isEmpty {
                    Button("View All") { goExpiringList = true }
                        .font(.stocked(.subheadline).weight(.semibold))
                        .foregroundStyle(session.accentColor)
                }
            }
            if expiringItems.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.stocked(.title2))
                        .foregroundStyle(Color.stockedGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing needs attention")
                            .font(.stockedSerif(16, weight: .bold, relativeTo: .headline))
                        Text("Your dated food is in good shape.")
                            .font(.stocked(.subheadline))
                            .foregroundStyle(session.themeSecondaryText)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(session.themeCardColor,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(expiringItems.prefix(8)) { item in
                            InventoryUseFirstCard(item: item)
                                .containerRelativeFrame(.horizontal, count: 3, spacing: 12)
                        }
                    }
                    .stockedScrollTargetLayout()
                }
                .stockedHorizontalSnap()
            }
        }
    }

    private var editorialKitchenSection: some View {
        let cards: [(String, Int, String, MockCategory?)] = [
            ("Fridge", allItems.filter { $0.zone == "Fridge" }.count, "inventory_category_fridge", nil),
            ("Pantry", allItems.filter { $0.zone == "Pantry" || $0.zone == "Staples" }.count, "inventory_category_pantry", .pantry),
            ("Freezer", allItems.filter { $0.zone == "Freezer" }.count, "inventory_category_freezer", .frozen),
            ("Produce", allItems.filter { MockCategory.classify($0) == .produce }.count, "inventory_category_produce", .produce)
        ]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                editorialSectionTitle("Your Kitchen")
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showSearchField.toggle() }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                        .font(.stocked(.subheadline).weight(.semibold))
                        .foregroundStyle(session.accentColor)
                }
                .buttonStyle(.plain)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(cards, id: \.0) { card in
                    Button {
                        if let category = card.3 { selectedCategory = category }
                        else { goAllInventory = true }
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                Image(card.2)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 94, maxHeight: 94)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(card.0)
                                        .font(.stockedSerif(18, weight: .bold, relativeTo: .headline))
                                    Text("\(card.1)")
                                        .font(.stockedSerif(29, weight: .semibold, relativeTo: .title2))
                                        .foregroundStyle(Color.stockedGreen)
                                }
                                Spacer(minLength: 0)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Image(card.2)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 86)
                                    .accessibilityHidden(true)
                                HStack(alignment: .firstTextBaseline) {
                                    Text(card.0)
                                        .font(.stockedSerif(18, weight: .bold, relativeTo: .headline))
                                    Spacer()
                                    Text("\(card.1)")
                                        .font(.stockedSerif(25, weight: .semibold, relativeTo: .title2))
                                        .foregroundStyle(Color.stockedGreen)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
                        .foregroundStyle(session.themeTextColor)
                        .padding(12)
                        .background(session.themeCardColor,
                                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(session.themeTextColor.opacity(0.07), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(card.0), \(card.1) items")
                }
            }
        }
    }

    private func editorialSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.stockedSerif(26, weight: .bold, relativeTo: .title2))
            .foregroundStyle(session.themeTextColor)
    }

    private var addInventoryButton: some View {
        VStack(spacing: 10) {
            Button { showAddItem = true } label: {
                Label("Add to Inventory", systemImage: "plus")
                    .font(.stockedSerif(17, weight: .bold, relativeTo: .headline))
                    .foregroundStyle(Color.selectedTabForeground(session.isDarkMode))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.stockedCharcoal,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            HStack(spacing: 18) {
                Button("View all") { goAllInventory = true }
                Button("Find meals") { goCookFromInventory = true }
                Button("Ask Stocked") { showAIAssistant = true }
            }
            .font(.stocked(.subheadline).weight(.semibold))
            .foregroundStyle(session.accentColor)
            .buttonStyle(.plain)
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
                        Image(systemName: "calendar.badge.clock").scaledFont(14).foregroundStyle(Color.stockedGold)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(snap.breakdowns.count) item\(snap.breakdowns.count == 1 ? "" : "s") reserved for planned meals")
                            .scaledFont(13.5, weight: .bold).foregroundStyle(session.themeTextColor)
                        Text(snap.conflicts.isEmpty
                             ? "Everything else is available to cook"
                             : "\(snap.conflicts.count) future meal\(snap.conflicts.count == 1 ? "" : "s") short — tap to review")
                            .scaledFont(11)
                            .foregroundStyle(snap.conflicts.isEmpty
                                             ? session.themeTextColor.opacity(0.5)
                                             : Color.stockedError.opacity(0.85))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").scaledFont(12, weight: .semibold).foregroundStyle(session.themeTextColor.opacity(0.35))
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
                        .scaledFont(32, weight: .medium)
                        .foregroundStyle(Color.stockedGold)
                }
                .padding(.top, 8)

                Text("Your kitchen is empty")
                    .scaledFont(20, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                Text("Add a few staples to get started — we'll instantly show meals you can cook and recipes worth a look.")
                    .scaledFont(14)
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                // Preview of what gets added.
                FlowLayout(items: Array(StarterStaples.all.prefix(8).map(\.name))) { name in
                    Text(name)
                        .scaledFont(11.5, weight: .medium)
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
                        Image(systemName: "sparkles").scaledFont(14, weight: .semibold)
                        Text("Stock \(StarterStaples.all.count) common staples")
                            .scaledFont(15, weight: .semibold, design: .serif)
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
                        .scaledFont(14, weight: .semibold)
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
                .scaledFont(14, weight: .semibold)
                .foregroundStyle(session.themeTextColor.opacity(0.45))
            TextField("Search inventory", text: $searchText)
                .scaledFont(15)
                .foregroundStyle(session.themeTextColor)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(15)
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
                    .scaledFont(13.5, weight: .medium)
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                Text("\(session.guestStore.stockPercent)% Stocked")
                    .scaledFont(26, weight: .bold, design: .serif)
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
                        .scaledFont(14.5, weight: .semibold)
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .scaledFont(12, weight: .semibold)
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
                .scaledFont(12.5)
                .foregroundStyle(session.themeTextColor.opacity(0.55))
            Text(value)
                .scaledFont(17, weight: .bold)
                .foregroundStyle(session.themeTextColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ── Categories grid ──────────────────────────────────────────────

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Categories")
                .scaledFont(17, weight: .bold, design: .serif)
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
                        .scaledFont(16, weight: .semibold)
                        .foregroundStyle(cat.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(cat.title)
                        .scaledFont(14.5, weight: .semibold)
                        .foregroundStyle(session.themeTextColor)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(count) item\(count == 1 ? "" : "s")")
                        .scaledFont(12.5)
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
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                Image(systemName: "chevron.right")
                    .scaledFont(12, weight: .semibold)
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
                    .scaledFont(17, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                if !expiringItems.isEmpty {
                    Button("View All") { goExpiringList = true }
                        .scaledFont(13.5, weight: .semibold)
                        .foregroundStyle(Color.stockedGold)
                }
            }

            if preview.isEmpty {
                Text("Nothing expiring in the next few days. Your kitchen's in good shape.")
                    .scaledFont(13.5)
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

// ── Editorial use-first card ────────────────────────────────────────

private struct InventoryUseFirstCard: View {
    @Environment(AppSession.self) private var session
    let item: LocalInventoryItem
    @State private var showEdit = false

    private var urgency: String {
        guard let days = item.daysUntilExpiry else { return "Use soon" }
        if days <= 0 { return "Use today" }
        if days == 1 { return "Use tomorrow" }
        return "Use within \(days) days"
    }

    var body: some View {
        Button { showEdit = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                CachedLocalDataImage(
                    data: item.imageData,
                    maxDimension: 220,
                    width: nil,
                    height: 108,
                    clip: .roundedRectangle(cornerRadius: 14)
                ) {
                    ZStack {
                        Color.stockedGold.opacity(0.07)
                        FoodIconView(name: item.name, size: 74, emojiSize: 44)
                    }
                }
                Text(item.name.displayNormalized)
                    .font(.stockedSerif(16, weight: .bold, relativeTo: .headline))
                    .foregroundStyle(session.themeTextColor)
                    .lineLimit(2)
                Text(urgency)
                    .font(.stocked(.caption).weight(.semibold))
                    .foregroundStyle(Color.stockedGoldDark)
            }
            .padding(12)
            .frame(minHeight: 178, alignment: .topLeading)
            .background(session.themeCardColor,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(session.themeTextColor.opacity(0.07), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showEdit) { EditItemSheet(item: item).environment(session) }
        .accessibilityLabel("\(item.name.displayNormalized), \(urgency)")
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
                    CachedLocalDataImage(
                        data: item.imageData,
                        maxDimension: 38,
                        width: 38,
                        height: 38,
                        clip: .circle
                    ) {
                        FoodIconView(name: item.name, size: 34, emojiSize: 19)
                    }
                }
                Text(item.name.displayNormalized)
                    .scaledFont(15, weight: .semibold)
                    .foregroundStyle(session.themeTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(expiryText)
                    .scaledFont(12.5, weight: .medium)
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

        // Stock, broth and bouillon often contain a vegetable or protein word
        // ("beef broth", "vegetable stock") but are pantry cooking bases.
        if ["broth", "stock", "bouillon", "consommé", "consomme"].contains(where: { n.contains($0) }) {
            return .pantry
        }

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
        StockedShell(showBack: true, scrollDisabled: false, canvasColor: session.inventoryCanvas) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: category.icon)
                        .scaledFont(17, weight: .semibold)
                        .foregroundStyle(category.tint)
                    Text(category.title)
                        .scaledFont(22, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                        .scaledFont(13)
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
                            .scaledFont(14, weight: .semibold)
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
                                    .scaledFont(15, weight: .bold, design: .serif)
                                    .foregroundStyle(session.themeTextColor.opacity(0.8))
                                Text("\(groupItems.count)")
                                    .scaledFont(11, weight: .bold)
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
                    .scaledFont(13.5)
                    .foregroundStyle(session.themeTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                if let d = item.daysUntilExpiry, d <= KitchenThresholds.expiringSoonDays {
                    Text(d < 0 ? "Expired" : d == 0 ? "Today" : "\(d)d")
                        .scaledFont(11, weight: .semibold)
                        .foregroundStyle(d <= 1 ? Color.red.opacity(0.85) : session.themeTextColor.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                        .fixedSize()
                }
                Text(item.level >= 0.66 ? "Full" : item.level >= 0.33 ? "Half" : "Low")
                    .scaledFont(11.5, weight: .semibold)
                    .foregroundStyle(item.level >= 0.33 ? Color.stockedGreen : Color.stockedGold)
                    .fixedSize(horizontal: false, vertical: true)
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
                    if let d = item.daysUntilExpiry, d <= KitchenThresholds.expiringSoonDays {
                        VStack { HStack { Spacer()
                            Circle().fill(d <= 1 ? Color.red : Color.stockedGold)
                                .frame(width: 8, height: 8).padding(5)
                        }; Spacer() }
                    }
                }
                Text(item.name.displayNormalized)
                    .scaledFont(11, weight: .medium)
                    .foregroundStyle(session.themeTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.level >= 0.66 ? "Full" : item.level >= 0.33 ? "Half" : "Low")
                    .scaledFont(9.5, weight: .semibold)
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
        StockedShell(showBack: true, scrollDisabled: false, canvasColor: session.inventoryCanvas) {
            VStack(alignment: .leading, spacing: 14) {
                InventoryEditorialHeading(title: "Expiring Soon", subtitle: "Use these first to avoid waste.", artwork: 2)

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
