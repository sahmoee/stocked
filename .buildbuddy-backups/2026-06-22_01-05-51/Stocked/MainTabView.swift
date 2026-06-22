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

    // MARK: - iPad auto-hide tab bar control
    private func revealIPadTabBar() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { iPadTabBarVisible = true }
        scheduleIPadTabBarAutoHide()
    }
    private func hideIPadTabBar() {
        iPadTabBarHideTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { iPadTabBarVisible = false }
    }
    private func scheduleIPadTabBarAutoHide() {
        iPadTabBarHideTask?.cancel()
        iPadTabBarHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // 4s idle → hide
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { iPadTabBarVisible = false }
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
            case .quickUpdate: showQuickUpdateSheet = true
            case .household:
                showHouseholdSheet = true   // open to everyone for now (no premium gate)
            case .activity: showActivityFeedMain = true
            case .addItems:    showAddItems  = true
            case .search:      showSearch    = true
            case .stats:       showStats     = true
            case .databases:   showDatabases = true
            case .editProfile:   showEditProfile  = true
            case .notifications: showNotifSettings = true
            }
        }
    }

    @State private var showReceipt   = false
    @State private var showBarcode   = false   // #250 — Scan Barcode (Action Center + Add Item)
    @State private var showAddItems  = false
    @State private var showSearch    = false
    @State private var showStats     = false
    @State private var showDatabases = false
    @State private var showEditProfile  = false   // Account sheets: presented from stable body
    @State private var showNotifSettings = false
    @State private var showQuickUpdateSheet = false   // #239 — drawer Quick Update
    @State private var showHouseholdSheet   = false   // #240 — drawer Household section
    @State private var showHouseholdPaywall = false
    @State private var showActivityFeedMain = false   // #245 — drawer Household → Activity
    @State private var showDrawer    = false
    @State private var showBrief     = false
    @State private var showCoachMark = false
    // iPad auto-hide tab bar: hidden by default, slides up on a tap near the bottom edge,
    // hides again when the content scrolls or after a few idle seconds.
    @State private var iPadTabBarVisible = false
    @State private var iPadTabBarHideTask: Task<Void, Never>? = nil
    // iPhone auto-hide tab bar: visible by default, hides when the content is scrolled,
    // reveals on a tap near the bottom edge, auto-hides after idle.
    @State private var iPhoneTabBarVisible = true
    @State private var iPhoneTabBarHideTask: Task<Void, Never>? = nil

    private let coachMarkKey = "hasSeenHeaderCoachMark_v2"
    @State private var showWalkthrough = false
    private let walkthroughKey = "hasSeenCoachWalkthrough_v1"
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
            // Refresh every scheduled notification against current inventory/profile.
            DailyBriefNotificationManager.shared.rescheduleAll(store: session.guestStore)
            // Push a fresh snapshot to the Home/Lock Screen widgets.
            WidgetBridge.refresh(store: session.guestStore)
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
        .sheet(isPresented: $showEditProfile) {
            QuizEditView().environment(session)
        }
        .sheet(isPresented: $showNotifSettings) {
            NavigationStack { DailyBriefNotificationSettingsView().environment(session) }
        }
        .sheet(isPresented: $showQuickUpdateSheet) {
            QuickUpdateSheet().environment(session)   // #239 — drawer Kitchen Tools entry
        }
        .sheet(isPresented: $showHouseholdSheet) {
            HouseholdHomeView().environment(session)   // new mockup-styled household experience
        }
        .sheet(isPresented: $showHouseholdPaywall) {
            HouseholdPaywallView(onUnlocked: { showHouseholdPaywall = false; showHouseholdSheet = true })
                .environment(session)
        }
        .sheet(isPresented: $showActivityFeedMain) {
            ActivityFeedSheet().environment(session)   // #245 — drawer Activity row
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
        .onAppear {
            // Show the bar once on launch so it's discoverable, then let it auto-hide.
            if !iPadTabBarVisible { revealIPadTabBar() }
        }
    }

    // iPad content: the selected tab + overlays + pull tab.
    private var iPadContentArea: some View {
        ZStack(alignment: .bottom) {
            // Content + overlays fill the whole area.
            ZStack(alignment: .leading) {
                iPadTabArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Hide the bar when the CONTENT is scrolled/dragged. Attached only to the
                    // content (not the whole ZStack), with a high threshold so a tab tap — which
                    // involves only a few points of finger jitter — never triggers a hide.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 24)
                            .onChanged { value in
                                if iPadTabBarVisible && abs(value.translation.height) > 24 {
                                    hideIPadTabBar()
                                }
                            }
                    )

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

            // Thin tap-catcher along the very bottom edge — tapping here reveals the bar.
            // A faint handle makes it discoverable (like a grab affordance).
            if !iPadTabBarVisible {
                HStack {
                    Spacer()
                    Capsule()
                        .fill(session.themeTextColor.opacity(0.25))
                        .frame(width: 44, height: 5)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .padding(.bottom, safeBottomInset + 4)
                .contentShape(Rectangle())
                .onTapGesture { revealIPadTabBar() }
            }

            // ── Floating bottom navigation — slides up when revealed ───────
            // Sits ABOVE the content's drag gesture (higher in the ZStack + zIndex), so its
            // Button taps are never intercepted by the scroll-to-hide gesture.
            if iPadTabBarVisible {
                StockedTabBar(
                    selected:  $selected,
                    onTap:     { tab in navigate(to: tab); scheduleIPadTabBarAutoHide() },
                    onSameTap: { navigate(to: selected); scheduleIPadTabBarAutoHide() }
                )
                    .frame(maxWidth: 600)
                    .padding(.bottom, safeBottomInset + 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(150)
            }
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
                    if showCoachMark {
                        HeaderCoachMark {
                            withAnimation(.easeOut(duration: 0.2)) { showCoachMark = false }
                            UserDefaults.standard.set(true, forKey: coachMarkKey)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                    if showWalkthrough {
                        CoachWalkthrough {
                            showWalkthrough = false
                            UserDefaults.standard.set(true, forKey: walkthroughKey)
                            UserDefaults.standard.set(true, forKey: coachMarkKey)  // walkthrough covers it
                        }
                        .environment(session)
                        .zIndex(3000)
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
                // First run → full guided walkthrough (Change 3). Falls back to nothing once seen.
                if !UserDefaults.standard.bool(forKey: walkthroughKey) {
                    Task { try? await Task.sleep(nanoseconds: 900_000_000)
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showWalkthrough = true } }
                } else if !UserDefaults.standard.bool(forKey: coachMarkKey) {
                    Task { try? await Task.sleep(nanoseconds: 1_000_000_000); withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showCoachMark = true } }
                }
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

    // MARK: - iPad tab area
    // Uses TabView as container (stable, no GPU fence) but hides its native tab bar
    // and overlays the custom StockedTabBar pill — identical appearance to iPhone.
    // MARK: - Tab area
    // ONE NavigationStack rendering only the SELECTED tab's content — never all four at
    // once (building every hub simultaneously triggers a GPU-fence timeout → blank screen).
    // The tab bar lives OUTSIDE this stack (in the VStack below), so tab buttons always
    // switch tabs and work from every screen. The .id below rebuilds the stack at root
    // whenever the tab changes OR the tab is re-tapped (pop-to-root), so deep flows never
    // linger when navigating away.
    private var iphoneTabArea: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea(.all)
            // Keep ALL tabs alive so switching tabs preserves each tab's state (scroll,
            // search, expanded sections, selection). Visibility is by opacity; only the
            // selected tab is hittable. Each tab has its OWN NavigationStack with an .id
            // keyed to ONLY that tab's pop-counter — so switching tabs does NOT rebuild
            // (state survives), while re-tapping the active tab still pops it to root.
            ForEach(StockedTab.allCases, id: \.self) { tab in
                NavigationStack {
                    ZStack {
                        session.themeBgColor.ignoresSafeArea(.all)
                        tabContent(tab)
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbarBackground(session.themeBgColor, for: .navigationBar)
                    .toolbarColorScheme(session.isDarkMode ? .dark : .light, for: .navigationBar)
                }
                .id("\(tab.rawValue)#\(rootPopID[tab]?.uuidString ?? "0")")
                .opacity(selected == tab ? 1 : 0)
                .allowsHitTesting(selected == tab)
                .accessibilityHidden(selected != tab)
            }
        }
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
            // Keep-alive: all four tabs stay mounted (inactive ones hidden via opacity and
            // made non-interactive / accessibility-hidden) so iPad tab switches preserve each
            // tab's scroll position and expanded state. This is the same approach the iPhone
            // path uses. (It was briefly replaced by a single-selected-tab version during the
            // memory-crash investigation, but the real cause was a per-row regex recompile in
            // displayNormalized — fixed in Build 145 — not the keep-alive, so it's safe to use.)
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
            HomeView().withQuickMenu(onScanReceipt: { showReceipt = true }, onAddItems: { showAddItems = true }, onShoppingList: { navigate(to: .grocery) })
        case .cook:
            CookConciergeView().withQuickMenu(onScanReceipt: { showReceipt = true }, onAddItems: { showAddItems = true }, onShoppingList: { navigate(to: .grocery) })
        case .inventory:
            InventoryHubView().withQuickMenu(onScanReceipt: { showReceipt = true }, onAddItems: { showAddItems = true }, onShoppingList: { navigate(to: .grocery) })
        case .recipes:
            RecipeVaultView().withQuickMenu(onScanReceipt: { showReceipt = true }, onAddItems: { showAddItems = true }, onShoppingList: { navigate(to: .grocery) })
        case .grocery:
            GroceryListView().withQuickMenu(onScanReceipt: { showReceipt = true }, onAddItems: { showAddItems = true }, onShoppingList: { navigate(to: .grocery) })
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

    // Drawer rests open (0) or closed (-drawerWidth). No drag — opens/closes by tapping the
    // pull-tab or the dim overlay. (Drag gestures were removed per design.)
    private var drawerOffsetX: CGFloat { showDrawer ? 0 : -drawerWidth }

    var body: some View {
        ZStack(alignment: .leading) {
            // Dim behind the drawer when open. Tapping it closes.
            if showDrawer {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.spring(response: 0.3)) { showDrawer = false } }
                    .zIndex(1100)
            }

            // Drawer panel — slides in/out on showDrawer.
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
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showDrawer)
            .zIndex(1200)

            // Left-edge pull tab (tap to open).
            HStack(spacing: 0) { pullTab; Spacer() }
                .zIndex(100)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .offset(x: showDrawer ? drawerWidth : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: showDrawer)
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
