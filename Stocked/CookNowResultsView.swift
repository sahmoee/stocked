// CookNowResultsView.swift
// ─────────────────────────────────────────────────────────────────
// The shared tiered results list every Cook Now surface routes to for
// "See meals" / "See All Options" / "More Possibilities". One list, real
// classification, honest sections:
//
//   Ready now         — five or fewer unresolved after in-stock substitutions
//   Swaps to review   — one confirmation away from ready
//   Almost ready      — missing 6+ items after substitutions (fewest first)
//   More possibilities— missing 6+ (closest first), collapsed by default
//                       unless the caller focuses it
//
// Rows reuse CookRecipeCard and show the tier-appropriate status subtitle
// instead of a raw N/M fraction, so a substitution-dependent meal is never
// presented as an exact match.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

struct CookNowResultsView: View {

    enum Focus { case readyFirst, almostFirst, morePossibilities }
    var focus: Focus = .readyFirst

    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    private var store: GuestDataStore { session.guestStore }

    @State private var snapshot = CookNowCompute.Output.empty
    @State private var openRecipe: UserRecipe? = nil
    @State private var goRecipe = false
    @State private var showMore = false
    @State private var isGeneratingRecipe = false
    @State private var generationMessage: String?
    // RL-004 — Cook Anyway review for recipes that touch meal-plan reservations.
    @State private var overridePayload: ReservationOverridePayload? = nil

    var body: some View {
        StockedShell(showBack: true, titleText: title) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Based on what's currently logged")
                    .font(.system(size: 12))
                    .foregroundStyle(session.themeTextColor.opacity(0.45))
                    .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)

                if focus == .readyFirst {
                    inventoryRecipeButton
                }

                if isEmptyEverywhere {
                    CookEmptyState(
                        icon: "fork.knife",
                        title: "No matches yet",
                        message: "Add ingredients or save recipes and your best matches will show up here.",
                        ctaTitle: "Refresh Kitchen"
                    ) { goRefresh = true }
                } else {
                    if focus == .almostFirst {
                        almostSection
                        readySection
                    } else if focus == .morePossibilities {
                        moreSection(expanded: true)
                        almostSection
                        readySection
                    } else {
                        readySection
                        reviewSection
                        almostSection
                    }
                    // Six-plus recipes already live in Almost Ready. Keep the explicit
                    // More Possibilities destination for legacy deep links, but do not
                    // duplicate that same population below the normal results list.
                }

                Spacer(minLength: 20)
            }
            .navigationDestination(isPresented: $goRecipe) {
                if let openRecipe { UserRecipeDetailView(recipe: openRecipe) }
            }
            .navigationDestination(isPresented: $goRefresh) { RefreshKitchenView() }
        }
        .task {
            // Hydrate the Discover pool from its own persisted cache before
            // classifying, so opening this screen on a cold launch scores the
            // real recipe library instead of only the starter meals.
            await OnlineRecipesLoader.shared.warmFromCacheIfNeeded()
            recompute()
            QABackgroundRunner.shared.runSoon()
        }
        .qaScreen("Cook Now results")
        .onChange(of: store.inventoryRevision) { _, _ in recompute() }
        .onChange(of: store.recipeRevision)    { _, _ in recompute() }
        .onChange(of: store.planRevision)      { _, _ in recompute() }  // RL-006: plan edits move reservations
        .sheet(item: $overridePayload) { payload in
            ReservationOverrideSheet(recipe: payload.recipe, touches: payload.touches) {
                // Cook Anyway: the override is recorded; proceed into the recipe.
                openRecipe = store.ensureSavedForCooking(payload.recipe)
                goRecipe = true
            }
            .environment(session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            goRecipe = false; goRefresh = false
        }
    }

    @State private var goRefresh = false

    private var title: String {
        switch focus {
        case .readyFirst:        return "What You Can Make"
        case .almostFirst:       return "Almost Ready"
        case .morePossibilities: return "More Possibilities"
        }
    }

    private func recompute() {
        snapshot = CookNowCompute.run(store: store, session: cookSession)
    }

    // PERF: this used to touch all four tier lists, and each of those was a
    // computed property that re-filtered and re-sorted the whole catalog. Between
    // this check and the sections below, one body pass ran ~10 full passes over
    // ~150 recipes. The tiers are stored on Output now and this is a Bool read.
    private var isEmptyEverywhere: Bool { snapshot.isEmptyEverywhere }

    private var inventoryRecipeButton: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: generateInventoryRecipe) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .bold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isGeneratingRecipe ? "Creating your recipe…" : "Create a recipe with AI")
                            .font(.system(size: 14, weight: .bold))
                        Text("Built from what's in your inventory")
                            .font(.system(size: 11, weight: .medium))
                            .opacity(0.72)
                    }
                    Spacer()
                    if isGeneratingRecipe {
                        ProgressView().tint(Color.stockedCharcoal)
                    } else {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                }
                .foregroundStyle(Color.stockedCharcoal)
                .padding(.vertical, 12).padding(.horizontal, 14)
                .background(Color.stockedGold)
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            }
            .buttonStyle(.plain)
            .disabled(isGeneratingRecipe || store.inventoryItems.isEmpty)
            .opacity(store.inventoryItems.isEmpty ? 0.5 : 1)
            .a11yButton("Create an AI recipe from available inventory")

            if let generationMessage {
                Text(generationMessage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
            }
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    private func generateInventoryRecipe() {
        guard !isGeneratingRecipe else { return }
        isGeneratingRecipe = true
        generationMessage = nil
        Task {
            let savedID = await MealsReadyNowGenerator.shared.generateAndStore(in: store)
            generationMessage = savedID == nil
                ? "Couldn't create a recipe right now. Check your connection and try again."
                : "Recipe created and saved."
            isGeneratingRecipe = false
            if savedID != nil { recompute() }
        }
    }

    // MARK: Sections

    private var readySection: some View {
        tierSection(title: "Ready now",
                    subtitle: snapshot.metrics.readyBreakdown,
                    items: snapshot.readyNow)
    }

    private var reviewSection: some View {
        tierSection(title: "Swaps to review",
                    subtitle: "One confirmation away",
                    items: snapshot.needsReview)
    }

    private var almostSection: some View {
        tierSection(title: "Almost ready",
                    subtitle: "Missing 6 or more items after substitutions",
                    items: snapshot.almostReady)
    }

    private func moreSection(expanded: Bool) -> some View {
        Group {
            if !snapshot.morePossibilities.isEmpty {
                if expanded {
                    tierSection(title: "More possibilities",
                                subtitle: "Meals to build toward — closest first",
                                items: snapshot.morePossibilities)
                } else {
                    Button { withAnimation { showMore = true } } label: {
                        HStack {
                            Text("More possibilities (\(snapshot.morePossibilities.count))")
                                .font(.system(size: 13.5, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color.stockedGold)
                        .padding(.vertical, 11).padding(.horizontal, 14)
                        .background(Color.stockedGold.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, CookStyle.screenHPad)
                    .a11yButton("Show more possibilities, \(snapshot.morePossibilities.count) recipes missing six or more items")
                }
            }
        }
    }

    private func tierSection(title: String, subtitle: String, items: [ClassifiedRecipe]) -> some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 16, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                        }
                    }
                    // PERF: LazyVStack. The eager VStack built all 12 CookRecipeCards
                    // — each with an AsyncImage — the instant the section appeared,
                    // for every section, whether or not any of them were on screen.
                    LazyVStack(spacing: 10) {
                        ForEach(items.prefix(12)) { c in
                            CookRecipeCard(
                                title: c.recipe.title,
                                subtitle: rowSubtitle(c),
                                matchPercent: matchPercent(c),
                                imageURL: c.recipe.imageURL,
                                usesUniformIcon: false
                            ) {
                                // RL-004 — a recipe using reserved ingredients gets the
                                // informative Cook Anyway review first (never blocking:
                                // it can still be cooked from inside the sheet).
                                let touches = ReservationLedger.shared.reservedTouches(
                                    ingredientNames: c.recipe.ingredients.filter { !$0.isOptional }.map(\.name))
                                if c.usesReservedIngredients && !touches.isEmpty {
                                    overridePayload = ReservationOverridePayload(recipe: c.recipe, touches: touches)
                                } else {
                                    // Persist first when this came from Discover or
                                    // a generated recipe, so the detail screen's
                                    // actions are real rather than silent no-ops.
                                    openRecipe = store.ensureSavedForCooking(c.recipe)
                                    goRecipe = true
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, CookStyle.screenHPad)
            }
        }
    }

    /// Honest per-row status: tier language, never a bare fraction that hides
    /// the substitution/uncertainty split.
    private func rowSubtitle(_ c: ClassifiedRecipe) -> String {
        var lead: String
        switch c.readiness {
        case .exact:           lead = "Everything in stock"
        case .readyWithSwap:   lead = "Ready with \(c.substitutionCount) swap\(c.substitutionCount == 1 ? "" : "s")"
        case .swapNeedsReview: lead = "\(c.reviewCount) swap\(c.reviewCount == 1 ? "" : "s") to review"
        case .missingOne, .missingTwo, .missingMany:
            lead = "Missing \(c.missingCount): \(c.missingNames.prefix(2).map { $0.displayNormalized }.joined(separator: ", "))"
        case .excluded:        lead = "Not a fit"
        }
        if !c.recipe.cookTime.isEmpty { lead += " · \(c.recipe.cookTime)" }
        // RL-004 — never present a reservation-touching recipe as fully safe:
        // the badge tells the truth ("the food exists, but it's spoken for").
        if c.usesReservedIngredients && c.readiness.isReadyNow {
            lead += " · Ready if plans change"
        }
        return lead
    }

    private func matchPercent(_ c: ClassifiedRecipe) -> Int {
        let required = c.resolutions.filter { if case .optional = $0.status { return false }; return true }
        guard !required.isEmpty else { return 0 }
        let resolved = required.count - c.missingCount - c.unconfirmedCount
        return Int(Double(max(0, resolved)) / Double(required.count) * 100)
    }
}
