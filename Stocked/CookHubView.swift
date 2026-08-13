// CookHubView.swift — the Cook tab entry (Cook Hub) and Cook Now Home.
//
// Checkpoint 1 of the Cook experience translation. Cook Hub is the top of the Cook tab: choose
// Cook Now (dinner tonight) or Cook Later (plan the week). Cook Now Home offers Build Around Food,
// Match My Mood, Surprise Me, plus an inventory-insight stack. Built from CookComponents and the
// package's navigation map. Cook Later and the deeper screens arrive in later checkpoints; their
// destinations are wired to existing flows where they already exist.

import SwiftUI

// MARK: - Cook Hub (Cook tab entry)

/// #FB2 — the Cook hub's two choices are circles by default (the original design),
/// with Photo Cards and Compact Rows available in Preferences → Appearance.
enum CookHubStyle: String, CaseIterable, Identifiable {
    case circles, cards, rows
    var id: String { rawValue }
    var label: String {
        switch self {
        case .circles: return "Circles"
        case .cards:   return "Photo Cards"
        case .rows:    return "Compact Rows"
        }
    }
    static let storageKey = "stocked.cookHubStyle"
}

struct CookHubView: View {
    @Environment(AppSession.self) private var session
    private var dark: Bool { session.isDarkMode }

    @AppStorage(CookHubStyle.storageKey) private var hubStyleRaw = CookHubStyle.circles.rawValue
    // The Cook Buttons setting (Settings > Preferences) is the single source of truth:
    // shape picks the representation, size scales it — both live. (The old stored style
    // had no picker anywhere, so the setting takes over cleanly; @AppStorage retained
    // only so existing installs don't lose the key.)
    private var hubStyle: CookHubStyle {
        switch session.cookButtonShape {
        case .circle:      return .circles
        case .pill:        return .rows
        case .roundedRect: return .cards
        }
    }
    /// 280pt is the slider's baseline (matches the hub's design size).
    private var sizeScale: CGFloat {
        min(400, max(150, CGFloat(session.cookButtonSize))) / 280.0
    }

    @State private var goCookNow = false
    @State private var goCookLater = false

    // RL-001 — paused/interrupted cooking session resume + RL-002 discard.
    private var cookRecord: ActiveCookSessionStore { .shared }
    @State private var resumeTarget: ActiveCookSessionSnapshot? = nil
    @State private var goResume = false
    @State private var showDiscardConfirm = false

    var body: some View {
        // #FB — the two choices are centered and fit the page on every device:
        // scrolling is disabled and the options are balanced with spacers so nothing
        // hangs off-screen or huddles at the top.
        StockedShell(scrollDisabled: true, titleText: "Cook", leadingTitle: true) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                    Text("What's on the menu tonight?")
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Cook Now solves tonight. Cook Later plans it, shops for it, and gets the household ahead.")
                        .font(.system(size: 14))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
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

                Spacer(minLength: 12)

                Group {
                    switch hubStyle {
                    case .circles: circleOptions
                    case .cards:   cardOptions
                    case .rows:    rowOptions
                    }
                }
                .padding(.horizontal, CookStyle.screenHPad)
                .frame(maxWidth: .infinity)
                // Live, centered, in-place: the Settings sliders animate these directly.
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: session.cookButtonSize)
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: session.cookButtonShape)

                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // ── Style 1 (default): two big circles stacked and centered ─────────
    // ViewThatFits drops to smaller circles on short screens (SE, zoomed display)
    // so both options always fit without scrolling.
    private var circleOptions: some View {
        ViewThatFits(in: .vertical) {
            circleStack(diameter: scaledDiameter(176), spacing: 26, showSubtitles: true)
            circleStack(diameter: scaledDiameter(148), spacing: 18, showSubtitles: true)
            circleStack(diameter: scaledDiameter(128), spacing: 14, showSubtitles: false)
        }
        .frame(maxWidth: .infinity)
    }

    /// Cook Buttons size applied per tier; clamped so ViewThatFits can always land a fit.
    private func scaledDiameter(_ base: CGFloat) -> CGFloat {
        min(230, max(100, base * sizeScale))
    }

    private func circleStack(diameter: CGFloat, spacing: CGFloat, showSubtitles: Bool) -> some View {
        VStack(spacing: spacing) {
            hubCircle(title: "Cook Now",
                      subtitle: showSubtitles ? "Solve tonight with what you already have." : "",
                      emoji: "🍳",
                      tint: Color.stockedCharcoal,
                      diameter: diameter) { goCookNow = true }
                .coachmarkAnchor("cook.now")
            hubCircle(title: "Cook Later",
                      subtitle: showSubtitles ? "Plan it. Shop for it. Prep it. Cook it." : "",
                      emoji: "📅",
                      tint: Color.stockedGold,
                      diameter: diameter) { goCookLater = true }
                .coachmarkAnchor("cook.later")
        }
        .frame(maxWidth: .infinity)
    }

    private func hubCircle(title: String, subtitle: String, emoji: String,
                           tint: Color, diameter: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(tint)
                    Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5)
                        .padding(6)
                    VStack(spacing: 6) {
                        Text(emoji).font(.system(size: diameter * 0.19))
                        Text(title)
                            .font(.system(size: diameter * 0.115, weight: .bold, design: .serif))
                            .foregroundStyle(Color.stockedWhite)
                    }
                }
                .frame(width: diameter, height: diameter)
                .shadow(color: tint.opacity(0.35), radius: 12, y: 6)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 230)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subtitle.isEmpty ? title : "\(title). \(subtitle)")
    }

    // ── Style 2: the photo hero cards ────────────────────────────────────
    private var cardOptions: some View {
        let side = min(190, max(140, 162 * sizeScale))
        return HStack(alignment: .top, spacing: 12) {
            CookHeroCard(
                title: "Cook Now",
                subtitle: "Solve tonight with what you already have.",
                emoji: "🍳",
                assetName: "cook_now_hero",
                tint: Color.stockedCharcoal,
                textOnDark: true,
                height: side
            ) { goCookNow = true }
            .frame(maxWidth: side)
            .coachmarkAnchor("cook.now")

            CookHeroCard(
                title: "Cook Later",
                subtitle: "Plan it. Shop for it. Prep it. Cook it.",
                icon: "calendar",
                assetName: "cook_later_hero",
                tint: Color.stockedGold,
                textOnDark: true,
                height: side
            ) { goCookLater = true }
            .frame(maxWidth: side)
            .coachmarkAnchor("cook.later")
        }
        .frame(maxWidth: .infinity)
    }

    // ── Style 3: compact rows ─────────────────────────────────────────────
    private var rowOptions: some View {
        VStack(spacing: 14) {
            hubRow(title: "Cook Now", subtitle: "Solve tonight with what you already have.",
                   emoji: "🍳", tint: Color.stockedCharcoal) { goCookNow = true }
                .coachmarkAnchor("cook.now")
            hubRow(title: "Cook Later", subtitle: "Plan it. Shop for it. Prep it. Cook it.",
                   emoji: "📅", tint: Color.stockedGold) { goCookLater = true }
                .coachmarkAnchor("cook.later")
        }
    }

    private func hubRow(title: String, subtitle: String, emoji: String,
                        tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.16))
                        .frame(width: min(60, max(36, 46 * sizeScale)), height: min(60, max(36, 46 * sizeScale)))
                    Text(emoji).font(.system(size: min(28, max(17, 22 * sizeScale))))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 19, weight: .bold, design: .serif))
                        .foregroundStyle(Color.stockedWhite)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.stockedWhite.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.stockedWhite.opacity(0.8))
            }
            .padding(min(26, max(12, 18 * sizeScale)))   // Cook Buttons size, live
            .frame(maxWidth: .infinity)
            .background(tint)
            // Pill means PILL: fully-rounded capsule ends, visually distinct from the
            // rounded-rectangle photo cards.
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
        return "\(part), Chef 👋"
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
        snapshot = CookNowCompute.run(store: store, session: cookSession)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dinner is closer than you think.")
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Here's what your kitchen is telling us.")
                        .font(.system(size: 14))
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
                .font(.system(size: 11, weight: .semibold))
            Text("Cooking for \(cookSession.servings)")
                .font(.system(size: 13, weight: .semibold))
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
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Color.stockedGold.opacity(0.14))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func adjustServings(_ delta: Int) {
        withAnimation(.spring(response: 0.25)) { cookSession.setServings(cookSession.servings + delta) }
    }

    // MARK: Readiness dashboard (normal + almost-first)

    private enum DashboardLead { case ready, almost }

    private func readinessDashboard(lead: DashboardLead) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if lead == .almost {
                Text("You're close to dinner.")
                    .font(.system(size: 17, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("WHAT YOU CAN MAKE")
                    .font(.system(size: 11, weight: .bold))
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
                                     sub: snapshot.metrics.almostReady > 0 ? "Missing 5 or fewer items" : "",
                                     cta: "See meals",
                                     enabled: snapshot.metrics.almostReady > 0) { goAlmostList = true }
                    } else {
                        metricColumn(count: snapshot.metrics.almostReady,
                                     title: "meals almost ready",
                                     sub: "Missing 5 or fewer items",
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
                        .font(.system(size: 12))
                        .foregroundStyle(Color.stockedWhite.opacity(0.6))
                }

                if snapshot.metrics.morePossibilities > 0 {
                    Button { goMoreList = true } label: {
                        HStack {
                            Text("See more possibilities (6+ missing)")
                                .font(.system(size: 12.5, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color.stockedGold)
                        .padding(.vertical, 9).padding(.horizontal, 12)
                        .background(Color.stockedGold.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                    }
                    .buttonStyle(.plain)
                }

                Text("Based on what's currently logged")
                    .font(.system(size: 11))
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
                .font(.system(size: 34, weight: .bold, design: .serif))
                .foregroundStyle(enabled ? Color.stockedGold : Color.stockedWhite.opacity(0.35))
                .contentTransition(.numericText())
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.stockedWhite)
                .fixedSize(horizontal: false, vertical: true)
            if !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.stockedGold.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if enabled {
                Button(action: action) {
                    Text(cta)
                        .font(.system(size: 12, weight: .semibold))
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
            Text("🧺").font(.system(size: 52))
            Text("Your kitchen is waiting to be stocked.")
                .font(.system(size: 19, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
                .multilineTextAlignment(.center)
            Text("Add items to get personalized meal ideas based on what you actually have.")
                .font(.system(size: 13.5))
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
                    .font(.system(size: 19, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Text("Your closest matches need a few more ingredients, but you still have options.")
                    .font(.system(size: 13.5))
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
                    .font(.system(size: 19, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Text("Recommendations use your saved inventory. Add ingredients or browse recipes to get started.")
                    .font(.system(size: 13.5))
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
                .font(.system(size: 15, weight: .semibold, design: .serif))
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
                .font(.system(size: 14, weight: .semibold))
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
                .font(.system(size: 15, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chipItems) { item in
                        Button {
                            chipIngredient = item.name
                            goChip = true
                        } label: {
                            HStack(spacing: 6) {
                                Text(ImageFallbackService.emoji(for: item.name)).font(.system(size: 13))
                                Text(item.name.displayNormalized)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                if item.isExpiringSoon {
                                    Image(systemName: "clock.fill")
                                        .font(.system(size: 9))
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
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.stockedGold)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.stockedGold.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Refresh Kitchen")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                    Text("Confirm a few items to improve tonight's matches.")
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
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
                .font(.system(size: 15, weight: .bold, design: .serif))
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
                .font(.system(size: 15, weight: .bold, design: .serif))
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
