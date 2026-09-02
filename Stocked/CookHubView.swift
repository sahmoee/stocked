// CookHubView.swift — the Cook tab entry (Cook Hub) and Cook Now Home.
//
// Checkpoint 1 of the Cook experience translation. Cook Hub is the top of the Cook tab: choose
// Cook Now (dinner tonight) or Cook Later (plan the week). Cook Now Home offers Build Around Food,
// Match My Mood, Surprise Me, plus an inventory-insight stack. Built from CookComponents and the
// package's navigation map. Cook Later and the deeper screens arrive in later checkpoints; their
// destinations are wired to existing flows where they already exist.

import SwiftUI

// MARK: - Cook Hub (Cook tab entry)

struct CookHubView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.stockedLayout) private var layoutMetrics

    @State private var goCookNow = false
    @State private var goCookLater = false

    // RL-001 — paused/interrupted cooking session resume + RL-002 discard.
    private var cookRecord: ActiveCookSessionStore { .shared }
    @State private var resumeTarget: ActiveCookSessionSnapshot? = nil
    @State private var goResume = false
    @State private var showDiscardConfirm = false

    var body: some View {
        StockedShell(titleText: "Cook") {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(greeting)
                        .scaledFont(12, weight: .semibold)
                        .foregroundStyle(Color.stockedGold)
                    Text("What's on the menu tonight?")
                        .scaledFont(32, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Cook Now solves tonight. Cook Later plans it, shops for it, and gets the household ahead.")
                        .scaledFont(14)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .lineSpacing(5)
                }
                .padding(.horizontal, CookStyle.screenHPad).padding(.top, 28)
                .coachmarkAnchor("cook.header")

                // RL-001 — a paused (or force-closed) cooking session surfaces
                // here for one-tap resume straight to the exact saved step.
                if let paused = cookRecord.resumable {
                    CookSessionResumeCard(
                        snapshot: paused,
                        onResume: { resumeTarget = paused; goResume = true },
                        onDiscard: { showDiscardConfirm = true }
                    )
                    .padding(.horizontal, CookStyle.screenHPad)
                    .padding(.top, 12)
                }

                VStack(spacing: 14) {
                    CookHubIllustratedButton(
                        title: "Cook Now",
                        primaryDetail: "Solve tonight with what you already have.",
                        secondaryDetail: "See what’s makeable, almost-ready, and worth using up.",
                        assetName: "cook_now_hero"
                    ) { goCookNow = true }
                    .coachmarkAnchor("cook.now")

                    CookHubIllustratedButton(
                        title: "Cook Later",
                        primaryDetail: "Plan it. Shop for it. Prep it. Cook it.",
                        secondaryDetail: "Build the week, create the list, and stay ahead.",
                        assetName: "cook_later_hero"
                    ) { goCookLater = true }
                    .coachmarkAnchor("cook.later")
                }
                .padding(.horizontal, CookStyle.screenHPad)
                .frame(maxWidth: .infinity)
            }
            .stockedSnapTargetLayout()
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            // When the two choices are shorter than the iPad/landscape viewport,
            // center the complete decision group instead of pinning it beneath the
            // wordmark. This is a minimum, not a fixed height: Dynamic Type can
            // still grow the content and the shell remains fully scrollable.
            .frame(minHeight: cookHubMinimumHeight, alignment: .center)
            .padding(.bottom, 20)
        }
        .navigationDestination(isPresented: $goCookNow) { CookNowHomeView() }
        .navigationDestination(isPresented: $goCookLater) { CookLaterHomeView() }
        // RL-001 — resume goes DIRECTLY to the cooking screen at the saved
        // step, never through the recipe detail page.
        .navigationDestination(isPresented: $goResume) {
            if let resumeTarget {
                CookingFlashcardView(recipeTitle: resumeTarget.recipeTitle,
                                     ingredients: resumeTarget.ingredients,
                                     steps: resumeTarget.steps,
                                     baseServings: resumeTarget.servings,
                                     sessionSubs: resumeTarget.substitutions,
                                     resume: resumeTarget)
            }
        }
        // RL-002 — deliberate cancel with an explicit consequences explainer.
        .alert("Cancel this meal?", isPresented: $showDiscardConfirm) {
            Button("Keep It", role: .cancel) {}
            Button("Discard Progress", role: .destructive) {
                cookRecord.cancel()
                session.activeCook = nil
                HapticManager.select()
            }
        } message: {
            Text("Your saved progress and timers will be discarded, and this meal won't be recorded as cooked. Nothing is deducted from inventory. If it came from your plan, the planned meal stays.")
        }
        // Terminal/stale records never reappear as resumable.
        .task { cookRecord.clearIfStale() }
        .onReceive(NotificationCenter.default.publisher(for: .stockedOpenCookLater)) { _ in
            goCookNow = false
            goCookLater = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            goResume = false   // collapse a resumed cook (e.g. after Cancel Meal)
        }
        .coachmarks(page: .cook, steps: CookCoachmarks.steps)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
        return "\(part), Chef 👋"
    }

    private var cookHubMinimumHeight: CGFloat {
        guard layoutMetrics.contentWidth >= 700 else { return 0 }
        let chromeHeight = StockedChrome.headerHeight
            + StockedChrome.headerTopPadding
            + StockedChrome.headerBottomPadding
        let tabAndScrollClearance: CGFloat = 190
        return max(0, layoutMetrics.contentHeight - chromeHeight - tabAndScrollClearance)
    }
}

// MARK: - Cook Now Home

// ═══════════════════════════════════════════════════════════════════
// Cook Now — Direction B inventory-first dashboard.
//
// Replaces the previous three-photography-card landing. The screen leads
// with what the kitchen can actually produce (classified by CookNowEngine),
// adapts its hierarchy when counts are zero, keeps the three pathways as
// compact secondary cards, and surfaces a focused Refresh Kitchen action.
// All counts come from real classification — nothing is hardcoded.
// ═══════════════════════════════════════════════════════════════════

struct CookNowHomeView: View {
    @Environment(AppSession.self) var session
    @Environment(\.quickMenuCallbacks) private var quickMenu
    @Environment(\.stockedMotion) private var motion
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    // One Cook Now session per visit — rehydrated from a persisted snapshot when
    // its context hasn't expired, otherwise fresh with the household default.
    // Non-optional so it can be injected into every downstream destination's
    // environment; bootstrap() swaps in the rehydrated/household-seeded session.
    @State private var cookSession = CookNowSession(householdSize: 2)
    @State private var sessionReady = false

    // Classified snapshot — computed off the render path, never in body.
    @State private var snapshot = CookNowCompute.Output.empty

    // Navigation
    @State private var goBuildFood  = false
    @State private var goMood       = false
    @State private var goRefresh    = false
    @State private var goReadyList  = false
    @State private var goAlmostList = false
    @State private var goMoreList   = false
    @State private var goSurpriseDetail = false
    @State private var chipIngredient: String? = nil
    @State private var goChip = false
    // Adaptive workspace entry points
    @State private var goStartWith    = false
    @State private var goMakeableNow  = false
    @State private var goUseItUp      = false
    @State private var goFinishServe  = false
    // Two Cook Now pathways that drop straight into the illustrated sub-option screen rather
    // than introducing a second planning surface.
    @State private var goExpiringSoon = false
    @State private var goLeftovers    = false

    // RL-001 — paused/interrupted cooking session resume + RL-002 discard.
    private var cookRecord: ActiveCookSessionStore { .shared }
    @State private var resumeTarget: ActiveCookSessionSnapshot? = nil
    @State private var goResumeCook = false
    @State private var showDiscardConfirm = false

    var body: some View {
        StockedShell(showBack: true, titleText: "Cook Now") {
            VStack(alignment: .leading, spacing: 18) {

                header

                // RL-001 — the paused-session banner: distinguishes a paused
                // cook from planned/completed meals and resumes at the exact step.
                if let paused = cookRecord.resumable {
                    CookSessionResumeCard(
                        snapshot: paused,
                        onResume: { resumeTarget = paused; goResumeCook = true },
                        onDiscard: { showDiscardConfirm = true }
                    )
                    .padding(.horizontal, CookStyle.screenHPad)
                }

                switch snapshot.emphasis {
                case .emptyInventory:      emptyInventoryState
                case .readyAndAlmost:      readinessDashboard(lead: .ready)
                case .almostOnly:          readinessDashboard(lead: .almost)
                case .morePossibilitiesOnly: buildTowardState
                case .noMatches:           noMatchesState
                }

                if snapshot.emphasis == .readyAndAlmost || snapshot.emphasis == .almostOnly {
                    ingredientChips
                    refreshKitchenCard
                }

                pathwaySection

                workspaceHubSection

                Spacer(minLength: 20)
            }
            .navigationDestination(isPresented: $goStartWith)   { StartWithSomethingView().environment(cookSession) }
            .navigationDestination(isPresented: $goMakeableNow) { MakeableNowView().environment(cookSession) }
            .navigationDestination(isPresented: $goUseItUp)     { UseSomethingUpView().environment(cookSession) }
            .navigationDestination(isPresented: $goFinishServe) { FinishAndServeView() }
            .navigationDestination(isPresented: $goBuildFood)  { BuildAroundFoodView(servings: cookSession.servings).environment(cookSession) }
            .navigationDestination(isPresented: $goExpiringSoon) {
                FoodsSubOptionView(category: "Expiring Soon", icon: "📅", servings: cookSession.servings)
            }
            .navigationDestination(isPresented: $goLeftovers) {
                FoodsSubOptionView(category: "Leftovers", icon: "🥡", servings: cookSession.servings)
            }
            .navigationDestination(isPresented: $goMood)       { MatchMyMoodFlowView().environment(cookSession) }
            .navigationDestination(isPresented: $goRefresh)    { RefreshKitchenView().environment(cookSession) }
            .navigationDestination(isPresented: $goReadyList)  { CookNowResultsView(focus: .readyFirst).environment(cookSession) }
            .navigationDestination(isPresented: $goAlmostList) { CookNowResultsView(focus: .almostFirst).environment(cookSession) }
            .navigationDestination(isPresented: $goMoreList)   { CookNowResultsView(focus: .morePossibilities).environment(cookSession) }
            .navigationDestination(isPresented: $goSurpriseDetail) {
                SmartRecommendationView(mode: .surprise).environment(cookSession)
            }
            .navigationDestination(isPresented: $goChip) {
                if let chipIngredient {
                    SmartRecommendationView(mode: .ingredient(chipIngredient)).environment(cookSession)
                }
            }
            // RL-001 — resume goes DIRECTLY to the cooking screen at the saved step.
            .navigationDestination(isPresented: $goResumeCook) {
                if let resumeTarget {
                    CookingFlashcardView(recipeTitle: resumeTarget.recipeTitle,
                                         ingredients: resumeTarget.ingredients,
                                         steps: resumeTarget.steps,
                                         baseServings: resumeTarget.servings,
                                         sessionSubs: resumeTarget.substitutions,
                                         resume: resumeTarget)
                        .environment(cookSession)
                }
            }
        }
        // RL-002 — deliberate cancel with an explicit consequences explainer.
        .alert("Cancel this meal?", isPresented: $showDiscardConfirm) {
            Button("Keep It", role: .cancel) {}
            Button("Discard Progress", role: .destructive) {
                cookRecord.cancel()
                session.activeCook = nil
                HapticManager.select()
            }
        } message: {
            Text("Your saved progress and timers will be discarded, and this meal won't be recorded as cooked. Nothing is deducted from inventory. If it came from your plan, the planned meal stays.")
        }
        .task { bootstrap() }
        .onChange(of: store.inventoryRevision) { _, _ in recompute() }
        .onChange(of: store.planRevision) { _, _ in recompute() }
        .onChange(of: OnlineRecipesLoader.shared.revision) { _, _ in recompute() }
        .onDisappear { classificationTask?.cancel() }
        .onChange(of: store.recipeRevision)    { _, _ in recompute() }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            goStartWith = false; goMakeableNow = false; goUseItUp = false; goFinishServe = false
            goBuildFood = false; goMood = false; goRefresh = false
            goReadyList = false; goAlmostList = false; goMoreList = false
            goSurpriseDetail = false; goChip = false; goResumeCook = false
            goExpiringSoon = false; goLeftovers = false
        }
    }

    // MARK: Bootstrap / recompute

    private func bootstrap() {
        // Hydrate the Discover pool from its own persisted cache so Cook scores
        // the real recipe library, not just starter meals, even when the user
        // has not opened Recipes this session. Off-main decode; recomputes when
        // it lands.
        Task {
            await OnlineRecipesLoader.shared.warmFromCacheIfNeeded()
            recompute()
            // QA mode: re-check invariants once the real catalog is loaded.
            QABackgroundRunner.shared.runSoon()
        }
        if !sessionReady {
            if let snap = CookNowSession.loadPersisted() {
                cookSession = CookNowSession(snapshot: snap)
            } else {
                cookSession = CookNowSession(householdSize: store.cookingProfile.householdSize)
            }
            sessionReady = true
        }
        recompute()
    }

    private func recompute() {
        classificationTask?.cancel()
        classificationTask = Task {
            if let result = await CookNowCompute.runYielding(store: store, session: cookSession),
               !Task.isCancelled { snapshot = result }
        }
    }

    @State private var classificationTask: Task<Void, Never>?

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dinner is closer than you think.")
                        .scaledFont(24, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text("Here's what your kitchen is telling us.")
                        .scaledFont(14)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                Spacer(minLength: 8)
            }
            servingPill
        }
        .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
        .coachmarkAnchor("cook.header")
    }

    /// Compact "Cooking for N" control. Session-scoped: adjusting it never
    /// silently rewrites the saved household profile.
    private var servingPill: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.fill")
                .scaledFont(11, weight: .semibold)
            Text("Cooking for \(cookSession.servings)")
                .scaledFont(13, weight: .semibold)
                .contentTransition(.numericText())
            HStack(spacing: 2) {
                stepButton("minus") { adjustServings(-1) }
                stepButton("plus")  { adjustServings(+1) }
            }
        }
        .foregroundStyle(dark ? Color.stockedWhite : Color.stockedCharcoal)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background((dark ? Color.darkSurface : Color.stockedWhite.opacity(0.7)))
        .overlay(Capsule().stroke(Color.stockedGold.opacity(0.35), lineWidth: 1))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cooking for \(cookSession.servings). Adjust servings for this session.")
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            HapticManager.select()
        } label: {
            Image(systemName: icon)
                .scaledFont(11, weight: .bold)
                .frame(width: 26, height: 26)
                .background(Color.stockedGold.opacity(0.14))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func adjustServings(_ delta: Int) {
        motion.animate(.selection, intent: .spatial) {
            cookSession.setServings(cookSession.servings + delta)
        }
    }

    // MARK: Readiness dashboard (normal + almost-first)

    private enum DashboardLead { case ready, almost }

    private func readinessDashboard(lead: DashboardLead) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if lead == .almost {
                Text("You're close to dinner.")
                    .scaledFont(17, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("WHAT YOU CAN MAKE")
                    .scaledFont(11, weight: .bold)
                    .kerning(1.1)
                    .foregroundStyle(Color.stockedGold)

                HStack(spacing: 12) {
                    if lead == .ready {
                        metricColumn(count: snapshot.metrics.readyNowTotal,
                                     title: "meals ready now",
                                     sub: snapshot.metrics.readyBreakdown,
                                     cta: "See meals",
                                     enabled: snapshot.metrics.readyNowTotal > 0) { goReadyList = true }
                        metricColumn(count: snapshot.metrics.almostReady,
                                     title: "meals almost ready",
                                     sub: snapshot.metrics.almostReady > 0 ? "Missing 6 or more items" : "",
                                     cta: "See meals",
                                     enabled: snapshot.metrics.almostReady > 0) { goAlmostList = true }
                    } else {
                        metricColumn(count: snapshot.metrics.almostReady,
                                     title: "meals almost ready",
                                     sub: "Missing 6 or more items",
                                     cta: "See meals",
                                     enabled: true) { goAlmostList = true }
                        metricColumn(count: snapshot.metrics.readyNowTotal,
                                     title: "meals ready now",
                                     sub: "",
                                     cta: "See meals",
                                     enabled: false) { }
                    }
                }

                if snapshot.needsReview.count > 0 {
                    Text("\(snapshot.needsReview.count) more possible with swaps to review")
                        .scaledFont(12)
                        .foregroundStyle(Color.stockedWhite.opacity(0.6))
                }

                Text("Based on what's currently logged")
                    .scaledFont(11)
                    .foregroundStyle(Color.stockedWhite.opacity(0.45))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.stockedCharcoal)
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    private func metricColumn(count: Int, title: String, sub: String, cta: String,
                              enabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(count)")
                .scaledFont(34, weight: .bold, design: .serif)
                .foregroundStyle(enabled ? Color.stockedGold : Color.stockedWhite.opacity(0.35))
                .contentTransition(.numericText())
            Text(title)
                .scaledFont(12.5, weight: .semibold)
                .foregroundStyle(Color.stockedWhite)
                .fixedSize(horizontal: false, vertical: true)
            if !sub.isEmpty {
                Text(sub)
                    .scaledFont(11)
                    .foregroundStyle(Color.stockedGold.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if enabled {
                Button(action: action) {
                    Text(cta)
                        .scaledFont(12, weight: .semibold)
                        .foregroundStyle(Color.stockedCharcoal)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.stockedWhite.opacity(0.9))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(count). \(sub)")
    }

    // MARK: Adaptive alternate states

    private var emptyInventoryState: some View {
        VStack(spacing: 14) {
            Text("🧺").scaledFont(52)
            Text("Your kitchen is waiting to be stocked.")
                .scaledFont(19, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
                .multilineTextAlignment(.center)
            Text("Add items to get personalized meal ideas based on what you actually have.")
                .scaledFont(13.5)
                .foregroundStyle(session.themeTextColor.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            VStack(spacing: 8) {
                primaryStateButton("Add Items") { quickMenu.onAddItems() }
                secondaryStateButton("Scan Items") { quickMenu.onScanReceipt() }
                secondaryStateButton("Browse Recipes") {
                    NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.recipes)
                }
            }
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, CookStyle.screenHPad)
    }

    private var buildTowardState: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Let's build toward dinner.")
                    .scaledFont(19, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                Text("Your closest matches need a few more ingredients, but you still have options.")
                    .scaledFont(13.5)
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            primaryStateButton("See Closest Matches") { goMoreList = true }
            secondaryStateButton("Refresh Kitchen") { goRefresh = true }
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    private var noMatchesState: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("We couldn't find a match yet.")
                    .scaledFont(19, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                Text("Recommendations use your saved inventory. Add ingredients or browse recipes to get started.")
                    .scaledFont(13.5)
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            primaryStateButton("Add Items") { quickMenu.onAddItems() }
            secondaryStateButton("Refresh Kitchen") { goRefresh = true }
            secondaryStateButton("Browse Recipes") {
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.recipes)
            }
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    private func primaryStateButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .scaledFont(15, weight: .semibold, design: .serif)
                .foregroundStyle(Color.stockedWhite)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(dark ? Color.darkSurface : Color.stockedCharcoal)
                .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL).stroke(dark ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
        }
        .buttonStyle(.plain)
    }

    private func secondaryStateButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .scaledFont(14, weight: .semibold)
                .foregroundStyle(session.themeTextColor)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background((dark ? Color.darkSurface : Color.stockedWhite.opacity(0.6)))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
        }
        .buttonStyle(.plain)
    }

    // MARK: Ingredient chips

    /// Top in-stock ingredients — expiring soonest first so the most urgent items
    /// lead. Labeled honestly: this is a real ranking (expiry), so "top" applies.
    private var chipItems: [LocalInventoryItem] {
        snapshotChipItems
    }
    @State private var snapshotChipItems: [LocalInventoryItem] = []

    private func recomputeChips() {
        let inStock = store.inventoryItems.filter { $0.effectiveLevel > 0 }
        let sorted = inStock.sorted {
            ($0.daysUntilExpiry ?? 999, $0.name) < ($1.daysUntilExpiry ?? 999, $1.name)
        }
        snapshotChipItems = Array(sorted.prefix(7))
    }

    private var ingredientChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top ingredients you can use")
                .scaledFont(15, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chipItems) { item in
                        Button {
                            chipIngredient = item.name
                            goChip = true
                        } label: {
                            HStack(spacing: 6) {
                                Text(ImageFallbackService.emoji(for: item.name)).scaledFont(13)
                                Text(item.name.displayNormalized)
                                    .scaledFont(13, weight: .semibold)
                                    .fixedSize(horizontal: false, vertical: true)
                                if item.isExpiringSoon {
                                    Image(systemName: "clock.fill")
                                        .scaledFont(9)
                                        .foregroundStyle(Color.stockedGold)
                                }
                            }
                            .foregroundStyle(session.themeTextColor)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.7))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .a11yButton("Cook with \(item.name)")
                    }
                    if store.inventoryItems.filter({ $0.effectiveLevel > 0 }).count > chipItems.count {
                        Button { goBuildFood = true } label: {
                            Text("+ more")
                                .scaledFont(13, weight: .semibold)
                                .foregroundStyle(Color.stockedGold)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.stockedGold.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .stockedScrollTargetLayout()
            }
            .stockedHorizontalSnap()
        }
        .padding(.horizontal, CookStyle.screenHPad)
        .task { recomputeChips() }
        .onChange(of: store.inventoryRevision) { _, _ in recomputeChips() }
    }

    // MARK: Refresh Kitchen card

    private var refreshKitchenCard: some View {
        Button { goRefresh = true } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.stockedGold.opacity(0.14)).frame(width: 38, height: 38)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(Color.stockedGold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Refresh Kitchen")
                        .scaledFont(14.5, weight: .semibold)
                        .foregroundStyle(session.themeTextColor)
                    Text("Confirm a few items to improve tonight's matches.")
                        .scaledFont(12)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(14)
            .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CookStyle.screenHPad)
        .a11yButton("Refresh Kitchen. Confirm a few items to improve tonight's matches.")
    }

    // MARK: Pathways

    private var pathwaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How do you want to cook?")
                .scaledFont(15, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)

            // Broadest entry: begin with any item and decide what to do with it.
            pathwayRow(emoji: "🧑\u{200d}🍳", asset: "cook_row_ingredient", title: "Start With Something",
                       subtitle: "Pick an ingredient and choose what to do — from one item to a full meal.") { goStartWith = true }
            pathwayRow(emoji: "🥩", asset: "cook_row_build_food", title: "Build Around Food",
                       subtitle: "Use what you have or what you love.") { goBuildFood = true }
            pathwayRow(emoji: "⏳", asset: "cook_row_expiring", title: "Expiring Soon",
                       subtitle: "Cook around what needs to go first.") { goExpiringSoon = true }
            pathwayRow(emoji: "🙂", asset: "cook_row_mood", title: "Match My Mood",
                       subtitle: "Find recipes that fit how you feel.") { goMood = true }
            pathwayRow(emoji: "🎁", asset: "cook_row_surprise", title: "Surprise Me",
                       subtitle: "Let us pick the perfect recipe.") { rollSurprise() }
            pathwayRow(emoji: "🥡", asset: "cook_row_leftovers", title: "Leftovers",
                       subtitle: "Start with what's already cooked.") { goLeftovers = true }
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    /// Secondary workspace entry points — browse makeable, use-it-up, finish & serve.
    private var workspaceHubSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("More ways in")
                .scaledFont(15, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
            pathwayRow(emoji: "✅", asset: "cook_row_makeable_now", title: "Makeable Now",
                       subtitle: "Browse entrées, sides, and meals you can make right now.") { goMakeableNow = true }
            pathwayRow(emoji: "⏳", asset: "cook_row_use_something_up", title: "Use Something Up",
                       subtitle: "Cook around what's expiring or already open.") { goUseItUp = true }
            pathwayRow(emoji: "🍽️", asset: "cook_row_finish_serve", title: "Finish & Serve",
                       subtitle: "Reheat and finish anything you cooked ahead.") { goFinishServe = true }
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    /// `asset` names a transparent illustration in the catalog. When one is present the row uses
    /// the illustrated treatment; when it is absent (or the asset has not shipped yet) the row
    /// falls back to the original emoji layout, so nothing regresses.
    private func pathwayRow(emoji: String, asset: String? = nil, title: String, subtitle: String,
                            action: @escaping () -> Void) -> some View {
        Group {
            if cookAssetImage(asset) != nil {
                CookIllustratedRow(title: title, subtitle: subtitle, assetName: asset,
                                   fallbackEmoji: emoji, tone: .soft, artSize: 68) {
                    action()
                    HapticManager.light()
                }
            } else {
                CookIllustratedRow(title: title, subtitle: subtitle,
                                   fallbackEmoji: emoji, tone: .soft, artSize: 68) {
                    action()
                    HapticManager.light()
                }
            }
        }
        .a11yButton("\(title). \(subtitle)")
    }

    private func rollSurprise() {
        goSurpriseDetail = true   // Surprise converges on the shared Smart Recommendation
    }
}
