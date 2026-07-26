// MainTabView.swift — Unified navigation for iPhone and iPad.
// iPhone: custom StockedTabBar pill + drawer + pull tab
// iPad:   native TabView (no custom layout = no GPU fence timeout) + drawer + pull tab
import SwiftUI
import os

struct MainTabView: View {
    @Environment(AppSession.self) var session
    @State private var sharedRecipeForm: AddRecipeForm? = nil
    @State private var sharedRecipeSource = "Shared"
    @State private var shareImportError: String? = nil
    @Environment(\.stockedDevice) var device

    @State private var selected:     StockedTab = .home
    @State private var rootPopID:    [StockedTab: UUID] = [:]   // bump to pop a specific tab's stack to root

    // MARK: - Shared navigation — used by BOTH global nav bar AND drawer
    // Single source of truth: closes drawer, dismisses all overlays, switches tab.
    // Re-tapping the SAME tab pops that tab's stack to root.

    // MARK: - Shared-recipe import (from the Share Extension)
    @MainActor
    private func runShareImport() async {
        switch await SharedRecipeImporter.consumePendingDetailed() {
        case .success(let result):
            sharedRecipeSource = result.source
            sharedRecipeForm = result.form
        case .noPayload:
            shareImportError = "Couldn't find the shared item. Try sharing again — if it keeps happening, the share extension may need its App Group reconnected."
        case .scrapeFailed(let host):
            shareImportError = "Couldn't read a recipe from \(host). That page may not publish structured recipe data (common for social posts). Try a recipe-website link, or use Text Manually."
        case .nothingExtracted:
            shareImportError = "Couldn't find a recipe in what was shared."
        }
    }

    // MARK: - iPhone auto-hide tab bar control (mirrors iPad)
    private func revealIPhoneTabBar() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { iPhoneTabBarVisible = true }
        scheduleIPhoneTabBarAutoHide()
    }
    private func hideIPhoneTabBar() {
        iPhoneTabBarHideTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { iPhoneTabBarVisible = false }
    }
    private func scheduleIPhoneTabBarAutoHide() {
        iPhoneTabBarHideTask?.cancel()
        iPhoneTabBarHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // 4s idle → hide
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { iPhoneTabBarVisible = false }
        }
    }

    func navigate(to tab: StockedTab) {
        withAnimation(.spring(response: 0.3)) {
            showDrawer   = false
            showBrief    = false
            showReceipt  = false
            showAddItems = false
            showSearch   = false
            showStats    = false
            showDatabases = false
        }
        // #228 — tabs remember your place. Switching tabs no longer pops anything:
        // each tab keeps its pushed stack (recipe detail, cook flow, etc.) and you land
        // back exactly where you left. Tapping the tab you're ALREADY on pops it to its
        // main page — that's the explicit "take me back to the top" gesture.
        if selected == tab {
            rootPopID[tab] = UUID()   // iPhone: .id rebuild pops the current tab to root
            NotificationCenter.default.post(name: .stockedPopToRoot, object: nil)   // iPad path
            return
        }
        selected = tab
    }
    // Force-return to a clean Home: pop the Home tab's stack to root, then select it.
    // Used by deep flows (e.g. cook → rating) so finishing always lands on Home root.
    func goHomeToRoot() {
        withAnimation(.spring(response: 0.3)) {
            showDrawer = false; showReceipt = false; showAddItems = false
            showSearch = false; showStats = false; showDatabases = false
        }
        rootPopID[.home] = UUID()
        NotificationCenter.default.post(name: .stockedPopToRoot, object: nil)
        selected = .home
    }

    // Runs a drawer quick action from MainTabView's own context: close the drawer first,
    // then present the requested overlay after the close animation. Owning this here
    // (instead of a detached Task inside DrawerContent mutating parent bindings) fixes
    // the crash when opening Scan Receipt from the drawer.
    func performDrawerQuickAction(_ action: DrawerQuickAction) {
        withAnimation(.spring(response: 0.3)) { showDrawer = false }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            switch action {
            case .scanReceipt: showReceipt   = true
            case .scanBarcode: showBarcode   = true
            case .quickUpdate: activeDrawerSheet = .quickUpdate
            case .household:
                activeDrawerSheet = .household   // open to everyone for now (no premium gate)
            case .activity: activeDrawerSheet = .activity
            case .addItems:    showAddItems  = true
            case .search:      showSearch    = true
            case .stats:       showStats     = true
            case .databases:   showDatabases = true
            case .editProfile:   activeDrawerSheet = .editProfile
            case .notifications: activeDrawerSheet = .notifications
            case .dataStorage:     activeDrawerSheet = .dataStorage
            case .transferKitchen: activeDrawerSheet = .transferKitchen
            case .recipeSources:   activeDrawerSheet = .recipeSources
            case .storePopout:     activeDrawerSheet = .storePopout
            }
        }
    }

    @State private var showReceipt   = false
    @State private var showBarcode   = false   // #250 — Scan Barcode (Action Center + Add Item)
    @State private var showAddItems  = false
    @State private var showSearch    = false
    @State private var showStats     = false
    @State private var showDatabases = false
    // One enum drives a SINGLE .sheet(item:) for the drawer account sheets. Stacking six
    // .sheet(isPresented:) on one view made SwiftUI present one then dismiss it (needed a
    // second tap); a single item-driven sheet presents reliably on the first tap.
    private enum DrawerActionSheet: Int, Identifiable {
        case editProfile, notifications, quickUpdate, household, householdPaywall, activity
        case dataStorage, transferKitchen, recipeSources, storePopout
        var id: Int { rawValue }
    }
    @State private var activeDrawerSheet: DrawerActionSheet? = nil
    @State private var showDrawer    = false
    @State private var showBrief     = false
    // iPad navigation is persistent. It never auto-hides while scrolling or after idle time.
    // iPhone auto-hide tab bar: visible by default, hides when the content is scrolled,
    // reveals on a tap near the bottom edge, auto-hides after idle.
    @State private var iPhoneTabBarVisible = true
    @State private var iPhoneTabBarHideTask: Task<Void, Never>? = nil

    private var drawerWidth:   CGFloat { SS.drawerW.value(for: device) }
    private var tabBarHeight:  CGFloat { SS.tabBarH.value(for: device) }

    private func openBrief() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showBrief = true }
    }

    private var safeBottomInset: CGFloat { StockedScreen.safeBottomInset }

    // MARK: - Body
    // Architecture: VStack separates content from global nav — nothing ever overlaps.
    // Outer ZStack only for drawer (which intentionally covers global nav when open).
    // Decide iPad vs iPhone from UIDevice directly. The injected stockedDevice
    // environment can be transiently .regular during the onboarding→main swap, which
    // would route iPad into iPhoneBody (whose iphoneTabArea blanks iPad). UIDevice is
    // always correct and never transient.
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        Group {
            if isPad {
                iPadBody
            } else {
                iPhoneBody
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedSwitchTab)) { note in
            if let tab = note.object as? StockedTab { navigate(to: tab) }
        }
        // #235 — Home's redesigned cards fire drawer quick actions + the Daily Brief
        // without needing MainTabView bindings threaded through.
        .onReceive(NotificationCenter.default.publisher(for: .stockedQuickAction)) { note in
            if let action = note.object as? DrawerQuickAction { performDrawerQuickAction(action) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedShowBrief)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showBrief = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedOpenSearch)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showSearch = true }
        }
        .background(keyboardShortcuts)
        // Consume a recipe shared in via the Share Extension. We check on appear (covers a
        // cold launch where the share started the app) and whenever the flag flips (covers the
        // app already running). The payload is deciphered off the App Group, then shown in the
        // editable form regardless of which tab is active.
        // Consume a recipe shared in via the Share Extension. IMPORTANT: we do NOT use
        // .task(id: pendingSharedRecipe) here — the consume sets the flag back to false, which
        // would change the task id and cancel the in-flight network scrape ("network error —
        // cancelled"). Instead we observe the flag and launch a Task whose lifetime isn't tied
        // to this view's render cycle, so the scrape can finish.
        .onChange(of: session.pendingSharedRecipe) { _, isPending in
            guard isPending else { return }
            session.pendingSharedRecipe = false
            Log.app.log("ShareImport: consumer fired (flag was set)")
            Task { await runShareImport() }
        }
        .task {
            // LAG FIX: notification rescheduling + widget refresh used to run on the very
            // first frame of the main UI, stacked on top of household sync, migrations and
            // image backfill. Defer them a few seconds — they are background maintenance and
            // nothing user-visible depends on them at launch.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                DailyBriefNotificationManager.shared.rescheduleAll(store: session.guestStore)
                WidgetBridge.refresh(store: session.guestStore)
                // Server daily briefs: upload the (scrubbed) context snapshot at most
                // every 12h so the Worker cron can generate household briefs.
                DailyBriefContextUploader.uploadIfNeeded(store: session.guestStore)
            }
            // Cold-launch case: the flag may already be true before onChange can observe a change.
            if session.pendingSharedRecipe {
                session.pendingSharedRecipe = false
                Log.app.log("ShareImport: consumer fired (flag already set at appear)")
                await runShareImport()
            }
        }
        .alert("Import", isPresented: Binding(get: { shareImportError != nil }, set: { if !$0 { shareImportError = nil } })) {
            Button("OK", role: .cancel) { shareImportError = nil }
        } message: {
            Text(shareImportError ?? "")
        }
        .sheet(item: Binding<SharedRecipeFormBox?>(
            get: { sharedRecipeForm.map { SharedRecipeFormBox(form: $0) } },
            set: { if $0 == nil { sharedRecipeForm = nil } }
        )) { box in
            CreateRecipeView(prefill: box.form, prefillSource: sharedRecipeSource)
                .environment(session)
        }
        // Account sheets — presented from the stable root (not from inside the drawer's
        // List), so they open first-tap and the system dismiss() works.
        .sheet(item: $activeDrawerSheet) { sheet in
            switch sheet {
            case .editProfile:      QuizEditView().environment(session)
            case .notifications:    NavigationStack { DailyBriefNotificationSettingsView().environment(session) }
            case .quickUpdate:      QuickUpdateSheet().environment(session)
            case .household:        HouseholdHomeView().environment(session)
            case .householdPaywall: HouseholdPaywallView(onUnlocked: { activeDrawerSheet = .household }).environment(session)
            case .activity:         ActivityFeedSheet().environment(session)
            case .dataStorage:      DataStorageView().environment(session)
            case .transferKitchen:  KitchenTransferView().environment(session)
            case .recipeSources:    RecipeSourcesManagerView().environment(session)
            case .storePopout:      PreferredStorePopout().environment(session)
            }
        }
        // #228/#229 — floating "In Progress" pill, isolated in its own view. Crucially,
        // MainTabView's body must NOT read session.activeCook directly: if it did,
        // clearing activeCook (on Finish Cooking) would re-evaluate this whole body and
        // rebuild the tab NavigationStack mid-push — blanking the plating screen. The
        // subview owns that read, so clearing the cook only re-renders the pill.
        .overlay(alignment: .bottom) {
            InProgressCookPill(isHome: selected == .home && !showDrawer && !showBrief,
                               bottomInset: isPad ? 24 : 96,
                               goHome: { goHomeToRoot() })
        }
    }

    // Hardware-keyboard shortcuts (iPad with keyboard / Mac): ⌘N new item, ⌘F search,
    // ⌘1–4 switch tabs. Rendered as zero-size hidden buttons so they register globally.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { showAddItems = true }.keyboardShortcut("n", modifiers: .command)
            Button("") { showSearch = true }.keyboardShortcut("f", modifiers: .command)
            Button("") { navigate(to: .home) }.keyboardShortcut("1", modifiers: .command)
            Button("") { navigate(to: .inventory) }.keyboardShortcut("2", modifiers: .command)
            Button("") { navigate(to: .recipes) }.keyboardShortcut("3", modifiers: .command)
            Button("") { navigate(to: .grocery) }.keyboardShortcut("4", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - iPad body
    // Drawer-only navigation. Renders the selected tab via the minimal iPadTabArea
    // (plain NavigationStack, no .id rebuild, no toolbar modifiers — those were the
    // iPad blank-screen trigger), with the pull tab + drawer overlaid.
    private var iPadBody: some View {
        ZStack(alignment: .leading) {
            session.themeBgColor.ignoresSafeArea()

            iPadContentArea

            // Pull-tab + drawer in one self-contained layer that owns the drag state, so
            // dragging it doesn't re-render the tab content behind it (smooth gestures).
            DrawerDragLayer(
                showDrawer:    $showDrawer,
                selected:      $selected,
                showReceipt:   $showReceipt,
                showAddItems:  $showAddItems,
                showSearch:    $showSearch,
                showStats:     $showStats,
                showDatabases: $showDatabases,
                onNavigate:    { tab in navigate(to: tab) },
                onQuickAction: { action in performDrawerQuickAction(action) }
            )
            .zIndex(1000)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // iPad content: the selected tab + overlays with a permanently visible global tab bar.
    private var iPadContentArea: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .leading) {
                iPadTabArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showBrief {
                    DailyBriefOverlay(
                        isPresented:    $showBrief,
                        onScanReceipt:  { showBrief = false; Task { try? await Task.sleep(nanoseconds: 300_000_000); showReceipt = true } },
                        onScanBarcode:  { showBrief = false; Task { try? await Task.sleep(nanoseconds: 300_000_000); showBarcode = true } },
                        onShoppingList: { showBrief = false; navigate(to: .grocery) },
                        onPreferences:  { showBrief = false; withAnimation(.spring(response: 0.3)) { showDrawer = true } },
                        onKitchenReport: { showBrief = false; Task { try? await Task.sleep(nanoseconds: 300_000_000); showStats = true } }
                    )
                    .environment(session)
                    .transition(.opacity)
                }
                if showReceipt   { overlaySheet($showReceipt)   { ReceiptScannerView() } }
                if showBarcode   { overlaySheet($showBarcode)   { BarcodeScannerView { _, _ in showBarcode = false } } }
                if showAddItems  { overlaySheet($showAddItems)  { AddItemSheet(defaultZone: "Fridge") } }
                if showSearch    { overlaySheet($showSearch)    { GlobalSearchView() } }
                if showStats     { overlaySheet($showStats)     { StatsView() } }
                if showDatabases { overlaySheet($showDatabases) { DatabasesView() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, tabBarHeight + safeBottomInset + 12)

            StockedTabBar(
                selected:  $selected,
                onTap:     { tab in navigate(to: tab) },
                onSameTap: { navigate(to: selected) }
            )
            .frame(maxWidth: 600)
            .padding(.bottom, safeBottomInset + 6)
            .zIndex(150)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - iPhone body
    // Architecture: VStack separates content from global nav — nothing ever overlaps.
    // Outer ZStack only for drawer (which intentionally covers global nav when open).
    private var iPhoneBody: some View {
        ZStack(alignment: .leading) {

            // ── Layout: content fills all space, global nav anchored below ──
            VStack(spacing: 0) {

                // Content area — all 4 hubs + sheets + overlays
                ZStack {
                    iphoneTabArea
                        // Tab bar stays visible on every screen (no auto-hide on scroll).

                    // Brief + coach mark (above hub content)
                    if showBrief {
                        DailyBriefOverlay(
                            isPresented:    $showBrief,
                            onScanReceipt:  { showBrief = false; Task { try? await Task.sleep(nanoseconds: 300_000_000); showReceipt = true } },
                            onScanBarcode:  { showBrief = false; Task { try? await Task.sleep(nanoseconds: 300_000_000); showBarcode = true } },
                            onShoppingList: { showBrief = false; navigate(to: .grocery) },
                            onPreferences:  { showBrief = false; withAnimation(.spring(response: 0.3)) { showDrawer = true } },
                            onKitchenReport: { showBrief = false; Task { try? await Task.sleep(nanoseconds: 300_000_000); showStats = true } }
                        )
                        .environment(session)
                        .transition(.opacity)
                    }

                    // Sheet overlays — fill content area, global nav stays visible below
                    if showReceipt   { overlaySheet($showReceipt)   { ReceiptScannerView() } }
                    if showBarcode   { overlaySheet($showBarcode)   { BarcodeScannerView { _, _ in showBarcode = false } } }
                    if showAddItems  { overlaySheet($showAddItems)  { AddItemSheet(defaultZone: "Fridge") } }
                    if showSearch    { overlaySheet($showSearch)    { GlobalSearchView() } }
                    if showStats     { overlaySheet($showStats)     { StatsView() } }
                    if showDatabases { overlaySheet($showDatabases) { DatabasesView() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // ── Global bottom navigation — iPhone tab bar ──────────────
                // Always visible on every screen (hidden only while the Daily Brief is
                // open, which presents its own full-screen surface).
                if !showBrief {
                    StockedTabBar(
                        selected:  $selected,
                        onTap:     { tab in navigate(to: tab) },
                        onSameTap: { navigate(to: selected) }
                    )
                        .padding(.bottom, safeBottomInset)
                        .background(session.themeBgColor.ignoresSafeArea(edges: .bottom))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ignoresSafeArea(edges: .bottom)
            // Navigation handled by navigate(to:) — no onChange needed
            .onAppear {
                let uiColor = UIColor(session.themeBgColor)
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
                    .forEach { $0.backgroundColor = uiColor }
                // The old full-screen welcome carousel was removed. New users are now introduced
                // by the per-page coachmark tour (see Coachmark.swift), which highlights features
                // in place on each page's first visit.
            }

            // ── Pull-tab + drawer in one self-contained drag layer (smooth gestures) ──
            // Hidden while the Daily Brief is open so the brief shows on its own.
            if !showBrief {
                DrawerDragLayer(
                    showDrawer:    $showDrawer,
                    selected:      $selected,
                    showReceipt:   $showReceipt,
                    showAddItems:  $showAddItems,
                    showSearch:    $showSearch,
                    showStats:     $showStats,
                    showDatabases: $showDatabases,
                    onNavigate:    { tab in navigate(to: tab) },
                    onQuickAction: { action in performDrawerQuickAction(action) }
                )
                .zIndex(1000)
            }
        }
    }

    // MARK: - iPhone tab area
    // ONE NavigationStack rendering only the SELECTED tab's content — never all four at
    // once (building every hub simultaneously triggers a GPU-fence timeout → blank screen).
    // The tab bar lives OUTSIDE this stack (in the VStack below), so tab buttons always
    // switch tabs and work from every screen. The .id below rebuilds the stack at root
    // whenever the tab changes OR the tab is re-tapped (pop-to-root), so deep flows never
    // linger when navigating away.
    private var iphoneTabArea: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea(.all)
                // Render only the selected iPhone tab. Keeping every recipe and grocery
                // screen alive behind opacity allowed hidden grids, image tasks, and marquee
                // animations to keep consuming the main thread while the drawer was moving.
                tabContent(selected)
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarBackground(session.themeBgColor, for: .navigationBar)
            .toolbarColorScheme(session.isDarkMode ? .dark : .light, for: .navigationBar)
        }
        .id("\(selected.rawValue)#\(rootPopID[selected]?.uuidString ?? "0")")
        .background(session.themeBgColor)
        .scrollContentBackground(.hidden)
        .environment(\.stockedTitleTap, openBrief)
        .environment(\.stockedGoHome, { goHomeToRoot() })
    }

    // MARK: - iPad tab area
    // Deliberately minimal: a plain NavigationStack with the selected tab's content and
    // NO .id() rebuild and NO toolbar modifiers. The toolbar modifiers + .id rebuild were
    // the iPad-specific blank-screen trigger (StockedShell already hides its own nav bar,
    // so hiding it again here was redundant and fenced on iPad). Tab switching rebuilds
    // naturally because `selected` changes; pop-to-root is handled by goHomeToRoot()/
    // navigate(to:) which also drive `selected`.
    private var iPadTabArea: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea(.all)
            // Keep-alive remains iPad-only so wider multi-column screens preserve each tab's
            // scroll position. iPhone renders only the active tab to keep the drawer and recipe
            // transitions responsive on the tighter memory and animation budget.
            ForEach(StockedTab.allCases, id: \.self) { tab in
                NavigationStack {
                    ZStack {
                        session.themeBgColor.ignoresSafeArea(.all)
                        tabContent(tab)
                    }
                }
                .opacity(selected == tab ? 1 : 0)
                .allowsHitTesting(selected == tab)
                .accessibilityHidden(selected != tab)
            }
        }
        .environment(\.stockedTitleTap, openBrief)
        .environment(\.stockedGoHome, { goHomeToRoot() })
    }

    // Single-selected-tab variant (used as a diagnostic in Build 140). Renders only the
    // active tab — lower memory but does NOT preserve per-tab scroll/expanded state on
    // switch. Kept for reference; the keep-alive version above is the one in use.
    private var iPadTabAreaSelectedOnly: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea(.all)
            NavigationStack {
                ZStack {
                    session.themeBgColor.ignoresSafeArea(.all)
                    tabContent(selected)
                }
            }
        }
        .environment(\.stockedTitleTap, openBrief)
        .environment(\.stockedGoHome, { goHomeToRoot() })
    }

    // MARK: - Overlay Sheet (tab bar always visible beneath)
    // Replaces .sheet() — slides up from above the tab bar, not from screen bottom.
    // Tap the dim area to dismiss. Tab bar remains fully interactive.
    @ViewBuilder
    private func overlaySheet<Content: View>(_ isPresented: Binding<Bool>,
                                             @ViewBuilder content: @escaping () -> Content) -> some View {
        ZStack(alignment: .bottom) {
            // Dim overlay — fills content area only, does NOT extend over global nav
            Color.black.opacity(0.45)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isPresented.wrappedValue = false
                    }
                }

            // Sheet content — stops above tab bar.
            // compositingGroup() flattens the content (including any inner
            // .ignoresSafeArea() backgrounds) BEFORE the clip, so nothing bleeds past
            // the rounded top corners (was showing a gray wedge in the corners).
            content()
                .environment(session)
                .environment(\.stockedDismiss, {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isPresented.wrappedValue = false
                    }
                })
                .environment(\.stockedTitleTap, {
                    // On an overlay sub-screen, tapping the title closes back to the
                    // main shell (where the Daily Brief lives).
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isPresented.wrappedValue = false
                    }
                })
                .frame(maxWidth: device == .tablet ? 900 : .infinity, maxHeight: .infinity)
                .background(session.themeBgColor)
                .compositingGroup()
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 20, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: 20
                ))
                .shadow(color: .black.opacity(0.3), radius: 20, y: -4)
                .frame(maxWidth: .infinity)   // center the constrained sheet on iPad
                // Swipe DOWN anywhere on the sheet to exit the whole flow at once (so a
                // multi-step flow like Add Item doesn't require tapping Back repeatedly).
                .simultaneousGesture(
                    DragGesture(minimumDistance: 40)
                        .onEnded { value in
                            if value.translation.height > 100 && abs(value.translation.width) < 80 {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    isPresented.wrappedValue = false
                                }
                            }
                        }
                )
                // No bottom padding needed — global nav is below in VStack
        }
        .zIndex(500)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Tab Content
    @ViewBuilder
    func tabContent(_ tab: StockedTab) -> some View {
        switch tab {
        case .home:
            HomeView().withQuickMenu(onScanReceipt: { showReceipt = true }, onAddItems: { showAddItems = true }, onShoppingList: { navigate(to: .grocery) }).qaScreen("Home")
        case .cook:
            CookHubView().withQuickMenu(onScanReceipt: { showReceipt = true }, onAddItems: { showAddItems = true }, onShoppingList: { navigate(to: .grocery) }).qaScreen("Cook")
        case .inventory:
            InventoryHubView().withQuickMenu(onScanReceipt: { showReceipt = true }, onAddItems: { showAddItems = true }, onShoppingList: { navigate(to: .grocery) }).qaScreen("Inventory")
        case .recipes:
            RecipeVaultView().withQuickMenu(onScanReceipt: { showReceipt = true }, onAddItems: { showAddItems = true }, onShoppingList: { navigate(to: .grocery) }).qaScreen("Recipes")
        case .grocery:
            GroceryListView().withQuickMenu(onScanReceipt: { showReceipt = true }, onAddItems: { showAddItems = true }, onShoppingList: { navigate(to: .grocery) }).qaScreen("Grocery")
        }
    }
}

extension Notification.Name {
    // Posted by navigate(to:)/goHomeToRoot(); tab roots observe it to clear pushed
    // deep-flow destinations. iPad-safe pop-to-root (the .id stack rebuild blanks iPad).
    static let stockedPopToRoot = Notification.Name("stockedPopToRoot")
    static let stockedRerollSuggestions = Notification.Name("stockedRerollSuggestions")  // #11
    static let stockedSwitchTab = Notification.Name("stockedSwitchTab")
    static let stockedQuickAction = Notification.Name("stockedQuickAction")   // #235 — Home cards → drawer quick actions
    static let stockedShowBrief = Notification.Name("stockedShowBrief")       // #235 — Home row → Daily Brief
    static let stockedOpenSearch = Notification.Name("stockedOpenSearch")     // header search button (#7)
    static let stockedOpenCookRightNow = Notification.Name("stockedOpenCookRightNow") // #13/#14 notif → Cook Right Now
}


// Owns the pull-tab + drawer and ALL of their drag state locally. This is the key to smooth
// dragging: previously the drag offsets were @State on MainTabView, so every drag frame
// re-evaluated MainTabView's whole body — including the four keep-alive iPad tabs — which
// made the drag stutter. With the drag state confined to this child view, dragging re-renders
// ONLY this layer; the tabs behind it are never touched. (It overlays the screen and positions
// its own pull-tab + drawer — it does NOT wrap or reframe the tab area, so it can't affect the
// tab layout the way the Build 147 attempt did.)
struct DrawerDragLayer: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedDevice) var device

    @Binding var showDrawer:    Bool
    @Binding var selected:      StockedTab
    @Binding var showReceipt:   Bool
    @Binding var showAddItems:  Bool
    @Binding var showSearch:    Bool
    @Binding var showStats:     Bool
    @Binding var showDatabases: Bool
    var onNavigate:    (StockedTab) -> Void
    var onQuickAction: (DrawerQuickAction) -> Void

    private var drawerWidth: CGFloat { SS.drawerW.value(for: device) }

    // Live finger translation while a drag is in progress (0 when not dragging). Combined with
    // the resting position below so the drawer tracks the finger 1:1, then springs to a final
    // open/closed state on release.
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false

    // Resting position: open (0) or closed (-drawerWidth).
    private var restOffsetX: CGFloat { showDrawer ? 0 : -drawerWidth }

    // Resting position plus the in-flight drag, clamped so the panel can't be pulled past
    // fully-open or pushed past fully-closed.
    private var drawerOffsetX: CGFloat {
        min(0, max(-drawerWidth, restOffsetX + dragOffset))
    }

    // How far open the drawer is right now, 0 (closed) ... 1 (open). Drives the dim overlay
    // and pull-tab position so they move smoothly with the drag, not just on the final toggle.
    private var openFraction: CGFloat {
        guard drawerWidth > 0 else { return showDrawer ? 1 : 0 }
        return (drawerOffsetX + drawerWidth) / drawerWidth
    }

    private let openSpring  = Animation.spring(response: 0.35, dampingFraction: 0.85)
    // Minimum horizontal travel before we treat a drag as a drawer drag (lets vertical
    // scrolls and taps pass through untouched).
    private let dragActivate: CGFloat = 12

    // Decide the resting state on release from BOTH position and throw velocity, so a quick
    // flick opens/closes even if the finger did not travel past the halfway point.
    private func settle(predictedTranslation: CGFloat) {
        let projected = drawerOffsetX + (predictedTranslation - dragOffset)
        let shouldOpen = projected > -drawerWidth / 2
        let changed = shouldOpen != showDrawer
        withAnimation(openSpring) {
            showDrawer = shouldOpen
            dragOffset = 0
        }
        isDragging = false
        if changed { HapticManager.select() }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Dim behind the drawer — its opacity tracks how far open the drawer is, so it
            // fades in smoothly during the drag. Tapping it (when open) closes the drawer.
            if openFraction > 0.001 {
                Color.black.opacity(0.35 * openFraction)
                    .ignoresSafeArea()
                    .allowsHitTesting(showDrawer && !isDragging)
                    .onTapGesture { withAnimation(openSpring) { showDrawer = false } }
                    .zIndex(1100)
            }

            // Closed-state left-edge catcher: a slim transparent strip that turns a rightward
            // swipe from the screen edge into an open drag, AND a tap into an open. Present only
            // while the drawer is closed, so it never blocks content when the drawer is open.
            // Sits BELOW the visible pull tab (zIndex 100) so the tab's own button still works;
            // the tap handler here covers taps that land in the wider edge zone but off the tab.
            // #FB2 — the strip's TOP segment (header height) no longer accepts taps: taps
            // aimed at the back chevron were opening the drawer instead. Swipe-to-open
            // still works across the full height; tap-to-open works below the header.
            if !showDrawer {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 116)
                        .contentShape(Rectangle())
                        .gesture(edgeDragGesture)
                    Color.clear
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            HapticManager.select()
                            withAnimation(openSpring) { showDrawer = true }
                        }
                        .gesture(edgeDragGesture)
                }
                .frame(width: 28)
                .frame(maxHeight: .infinity, alignment: .leading)
                .zIndex(50)
            }

            // Drawer panel — slides in/out on showDrawer, and tracks the finger while dragging.
            DrawerContent(
                selected:      $selected,
                showDrawer:    $showDrawer,
                showReceipt:   $showReceipt,
                showAddItems:  $showAddItems,
                showSearch:    $showSearch,
                showStats:     $showStats,
                showDatabases: $showDatabases,
                onNavigate:    onNavigate,
                onQuickAction: onQuickAction
            )
            .frame(width: drawerWidth)
            .offset(x: drawerOffsetX)
            .animation(isDragging ? nil : openSpring, value: showDrawer)
            // Open-state drag: a leftward drag on the panel itself closes the drawer.
            .gesture(panelDragGesture)
            .zIndex(1200)

            // Left-edge pull tab (tap to open).
            HStack(spacing: 0) { pullTab; Spacer() }
                .zIndex(100)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Drag that OPENS the drawer from the closed state (starts at the left edge).
    private var edgeDragGesture: some Gesture {
        DragGesture(minimumDistance: dragActivate)
            .onChanged { value in
                guard value.translation.width > 0 || isDragging else { return }
                isDragging = true
                dragOffset = max(0, value.translation.width)
            }
            .onEnded { value in
                guard isDragging else { return }
                settle(predictedTranslation: value.predictedEndTranslation.width)
            }
    }

    // Drag that CLOSES the drawer from the open state (leftward on the panel).
    private var panelDragGesture: some Gesture {
        DragGesture(minimumDistance: dragActivate)
            .onChanged { value in
                guard showDrawer else { return }
                guard value.translation.width < 0 || isDragging else { return }
                isDragging = true
                dragOffset = min(0, value.translation.width)
            }
            .onEnded { value in
                guard isDragging else { return }
                settle(predictedTranslation: value.predictedEndTranslation.width)
            }
    }

    private var pullTab: some View {
        // Slim edge handle. The old tab was a tall opaque slab (defaulted ~28×112) that
        // floated over content; this is a thin grabber with a generous transparent hit
        // area, so it stays easy to tap without covering recipe cards / list rows.
        return VStack {
            Spacer()
            Button {
                HapticManager.select()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    showDrawer = true
                }
            } label: {
                ZStack(alignment: .leading) {
                    Color.clear.frame(width: 26, height: 72)          // easy-to-hit target
                    Capsule()
                        .fill(Color.stockedCharcoal.opacity(0.55))
                        .frame(width: 5, height: 46)
                        .shadow(color: .black.opacity(0.18), radius: 3, x: 2, y: 0)
                        .padding(.leading, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .a11yButton("Open menu", hint: "Opens the menu drawer.")
            .accessibilityIdentifier("btn_menu_pull_tab")
            Spacer()
        }
        // Pull tab rides the drawer edge: follows the live drag, then settles with the spring.
        .offset(x: openFraction * drawerWidth)
        .animation(isDragging ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: showDrawer)
        .opacity(showDrawer ? 0 : 1)
    }
}

// MARK: - In Progress cook pill (#229)
// Isolated so the parent body never depends on session.activeCook. Reads it here;
// owns the resume cover. Clearing the active cook re-renders only this pill — never
// the tab NavigationStack — so finishing a cook can't blank the plating screen.
private struct InProgressCookPill: View {
    @Environment(AppSession.self) private var session
    let isHome: Bool
    let bottomInset: CGFloat
    let goHome: () -> Void
    @State private var resumeCook: AppSession.ActiveCookSession? = nil

    var body: some View {
        Group {
            if let cook = session.activeCook, isHome {
                Button { resumeCook = cook } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.stockedGold)
                        Text("Cooking: \(cook.title)")
                            .font(.system(size: 13, weight: .semibold, design: .serif))
                            .foregroundStyle(Color.stockedWhite)
                            .lineLimit(1)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.stockedWhite.opacity(0.5))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(Color.stockedCharcoal.opacity(0.95))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                    .frame(maxWidth: 280)
                }
                .buttonStyle(.plain)
                .padding(.bottom, bottomInset)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        // Snapshot-driven (item:) so clearing activeCook can't blank a still-open cover.
        .fullScreenCover(item: $resumeCook) { cook in
            NavigationStack {
                CookingFlashcardView(recipeTitle: cook.title,
                                     ingredients: cook.ingredients,
                                     steps: cook.steps,
                                     baseServings: cook.servings)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { resumeCook = nil }
                        }
                    }
            }
            .environment(session)
            .environment(\.stockedGoHome, { resumeCook = nil; goHome() })
        }
    }
}
