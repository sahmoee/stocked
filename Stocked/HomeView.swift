// HomeView.swift — Home tab, 1:1 with the master mockup sheet (#246).
// Order: greeting → Daily Brief card → What's New → Action Center → Use It Soon.
import SwiftUI
import UniformTypeIdentifiers
import os

/// The Home recipe preview is intentionally a snapshot operation. Matching every
/// saved recipe against every expiring item from SwiftUI's render path caused the
/// reported multi-second Home stalls on large libraries. This pure helper can run
/// on a utility executor and returns the one small array the widgets actually need.
nonisolated enum HomeReadyToCookPolicy {
    static func picks(
        recipes: [UserRecipe],
        inventory: [LocalInventoryItem],
        within days: Int = KitchenThresholds.expiringSoonDays,
        limit: Int = 3,
        now: Date = Date()
    ) -> [UserRecipe] {
        guard limit > 0 else { return [] }
        let cutoff = now.addingTimeInterval(Double(days) * 86_400)
        let expiring = inventory.filter {
            $0.effectiveLevel > 0 && ($0.expirationDate.map { $0 <= cutoff } ?? false)
        }
        guard !expiring.isEmpty else { return [] }

        var scored: [(recipe: UserRecipe, uses: Int)] = []
        scored.reserveCapacity(min(recipes.count, limit * 4))
        for recipe in recipes {
            if Task.isCancelled { return [] }
            var uses = 0
            for item in expiring where recipe.ingredients.contains(where: {
                KitchenAvailability.nameMatches($0.name, item.name)
            }) {
                uses += 1
            }
            if uses > 0 { scored.append((recipe, uses)) }
        }
        scored.sort {
            if $0.uses != $1.uses { return $0.uses > $1.uses }
            if $0.recipe.cookCount != $1.recipe.cookCount {
                return $0.recipe.cookCount > $1.recipe.cookCount
            }
            return $0.recipe.title.localizedCaseInsensitiveCompare($1.recipe.title) == .orderedAscending
        }
        return Array(scored.prefix(limit).map(\.recipe))
    }
}

struct HomeView: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedDevice) var device
    @Environment(\.stockedLayout) private var layoutMetrics
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.stockedMotion) private var motion
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    // Single .sheet(item:) — stacked .sheet(isPresented:) made these need a second tap.
    private enum HomeScreenSheet: Int, Identifiable {
        case quickUpdate, activityFeed, widgetGallery, widgetThemeGallery
        var id: Int { rawValue }
    }
    private enum HomeActionMenu: Int, Identifiable {
        case scan, add, log
        var id: Int { rawValue }
    }
    @State private var activeHomeSheet: HomeScreenSheet? = nil
    @State private var activeActionMenu: HomeActionMenu? = nil
    @State private var goExpiringList   = false
    // #250 — Daily Brief collapse state, remembered across launches.
    private let briefCollapsedKey = "stocked.homeBriefCollapsed"
    @State private var briefCollapsed = UserDefaults.standard.bool(forKey: "stocked.homeBriefCollapsed")
    // #252 — customizable widget board (iPhone-style long-press to edit).
    @State private var editMode = false
    // #18 — guards the one-tap staple seed on the getting-started card.
    @State private var seeding = false
    @State private var layout = HomeWidget.loadLayout()
    @State private var draggingWidget: HomeWidget? = nil   // #11 drag-to-reorder
    @State private var dropTargetWidget: HomeWidget? = nil
    @State private var dragStartLayout: [HomeWidget]? = nil
    @State private var widgetFootprints = HomeWidget.loadGridFootprints()
    @State private var resizingWidget: HomeWidget? = nil
    @State private var resizeStartFootprint: HomeWidgetGridFootprint? = nil
    @State private var resizePreviewFootprint: HomeWidgetGridFootprint? = nil
    @State private var kitchenMetrics = KitchenMetrics()
    @State private var readyToCookPicks: [UserRecipe] = []
    @State private var widgetsLastUpdated = Date()
    @State private var smartWidgetSuggestions = UserDefaults.standard.bool(forKey: "stocked.smartWidgetSuggestions_v1")
    @State private var dismissedSizeRecommendations: Set<HomeWidget> = []
    @State private var previewingSizeRecommendation: HomeWidget? = nil
    @AppStorage("stocked.homeWidgetDensity_v1") private var widgetDensityRaw = HomeWidgetDensity.standard.rawValue

    private var widgetDensity: HomeWidgetDensity {
        HomeWidgetDensity(rawValue: widgetDensityRaw) ?? .standard
    }

    private var sub: Color { Color.appSubtextStrong(session.isDarkMode) }

    private var expiringCount: Int { kitchenMetrics.expiringSoonCount }
    private var mealsAvailable: Int { kitchenMetrics.mealsReady }
    private var metricsRevision: String {
        "\(store.inventoryRevision):\(store.groceryRevision):\(store.recipeRevision):\(store.planRevision)"
    }
    private var readyToCookRevision: String {
        "\(store.inventoryRevision):\(store.recipeRevision)"
    }
    private var usesReferencePhoneGeometry: Bool {
        // The old 393-point reference branch forced 8–11 point labels, fixed card
        // heights, and fixed internal columns on every ordinary Pro-sized phone.
        // Keep it retired: the adaptive branch preserves widget order and uses
        // ViewThatFits while allowing every card and button to grow vertically.
        false
    }
    private var homeHorizontalPadding: CGFloat {
        usesReferencePhoneGeometry ? 20 : layoutMetrics.horizontalPadding
    }

    var body: some View {
        StockedShell {
            VStack(alignment: .leading, spacing: 0) {
                referenceHero
                    .padding(.bottom, usesReferencePhoneGeometry ? 10 : (isWideHomeCanvas ? 6 : 10))
                    .onTapGesture {
                        // A plain tap on the non-interactive hero is the safe,
                        // discoverable way out without stealing taps from widget
                        // menus, resize handles, or the Done button.
                        if editMode { exitEditMode() }
                    }
                if editMode {
                    HStack(spacing: 12) {
                        Menu {
                            Section("Layout presets") {
                                ForEach(HomeWidgetPreset.allCases) { preset in
                                    Button(preset.title, systemImage: preset.icon) { applyPreset(preset) }
                                }
                            }
                            Section("Widget spacing") {
                                ForEach(HomeWidgetDensity.allCases) { density in
                                    Button(density.rawValue, systemImage: widgetDensity == density ? "checkmark" : "circle") {
                                        widgetDensityRaw = density.rawValue
                                    }
                                }
                            }
                            Button("Widget Theme Gallery", systemImage: "paintpalette") {
                                activeHomeSheet = .widgetThemeGallery
                            }
                            Button("Reset Home layout", systemImage: "arrow.counterclockwise") { resetHomeLayout() }
                        } label: {
                            Label("Layouts", systemImage: "rectangle.3.group")
                                .font(.stockedSystem(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(Color.stockedGold)
                        Spacer(minLength: 8)
                        Button("Done") { exitEditMode() }
                            .font(.stockedSystem(size: usesReferencePhoneGeometry ? 11 : 15, weight: .bold))
                            .foregroundStyle(Color.stockedGold)
                    }
                    .padding(.bottom, usesReferencePhoneGeometry ? 6 : 10)
                    if let recommendation = layoutSizeRecommendation {
                        layoutRecommendationBanner(recommendation)
                            .padding(.bottom, 8)
                    }
                }
                homeWidgetBoard
                Spacer(minLength: 12)
            }
            .stockedSnapTargetLayout()
            .frame(maxWidth: layoutMetrics.readableContentWidth)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, homeHorizontalPadding)
            .navigationDestination(isPresented: $goExpiringList) { ExpiringSoonListView() }
            .task(id: metricsRevision) {
                // Let the first frame render before deriving recipe/inventory metrics.
                // Large restored kitchens previously repeated these passes many times
                // during Home's initial body evaluation and could block the main thread.
                await Task.yield()
                kitchenMetrics = store.lightweightMetrics
                widgetsLastUpdated = Date()
            }
            .task(id: readyToCookRevision) {
                await Task.yield()
                let recipes = store.userRecipes
                let inventory = store.inventoryItems
                let worker = Task.detached(priority: .utility) {
                    HomeReadyToCookPolicy.picks(
                        recipes: recipes,
                        inventory: inventory,
                        limit: 3
                    )
                }
                let picks = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                readyToCookPicks = picks
            }
            .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
                goExpiringList = false
                if editMode { exitEditMode() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .stockedOpenHomeWidgets)) { _ in
                activeHomeSheet = .widgetGallery
            }
            .sheet(item: $activeHomeSheet) { sheet in
                switch sheet {
                case .quickUpdate:   QuickUpdateSheet().environment(session)
                case .activityFeed:  ActivityFeedSheet().environment(session)
                case .widgetGallery: widgetGallerySheet
                case .widgetThemeGallery: HomeWidgetThemeGallery().environment(session)
                }
            }
        }
        .confirmationDialog(actionMenuTitle, isPresented: actionMenuPresented, titleVisibility: .visible) {
            if let menu = activeActionMenu { actionMenuButtons(menu) }
        }
        .background {
            OneFingerWidgetLongPressCatcher { enterEditMode() }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .coachmarks(page: .home, steps: HomeCoachmarks.steps)
    }

    private var referenceHero: some View {
        Group {
            if usesReferencePhoneGeometry {
                ZStack(alignment: .topLeading) {
                    StockedGreeting()
                        .offset(y: 1)

                    referenceHeroCopy
                        .frame(width: 210, alignment: .leading)
                        .offset(y: 21)

                    StockedKitchenArtwork(asset: "home_kitchen_still_life")
                        .frame(width: 172, height: 120, alignment: .bottomTrailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(x: 8, y: 15)
                        .accessibilityHidden(true)
                }
                .frame(height: 124, alignment: .top)
            } else {
                VStack(alignment: .leading, spacing: isWideHomeCanvas ? 8 : 12) {
                    StockedGreeting()
                    referenceHeroCopy
                    HStack(alignment: .bottom, spacing: isWideHomeCanvas ? 20 : 12) {
                        referenceStockLevel
                            .layoutPriority(1)
                        referenceHeroArtwork
                            .fixedSize()
                    }
                }
            }
        }
        .coachmarkAnchor("home.greeting")
    }

    private var referenceHeroArtwork: some View {
        StockedKitchenArtwork(asset: "home_kitchen_still_life")
            .frame(
                width: layoutMetrics.homeHeroArtworkWidth,
                height: isWideHomeCanvas ? 170 : 190,
                alignment: .bottom
            )
            .accessibilityHidden(true)
    }

    private var isWideHomeCanvas: Bool {
        layoutMetrics.contentWidth >= 700
    }

    private var referenceHeroCopy: some View {
        VStack(alignment: .leading, spacing: usesReferencePhoneGeometry ? 6 : 12) {
            Text(kitchenMetrics.stockPercent >= 80 ? "Your kitchen is\nin good shape." : "Let’s refresh\nyour kitchen.")
                .font(usesReferencePhoneGeometry
                      ? .stockedSerif(29, weight: .bold, relativeTo: .title)
                      : .stockedSerif(34, weight: .bold, relativeTo: .largeTitle))
                .foregroundStyle(session.themeTextColor)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(usesReferencePhoneGeometry ? -5 : 0)

                .fixedSize(horizontal: false, vertical: true)
            Text(kitchenMetrics.stockPercent >= 80
                 ? "Everything you need is already inside of your kitchen"
                 : "A few smart updates will unlock more meals and keep the week moving.")
                .font(usesReferencePhoneGeometry ? .stockedSans(11.5) : .stocked(.body))
                .foregroundStyle(session.themeTextColor.opacity(0.76))

                .lineSpacing(usesReferencePhoneGeometry ? 1 : 0)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var referenceStockLevel: some View {
        Button {
            NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.stats)
        } label: {
            VStack(alignment: .leading, spacing: isWideHomeCanvas ? 14 : 10) {
                referenceStockIdentity
                Rectangle()
                    .fill(session.themeTextColor.opacity(0.18))
                    .frame(height: 1)
                referenceStockSummary
            }
            .padding(homeWidgetContentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(session.themeCardColor)
            .clipShape(RoundedRectangle(cornerRadius: isWideHomeCanvas ? 24 : 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .a11yButton("Stock level \(kitchenMetrics.stockPercent) percent. \(stockLabel)")
    }

    private var referenceStockIdentity: some View {
        lockedWidgetRow {
            referenceStockIcon
        } content: {
            referenceStockValue
        }
    }

    private var referenceStockIcon: some View {
        let iconSize = layoutMetrics.homeStockLevelIllustrationSize
        return ZStack {
            RoundedRectangle(cornerRadius: isWideHomeCanvas ? 18 : 14, style: .continuous).fill(Color.stockedCharcoal)
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.stockedSystem(size: iconSize.width * 0.58, weight: .medium))
                .foregroundStyle(Color.stockedGold)
        }
        .frame(width: iconSize.width, height: iconSize.height)
    }

    private var referenceStockValue: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Stock Level")
                .font(.stockedSystem(size: isWideHomeCanvas ? 14 : 11.5, weight: .semibold))
                .foregroundStyle(session.themeTextColor.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            fittedWidgetValue(
                "\(kitchenMetrics.stockPercent)%",
                preferredSize: isWideHomeCanvas ? 36 : 29
            )
                .foregroundStyle(session.themeTextColor)
            Text(stockLabel)
                .font(.stockedSystem(size: isWideHomeCanvas ? 14 : 11, weight: .semibold))
                .foregroundStyle(Color.stockedGold)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    private var referenceStockSummary: some View {
        VStack(alignment: .leading, spacing: isWideHomeCanvas ? 7 : 5) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(lowStockCount == 0 ? "You’re all set!" : "A few things are running low")
                        .font(.stockedSystem(size: isWideHomeCanvas ? 16 : 12.5, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)


                    Text(lowStockCount == 0 ? "Nothing running low right now. Keep cooking."
                                            : "\(lowStockCount) item\(lowStockCount == 1 ? "" : "s") could use attention.")
                        .font(.stockedSystem(size: isWideHomeCanvas ? 14 : 11.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)

                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.stockedSystem(size: isWideHomeCanvas ? 14 : 11, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
            }
            ProgressView(value: Double(kitchenMetrics.stockPercent), total: 100)
                .tint(Color.stockedGold)
                .scaleEffect(x: 1, y: isWideHomeCanvas ? 1 : 0.8, anchor: .center)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var referenceActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Keep your kitchen moving")
                    .font(usesReferencePhoneGeometry
                          ? .stockedSerif(13, weight: .bold, relativeTo: .headline)
                          : .stockedSerif(22, weight: .bold, relativeTo: .title2))
                    .foregroundStyle(session.themeTextColor)


                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Edit widgets") { enterEditMode() }
                    .font(.stockedSystem(size: usesReferencePhoneGeometry ? 9 : 15, weight: .semibold))
                    .foregroundStyle(Color.stockedGold)
            }
            .frame(minHeight: usesReferencePhoneGeometry ? 20 : nil)
            .padding(.bottom, usesReferencePhoneGeometry ? 6 : 10)

            HStack(alignment: .center, spacing: layoutMetrics.homeWidgetRowSpacing) {
                referencePrimaryAction
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                referenceActionIllustration
                    .fixedSize()
            }
            .frame(minHeight: usesReferencePhoneGeometry ? 77 : nil)
            .padding(.bottom, usesReferencePhoneGeometry ? 6 : 6)

            // Placement follows available width only. Dynamic Type changes the
            // shared row height, never the number of columns.
            if layoutMetrics.contentWidth >= 360 {
                StockedEqualHeightRow(spacing: 8) {
                    referenceActionButtons
                }
            } else {
                VStack(spacing: 8) { referenceActionButtons }
            }
        }
    }

    private var referenceActionIllustration: some View {
        // The bag is a tall cutout paired with the primary Scan card. Give it a
        // matching vertical footprint; shared widget geometry still shrinks its
        // width first on narrow canvases so it cannot crowd the action copy.
        adaptiveWidgetArtwork("home_grocery_bag", preferredWidth: 118, preferredHeight: 132)
    }

    private var actionMenuTitle: String {
        switch activeActionMenu {
        case .scan: return "What would you like to scan?"
        case .add: return "What would you like to add?"
        case .log: return "What would you like to log?"
        case nil: return "Kitchen action"
        }
    }

    private var actionMenuPresented: Binding<Bool> {
        Binding(
            get: { activeActionMenu != nil },
            set: { if !$0 { activeActionMenu = nil } }
        )
    }

    @ViewBuilder
    private func actionMenuButtons(_ menu: HomeActionMenu) -> some View {
        switch menu {
        case .scan:
            Button("Scan Receipt") { postQuick(.scanReceipt) }
            Button("Scan Barcode") { postQuick(.scanBarcode) }
        case .add:
            Button("Add Inventory Item") { postQuick(.addItems) }
            Button("Quick Add or Update") { activeHomeSheet = .quickUpdate }
            Button("Add Grocery Item") { switchTab(.grocery) }
            Button("Add Recipe") {
                session.pendingRecipeImport = true
                switchTab(.recipes)
            }
        case .log:
            Button("Past Meals") { switchTab(.recipes) }
            Button("Log Cooked Meal") { switchTab(.cook) }
            Button("Log Items Used Recently") { activeHomeSheet = .quickUpdate }
        }
        Button("Cancel", role: .cancel) {}
    }

    private func postQuick(_ action: DrawerQuickAction) {
        NotificationCenter.default.post(name: .stockedQuickAction, object: action)
    }

    private func switchTab(_ tab: StockedTab) {
        NotificationCenter.default.post(name: .stockedSwitchTab, object: tab)
    }

    @ViewBuilder
    private var referenceActionButtons: some View {
        referenceCompactAction("Add", "Kitchen or recipe", "plus") {
            activeActionMenu = .add
        }
        referenceCompactAction("Log", "Cooked or used", "clock.arrow.circlepath") {
            activeActionMenu = .log
        }
    }

    private var referencePrimaryAction: some View {
        Button {
            activeActionMenu = .scan
        } label: {
            HStack(spacing: usesReferencePhoneGeometry ? 10 : 16) {
                referenceDarkIcon("doc.text.viewfinder")
                VStack(alignment: .leading, spacing: usesReferencePhoneGeometry ? 2 : 4) {
                    Text("Scan")
                        .font(usesReferencePhoneGeometry
                              ? .stockedSerif(13, weight: .bold, relativeTo: .headline)
                              : .stockedSerif(20, weight: .bold, relativeTo: .title3))
                        .fixedSize(horizontal: false, vertical: true)

                        .allowsTightening(true)
                    Text("Receipt or barcode")
                        .font(.stockedSystem(size: usesReferencePhoneGeometry ? 10.5 : 15))
                        .opacity(0.72)
                }
                Spacer()
                Circle().fill(Color.white.opacity(0.08))
                    .frame(
                        width: adaptiveWidgetSquareSide(usesReferencePhoneGeometry ? 28 : 48),
                        height: adaptiveWidgetSquareSide(usesReferencePhoneGeometry ? 28 : 48)
                    )
                    .overlay(Image(systemName: "chevron.right")
                        .font(.stockedSystem(size: usesReferencePhoneGeometry ? 11 : 15, weight: .semibold))
                        .foregroundStyle(Color.stockedGold))
            }
            .foregroundStyle(Color.stockedWhite)
            .padding(.horizontal, usesReferencePhoneGeometry ? 14 : layoutMetrics.homeWidgetContentPadding)
            .frame(maxWidth: .infinity,
                   minHeight: usesReferencePhoneGeometry ? 66 : 112)
            .background(Color.stockedCharcoal)
            .clipShape(RoundedRectangle(cornerRadius: usesReferencePhoneGeometry ? 12 : 24, style: .continuous))
        }.buttonStyle(.plain)
    }

    private func referenceCompactAction(_ title: String, _ subtitle: String, _ icon: String,
                                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: max(8, layoutMetrics.homeWidgetRowSpacing * 0.6)) {
                referenceDarkIcon(icon, compact: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.stockedSystem(size: usesReferencePhoneGeometry ? 8.8 : 12, weight: .bold))
                        .foregroundStyle(session.themeTextColor)
                        .fixedSize(horizontal: true, vertical: false)
                        .allowsTightening(true)
                    Text(subtitle)
                        .font(.stockedSystem(size: usesReferencePhoneGeometry ? 8.5 : 10))
                        .foregroundStyle(session.themeTextColor.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)

                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.stockedSystem(size: usesReferencePhoneGeometry ? 8 : 10, weight: .bold))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
            }
            .padding(.horizontal, min(layoutMetrics.homeWidgetContentPadding, 14))
            .padding(.vertical, max(8, 6 * layoutMetrics.textScale))
            .frame(maxWidth: .infinity,
                   minHeight: max(70, layoutMetrics.minimumControlHeight),
                   alignment: .leading)
            .background(session.themeCardColor)
            .clipShape(RoundedRectangle(cornerRadius: layoutMetrics.controlCornerRadius, style: .continuous))
        }.buttonStyle(.plain)
    }

    private func referenceDarkIcon(_ icon: String, compact: Bool = false) -> some View {
        let base: CGFloat = usesReferencePhoneGeometry ? (compact ? 28 : 40) : (compact ? (layoutMetrics.width < 390 ? 34 : 40) : 58)
        let side = min(base * layoutMetrics.homeWidgetWidthScale, compact ? 50 : 72)
        return Circle().fill(Color.stockedCharcoal).frame(width: side, height: side)
            .overlay(Image(systemName: icon)
                .font(.stockedSystem(size: usesReferencePhoneGeometry ? (compact ? 12 : 17) : (compact ? 16 : 22), weight: .medium))
                .foregroundStyle(Color.stockedGold))
    }

    private var referenceUseItSoon: some View {
        VStack(alignment: .leading, spacing: usesReferencePhoneGeometry ? 7 : 8) {
            HStack {
                Text("Use It Soon")
                    .font(usesReferencePhoneGeometry
                          ? .stockedSerif(13, weight: .bold, relativeTo: .headline)
                          : .stockedSerif(22, weight: .bold, relativeTo: .title2))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                Button("View All") { goExpiringList = true }
                    .font(.stockedSystem(size: usesReferencePhoneGeometry ? 11 : 15, weight: .semibold))
                    .foregroundStyle(Color.stockedGold)
                Image(systemName: "chevron.right")
                    .font(.stockedSystem(size: usesReferencePhoneGeometry ? 9 : 12, weight: .bold))
                    .foregroundStyle(Color.stockedGold)
            }
            .frame(height: usesReferencePhoneGeometry ? 20 : nil)
            Button { goExpiringList = true } label: {
                lockedWidgetRow(spacing: usesReferencePhoneGeometry ? 10 : layoutMetrics.homeWidgetRowSpacing) {
                    adaptiveWidgetArtwork(
                        "home_produce_crate",
                        preferredWidth: usesReferencePhoneGeometry ? 100 : 150,
                        preferredHeight: usesReferencePhoneGeometry ? 72 : 120
                    )
                        .scaleEffect(usesReferencePhoneGeometry ? 1.12 : 1)
                } content: {
                    VStack(alignment: .leading, spacing: usesReferencePhoneGeometry ? 3 : 8) {
                        Text(expiringCount == 0 ? "Nothing expiring soon" : "\(expiringCount) item\(expiringCount == 1 ? "" : "s") expiring soon")
                            .font(usesReferencePhoneGeometry
                                  ? .stockedSerif(14.25, weight: .bold, relativeTo: .headline)
                                  : .stockedSerif(17, weight: .bold, relativeTo: .headline))
                            .foregroundStyle(session.themeTextColor)


                            .allowsTightening(true)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(expiringCount == 0 ? "You’re in good shape!" : "Use these first to waste less.")
                            .font(.stockedSystem(size: usesReferencePhoneGeometry ? 11 : 17))
                            .foregroundStyle(session.themeTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(expiringCount == 0 ? "We’ll let you know when something is close to expiring."
                                                : "Tap to see what needs attention.")
                            .font(.stockedSystem(size: usesReferencePhoneGeometry ? 10 : 15))
                            .foregroundStyle(session.themeTextColor.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } accessory: {
                    if expiringCount == 0 {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.stockedSystem(size: usesReferencePhoneGeometry ? 15 : 21, weight: .semibold))
                            .foregroundStyle(Color.stockedGreen)
                            .frame(
                                width: adaptiveWidgetSquareSide(usesReferencePhoneGeometry ? 24 : 30),
                                height: adaptiveWidgetSquareSide(usesReferencePhoneGeometry ? 24 : 30)
                            )
                            .accessibilityHidden(true)
                    } else {
                        Circle().fill(session.themeTextColor.opacity(0.06))
                            .frame(
                                width: adaptiveWidgetSquareSide(usesReferencePhoneGeometry ? 32 : 40),
                                height: adaptiveWidgetSquareSide(usesReferencePhoneGeometry ? 32 : 40)
                            )
                            .overlay(Image(systemName: "chevron.right")
                                .font(.stockedSystem(size: usesReferencePhoneGeometry ? 12 : 14, weight: .semibold))
                                .foregroundStyle(session.themeTextColor))
                    }
                }
                .padding(.horizontal, layoutMetrics.homeWidgetContentPadding)
                .frame(maxWidth: .infinity,
                       minHeight: usesReferencePhoneGeometry ? 90 : 154,
                       alignment: .leading)
                .background(session.themeCardColor)
                .clipShape(RoundedRectangle(cornerRadius: usesReferencePhoneGeometry ? 14 : 24, style: .continuous))
            }.buttonStyle(.plain)
        }
    }

    private var referenceSnapshot: some View {
        Button {
            NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.stats)
        } label: {
            VStack(alignment: .leading, spacing: usesReferencePhoneGeometry ? 6 : 16) {
                HStack {
                    Text("Kitchen Snapshot")
                        .font(.stockedSystem(size: usesReferencePhoneGeometry ? 11 : 17, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.stockedSystem(size: usesReferencePhoneGeometry ? 10 : 15, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                }
                HStack(spacing: usesReferencePhoneGeometry ? 6 : 12) {
                    if usesReferencePhoneGeometry {
                        snapshotMetric("refrigerator", "\(store.inventoryItems.count)", "Items in inventory", "Well stocked")
                        snapshotDivider
                        snapshotMetric("bag", "\(lowStockCount)", "Low stock items", "You’re good")
                        snapshotDivider
                        snapshotMetric("list.clipboard", "\(groceryToBuy)", "On grocery list", "Ready to shop")
                    } else {
                        adaptiveSnapshotMetrics
                    }
                }
            }
            .padding(usesReferencePhoneGeometry ? 10 : layoutMetrics.homeWidgetContentPadding)
            .frame(maxWidth: .infinity,
                   minHeight: usesReferencePhoneGeometry ? 95 : nil,
                   alignment: .topLeading)
            .background(Color.stockedCharcoal)
            .clipShape(RoundedRectangle(cornerRadius: usesReferencePhoneGeometry ? 14 : 24, style: .continuous))
        }.buttonStyle(.plain)
    }

    private var adaptiveSnapshotMetrics: some View {
        LazyVGrid(columns: layoutMetrics.gridColumns(minimum: 150, maximum: 3, spacing: 16),
                  alignment: .leading,
                  spacing: 16) {
            snapshotMetric("refrigerator", "\(store.inventoryItems.count)", "Items in inventory", "Well stocked")
            snapshotMetric("bag", "\(lowStockCount)", "Low stock items", "You’re good")
            snapshotMetric("list.clipboard", "\(groceryToBuy)", "On grocery list", "Ready to shop")
        }
    }

    private func snapshotMetric(_ icon: String, _ value: String, _ label: String, _ status: String) -> some View {
        let iconSide = adaptiveWidgetSquareSide(usesReferencePhoneGeometry ? 32 : 46)
        return VStack(alignment: .leading, spacing: usesReferencePhoneGeometry ? 1 : 4) {
            HStack(spacing: usesReferencePhoneGeometry ? 6 : 10) {
                Circle().fill(Color.white.opacity(0.07))
                    .frame(width: iconSide, height: iconSide)
                    .overlay(Image(systemName: icon)
                        .font(.stockedSystem(size: usesReferencePhoneGeometry ? 13 : 17))
                        .foregroundStyle(Color.stockedGold))
                fittedWidgetValue(value, preferredSize: usesReferencePhoneGeometry ? 19 : 28)
                    .foregroundStyle(Color.stockedWhite)
            }
            Text(label)
                .font(.stockedSystem(size: usesReferencePhoneGeometry ? 8.5 : 12))
                .foregroundStyle(Color.stockedWhite)
                .fixedSize(horizontal: false, vertical: true)

                .fixedSize(horizontal: false, vertical: true)
            Text(status)
                .font(.stockedSystem(size: usesReferencePhoneGeometry ? 8.5 : 12, weight: .semibold))
                .foregroundStyle(Color.stockedGold)
                .fixedSize(horizontal: false, vertical: true)

                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var snapshotDivider: some View {
        Rectangle().fill(Color.white.opacity(0.18))
            .frame(width: 1, height: usesReferencePhoneGeometry ? 48 : 84)
    }

    private func enterEditMode() {
        guard !editMode else { return }
        HapticManager.medium()
        UsageMetrics.shared.record(.homeEditModeEntered)
        motion.animate(.standard, intent: .spatial) { editMode = true }
    }

    // ── Action Center (extracted so every widget is a uniform view) ──
    private var actionCenterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Action Center")
                .scaledFont(16, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
            LazyVGrid(columns: layoutMetrics.gridColumns(minimum: 150, maximum: 2, spacing: 10), spacing: 10) {
                quickAction(icon: "viewfinder", title: "Scan Receipt", caption: "Add items fast") {
                    NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.scanReceipt)
                }
                quickAction(icon: "barcode.viewfinder", title: "Scan Barcode", caption: "Look up a product") {
                    NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.scanBarcode)
                }
                quickAction(icon: "plus", title: "Add Item", caption: "Add by hand") {
                    NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.addItems)
                }
                quickAction(icon: "scribble.variable", title: "Quick Update", caption: "Tell me what changed") {
                    activeHomeSheet = .quickUpdate
                }
            }
        }
    }

    // MARK: - #252 Widget board

    /// Stock Level is an essential, pinned part of the hero's left column beside
    /// its illustration, so a legacy saved layout must never duplicate it below.
    private var visibleWidgets: [HomeWidget] { layout.filter { $0 != .stockLevel } }
    /// The master Home mockup already represents the essential widgets with its
    /// purpose-built Stock Level, action, Use It Soon, and snapshot sections. Any
    /// additional gallery choices still need a real place in that layout; the old
    /// customizable board was accidentally dropped when Home adopted the reference
    /// design, which left successful gallery additions invisible.
    private var removedWidgets: [HomeWidget] {
        HomeWidget.allCases.filter { $0 != .stockLevel && !layout.contains($0) }
    }

    @ViewBuilder
    private var homeWidgetBoard: some View {
        HomeWidgetGridLayout(
            spacing: max(4, layoutMetrics.homeWidgetGridSpacing * widgetDensity.spacingScale),
            rowUnit: layoutMetrics.homeWidgetGridRowUnit
        ) {
            ForEach(visibleWidgets, id: \.self) { widget in
                editableBoardWidget(widget) {
                    homeWidgetContent(widget)
                }
                .homeWidgetGridFootprint(gridFootprint(for: widget))
            }
            if editMode {
                widgetRemovalTarget
                    .homeWidgetGridFootprint(.init(columns: 4, rows: 2))
                addWidgetTile
                    .homeWidgetGridFootprint(.init(columns: 4, rows: 2))
            } else if visibleWidgets.isEmpty {
                emptyBoardHint
                    .homeWidgetGridFootprint(.init(columns: 4, rows: 2))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func homeWidgetContent(_ widget: HomeWidget) -> some View {
        switch widget {
        case .stockLevel: referenceStockLevel
        case .actionCenter: referenceActions
        case .useItSoon: referenceUseItSoon
        default: widgetView(widget)
        }
    }

    private func editableBoardWidget<Content: View>(
        _ widget: HomeWidget,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            // Reference widgets also contain navigation/action buttons. The edit
            // controls remain interactive because they are added by the overlay
            // below, after hit testing is disabled for the widget content itself.
            .allowsHitTesting(!editMode)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                if editMode { removeBadge(widget).offset(x: -7, y: -7) }
            }
            .modifier(JiggleEffect(active: editMode))
            .contentShape(Rectangle())
            .if(editMode) { view in
                view
                    .onDrag {
                        dragStartLayout = layout
                        draggingWidget = widget
                        return NSItemProvider(object: widget.rawValue as NSString)
                    }
                    .onDrop(of: [UTType.text], delegate: WidgetDropDelegate(
                        item: widget,
                        layout: $layout,
                        dragging: $draggingWidget,
                        dropTarget: $dropTargetWidget,
                        onCommit: commitWidgetReorder
                    ))
            }
            .overlay(alignment: .bottomTrailing) {
                if editMode && widget.supportsManualResize {
                    widgetResizeHandle(widget)
                        .offset(x: 7, y: 7)
                }
            }
            .overlay(alignment: .topTrailing) {
                if editMode { widgetEditMenu(widget).offset(x: 7, y: -7) }
            }
            .overlay(alignment: .bottomLeading) {
                if (resizingWidget == widget || previewingSizeRecommendation == widget), let preview = resizePreviewFootprint {
                    Label(preview.storageValue, systemImage: "rectangle.resize")
                        .scaledFont(11, weight: .bold)
                        .foregroundStyle(Color.stockedWhite)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Color.widgetFocus(dark))
                        .clipShape(Capsule())
                        .offset(x: 8, y: -8)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if editMode && draggingWidget != nil && draggingWidget != widget {
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                        .stroke(
                            dropTargetWidget == widget ? Color.stockedGold : Color.stockedGreen.opacity(0.45),
                            style: StrokeStyle(lineWidth: dropTargetWidget == widget ? 3 : 1, dash: [6, 4])
                        )
                        .background((dropTargetWidget == widget ? Color.stockedGold : Color.stockedGreen).opacity(0.06))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .if(editMode) { view in
                view
                    .accessibilityAction(named: "Move earlier") { moveWidget(widget, by: -1) }
                    .accessibilityAction(named: "Move later") { moveWidget(widget, by: 1) }
                    .accessibilityAction(named: "Make larger") { growWidget(widget) }
                    .accessibilityAction(named: "Make smaller") { shrinkWidget(widget) }
                    .accessibilityAction(named: "Remove widget") { removeWidget(widget) }
            }
    }

    private func widgetEditMenu(_ widget: HomeWidget) -> some View {
        Menu {
            Section("Position") {
                Button("Move earlier", systemImage: "arrow.up") { moveWidget(widget, by: -1) }
                    .disabled(layout.first == widget)
                Button("Move later", systemImage: "arrow.down") { moveWidget(widget, by: 1) }
                    .disabled(layout.last == widget)
            }
            Section("Size") {
                Button("Make smaller", systemImage: "arrow.down.right.and.arrow.up.left") { shrinkWidget(widget) }
                    .disabled(gridFootprint(for: widget) == widget.allowedGridFootprints.first)
                Button("Make larger", systemImage: "arrow.up.left.and.arrow.down.right") { growWidget(widget) }
                    .disabled(gridFootprint(for: widget) == widget.allowedGridFootprints.last)
                Text(widget.sizeAvailabilityDescription(for: gridFootprint(for: widget)))
            }
            Button("Remove Widget", systemImage: "minus.circle", role: .destructive) { removeWidget(widget) }
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(13, weight: .bold)
                .foregroundStyle(Color.widgetPrimaryText(dark))
                .frame(width: 30, height: 30)
                .background(Color.widgetSurface(dark, increasedContrast: colorSchemeContrast == .increased,
                                                reduceTransparency: reduceTransparency))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Edit \(widget.title) widget")
    }

    private func gridFootprint(for widget: HomeWidget) -> HomeWidgetGridFootprint {
        let requested = widget.resolvedGridFootprint(widgetFootprints[widget] ?? widget.gridFootprint)
        // Expanded list widgets collapse when there is no additional content to
        // reveal, but retain the saved preference and grow again as data arrives.
        if widget == .readyToCook,
           readyToCookPicks.prefix(2).count < 2 {
            return .init(columns: 4, rows: 2)
        }
        if widget == .whatsNew, newsRows.count < 2 {
            return .init(columns: 4, rows: 2)
        }
        return requested
    }

    private var layoutSizeRecommendation: (widget: HomeWidget, footprint: HomeWidgetGridFootprint, reason: String)? {
        guard smartWidgetSuggestions else { return nil }
        if layout.contains(.groceryCount), groceryToBuy > 0,
           gridFootprint(for: .groceryCount).columns == 2,
           !dismissedSizeRecommendations.contains(.groceryCount) {
            return (.groceryCount, .init(columns: 4, rows: 2), "Show grocery items and check them off from Home.")
        }
        if layout.contains(.readyToCook),
           readyToCookPicks.prefix(2).count >= 2,
           gridFootprint(for: .readyToCook).rows == 2,
           !dismissedSizeRecommendations.contains(.readyToCook) {
            return (.readyToCook, .init(columns: 4, rows: 4), "Reveal more ready-to-cook recipe matches.")
        }
        if layout.contains(.whatsNew), newsRows.count >= 2,
           gridFootprint(for: .whatsNew).rows == 2,
           !dismissedSizeRecommendations.contains(.whatsNew) {
            return (.whatsNew, .init(columns: 4, rows: 4), "Reveal more recent kitchen activity.")
        }
        return nil
    }

    private func layoutRecommendationBanner(
        _ recommendation: (widget: HomeWidget, footprint: HomeWidgetGridFootprint, reason: String)
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Suggested size: \(recommendation.widget.title) \(recommendation.footprint.storageValue)",
                  systemImage: "sparkles")
                .scaledFont(13.5, weight: .bold)
                .foregroundStyle(widgetPrimaryText)
            Text(recommendation.reason).scaledFont(12).foregroundStyle(widgetSecondaryText)
            HStack {
                Button("Preview") {
                    previewingSizeRecommendation = recommendation.widget
                    resizePreviewFootprint = recommendation.footprint
                }
                Button("Apply") {
                    setWidgetFootprint(recommendation.footprint, for: recommendation.widget)
                    previewingSizeRecommendation = nil
                    resizePreviewFootprint = nil
                }.fontWeight(.semibold)
                Spacer()
                Button("Dismiss") {
                    dismissedSizeRecommendations.insert(recommendation.widget)
                    previewingSizeRecommendation = nil
                    resizePreviewFootprint = nil
                }
            }
            .scaledFont(12.5)
            .foregroundStyle(Color.widgetFocus(dark))
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(widgetBackground)
    }

    /// A dedicated handle keeps resize drags separate from whole-card reorder drags.
    /// Changes are quantized to valid two- or four-track footprints, then the custom
    /// layout repacks every neighbor from the shared occupancy map with no overlap.
    private func widgetResizeHandle(_ widget: HomeWidget) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .scaledFont(12, weight: .bold)
            .foregroundStyle(Color.stockedWhite)
            .frame(width: 30, height: 30)
            .background(Color.stockedGold)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in prepareWidgetResize(widget, translation: value.translation) }
                    .onEnded { value in
                        // Project the release velocity to the same magnetic size
                        // grid used during the drag. A quick intentional flick can
                        // reach the next valid footprint; a slow release stays at
                        // the previewed footprint. Unsupported sizes remain impossible.
                        commitWidgetResize(widget, translation: value.predictedEndTranslation)
                    }
            )
            .onTapGesture { cycleWidgetFootprint(widget) }
            .accessibilityLabel("Resize \(widget.title) widget")
            .accessibilityHint(widget.resizeAccessibilityHint)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: growWidget(widget)
                case .decrement: shrinkWidget(widget)
                @unknown default: break
                }
            }
    }

    private func prepareWidgetResize(_ widget: HomeWidget, translation: CGSize) {
        if resizingWidget != widget {
            resizingWidget = widget
            resizeStartFootprint = gridFootprint(for: widget)
        }
        resizePreviewFootprint = widget.resizedGridFootprint(
            from: resizeStartFootprint ?? gridFootprint(for: widget),
            translation: translation
        )
    }

    private func commitWidgetResize(_ widget: HomeWidget, translation: CGSize) {
        let start = resizeStartFootprint ?? gridFootprint(for: widget)
        let target = widget.resizedGridFootprint(from: start, translation: translation)
        setWidgetFootprint(target, for: widget)
        resizingWidget = nil
        resizeStartFootprint = nil
        resizePreviewFootprint = nil
    }

    private func cycleWidgetFootprint(_ widget: HomeWidget) {
        let current = gridFootprint(for: widget)
        let sizes = widget.allowedGridFootprints
        let index = sizes.firstIndex(of: current) ?? -1
        setWidgetFootprint(sizes[(index + 1) % sizes.count], for: widget)
    }

    private func growWidget(_ widget: HomeWidget) {
        let current = gridFootprint(for: widget)
        let sizes = widget.allowedGridFootprints
        guard let index = sizes.firstIndex(of: current), index < sizes.index(before: sizes.endIndex) else {
            ToastCenter.shared.info(widget.sizeAvailabilityDescription(for: current)); return
        }
        setWidgetFootprint(sizes[index + 1], for: widget)
    }

    private func shrinkWidget(_ widget: HomeWidget) {
        let current = gridFootprint(for: widget)
        let sizes = widget.allowedGridFootprints
        guard let index = sizes.firstIndex(of: current), index > sizes.startIndex else {
            ToastCenter.shared.info(widget.sizeAvailabilityDescription(for: current)); return
        }
        setWidgetFootprint(sizes[index - 1], for: widget)
    }

    private func moveWidget(_ widget: HomeWidget, by offset: Int) {
        guard let current = layout.firstIndex(of: widget) else { return }
        let destination = min(max(layout.startIndex, current + offset), layout.index(before: layout.endIndex))
        guard destination != current else { return }
        let previous = boardSnapshot
        var updated = layout
        updated.remove(at: current)
        updated.insert(widget, at: destination)
        layout = updated
        HomeWidget.saveLayout(updated)
        HapticManager.select()
        offerUndo("Moved \(widget.title)", restoring: previous)
    }

    private func setWidgetFootprint(
        _ footprint: HomeWidgetGridFootprint,
        for widget: HomeWidget
    ) {
        let normalized = widget.resolvedGridFootprint(footprint)
        guard gridFootprint(for: widget) != normalized else { return }
        let previous = boardSnapshot
        var updatedFootprints = widgetFootprints
        updatedFootprints[widget] = normalized
        // Commit as one magnetic snap. Interpolating two complete occupancy maps
        // makes neighboring frames cross in flight even though both endpoints are
        // valid; an atomic assignment guarantees there is never an overlap frame.
        widgetFootprints = updatedFootprints
        HomeWidget.saveGridFootprints(updatedFootprints)
        HapticManager.light()
        offerUndo("Resized \(widget.title)", restoring: previous)
    }

    private func addWidget(_ widget: HomeWidget) {
        guard !layout.contains(widget) else { return }
        let previous = boardSnapshot
        let updatedLayout = layout + [widget]
        HapticManager.success()
        motion.animate(.standard, intent: .spatial) {
            layout = updatedLayout
        }
        // Persist the exact value assigned above. Saving the captured pre-animation
        // array could race the state update and lose the newly selected widget.
        HomeWidget.saveLayout(updatedLayout)
        UsageMetrics.shared.record(.widgetAdded, detail: widget.rawValue)
        offerUndo("Added \(widget.title)", restoring: previous)
        if HomeWidget.allCases.allSatisfy(updatedLayout.contains) {
            activeHomeSheet = nil
        }
    }

    @ViewBuilder
    private func widgetView(_ widget: HomeWidget) -> some View {
        switch widget {
        case .dailyBrief:    dailyBriefCard
        case .whatsNew:      whatsNewSection
        case .actionCenter:  actionCenterSection
        case .useItSoon:     useItSoonSection
        // ── #253 stat cards ──
        case .stockLevel:
            statWidget(.stockLevel, value: "\(store.stockPercent)%", sub: stockLabel, tint: .stockedGold) {
                NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.stats)
            }
        case .mealsReady:
            statWidget(.mealsReady, value: "\(mealsAvailable)", sub: mealsAvailable == 1 ? "meal you can cook" : "meals you can cook", tint: .stockedGreen) {
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.cook)
            }
        case .cookStreak:
            statWidget(.cookStreak, value: "\(session.cookStreak)", sub: session.cookStreak == 1 ? "day streak" : "day streak", tint: .stockedError) {
                NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.stats)
            }
        case .groceryCount:
            if gridFootprint(for: .groceryCount).columns == 4 {
                groceryChecklistWidget
            } else {
                statWidget(.groceryCount, value: "\(groceryToBuy)", sub: groceryToBuy == 1 ? "item to buy" : "items to buy", tint: .stockedGold) {
                    NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.grocery)
                }
            }
        case .nextRun:
            statWidget(.nextRun, value: store.groceryRunDays == 0 ? "Today" : "\(store.groceryRunDays)d", sub: store.groceryRunDays == 0 ? "grocery run" : "until grocery run", tint: .stockedInfo) {
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.grocery)
            }
        case .expiringCount:
            statWidget(.expiringCount, value: "\(expiringCount)", sub: expiringCount == 1 ? "expiring soon" : "expiring soon", tint: .stockedError) {
                goExpiringList = true
            }
        case .lowStock:
            statWidget(.lowStock, value: "\(lowStockCount)", sub: lowStockCount == 1 ? "running low" : "running low", tint: .stockedGold) {
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.inventory)
            }
        case .totalItems:
            statWidget(.totalItems, value: "\(store.inventoryItems.count)", sub: "items tracked", tint: .stockedGreen) {
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.inventory)
            }
        // ── #253 action shortcuts ──
        case .cookNow:
            actionWidget(.cookNow, tint: .stockedGold) {
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.cook)
            }
        case .discover:
            actionWidget(.discover, tint: .stockedInfo) {
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.recipes)
            }
        case .quickAdd:
            actionWidget(.quickAdd, tint: .stockedGreen) {
                NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.addItems)
            }
        case .scanReceiptW:
            actionWidget(.scanReceiptW, tint: .stockedGold) {
                NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.scanReceipt)
            }
        case .scanBarcodeW:
            actionWidget(.scanBarcodeW, tint: .stockedInfo) {
                NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.scanBarcode)
            }
        case .quickUpdateW:
            actionWidget(.quickUpdateW, tint: .stockedGreen) { activeHomeSheet = .quickUpdate }
        case .shoppingList:
            actionWidget(.shoppingList, tint: .stockedGold) {
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.grocery)
            }
        case .searchW:
            actionWidget(.searchW, tint: .stockedInfo) {
                NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.search)
            }
        // ── #253 richer cards ──
        case .readyToCook:   readyToCookWidget
        case .favorites:
            statWidget(.favorites, value: "\(favoriteCount)", sub: favoriteCount == 1 ? "favorite recipe" : "favorite recipes", tint: .stockedError) {
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.recipes)
            }
        case .plannedMeals:
            statWidget(.plannedMeals, value: "\(plannedCount)", sub: plannedCount == 1 ? "meal planned" : "meals planned", tint: .stockedGold) {
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.cook)
            }
        case .wasteSaved:    wasteTrackerWidget
        case .preferredStore: preferredStoreWidget
        case .tipOfDay:      tipWidget
        }
    }

    // Red "−" delete badge shown on each widget in edit mode.
    private func removeBadge(_ widget: HomeWidget) -> some View {
        Button {
            removeWidget(widget)
        } label: {
            ZStack {
                Circle().fill(Color.stockedCharcoal).frame(width: 24, height: 24)
                Image(systemName: "minus")
                    .scaledFont(12, weight: .heavy)
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(widget.title) widget")
    }

    private var widgetRemovalTarget: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .scaledFont(22, weight: .bold)
            Text("Drag here to remove")
                .scaledFont(15, weight: .bold, design: .serif)
        }
        .foregroundStyle(Color.stockedError)
        .frame(maxWidth: .infinity, minHeight: layoutMetrics.minimumControlHeight)
        .padding(.vertical, 8)
        .background(Color.stockedError.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                .stroke(Color.stockedError.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .onDrop(of: [UTType.text], delegate: WidgetRemovalDropDelegate(
            dragging: $draggingWidget,
            onRemove: removeWidget
        ))
        .accessibilityLabel("Remove widget drop target")
    }

    private func removeWidget(_ widget: HomeWidget) {
        let previous = boardSnapshot
        HapticManager.light()
        let updatedLayout = layout.filter { $0 != widget }
        motion.animate(.standard, intent: .spatial) {
            layout = updatedLayout
        }
        HomeWidget.saveLayout(updatedLayout)
        UsageMetrics.shared.record(.widgetRemoved, detail: widget.rawValue)
        offerUndo("Removed \(widget.title)", restoring: previous)
    }

    // Dashed "Add widgets" tile shown at the bottom in edit mode.
    private var addWidgetTile: some View {
        Button {
            if removedWidgets.isEmpty {
                // Nothing to add — gentle nudge instead of an empty sheet.
                HapticManager.light()
            } else {
                activeHomeSheet = .widgetGallery
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .scaledFont(20, weight: .semibold)
                    .foregroundStyle(removedWidgets.isEmpty ? session.themeTextColor.opacity(0.3) : Color.stockedGold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(removedWidgets.isEmpty ? "All widgets added" : "Add widgets")
                        .scaledFont(15, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text(removedWidgets.isEmpty ? "Remove one above to choose it again"
                                                : "\(removedWidgets.count) available")
                        .scaledFont(12)
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                }
                Spacer()
            }
            .padding(homeWidgetContentPadding)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(session.themeTextColor.opacity(0.25))
            )
        }
        .buttonStyle(.plain)
        .stockedInteractiveSurface()
        .a11yRow(removedWidgets.isEmpty ? "All widgets added" : "Add widgets")
        .disabled(removedWidgets.isEmpty)
    }

    // Shown only if the user has removed every widget and isn't editing.
    // #18 — first-run activation card. Shown on Home only while the kitchen is empty.
    private var gettingStartedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .scaledFont(18, weight: .semibold)
                    .foregroundStyle(Color.stockedGold)
                Text("Let's stock your kitchen")
                    .scaledFont(18, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
            }
            Text("Add a few items and Stocked instantly shows meals you can cook, what's expiring, and a smarter grocery list. Takes about a minute.")
                .scaledFont(13.5)
                .foregroundStyle(session.themeTextColor.opacity(0.6))

            // Primary: stock common staples in one tap.
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
                    Image(systemName: "plus.circle.fill").scaledFont(15, weight: .semibold)
                    Text("Stock \(StarterStaples.all.count) common staples")
                        .scaledFont(15, weight: .semibold, design: .serif)
                }
                .foregroundStyle(Color.stockedWhite)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.stockedCharcoal)
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }
            .buttonStyle(.plain)

            // Secondary: scan a receipt or barcode (reuses Action Center routing).
            StockedEqualHeightRow(spacing: 10) { gettingStartedActions }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(session.themeCardColor)
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
        .overlay {
            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                .stroke(session.themeContrastAccent.opacity(0.30), lineWidth: 1.25)
        }
    }

    @ViewBuilder
    private var gettingStartedActions: some View {
        gettingStartedSecondary(title: "Scan Receipt", icon: "doc.text.viewfinder") {
            NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.scanReceipt)
        }
        gettingStartedSecondary(title: "Scan Barcode", icon: "barcode.viewfinder") {
            NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.scanBarcode)
        }
    }

    private func gettingStartedSecondary(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: { HapticManager.light(); action() }) {
            HStack(spacing: 7) {
                Image(systemName: icon).scaledFont(14, weight: .medium)
                Text(title)
                    .scaledFont(13.5, weight: .medium)
                    .stockedAdaptiveLabel(maxLines: 3, alignment: .center)
            }
            .foregroundStyle(session.themeTextColor.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(session.themeTextColor.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
        .stockedInteractiveSurface()
        .a11yButton(title)
    }

    private var emptyBoardHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .scaledFont(30)
                .foregroundStyle(session.themeTextColor.opacity(0.3))
            Text("Your Home is empty")
                .scaledFont(17, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
            Text("Touch and hold to add widgets back.")
                .scaledFont(13.5)
                .foregroundStyle(session.themeTextColor.opacity(0.55))
            Button {
                HapticManager.medium()
                motion.animate(.standard, intent: .spatial) { editMode = true }
                activeHomeSheet = .widgetGallery
            } label: {
                Text("Add widgets")
                    .scaledFont(14, weight: .semibold)
                    .foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Color.stockedCharcoal)
                    .clipShape(Capsule())
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // Gallery of removed widgets to add back.
    private var widgetGallerySheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Toggle(isOn: $smartWidgetSuggestions) {
                        Label("Suggest widgets from my kitchen", systemImage: "sparkles")
                            .scaledFont(14, weight: .semibold)
                    }
                    .tint(Color.stockedGold)
                    .padding(14)
                    .background(session.themeCardColor)
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                    .onChange(of: smartWidgetSuggestions) { _, value in
                        UserDefaults.standard.set(value, forKey: "stocked.smartWidgetSuggestions_v1")
                    }
                    if removedWidgets.isEmpty {
                        Text("Every widget is already on your Home screen.")
                            .scaledFont(14)
                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                            .padding(.top, 40)
                    } else {
                        ForEach(galleryWidgets, id: \.self) { widget in
                            Button {
                                addWidget(widget)
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.stockedGold.opacity(0.14))
                                            .frame(width: 46, height: 46)
                                        Image(systemName: widget.icon)
                                            .scaledFont(19, weight: .semibold)
                                            .foregroundStyle(Color.stockedGold)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(widget.title)
                                                .scaledFont(16, weight: .bold, design: .serif)
                                                .foregroundStyle(session.themeTextColor)
                                            if smartWidgetSuggestions && recommendedWidgets.contains(widget) {
                                                Text("Suggested")
                                                    .scaledFont(10, weight: .bold)
                                                    .foregroundStyle(Color.stockedGold)
                                            }
                                        }
                                        Text(widget.blurb)
                                            .scaledFont(12.5)
                                            .foregroundStyle(session.themeSecondaryText)
                                            .multilineTextAlignment(.leading)
                                        HStack(spacing: 6) {
                                            ForEach(widget.allowedGridFootprints, id: \.self) { size in
                                                Text(size.storageValue)
                                                    .scaledFont(10, weight: .semibold)
                                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                                    .background(Color.stockedGold.opacity(0.12))
                                                    .clipShape(Capsule())
                                            }
                                            Text(widget.densityPreview)
                                                .scaledFont(10)
                                                .foregroundStyle(session.themeSecondaryText)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .scaledFont(22)
                                        .foregroundStyle(Color.stockedGold)
                                }
                                .padding(16)
                                .background(session.themeCardColor)
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Add Widgets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { activeHomeSheet = nil }
                        .foregroundStyle(Color.stockedGold)
                }
            }
        }
        .environment(session)
    }

    private var recommendedWidgets: Set<HomeWidget> {
        var result: Set<HomeWidget> = []
        if expiringCount > 0 { result.insert(.useItSoon); result.insert(.readyToCook) }
        if lowStockCount > 0 { result.insert(.lowStock) }
        if groceryToBuy > 0 { result.insert(.groceryCount) }
        if mealsAvailable > 0 { result.insert(.mealsReady) }
        if result.isEmpty { result = [.quickAdd, .cookNow, .tipOfDay] }
        return result
    }

    private var galleryWidgets: [HomeWidget] {
        guard smartWidgetSuggestions else { return removedWidgets }
        return removedWidgets.sorted {
            let left = recommendedWidgets.contains($0)
            let right = recommendedWidgets.contains($1)
            return left == right ? $0.title < $1.title : left && !right
        }
    }

    private struct BoardSnapshot {
        let layout: [HomeWidget]
        let footprints: [HomeWidget: HomeWidgetGridFootprint]
    }

    private var boardSnapshot: BoardSnapshot { BoardSnapshot(layout: layout, footprints: widgetFootprints) }

    private func restoreBoard(_ snapshot: BoardSnapshot) {
        layout = snapshot.layout
        widgetFootprints = snapshot.footprints
        HomeWidget.saveLayout(layout)
        HomeWidget.saveGridFootprints(widgetFootprints)
    }

    private func offerUndo(_ message: String, restoring snapshot: BoardSnapshot) {
        ToastCenter.shared.undo(message) { restoreBoard(snapshot) }
    }

    private func commitWidgetReorder() {
        dropTargetWidget = nil
        guard let previousLayout = dragStartLayout else { HomeWidget.saveLayout(layout); return }
        dragStartLayout = nil
        guard previousLayout != layout else { return }
        HomeWidget.saveLayout(layout)
        UsageMetrics.shared.record(.widgetsReordered)
        offerUndo("Reordered widgets", restoring: BoardSnapshot(layout: previousLayout, footprints: widgetFootprints))
    }

    private func applyPreset(_ preset: HomeWidgetPreset) {
        let previous = boardSnapshot
        layout = preset.widgets
        widgetFootprints = [:]
        HomeWidget.saveLayout(layout)
        HomeWidget.saveGridFootprints(widgetFootprints)
        offerUndo("Applied \(preset.title)", restoring: previous)
    }

    private func resetHomeLayout() {
        let previous = boardSnapshot
        layout = HomeWidget.defaultLayout
        widgetFootprints = [:]
        HomeWidget.saveLayout(layout)
        HomeWidget.saveGridFootprints(widgetFootprints)
        offerUndo("Reset Home layout", restoring: previous)
    }

    private func exitEditMode() {
        draggingWidget = nil   // never leave a widget stuck at drag opacity / disabled
        dropTargetWidget = nil
        dragStartLayout = nil
        resizingWidget = nil
        resizeStartFootprint = nil
        resizePreviewFootprint = nil
        HomeWidget.saveGridFootprints(widgetFootprints)
        motion.animate(.standard, intent: .spatial) { editMode = false }
    }

    // MARK: - #253 Widget data + builders

    private var groceryToBuy: Int { kitchenMetrics.groceryToBuy }
    private var lowStockCount: Int { kitchenMetrics.lowStockCount }
    private var favoriteCount: Int { kitchenMetrics.favoriteRecipeCount }
    private var plannedCount: Int { kitchenMetrics.plannedMealCount }
    private var stockLabel: String { kitchenMetrics.stockStatusPhrase }
    private var homeWidgetContentPadding: CGFloat {
        max(10, layoutMetrics.homeWidgetContentPadding * widgetDensity.spacingScale)
    }
    private var widgetPrimaryText: Color { Color.widgetPrimaryText(dark) }
    private var widgetSecondaryText: Color { Color.widgetSecondaryText(dark) }

    private func widgetHeader(
        _ title: String,
        family: StockedWidgetThemeFamily,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(title, systemImage: family.icon)
                .scaledFont(16, weight: .bold, design: .serif)
                .foregroundStyle(widgetPrimaryText)
                .stockedAdaptiveLabel(maxLines: 2)
            Spacer(minLength: 6)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .scaledFont(12.5, weight: .semibold)
                    .foregroundStyle(family.accent(dark: dark))
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
            }
        }
    }

    private func widgetAccessory(tint: Color) -> some View {
        Image(systemName: "chevron.right")
            .scaledFont(11, weight: .semibold)
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    private var widgetFreshness: some View {
        Label("Updated now", systemImage: "clock")
            .scaledFont(9.5, weight: .medium)
            .foregroundStyle(widgetSecondaryText)
            .accessibilityLabel("Last updated \(relative(widgetsLastUpdated))")
    }

    // Compact stat card: big number + caption, gold icon chip, taps somewhere useful.
    private func statWidget(_ widget: HomeWidget, value: String, sub: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                widgetIllustration(widget, width: 64, height: 52)
                Text(widget.title)
                    .scaledFont(12.5, weight: .semibold)
                    .foregroundStyle(widgetSecondaryText)
                    .stockedAdaptiveLabel(maxLines: 3, alignment: .center)
                fittedWidgetValue(value, preferredSize: 24)
                    .foregroundStyle(session.themeTextColor)
                Text(sub)
                    .scaledFont(12.5)
                    .foregroundStyle(widgetSecondaryText)
                    .stockedAdaptiveLabel(maxLines: 4, alignment: .center)
                widgetFreshness
                if gridFootprint(for: widget).columns == 4 {
                    Divider().overlay(Color.widgetDivider(dark, increasedContrast: colorSchemeContrast == .increased))
                    Text(widget.expandedDetail)
                        .scaledFont(11.5)
                        .foregroundStyle(widgetSecondaryText)
                        .stockedAdaptiveLabel(maxLines: 2, alignment: .center)
                }
            }
            .padding(homeWidgetContentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(widgetBackground)
            .overlay(alignment: .topTrailing) {
                widgetAccessory(tint: tint).padding(7)
            }
        }
        .buttonStyle(StockedWidgetButtonStyle())
        .stockedInteractiveSurface()
        .a11yRow("\(widget.title), \(value), \(sub)", hint: "Opens \(widget.title)")
    }

    // Compact action shortcut: icon + title + caption, charcoal-tinted, single tap.
    private func actionWidget(_ widget: HomeWidget, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                widgetIllustration(widget, width: 68, height: 54)
                Text(widget.title)
                    .scaledFont(15.5, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                    .stockedAdaptiveLabel(maxLines: 3, alignment: .center)
                Text(widget.blurb)
                    .scaledFont(12)
                    .foregroundStyle(widgetSecondaryText)
                    .stockedAdaptiveLabel(maxLines: 5, alignment: .center)
                if gridFootprint(for: widget).columns == 4 {
                    Text(widget.expandedDetail)
                        .scaledFont(11.5, weight: .medium)
                        .foregroundStyle(widgetSecondaryText)
                        .stockedAdaptiveLabel(maxLines: 2, alignment: .center)
                }
            }
            .padding(homeWidgetContentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(widgetBackground)
            .overlay(alignment: .topTrailing) {
                widgetAccessory(tint: tint).padding(7)
            }
        }
        .buttonStyle(StockedWidgetButtonStyle())
        .stockedInteractiveSurface()
        .a11yRow("\(widget.title). \(widget.blurb)", hint: "Opens \(widget.title)")
    }

    private func widgetIllustration(_ widget: HomeWidget, width: CGFloat, height: CGFloat) -> some View {
        let footprint = gridFootprint(for: widget)
        let widthFactor: CGFloat = footprint.columns == 2 ? 0.78 : 1
        let textFactor: CGFloat = dynamicTypeSize.isAccessibilitySize ? 0.82 : 1
        let targetWidth = min(widget.illustrationWidthRange.upperBound, max(
            widget.illustrationWidthRange.lowerBound,
            width * widthFactor * textFactor
        ))
        return adaptiveWidgetArtwork(
            widget.illustrationAsset,
            preferredWidth: targetWidth,
            preferredHeight: height * (targetWidth / max(1, width))
        )
    }

    private func adaptiveWidgetArtwork(
        _ asset: String,
        preferredWidth: CGFloat,
        preferredHeight: CGFloat
    ) -> some View {
        let size = layoutMetrics.homeWidgetIllustrationSize(
            preferredWidth: preferredWidth,
            preferredHeight: preferredHeight
        )
        return StockedKitchenArtwork(asset: asset)
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
    }

    private func adaptiveWidgetSquareSide(_ preferred: CGFloat) -> CGFloat {
        layoutMetrics.homeWidgetIllustrationSize(
            preferredWidth: preferred,
            preferredHeight: preferred
        ).width
    }

    /// One geometry contract for every illustrated Home widget. The image and its copy
    /// are never reordered by Dynamic Type; copy wraps and grows vertically in place.
    private func lockedWidgetRow<Illustration: View, Content: View, Accessory: View>(
        spacing: CGFloat? = nil,
        @ViewBuilder illustration: () -> Illustration,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .center, spacing: spacing ?? layoutMetrics.homeWidgetRowSpacing) {
            illustration().fixedSize()
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            accessory().fixedSize()
        }
    }

    private func lockedWidgetRow<Illustration: View, Content: View>(
        spacing: CGFloat? = nil,
        @ViewBuilder illustration: () -> Illustration,
        @ViewBuilder content: () -> Content
    ) -> some View {
        lockedWidgetRow(spacing: spacing, illustration: illustration, content: content) { EmptyView() }
    }

    /// Values stay linked to system and in-app text size. ViewThatFits chooses the
    /// largest scaled base that fits the remaining row width instead of wrapping an
    /// atomic value or moving it below its illustration.
    private func fittedWidgetValue(_ value: String, preferredSize: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            fittedWidgetValueText(value, size: preferredSize)
            fittedWidgetValueText(value, size: preferredSize * 0.88)
            fittedWidgetValueText(value, size: preferredSize * 0.76)
            fittedWidgetValueText(value, size: preferredSize * 0.64)
            fittedWidgetValueText(value, size: max(15, preferredSize * 0.52))
        }
    }

    private func fittedWidgetValueText(_ value: String, size: CGFloat) -> some View {
        Text(value)
            .font(.stockedSystem(size: size, weight: .bold, design: .serif))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
    }

    private var widgetBackground: some View {
        RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
            .fill(Color.widgetSurface(
                dark,
                increasedContrast: colorSchemeContrast == .increased,
                reduceTransparency: reduceTransparency
            ))
            .overlay {
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                    .stroke(Color.widgetDivider(dark, increasedContrast: colorSchemeContrast == .increased),
                            lineWidth: colorSchemeContrast == .increased ? 2 : 1)
            }
    }

    // Ready to Cook — recipes you can make from what's expiring (reuses store logic).
    private var readyToCookWidget: some View {
        let expanded = widgetFootprints[.readyToCook]?.rows == 4
        let picks = Array(readyToCookPicks.prefix(expanded ? 3 : 1))
        return VStack(alignment: .leading, spacing: 10) {
            widgetHeader("Ready to Cook", family: .cooking, actionTitle: "Cook") {
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.cook)
            }
            if picks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nothing’s about to expire — add ingredients to discover meals.")
                        .scaledFont(13.5).foregroundStyle(widgetSecondaryText)
                    Button("Add ingredients") {
                        NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.addItems)
                    }
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Color.stockedGold)
                    .buttonStyle(.plain)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(picks, id: \.id) { r in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").scaledFont(13).foregroundStyle(Color.stockedGreen)
                            Text(r.title).scaledFont(14, weight: .medium).foregroundStyle(session.themeTextColor).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Image(systemName: "chevron.right").scaledFont(11, weight: .semibold).foregroundStyle(session.themeTextColor.opacity(0.3))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(Color.widgetPressedSurface(dark))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm + 2))
                    }
                }
            }
        }
        .padding(homeWidgetContentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(widgetBackground)
    }

    private var groceryChecklistWidget: some View {
        let items = Array(store.groceryItems.filter { !$0.isChecked }.prefix(2))
        return VStack(alignment: .leading, spacing: 9) {
            widgetHeader("Shopping List", family: .shopping, actionTitle: "View all") {
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.grocery)
            }
            if items.isEmpty {
                Button("Add your first grocery item") {
                    NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.grocery)
                }
                .scaledFont(13.5, weight: .semibold).foregroundStyle(Color.stockedGold).buttonStyle(.plain)
            } else {
                ForEach(items, id: \.id) { item in
                    Button {
                        store.toggleGrocery(id: item.id)
                        ToastCenter.shared.undo("Checked \(item.name.displayNormalized)") {
                            store.toggleGrocery(id: item.id)
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "square").scaledFont(16).foregroundStyle(Color.stockedGold)
                            Text(item.name.displayNormalized).scaledFont(13.5, weight: .medium)
                                .foregroundStyle(session.themeTextColor)
                                .stockedAdaptiveLabel(maxLines: 2, alignment: .leading)
                            Spacer()
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(homeWidgetContentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(widgetBackground)
    }

    // Waste tracker — used vs wasted in the last 30 days.
    private var wasteTrackerWidget: some View {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let recent = store.consumptionLog.filter { $0.depletedAt > cutoff }
        let used = recent.filter { !$0.wasted }.count
        let wasted = recent.filter { $0.wasted }.count
        return Button {
            NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.stats)
        } label: {
            VStack(spacing: 5) {
                widgetIllustration(.wasteSaved, width: 68, height: 54)
                Text("Waste Tracker").scaledFont(12.5, weight: .semibold)
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .stockedAdaptiveLabel(maxLines: 3, alignment: .center)
                Text("\(used) used · \(wasted) wasted")
                    .scaledFont(17, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                    .stockedAdaptiveLabel(maxLines: 3, alignment: .center)
                Text("last 30 days").scaledFont(11.5).foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            .padding(homeWidgetContentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(widgetBackground)
        }.buttonStyle(.plain)
    }

    // Preferred store shortcut.
    private var preferredStoreWidget: some View {
        Button { NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.grocery) } label: {
            VStack(spacing: 6) {
                widgetIllustration(.preferredStore, width: 68, height: 54)
                Text("Preferred Store").scaledFont(12.5, weight: .semibold)
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .stockedAdaptiveLabel(maxLines: 3, alignment: .center)
                Text(session.preferredStore.isEmpty ? "Not set" : session.preferredStore)
                    .scaledFont(17, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                    .stockedAdaptiveLabel(maxLines: 4, alignment: .center)
            }
            .padding(homeWidgetContentPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(widgetBackground)
        }.buttonStyle(.plain)
    }

    // Kitchen tip — a stable daily pick from a small rotation.
    private var tipWidget: some View {
        let tips = [
            "Store herbs like flowers — stems in water, loosely covered, in the fridge.",
            "Keep onions and potatoes apart; together they spoil faster.",
            "Freeze leftover herbs in olive oil in an ice-cube tray.",
            "Most ‘best by’ dates are about quality, not safety — trust your senses.",
            "Revive limp greens in ice water for 10 minutes.",
            "Store tomatoes on the counter, not the fridge, for better flavor.",
            "Label and date your freezer items — future you will be grateful.",
            "Keep a running list: add it the moment you run low, not when you’re out."
        ]
        let idx = Calendar.current.ordinality(of: .day, in: .era, for: Date()).map { $0 % tips.count } ?? 0
        return VStack(spacing: 10) {
            widgetIllustration(.tipOfDay, width: 104, height: 82)
            Text("Kitchen Tip").scaledFont(15, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
                .stockedAdaptiveLabel(maxLines: 3, alignment: .center)
            Text(tips[idx]).scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.76))
                .stockedAdaptiveLabel(maxLines: 8, alignment: .center)
        }
        .padding(homeWidgetContentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(widgetBackground)
    }

    // MARK: - Daily Brief card (mockup)
    // Charcoal card: header row, four stat rows, divider, kitchen-report footer.
    // Collapsible via the chevron in the header; tapping the stat body opens the
    // expanded Daily Brief, and the footer opens the kitchen report.
    private var dailyBriefCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — title opens the full brief, chevron collapses the card.
            HStack {
                Button {
                    NotificationCenter.default.post(name: .stockedShowBrief, object: nil)
                } label: {
                    Text("Daily Brief")
                        .scaledFont(17, weight: .bold, design: .serif)
                        .foregroundStyle(Color.stockedWhite)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .a11yButton("Daily Brief", hint: "Opens your full daily brief")

                Spacer()

                if !briefCollapsed {
                    Text("Updated just now")
                        .scaledFont(11)
                        .foregroundStyle(Color.stockedWhite.opacity(0.45))
                        .padding(.trailing, 10)
                }

                Button {
                    motion.animate(.standard, intent: .spatial) {
                        briefCollapsed.toggle()
                    }
                    UserDefaults.standard.set(briefCollapsed, forKey: briefCollapsedKey)
                } label: {
                    Image(systemName: "chevron.down")
                        .scaledFont(13, weight: .semibold)
                        .foregroundStyle(Color.stockedWhite.opacity(0.6))
                        .rotationEffect(.degrees(briefCollapsed ? -90 : 0))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .a11yButton(briefCollapsed ? "Expand Daily Brief" : "Collapse Daily Brief")
            }

            if !briefCollapsed {
                Button {
                    NotificationCenter.default.post(name: .stockedShowBrief, object: nil)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        briefRow(icon: "fork.knife",
                                 value: "\(mealsAvailable) makeable meal\(mealsAvailable == 1 ? "" : "s")",
                                 label: "You can cook right now")
                        briefRow(icon: "refrigerator",
                                 value: "\(kitchenMetrics.stockPercent)% stocked",
                                 label: kitchenMetrics.stockStatusSentence)
                        briefRow(icon: "clock.badge.exclamationmark",
                                 value: "\(expiringCount) item\(expiringCount == 1 ? "" : "s") expiring soon",
                                 label: store.expiringSoonItems.first.map { "Use tonight: \($0.name.displayNormalized)" } ?? "Nothing urgent",
                                 badged: expiringCount > 0)
                        briefRow(icon: "cart",
                                 value: store.groceryRunDays == 0 ? "Grocery run today"
                                      : "Grocery run in \(store.groceryRunDays) day\(store.groceryRunDays == 1 ? "" : "s")",
                                 label: store.groceryRunDateText)
                    }
                    .padding(.top, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .a11yButton("Daily Brief", hint: "Opens your full daily brief")

                Divider().background(Color.stockedWhite.opacity(0.12)).padding(.top, 6)

                Button {
                    NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.stats)
                } label: {
                    HStack {
                        Text("View full kitchen report")
                            .scaledFont(14, weight: .semibold)
                            .foregroundStyle(Color.stockedWhite)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .scaledFont(12, weight: .semibold)
                            .foregroundStyle(Color.stockedWhite.opacity(0.45))
                    }
                    .padding(.top, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .a11yButton("View full kitchen report")
            }
        }
        .padding(homeWidgetContentPadding)
        .background(Color.stockedCharcoal)
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
    }

    private func briefRow(icon: String, value: String, label: String, badged: Bool = false) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.stockedWhite.opacity(0.08)).frame(width: 38, height: 38)
                if badged {
                    Image(systemName: icon)
                        .scaledFont(15)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.stockedGold, Color.stockedError)
                } else {
                    Image(systemName: icon)
                        .scaledFont(15)
                        .foregroundStyle(Color.stockedGold)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .scaledFont(14.5, weight: .bold)
                    .foregroundStyle(Color.stockedWhite)
                Text(label)
                    .scaledFont(12)
                    .foregroundStyle(Color.stockedWhite.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func quickAction(icon: String, title: String, caption: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .scaledFont(17, weight: .medium)
                    .foregroundStyle(session.themeTextColor.opacity(0.75))
                    .frame(height: 24)
                Text(title)
                    .scaledFont(13, weight: .bold)
                    .foregroundStyle(session.themeTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text(caption)
                    .scaledFont(10.5)
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.40))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
        .stockedInteractiveSurface()
        .a11yButton(title, hint: caption)
    }

    // MARK: - What's New (mockup)
    private struct NewsRow: Identifiable {
        let id = UUID(); let icon: String; let text: String; let when: Date
    }
    private var newsRows: [NewsRow] {
        var rows: [NewsRow] = []
        // Recently added items, grouped — "Jessie added 16 items".
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let added = store.inventoryItems.filter { ($0.purchaseDate ?? .distantPast) > cutoff }
        if !added.isEmpty {
            let newest = added.compactMap(\.purchaseDate).max() ?? Date()
            rows.append(NewsRow(icon: "plus.square",
                                text: "\(session.userName) added \(added.count) item\(added.count == 1 ? "" : "s")",
                                when: newest))
        }
        // Recent use/toss — "Milk was used", or grouped "2 items were used".
        let recent = Array(store.consumptionLog.suffix(6)).sorted { $0.depletedAt > $1.depletedAt }
        let usedToday = recent.filter { !$0.wasted && Calendar.current.isDateInToday($0.depletedAt) }
        if usedToday.count > 1, let newest = usedToday.first {
            rows.append(NewsRow(icon: "checkmark.square",
                                text: "\(usedToday.count) items were used",
                                when: newest.depletedAt))
            for r in recent where r.wasted {
                rows.append(NewsRow(icon: "trash", text: "\(r.itemName.displayNormalized) was tossed", when: r.depletedAt))
            }
        } else {
            for r in recent.prefix(3) {
                rows.append(NewsRow(icon: r.wasted ? "trash" : "checkmark.square",
                                    text: r.wasted ? "\(r.itemName.displayNormalized) was tossed"
                                                   : "\(r.itemName.displayNormalized) was used",
                                    when: r.depletedAt))
            }
        }
        return Array(rows.sorted { $0.when > $1.when }.prefix(3))
    }
    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
    private var whatsNewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's New")
                .scaledFont(16, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)

            let rows = Array(newsRows.prefix(widgetFootprints[.whatsNew]?.rows == 4 ? 3 : 1))
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.45))
                                .frame(width: 30, height: 30)
                            Image(systemName: "clock.arrow.circlepath").scaledFont(13)
                                .foregroundStyle(session.themeTextColor.opacity(0.6))
                        }
                        Text("No recent activity — changes will show here")
                            .scaledFont(13.5)
                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    Button("Add an item") {
                        NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.addItems)
                    }
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Color.stockedGold)
                    .buttonStyle(.plain)
                }
            } else {
                VStack(spacing: 14) {
                    ForEach(rows) { row in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.45))
                                    .frame(width: 30, height: 30)
                                Image(systemName: row.icon).scaledFont(13)
                                    .foregroundStyle(session.themeTextColor.opacity(0.65))
                            }
                            Text(row.text).scaledFont(14)
                                .foregroundStyle(session.themeTextColor.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text(relative(row.when)).scaledFont(12)
                                .foregroundStyle(session.themeTextColor.opacity(0.45))
                        }
                    }
                }
            }

            Button { activeHomeSheet = .activityFeed } label: {
                HStack {
                    Text("See all activity")
                        .scaledFont(13.5, weight: .semibold)
                        .foregroundStyle(session.themeTextColor.opacity(0.85))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .scaledFont(12, weight: .semibold)
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .background(dark ? Color.darkSurface : Color.stockedCharcoal.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            }
            .buttonStyle(.plain)
            .a11yButton("See all activity")
            .padding(.top, 2)
        }
    }

    // MARK: - Use It Soon (mockup)
    private var useItSoonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Use It Soon")
                    .scaledFont(16, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                Button {
                    // Diagnostic instrumentation (T2): the Use It Soon / View All button has been
                    // reported to produce an error page. Log the data state and navigation intent
                    // so a crash leaves a trail bracketing exactly where it fails. Remove once the
                    // root cause is confirmed.
                    let urgent = store.urgentItems
                    let expiring = store.inventoryItems.filter { ($0.daysUntilExpiry ?? 999) <= KitchenThresholds.expiringSoonDays || $0.isExpired }
                    Log.app.notice("UseItSoon ViewAll tapped: urgentItems=\(urgent.count, privacy: .public) expiringList=\(expiring.count, privacy: .public) totalInventory=\(store.inventoryItems.count, privacy: .public)")
                    goExpiringList = true
                } label: {
                    Text("View All").scaledFont(12.5, weight: .semibold)
                        .foregroundStyle(Color.stockedGold)
                }.buttonStyle(.plain)
            }
            let items = store.urgentItems.prefix(3)
            if items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").scaledFont(13)
                        .foregroundStyle(Color.stockedGreen)
                    Text("Nothing expiring soon — you're in good shape")
                        .scaledFont(13.5)
                        .foregroundStyle(session.themeTextColor.opacity(0.6))
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.30))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm + 2))
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(items), id: \.id) { item in
                        HStack(spacing: 10) {
                            Circle().fill(Color.stockedGold).frame(width: 6, height: 6)
                            Text(item.name.displayNormalized)
                                .scaledFont(14, weight: .medium)
                                .foregroundStyle(session.themeTextColor)
                            Spacer()
                            if let days = item.daysUntilExpiry {
                                Text(days < 0 ? "Expired \(-days) day\(days == -1 ? "" : "s") ago"
                                     : (days == 0 ? "Expires today" : (days == 1 ? "Expires tomorrow" : "Expires in \(days) days")))
                                    .scaledFont(12, weight: .semibold)
                                    .foregroundStyle(Color.red.opacity(0.8))
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(Color.red.opacity(dark ? 0.10 : 0.06))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm + 2))
                    }
                }
            }
        }
    }
}

// MARK: - #240 — full activity feed (View All)
// Local-actor attribution: every row names the signed-in user, mirroring the mockup's
// "Jessie added 16 items" style. Per-member attribution across a synced household would
// need author metadata in the sync protocol — rows here reflect this device's actions.
struct ActivityFeedSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) private var dismiss
    private var store: GuestDataStore { session.guestStore }

    private struct FeedRow: Identifiable {
        let id = UUID(); let icon: String; let tint: Color; let text: String; let when: Date
    }
    private var rows: [FeedRow] {
        var out: [FeedRow] = []
        for r in store.consumptionLog.suffix(40) {
            out.append(FeedRow(icon: r.wasted ? "trash" : "checkmark.circle",
                               tint: r.wasted ? .red : Color.stockedGreen,
                               text: r.wasted ? "\(session.userName) tossed \(r.itemName)"
                                              : "\(session.userName) used \(r.itemName)",
                               when: r.depletedAt))
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let added = store.inventoryItems.filter { ($0.purchaseDate ?? .distantPast) > cutoff }
        for item in added.suffix(40) {
            out.append(FeedRow(icon: "plus.circle", tint: Color.stockedGold,
                               text: "\(session.userName) added \(item.name)",
                               when: item.purchaseDate ?? Date()))
        }
        return out.sorted { $0.when > $1.when }
    }

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    StockedEmptyState(icon: "clock.arrow.circlepath",
                                      title: "No activity yet",
                                      subtitle: "Adding, using, and cooking items will show up here.")
                } else {
                    List(rows) { row in
                        HStack(spacing: 12) {
                            Image(systemName: row.icon).scaledFont(14)
                                .foregroundStyle(row.tint).frame(width: 22)
                            Text(row.text).scaledFont(14)
                                .foregroundStyle(session.themeTextColor)
                            Spacer()
                            Text(row.when, style: .relative)
                                .scaledFont(11.5)
                                .foregroundStyle(session.themeTextColor.opacity(0.45))
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Household Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - #252 Home widget model + jiggle effect

enum HomeWidgetPreviewState: String, CaseIterable, Identifiable {
    case content = "Content"
    case loading = "Loading"
    case empty = "Empty"
    case stale = "Stale"
    case failure = "Error"
    var id: String { rawValue }
}

private enum HomeWidgetPreviewAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Internal visual QA surface: every widget family, permitted footprint, density,
/// appearance, and data state can be inspected without manufacturing app data.
private struct HomeWidgetThemeGallery: View {
    @Environment(\.dismiss) private var dismiss
    @State private var state = HomeWidgetPreviewState.content
    @State private var density = HomeWidgetDensity.standard
    @State private var appearance = HomeWidgetPreviewAppearance.system

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(HomeWidgetPreviewAppearance.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("State", selection: $state) {
                        ForEach(HomeWidgetPreviewState.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Density", selection: $density) {
                        ForEach(HomeWidgetDensity.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)

                    WidgetThemePreviewCanvas(state: state, density: density)
                        .preferredColorScheme(appearance.scheme)
                }
                .padding(16)
            }
            .navigationTitle("Widget Theme Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct WidgetThemePreviewCanvas: View {
    let state: HomeWidgetPreviewState
    let density: HomeWidgetDensity
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var dark: Bool { scheme == .dark }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18 * density.spacingScale) {
            semanticPalette
            ForEach(StockedWidgetThemeFamily.allCases) { family in
                VStack(alignment: .leading, spacing: 10) {
                    Label(family.rawValue, systemImage: family.icon)
                        .scaledFont(18, weight: .bold, design: .serif)
                        .foregroundStyle(Color.widgetPrimaryText(dark))
                    ForEach(HomeWidget.allCases.filter { $0.themeFamily == family }, id: \.self) { widget in
                        preview(widget, family: family)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.appBg(dark))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
    }

    private var semanticPalette: some View {
        HStack(spacing: 8) {
            paletteChip("Surface", Color.widgetSurface(dark, increasedContrast: contrast == .increased,
                                                       reduceTransparency: reduceTransparency))
            paletteChip("Text", Color.widgetPrimaryText(dark))
            paletteChip("Success", Color.widgetSuccess(dark))
            paletteChip("Warning", Color.widgetWarning(dark))
            paletteChip("Error", Color.widgetFailure(dark))
        }
    }

    private func paletteChip(_ name: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Circle().fill(color).frame(width: 24, height: 24)
            Text(name).scaledFont(8.5).foregroundStyle(Color.widgetSecondaryText(dark))
        }.frame(maxWidth: .infinity)
    }

    private func preview(_ widget: HomeWidget, family: StockedWidgetThemeFamily) -> some View {
        VStack(alignment: .leading, spacing: 8 * density.spacingScale) {
            HStack {
                Label(widget.title, systemImage: widget.icon)
                    .scaledFont(14, weight: .bold, design: .serif)
                    .foregroundStyle(Color.widgetPrimaryText(dark))
                Spacer()
                ForEach(widget.allowedGridFootprints, id: \.self) { size in
                    Text(size.storageValue).scaledFont(9, weight: .bold)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(family.accent(dark: dark).opacity(0.14)).clipShape(Capsule())
                }
            }
            previewState(widget, family: family)
        }
        .padding(max(10, 14 * density.spacingScale))
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(Color.widgetSurface(dark, increasedContrast: contrast == .increased,
                                        reduceTransparency: reduceTransparency))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                .stroke(Color.widgetDivider(dark, increasedContrast: contrast == .increased),
                        lineWidth: contrast == .increased ? 2 : 1)
        }
    }

    @ViewBuilder private func previewState(_ widget: HomeWidget, family: StockedWidgetThemeFamily) -> some View {
        switch state {
        case .content:
            Text(widget.expandedDetail).scaledFont(12.5).foregroundStyle(Color.widgetSecondaryText(dark))
        case .loading:
            VStack(alignment: .leading, spacing: 7) {
                SkeletonView().frame(height: 13)
                SkeletonView().frame(width: 150, height: 13)
            }.accessibilityLabel("Loading \(widget.title)")
        case .empty:
            Label("No data yet — tap to get started", systemImage: "plus.circle")
                .scaledFont(12.5, weight: .semibold).foregroundStyle(family.accent(dark: dark))
        case .stale:
            Label("Last update is out of date — refresh", systemImage: "clock.badge.exclamationmark")
                .scaledFont(12.5, weight: .semibold).foregroundStyle(Color.widgetWarning(dark))
        case .failure:
            Label("Couldn’t update — retry", systemImage: "arrow.clockwise.circle")
                .scaledFont(12.5, weight: .semibold).foregroundStyle(Color.widgetFailure(dark))
        }
    }
}

enum HomeWidgetPreset: String, CaseIterable, Identifiable {
    case minimal, dailyPlanning, inventoryFocus, cookingFocus
    var id: String { rawValue }
    var title: String {
        switch self {
        case .minimal: return "Minimal"
        case .dailyPlanning: return "Daily Planning"
        case .inventoryFocus: return "Inventory Focus"
        case .cookingFocus: return "Cooking Focus"
        }
    }
    var icon: String {
        switch self {
        case .minimal: return "rectangle.grid.1x2"
        case .dailyPlanning: return "calendar"
        case .inventoryFocus: return "shippingbox"
        case .cookingFocus: return "fork.knife"
        }
    }
    var widgets: [HomeWidget] {
        switch self {
        case .minimal: return [.useItSoon, .cookNow, .lowStock, .stockLevel]
        case .dailyPlanning: return [.dailyBrief, .useItSoon, .plannedMeals, .groceryCount, .stockLevel]
        case .inventoryFocus: return [.useItSoon, .lowStock, .totalItems, .groceryCount, .stockLevel]
        case .cookingFocus: return [.readyToCook, .cookNow, .mealsReady, .plannedMeals, .stockLevel]
        }
    }
}

/// The sections that make up the customizable Home board. The persisted layout is an
/// ordered list of the widgets currently ON the board; anything absent is "removed" and
/// can be re-added from the gallery. Order in the array = top-to-bottom on screen.
enum HomeWidget: String, CaseIterable, Hashable, Codable {
    // Original four
    case dailyBrief, whatsNew, actionCenter, useItSoon
    // #253 — twenty more
    case stockLevel          // % stocked ring
    case mealsReady          // makeable meals count
    case cookStreak          // current cooking streak
    case groceryCount        // items on the shopping list
    case nextRun             // next grocery run countdown
    case expiringCount       // # items expiring soon
    case lowStock            // # items running low
    case totalItems          // total inventory count
    case cookNow             // jump to Cook Now
    case discover            // jump to Discover/Recipes
    case quickAdd            // single Add Item button
    case scanReceiptW        // single Scan Receipt button
    case scanBarcodeW        // single Scan Barcode button
    case quickUpdateW        // single Quick Update button
    case shoppingList        // open grocery tab
    case readyToCook         // recipes you can make from expiring items
    case favorites           // saved/favorite recipes count
    case plannedMeals        // meals on the planner
    case wasteSaved          // items used vs wasted this period
    case preferredStore      // your store + find-in-store
    case searchW             // global search
    case tipOfDay            // a rotating kitchen tip

    var title: String {
        switch self {
        case .dailyBrief:   return "Daily Brief"
        case .whatsNew:     return "What's New"
        case .actionCenter: return "Action Center"
        case .useItSoon:    return "Use It Soon"
        case .stockLevel:   return "Stock Level"
        case .mealsReady:   return "Meals Ready"
        case .cookStreak:   return "Cooking Streak"
        case .groceryCount: return "Shopping List"
        case .nextRun:      return "Next Grocery Run"
        case .expiringCount:return "Expiring Soon"
        case .lowStock:     return "Running Low"
        case .totalItems:   return "Kitchen Total"
        case .cookNow:      return "Cook Now"
        case .discover:     return "Discover Recipes"
        case .quickAdd:     return "Add Item"
        case .scanReceiptW: return "Scan Receipt"
        case .scanBarcodeW: return "Scan Barcode"
        case .quickUpdateW: return "Quick Update"
        case .shoppingList: return "Open Shopping List"
        case .readyToCook:  return "Ready to Cook"
        case .favorites:    return "Favorites"
        case .plannedMeals: return "Meal Plan"
        case .wasteSaved:   return "Waste Tracker"
        case .preferredStore:return "Preferred Store"
        case .searchW:      return "Search"
        case .tipOfDay:     return "Kitchen Tip"
        }
    }
    var icon: String {
        switch self {
        case .dailyBrief:   return "doc.text.image"
        case .whatsNew:     return "sparkles"
        case .actionCenter: return "square.grid.2x2"
        case .useItSoon:    return "clock.badge.exclamationmark"
        case .stockLevel:   return "gauge.medium"
        case .mealsReady:   return "fork.knife"
        case .cookStreak:   return "flame.fill"
        case .groceryCount: return "cart"
        case .nextRun:      return "calendar"
        case .expiringCount:return "exclamationmark.triangle"
        case .lowStock:     return "battery.25"
        case .totalItems:   return "shippingbox"
        case .cookNow:      return "frying.pan.fill"
        case .discover:     return "globe"
        case .quickAdd:     return "plus.circle.fill"
        case .scanReceiptW: return "viewfinder"
        case .scanBarcodeW: return "barcode.viewfinder"
        case .quickUpdateW: return "scribble.variable"
        case .shoppingList: return "cart.fill"
        case .readyToCook:  return "checkmark.circle.fill"
        case .favorites:    return "heart.fill"
        case .plannedMeals: return "calendar.badge.clock"
        case .wasteSaved:   return "leaf.fill"
        case .preferredStore:return "mappin.and.ellipse"
        case .searchW:      return "magnifyingglass"
        case .tipOfDay:     return "lightbulb.fill"
        }
    }
    var blurb: String {
        switch self {
        case .dailyBrief:   return "Your kitchen at a glance — meals, stock, expiring items, next grocery run."
        case .whatsNew:     return "Recent activity in your kitchen."
        case .actionCenter: return "Quick actions: scan, add, and update items."
        case .useItSoon:    return "Items expiring soon, so nothing goes to waste."
        case .stockLevel:   return "How stocked your kitchen is right now."
        case .mealsReady:   return "How many meals you can cook with what you have."
        case .cookStreak:   return "Your current run of days cooking at home."
        case .groceryCount: return "How many items are on your shopping list."
        case .nextRun:      return "Days until your recommended grocery run."
        case .expiringCount:return "A count of items expiring soon."
        case .lowStock:     return "A count of items running low."
        case .totalItems:   return "Total items tracked in your kitchen."
        case .cookNow:      return "Jump straight to meals you can make now."
        case .discover:     return "Browse recipes from around the web."
        case .quickAdd:     return "A one-tap shortcut to add an item."
        case .scanReceiptW: return "A one-tap shortcut to scan a receipt."
        case .scanBarcodeW: return "A one-tap shortcut to scan a barcode."
        case .quickUpdateW: return "Tell Stocked what changed in plain words."
        case .shoppingList: return "Open your full shopping list."
        case .readyToCook:  return "Recipes you can make from what's expiring."
        case .favorites:    return "Your favorite saved recipes."
        case .plannedMeals: return "Meals you've planned for the week."
        case .wasteSaved:   return "How much you've used vs. wasted lately."
        case .preferredStore:return "Your go-to store, one tap away."
        case .searchW:      return "Search across your whole kitchen."
        case .tipOfDay:     return "A little kitchen wisdom, refreshed daily."
        }
    }

    /// Related widgets share a small, cohesive illustration family. Keeping these
    /// project-local cutouts reusable avoids decoding dozens of near-duplicate assets.
    var illustrationAsset: String {
        switch self {
        case .mealsReady, .cookStreak, .cookNow, .discover, .readyToCook, .favorites:
            return "home_widget_cooking"
        case .expiringCount, .useItSoon:
            return KitchenArtworkCatalog.inventoryActions[0]
        case .lowStock:
            return KitchenArtworkCatalog.inventoryActions[1]
        case .quickAdd:
            return KitchenArtworkCatalog.inventoryActions[2]
        case .stockLevel, .totalItems, .dailyBrief:
            return "home_widget_pantry"
        case .groceryCount, .nextRun, .shoppingList, .preferredStore:
            return "home_widget_shopping"
        case .plannedMeals:
            return "home_widget_planning"
        case .wasteSaved:
            return "home_widget_waste"
        case .actionCenter, .whatsNew, .scanReceiptW, .scanBarcodeW,
             .quickUpdateW, .searchW, .tipOfDay:
            return "home_widget_tools"
        }
    }

    var themeFamily: StockedWidgetThemeFamily {
        switch self {
        case .stockLevel, .expiringCount, .lowStock, .totalItems, .useItSoon, .dailyBrief:
            return .pantry
        case .mealsReady, .cookStreak, .cookNow, .discover, .readyToCook, .favorites, .wasteSaved:
            return .cooking
        case .groceryCount, .nextRun, .shoppingList, .preferredStore:
            return .shopping
        case .plannedMeals:
            return .planning
        default:
            return .tools
        }
    }

    /// The additional insight shown only when a compact widget receives more width.
    var expandedDetail: String {
        switch self {
        case .stockLevel: return "Review low-stock items and restore your kitchen target."
        case .mealsReady: return "Open Cook to compare the best matches from your current kitchen."
        case .cookStreak: return "Cooking at home keeps your streak and kitchen history current."
        case .groceryCount, .shoppingList: return "Check items here or open the complete shopping list."
        case .nextRun: return "Based on current stock, planned meals, and shopping needs."
        case .expiringCount, .useItSoon: return "Use the closest-dated ingredients first to reduce waste."
        case .lowStock: return "Restock soon to unlock more complete recipe matches."
        case .totalItems: return "Includes every currently tracked pantry, fridge, and freezer item."
        case .cookNow: return "Uses availability, confidence, time, and household preferences."
        case .discover: return "Browse complete recipes from your local and synced catalog."
        case .quickAdd: return "Add a kitchen item manually with quantity, location, and freshness."
        case .scanReceiptW, .scanBarcodeW: return "Scan once, review the detected items, then confirm changes."
        case .quickUpdateW: return "Describe several kitchen changes together in natural language."
        case .searchW: return "Search inventory, recipes, plans, and grocery items together."
        case .favorites: return "Open your saved recipes and choose what to cook next."
        case .plannedMeals: return "Review the week and move planned meals into cooking."
        case .wasteSaved: return "Compare what was used with what was discarded this month."
        case .preferredStore: return "Open your shopping flow using the store you prefer."
        case .readyToCook: return "Larger sizes reveal additional matching recipes."
        case .dailyBrief: return "A complete snapshot of the kitchen right now."
        case .whatsNew: return "Larger sizes reveal additional recent activity."
        case .actionCenter: return "Scan, add, and update the kitchen from one place."
        case .tipOfDay: return "A practical kitchen habit selected for today."
        }
    }

    /// Artwork has a per-widget visual budget so illustrations respond to available
    /// width without crowding copy or becoming disproportionate to compact cards.
    var illustrationWidthRange: ClosedRange<CGFloat> {
        switch self {
        case .tipOfDay:
            return 72...112
        case .dailyBrief, .actionCenter, .useItSoon:
            return 88...150
        case .readyToCook, .cookNow, .discover, .mealsReady:
            return 48...92
        default:
            return 44...76
        }
    }

    // The first screen answers the three decisions users open Stocked for: what must be
    // used, what can be cooked, and what needs restocking. Everything else stays available
    // in the gallery. Existing customized boards are never reset.
    static let defaultLayout: [HomeWidget] = [.useItSoon, .cookNow, .lowStock, .stockLevel]

    /// Widgets already expressed by the fixed master-mockup Home composition. They
    /// remain in the persisted model for compatibility but must not be duplicated
    /// underneath the matching reference sections.
    static let referenceRepresented: Set<HomeWidget> = Set(defaultLayout)

    private static let layoutKey = "stocked.homeWidgetLayout_v3"
    private static let footprintKey = "stocked.homeWidgetFootprints_v1"

    static func loadLayout() -> [HomeWidget] {
        guard let raw = UserDefaults.standard.array(forKey: layoutKey) as? [String] else {
            return defaultLayout
        }
        // Empty is valid (user removed everything); only fall back when the key is absent.
        return raw.compactMap { HomeWidget(rawValue: $0) }
    }

    static func saveLayout(_ layout: [HomeWidget]) {
        UserDefaults.standard.set(layout.map(\.rawValue), forKey: layoutKey)
    }

    static func loadGridFootprints() -> [HomeWidget: HomeWidgetGridFootprint] {
        guard let stored = UserDefaults.standard.dictionary(forKey: footprintKey) as? [String: String] else {
            return [:]
        }
        return stored.reduce(into: [:]) { result, entry in
            guard let widget = HomeWidget(rawValue: entry.key),
                  let footprint = HomeWidgetGridFootprint(storageValue: entry.value) else { return }
            result[widget] = widget.resolvedGridFootprint(footprint)
        }
    }

    static func saveGridFootprints(_ footprints: [HomeWidget: HomeWidgetGridFootprint]) {
        let stored = footprints.reduce(into: [String: String]()) { result, entry in
            result[entry.key.rawValue] = entry.key.resolvedGridFootprint(entry.value).storageValue
        }
        UserDefaults.standard.set(stored, forKey: footprintKey)
    }

    /// Four-column Home footprint. 2x2 is reserved for concise values/actions,
    /// 4x2 for readable rails/actions, 2x4 for long illustrated editorial content,
    /// and 4x4 only for the information-dense Daily Brief summary.
    var gridFootprint: HomeWidgetGridFootprint {
        switch self {
        case .dailyBrief:
            return .init(columns: 4, rows: 4)
        case .actionCenter:
            return .init(columns: 4, rows: 2)
        case .useItSoon, .whatsNew, .readyToCook:
            return .init(columns: 4, rows: 2)
        case .tipOfDay:
            return .init(columns: 2, rows: 4)
        default:
            return .init(columns: 2, rows: 2)
        }
    }

    /// Sizes reflect what each widget can use today. Concise value/action cards
    /// can gain width for large text but cannot become tall empty billboards.
    /// Only list widgets with additional rows may grow vertically. Purpose-built
    /// reference cards remain fixed until their functionality changes.
    var allowedGridFootprints: [HomeWidgetGridFootprint] {
        switch self {
        case .dailyBrief:
            return [.init(columns: 4, rows: 4)]
        case .actionCenter, .useItSoon:
            return [.init(columns: 4, rows: 2)]
        case .whatsNew, .readyToCook:
            return [.init(columns: 4, rows: 2), .init(columns: 4, rows: 4)]
        case .tipOfDay:
            return [.init(columns: 2, rows: 4)]
        default:
            return [.init(columns: 2, rows: 2), .init(columns: 4, rows: 2)]
        }
    }

    var supportsManualResize: Bool { allowedGridFootprints.count > 1 }

    var densityPreview: String {
        switch self {
        case .whatsNew, .readyToCook: return "1 or 3 rows"
        case .dailyBrief: return "full summary"
        case .actionCenter: return "3 actions"
        case .useItSoon: return "status + next item"
        case .tipOfDay: return "illustrated tip"
        default: return "value + action"
        }
    }

    var resizeAccessibilityHint: String {
        let values = allowedGridFootprints.map(\.storageValue).joined(separator: " or ")
        return "Drag to snap between \(values), or double tap to cycle."
    }

    func sizeAvailabilityDescription(for footprint: HomeWidgetGridFootprint) -> String {
        guard allowedGridFootprints.count > 1 else {
            return "Fixed at \(gridFootprint.storageValue) because this widget has no additional content."
        }
        if footprint == allowedGridFootprints.first {
            return "Minimum size. Make it larger to reveal more detail."
        }
        if footprint == allowedGridFootprints.last {
            return "Maximum useful size for its current features."
        }
        return "Resize between \(allowedGridFootprints.map(\.storageValue).joined(separator: " and "))."
    }

    func resolvedGridFootprint(_ requested: HomeWidgetGridFootprint) -> HomeWidgetGridFootprint {
        let normalized = requested.normalizedManual
        return allowedGridFootprints.contains(normalized) ? normalized : gridFootprint
    }

    func resizedGridFootprint(
        from start: HomeWidgetGridFootprint,
        translation: CGSize
    ) -> HomeWidgetGridFootprint {
        // Quantize both the live drag and the predicted release to the shared
        // 64-point magnetic lattice. Its midpoint preserves the existing 32-point
        // dead zone while the projected end translation adds velocity awareness.
        let snap = StockedVelocitySnapPolicy()
        let magneticX = snap.magneticValue(translation.width, increment: 64)
        let magneticY = snap.magneticValue(translation.height, increment: 64)
        var requested = resolvedGridFootprint(start)
        if magneticX > 0 { requested = .init(columns: 4, rows: requested.rows) }
        if magneticX < 0 { requested = .init(columns: 2, rows: requested.rows) }
        if magneticY > 0 { requested = .init(columns: requested.columns, rows: 4) }
        if magneticY < 0 { requested = .init(columns: requested.columns, rows: 2) }
        if let exact = allowedGridFootprints.first(where: { $0 == requested }) { return exact }
        return allowedGridFootprints.min { lhs, rhs in
            lhs.distance(to: requested) < rhs.distance(to: requested)
        } ?? gridFootprint
    }
}

nonisolated struct HomeWidgetGridFootprint: Equatable, Hashable, Sendable {
    let columns: Int
    let rows: Int

    var normalized: HomeWidgetGridFootprint {
        HomeWidgetGridFootprint(
            columns: columns <= 2 ? 2 : 4,
            rows: max(1, rows)
        )
    }

    var normalizedManual: HomeWidgetGridFootprint {
        HomeWidgetGridFootprint(
            columns: columns <= 2 ? 2 : 4,
            rows: rows <= 2 ? 2 : 4
        )
    }

    static let manualSizes: [HomeWidgetGridFootprint] = [
        .init(columns: 2, rows: 2),
        .init(columns: 4, rows: 2),
        .init(columns: 2, rows: 4),
        .init(columns: 4, rows: 4),
    ]

    var storageValue: String { "\(columns)x\(rows)" }

    func distance(to other: HomeWidgetGridFootprint) -> Int {
        abs(columns - other.columns) + abs(rows - other.rows)
    }

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, [2, 4].contains(parts[0]), [2, 4].contains(parts[1]) else {
            return nil
        }
        self.init(columns: parts[0], rows: parts[1])
    }
}

nonisolated struct HomeWidgetGridPosition: Equatable, Sendable {
    let column: Int
    let row: Int
    let footprint: HomeWidgetGridFootprint
}

nonisolated enum HomeWidgetGridPacking {
    /// Packs half- and full-width widgets into four logical columns. Half-width tall
    /// cards leave a real 2x2 opening that later compact cards can fill. Full-width
    /// widgets form order barriers so later content never jumps above a command card.
    static func positions(for requested: [HomeWidgetGridFootprint]) -> [HomeWidgetGridPosition] {
        var occupied: Set<Int> = []
        var positions: [HomeWidgetGridPosition] = []
        var barrierRow = 0
        var maximumBottom = 0

        func cellKey(column: Int, row: Int) -> Int { row * 4 + column }
        func isAvailable(column: Int, row: Int, footprint: HomeWidgetGridFootprint) -> Bool {
            guard column + footprint.columns <= 4 else { return false }
            for y in row..<(row + footprint.rows) {
                for x in column..<(column + footprint.columns) {
                    if occupied.contains(cellKey(column: x, row: y)) { return false }
                }
            }
            return true
        }

        for requestedFootprint in requested {
            let footprint = requestedFootprint.normalized
            var row = footprint.columns == 4 ? maximumBottom : barrierRow
            var column = 0

            search: while true {
                let candidates = footprint.columns == 4 ? [0] : [0, 2]
                for candidate in candidates where isAvailable(
                    column: candidate,
                    row: row,
                    footprint: footprint
                ) {
                    column = candidate
                    break search
                }
                row += 1
            }

            for y in row..<(row + footprint.rows) {
                for x in column..<(column + footprint.columns) {
                    occupied.insert(cellKey(column: x, row: y))
                }
            }
            positions.append(HomeWidgetGridPosition(
                column: column,
                row: row,
                footprint: footprint
            ))
            maximumBottom = max(maximumBottom, row + footprint.rows)
            if footprint.columns == 4 { barrierRow = maximumBottom }
        }
        return positions
    }

    static func containsOverlap(_ positions: [HomeWidgetGridPosition]) -> Bool {
        var occupied: Set<Int> = []
        for position in positions {
            for row in position.row..<(position.row + position.footprint.rows) {
                for column in position.column..<(position.column + position.footprint.columns) {
                    let key = row * 4 + column
                    if !occupied.insert(key).inserted { return true }
                }
            }
        }
        return false
    }

    /// Stable structural snapshot used by regression tests. Unlike pixel snapshots,
    /// this catches overlap/reflow changes without depending on a simulator runtime.
    static func snapshotSignature(for requested: [HomeWidgetGridFootprint]) -> String {
        positions(for: requested).map {
            "\($0.column):\($0.row):\($0.footprint.storageValue)"
        }.joined(separator: "|")
    }
}

private nonisolated struct HomeWidgetGridFootprintKey: LayoutValueKey {
    static let defaultValue = HomeWidgetGridFootprint(columns: 4, rows: 2)
}

private extension View {
    func homeWidgetGridFootprint(_ footprint: HomeWidgetGridFootprint) -> some View {
        layoutValue(key: HomeWidgetGridFootprintKey.self, value: footprint.normalized)
    }
}

private nonisolated struct HomeWidgetGridLayout: Layout {
    let spacing: CGFloat
    let rowUnit: CGFloat

    struct Cache {
        var width: CGFloat = 0
        var frames: [CGRect] = []
        var height: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = max(1, proposal.width ?? 393)
        update(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: cache.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        if abs(cache.width - bounds.width) > 0.5 || cache.frames.count != subviews.count {
            update(width: bounds.width, subviews: subviews, cache: &cache)
        }
        for (subview, frame) in zip(subviews, cache.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func update(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        let columnWidth = max(1, (width - spacing * 3) / 4)
        let measuredFootprints = subviews.map { subview in
            let declared = subview[HomeWidgetGridFootprintKey.self].normalized
            let itemWidth = columnWidth * CGFloat(declared.columns)
                + spacing * CGFloat(declared.columns - 1)
            let idealHeight = subview.sizeThatFits(
                ProposedViewSize(width: itemWidth, height: nil)
            ).height
            let measuredRows = max(
                declared.rows,
                Int(ceil((max(1, idealHeight) + spacing) / (rowUnit + spacing)))
            )
            return HomeWidgetGridFootprint(columns: declared.columns, rows: measuredRows)
        }
        let positions = HomeWidgetGridPacking.positions(for: measuredFootprints)
        assert(!HomeWidgetGridPacking.containsOverlap(positions), "Home widget grid produced overlapping cells")
        cache.frames = positions.map { position in
            CGRect(
                x: CGFloat(position.column) * (columnWidth + spacing),
                y: CGFloat(position.row) * (rowUnit + spacing),
                width: columnWidth * CGFloat(position.footprint.columns)
                    + spacing * CGFloat(position.footprint.columns - 1),
                height: rowUnit * CGFloat(position.footprint.rows)
                    + spacing * CGFloat(position.footprint.rows - 1)
            )
        }
        cache.width = width
        cache.height = cache.frames.map(\.maxY).max() ?? 0
    }
}

/// iPhone-style wiggle applied to each widget while the board is in edit mode.
struct JiggleEffect: ViewModifier {
    let active: Bool
    @Environment(\.stockedMotion) private var motion
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active && motion.permitsContinuousMotion ? (phase ? 0.7 : -0.7) : 0))
            .animation(active && motion.permitsContinuousMotion
                       ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true)
                       : nil,
                       value: phase)
            .onChange(of: active) { _, on in
                phase = on
            }
            .onAppear { if active { phase = true } }
    }
}

// MARK: - #11 Drag-to-reorder support

/// Reorders the Home widget board as a dragged widget hovers over others. Mutates the
/// shared layout live so the move animates, and persists once on drop.
private struct WidgetDropDelegate: DropDelegate {
    let item: HomeWidget
    @Binding var layout: [HomeWidget]
    @Binding var dragging: HomeWidget?
    @Binding var dropTarget: HomeWidget?
    var onCommit: @MainActor () -> Void

    func dropEntered(info: DropInfo) {
        dropTarget = item
        guard let dragging, dragging != item,
              let from = layout.firstIndex(of: dragging),
              let to = layout.firstIndex(of: item) else { return }
        if layout[to] != dragging {
            let animation = StockedMotionPolicy(
                reduceMotion: UIAccessibility.isReduceMotionEnabled
            ).animation(.settle, intent: .spatial)
            withAnimation(animation) {
                layout.move(fromOffsets: IndexSet(integer: from),
                            toOffset: to > from ? to + 1 : to)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    // If the drag leaves this row without dropping (common when the user lifts their
    // finger between cards or cancels), clear the dragging state so the widget doesn't
    // stay stuck at reduced opacity and disabled. Without this, a cancelled drag left
    // areas greyed and uninteractable.
    func dropExited(info: DropInfo) {
        if dropTarget == item { dropTarget = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // Only clear if a drop didn't already resolve it.
            if dragging == item { dragging = nil }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        dropTarget = nil
        // SwiftUI invokes performDrop on the main thread; honor the MainActor closure safely.
        MainActor.assumeIsolated { onCommit() }
        return true
    }
}

private struct WidgetRemovalDropDelegate: DropDelegate {
    @Binding var dragging: HomeWidget?
    var onRemove: @MainActor (HomeWidget) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let widget = dragging else { return false }
        dragging = nil
        MainActor.assumeIsolated { onRemove(widget) }
        return true
    }
}

/// Window-level one-finger long press used only while Home is the visible screen.
/// Installing at the window avoids stealing taps from controls inside each widget.
private struct OneFingerWidgetLongPressCatcher: UIViewRepresentable {
    let onFire: @MainActor () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = WidgetPressObserver()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.onFire = onFire }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.detach() }
    func makeCoordinator() -> Coordinator { Coordinator(onFire: onFire) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onFire: @MainActor () -> Void
        private weak var window: UIWindow?
        private var recognizer: UILongPressGestureRecognizer?

        init(onFire: @escaping @MainActor () -> Void) { self.onFire = onFire }

        func attach(to window: UIWindow) {
            guard self.window !== window else { return }
            detach()
            let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            press.minimumPressDuration = 0.65
            press.numberOfTouchesRequired = 1
            press.allowableMovement = 18
            press.cancelsTouchesInView = false
            press.delegate = self
            window.addGestureRecognizer(press)
            self.window = window
            recognizer = press
        }

        func detach() {
            if let recognizer { window?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            window = nil
        }

        @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            let screen = QAContextCapture.current().screen.lowercased()
            guard screen.contains("home") else { return }
            MainActor.assumeIsolated { onFire() }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    private final class WidgetPressObserver: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { coordinator?.attach(to: window) } else { coordinator?.detach() }
        }
    }
}

extension View {
    /// Apply a modifier only when `condition` is true. Used so drag/drop attaches only in edit mode.
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition { transform(self) } else { self }
    }
}
