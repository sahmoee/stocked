// HomeView.swift — Home tab, 1:1 with the master mockup sheet (#246).
// Order: greeting → Daily Brief card → What's New → Action Center → Use It Soon.
import SwiftUI
import UniformTypeIdentifiers
import os

struct HomeView: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedDevice) var device
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    // Single .sheet(item:) — stacked .sheet(isPresented:) made these need a second tap.
    private enum HomeScreenSheet: Int, Identifiable {
        case quickUpdate, activityFeed, widgetGallery
        var id: Int { rawValue }
    }
    @State private var activeHomeSheet: HomeScreenSheet? = nil
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

    private var greeting: String { StockedFormatters.timeOfDayGreeting }
    private var sub: Color { Color.appSubtextStrong(session.isDarkMode) }

    private var expiringCount: Int { store.metrics.expiringSoonCount }
    private var mealsAvailable: Int { store.metrics.mealsReady }

    var body: some View {
        StockedShell(leadingTitle: true,
                     trailingIcon: editMode ? "checkmark" : nil,
                     trailingLabel: editMode ? "Done" : "",
                     onTrailing: {
                         if editMode { exitEditMode() }
                     }) {
            VStack(alignment: .leading, spacing: 20) {

                // ── Greeting (fixed header — like the iPhone, not a removable widget) ──
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(greeting), \(session.userName)")
                            .font(.system(size: 26, weight: .bold, design: .serif))
                            .dynamicTypeSize(.xSmall ... .accessibility2)
                            .foregroundStyle(session.isDarkMode ? session.accentColor : Color.stockedWhite)
                        Text(editMode ? "Tap − to remove, + to add widgets." : "Here's what's happening in your kitchen.")
                            .font(.system(size: 14.5))
                            .foregroundStyle(sub)
                    }
                    Spacer()
                    if editMode {
                        Button { exitEditMode() } label: {
                            Text("Done")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.stockedCharcoal)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Color.stockedGold)
                                .clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 2)
                .coachmarkAnchor("home.greeting")

                // ── First-run activation (#18) ────────────────────────
                // When the kitchen is empty, show a guided card instead of a dead "0/0/0"
                // dashboard: one tap to scan a receipt or stock common staples, so the app
                // has data to work with within the first minute.
                if !editMode && session.guestStore.inventoryItems.isEmpty {
                    gettingStartedCard.padding(.horizontal, 24)
                }

                // ── Customizable widget board ─────────────────────────
                ForEach(visibleWidgets, id: \.self) { widget in
                    widgetView(widget)
                        // Keep the original press-and-hold customization gesture available even
                        // when a widget contains its own buttons or navigation links.
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in enterEditMode() }
                        )
                        .disabled(editMode)          // iOS-style: taps don't fire while editing
                        .padding(.horizontal, 24)
                        .coachmarkAnchor("home.widget.\(widget.rawValue)")
                        .overlay(alignment: .topLeading) {
                            if editMode { removeBadge(widget).offset(x: 14, y: -6) }
                        }
                        .overlay(alignment: .topTrailing) {
                            if editMode {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(session.themeTextColor.opacity(0.35))
                                    .padding(8)
                                    .offset(x: -28, y: 2)
                            }
                        }
                        .opacity(draggingWidget == widget ? 0.4 : 1)
                        .modifier(JiggleEffect(active: editMode))
                        // #11 — in edit mode, drag a widget to reorder the board.
                        .if(editMode) { view in
                            view
                                .onDrag {
                                    draggingWidget = widget
                                    return NSItemProvider(object: widget.rawValue as NSString)
                                }
                                .onDrop(of: [.text],
                                        delegate: WidgetDropDelegate(item: widget,
                                                                     layout: $layout,
                                                                     dragging: $draggingWidget,
                                                                     onCommit: { HomeWidget.saveLayout(layout); UsageMetrics.shared.record(.widgetsReordered) }))
                        }
                }

                // ── Add-widgets affordance (edit mode) ────────────────
                if editMode {
                    addWidgetTile.padding(.horizontal, 24)
                } else if visibleWidgets.isEmpty {
                    emptyBoardHint.padding(.horizontal, 24)
                }

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Long-press anywhere enters customize mode (iPhone-style).
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.5) { enterEditMode() }
            .navigationDestination(isPresented: $goExpiringList) { ExpiringSoonListView() }
            .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
                goExpiringList = false
                if editMode { exitEditMode() }
            }
            .sheet(item: $activeHomeSheet) { sheet in
                switch sheet {
                case .quickUpdate:   QuickUpdateSheet().environment(session)
                case .activityFeed:  ActivityFeedSheet().environment(session)
                case .widgetGallery: widgetGallerySheet
                }
            }
        }
        .coachmarks(page: .home, steps: HomeCoachmarks.steps)
    }

    private func enterEditMode() {
        guard !editMode else { return }
        HapticManager.medium()
        UsageMetrics.shared.record(.homeEditModeEntered)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { editMode = true }
    }

    // ── Action Center (extracted so every widget is a uniform view) ──
    private var actionCenterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Action Center")
                .font(.system(size: 16, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
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

    private var visibleWidgets: [HomeWidget] { layout }
    private var removedWidgets: [HomeWidget] {
        HomeWidget.allCases.filter { !layout.contains($0) }
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
            statWidget(.groceryCount, value: "\(groceryToBuy)", sub: groceryToBuy == 1 ? "item to buy" : "items to buy", tint: .stockedGold) {
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.grocery)
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
            HapticManager.light()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                layout.removeAll { $0 == widget }
            }
            HomeWidget.saveLayout(layout)
            UsageMetrics.shared.record(.widgetRemoved, detail: widget.rawValue)
        } label: {
            ZStack {
                Circle().fill(Color.stockedCharcoal).frame(width: 24, height: 24)
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(widget.title) widget")
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
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(removedWidgets.isEmpty ? session.themeTextColor.opacity(0.3) : Color.stockedGold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(removedWidgets.isEmpty ? "All widgets added" : "Add widgets")
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text(removedWidgets.isEmpty ? "Remove one above to choose it again"
                                                : "\(removedWidgets.count) available")
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                }
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(session.themeTextColor.opacity(0.25))
            )
        }
        .buttonStyle(.plain)
        .disabled(removedWidgets.isEmpty)
    }

    // Shown only if the user has removed every widget and isn't editing.
    // #18 — first-run activation card. Shown on Home only while the kitchen is empty.
    private var gettingStartedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.stockedGold)
                Text("Let's stock your kitchen")
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
            }
            Text("Add a few items and Stocked instantly shows meals you can cook, what's expiring, and a smarter grocery list. Takes about a minute.")
                .font(.system(size: 13.5))
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
                    Image(systemName: "plus.circle.fill").font(.system(size: 15, weight: .semibold))
                    Text("Stock \(StarterStaples.all.count) common staples")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                }
                .foregroundStyle(Color.stockedWhite)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.stockedCharcoal)
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }
            .buttonStyle(.plain)

            // Secondary: scan a receipt or barcode (reuses Action Center routing).
            HStack(spacing: 10) {
                gettingStartedSecondary(title: "Scan Receipt", icon: "doc.text.viewfinder") {
                    NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.scanReceipt)
                }
                gettingStartedSecondary(title: "Scan Barcode", icon: "barcode.viewfinder") {
                    NotificationCenter.default.post(name: .stockedQuickAction, object: DrawerQuickAction.scanBarcode)
                }
            }
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

    private func gettingStartedSecondary(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: { HapticManager.light(); action() }) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                Text(title).font(.system(size: 13.5, weight: .medium))
            }
            .foregroundStyle(session.themeTextColor.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(session.themeTextColor.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
    }

    private var emptyBoardHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 30))
                .foregroundStyle(session.themeTextColor.opacity(0.3))
            Text("Your Home is empty")
                .font(.system(size: 17, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            Text("Touch and hold to add widgets back.")
                .font(.system(size: 13.5))
                .foregroundStyle(session.themeTextColor.opacity(0.55))
            Button {
                HapticManager.medium()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { editMode = true }
                activeHomeSheet = .widgetGallery
            } label: {
                Text("Add widgets")
                    .font(.system(size: 14, weight: .semibold))
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
                    if removedWidgets.isEmpty {
                        Text("Every widget is already on your Home screen.")
                            .font(.system(size: 14))
                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                            .padding(.top, 40)
                    } else {
                        ForEach(removedWidgets, id: \.self) { widget in
                            Button {
                                HapticManager.success()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    layout.append(widget)
                                }
                                HomeWidget.saveLayout(layout)
                                UsageMetrics.shared.record(.widgetAdded, detail: widget.rawValue)
                                if removedWidgets.isEmpty { activeHomeSheet = nil }
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.stockedGold.opacity(0.14))
                                            .frame(width: 46, height: 46)
                                        Image(systemName: widget.icon)
                                            .font(.system(size: 19, weight: .semibold))
                                            .foregroundStyle(Color.stockedGold)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(widget.title)
                                            .font(.system(size: 16, weight: .bold, design: .serif))
                                            .foregroundStyle(session.themeTextColor)
                                        Text(widget.blurb)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(Color.stockedGold)
                                }
                                .padding(16)
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
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

    private func exitEditMode() {
        draggingWidget = nil   // never leave a widget stuck at drag opacity / disabled
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { editMode = false }
    }

    // MARK: - #253 Widget data + builders

    private var groceryToBuy: Int { store.metrics.groceryToBuy }
    private var lowStockCount: Int { store.metrics.lowStockCount }
    private var favoriteCount: Int {
        store.userRecipes.filter(\.isFavorited).count + store.favoriteRecipes.count
    }
    private var plannedCount: Int { store.plannedMeals.filter { !$0.isCooked }.count }
    private var stockLabel: String { store.metrics.stockStatusPhrase }

    // Compact stat card: big number + caption, gold icon chip, taps somewhere useful.
    private func statWidget(_ widget: HomeWidget, value: String, sub: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.15)).frame(width: 46, height: 46)
                    Image(systemName: widget.icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(widget.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(value)
                            .font(.system(size: 24, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text(sub)
                            .font(.system(size: 12.5))
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(widgetBackground)
        }
        .buttonStyle(.plain)
    }

    // Compact action shortcut: icon + title + caption, charcoal-tinted, single tap.
    private func actionWidget(_ widget: HomeWidget, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.15)).frame(width: 46, height: 46)
                    Image(systemName: widget.icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(widget.title)
                        .font(.system(size: 15.5, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text(widget.blurb)
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(widgetBackground)
        }
        .buttonStyle(.plain)
    }

    private var widgetBackground: some View {
        RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
            .fill(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
    }

    // Ready to Cook — recipes you can make from what's expiring (reuses store logic).
    private var readyToCookWidget: some View {
        let picks = store.recipesUsingExpiringItems(within: 4, limit: 3)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ready to Cook").font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                Button { NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.cook) } label: {
                    Text("Cook").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.stockedGold)
                }.buttonStyle(.plain)
            }
            if picks.isEmpty {
                Text("Nothing’s about to expire — cook anything you like.")
                    .font(.system(size: 13.5)).foregroundStyle(session.themeTextColor.opacity(0.55))
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 8) {
                    ForEach(picks, id: \.id) { r in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.stockedGreen)
                            Text(r.title).font(.system(size: 14, weight: .medium)).foregroundStyle(session.themeTextColor).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.3))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.30))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm + 2))
                    }
                }
            }
        }
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
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.stockedGreen.opacity(0.15)).frame(width: 46, height: 46)
                    Image(systemName: "leaf.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.stockedGreen)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waste Tracker").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.55))
                    Text("\(used) used · \(wasted) wasted")
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("last 30 days").font(.system(size: 11.5)).foregroundStyle(session.themeTextColor.opacity(0.5))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(16).frame(maxWidth: .infinity).background(widgetBackground)
        }.buttonStyle(.plain)
    }

    // Preferred store shortcut.
    private var preferredStoreWidget: some View {
        Button { NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.grocery) } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.stockedGold.opacity(0.15)).frame(width: 46, height: 46)
                    Image(systemName: "mappin.and.ellipse").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.stockedGold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preferred Store").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.55))
                    Text(session.preferredStore.isEmpty ? "Not set" : session.preferredStore)
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(16).frame(maxWidth: .infinity).background(widgetBackground)
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
        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.stockedGold.opacity(0.15)).frame(width: 46, height: 46)
                Image(systemName: "lightbulb.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.stockedGold)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Kitchen Tip").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.55))
                Text(tips[idx]).font(.system(size: 14)).foregroundStyle(session.themeTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity).background(widgetBackground)
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
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(Color.stockedWhite)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .a11yButton("Daily Brief", hint: "Opens your full daily brief")

                Spacer()

                if !briefCollapsed {
                    Text("Updated just now")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.stockedWhite.opacity(0.45))
                        .padding(.trailing, 10)
                }

                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        briefCollapsed.toggle()
                    }
                    UserDefaults.standard.set(briefCollapsed, forKey: briefCollapsedKey)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
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
                                 value: "\(store.metrics.stockPercent)% stocked",
                                 label: store.metrics.stockStatusSentence)
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
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.stockedWhite)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.stockedWhite.opacity(0.45))
                    }
                    .padding(.top, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .a11yButton("View full kitchen report")
            }
        }
        .padding(18)
        .background(Color.stockedCharcoal)
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
    }

    private func briefRow(icon: String, value: String, label: String, badged: Bool = false) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.stockedWhite.opacity(0.08)).frame(width: 38, height: 38)
                if badged {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.stockedGold, Color.stockedError)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.stockedGold)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(Color.stockedWhite)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.stockedWhite.opacity(0.55))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func quickAction(icon: String, title: String, caption: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(session.themeTextColor.opacity(0.75))
                    .frame(height: 24)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(session.themeTextColor)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.40))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
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
                .font(.system(size: 16, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)

            let rows = newsRows
            if rows.isEmpty {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.45))
                            .frame(width: 30, height: 30)
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 13))
                            .foregroundStyle(session.themeTextColor.opacity(0.6))
                    }
                    Text("No recent activity — changes will show here")
                        .font(.system(size: 13.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Spacer()
                }
            } else {
                VStack(spacing: 14) {
                    ForEach(rows) { row in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.45))
                                    .frame(width: 30, height: 30)
                                Image(systemName: row.icon).font(.system(size: 13))
                                    .foregroundStyle(session.themeTextColor.opacity(0.65))
                            }
                            Text(row.text).font(.system(size: 14))
                                .foregroundStyle(session.themeTextColor.opacity(0.9)).lineLimit(1)
                            Spacer()
                            Text(relative(row.when)).font(.system(size: 12))
                                .foregroundStyle(session.themeTextColor.opacity(0.45))
                        }
                    }
                }
            }

            Button { activeHomeSheet = .activityFeed } label: {
                HStack {
                    Text("See all activity")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.85))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 16, weight: .bold, design: .serif))
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
                    Text("View All").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                }.buttonStyle(.plain)
            }
            let items = store.urgentItems.prefix(3)
            if items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.system(size: 13))
                        .foregroundStyle(Color.stockedGreen)
                    Text("Nothing expiring soon — you're in good shape")
                        .font(.system(size: 13.5))
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
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(session.themeTextColor)
                            Spacer()
                            if let days = item.daysUntilExpiry {
                                Text(days < 0 ? "Expired \(-days) day\(days == -1 ? "" : "s") ago"
                                     : (days == 0 ? "Expires today" : (days == 1 ? "Expires tomorrow" : "Expires in \(days) days")))
                                    .font(.system(size: 12, weight: .semibold))
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
                            Image(systemName: row.icon).font(.system(size: 14))
                                .foregroundStyle(row.tint).frame(width: 22)
                            Text(row.text).font(.system(size: 14))
                                .foregroundStyle(session.themeTextColor)
                            Spacer()
                            Text(row.when, style: .relative)
                                .font(.system(size: 11.5))
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

    // #253 — Default board no longer includes the Daily Brief; it's now optional and
    // can be added from the gallery. Default is the everyday essentials.
    static let defaultLayout: [HomeWidget] = [.stockLevel, .actionCenter, .useItSoon, .tipOfDay]

    private static let layoutKey = "stocked.homeWidgetLayout_v3"   // v3: new default order (Stock Level, Action Center, Use It Soon, Kitchen Tip)

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
}

/// iPhone-style wiggle applied to each widget while the board is in edit mode.
struct JiggleEffect: ViewModifier {
    let active: Bool
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active ? (phase ? 0.7 : -0.7) : 0))
            .animation(active
                       ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true)
                       : .default,
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
    var onCommit: @MainActor () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = layout.firstIndex(of: dragging),
              let to = layout.firstIndex(of: item) else { return }
        if layout[to] != dragging {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // Only clear if a drop didn't already resolve it.
            if dragging == item { dragging = nil }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        // SwiftUI invokes performDrop on the main thread; honor the MainActor closure safely.
        MainActor.assumeIsolated { onCommit() }
        return true
    }
}

extension View {
    /// Apply a modifier only when `condition` is true. Used so drag/drop attaches only in edit mode.
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition { transform(self) } else { self }
    }
}
