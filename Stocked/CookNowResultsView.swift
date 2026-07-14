// CookNowResultsView.swift
// ─────────────────────────────────────────────────────────────────
// The shared tiered results list every Cook Now surface routes to for
// "See meals" / "See All Options" / "More Possibilities". One list, real
// classification, honest sections:
//
//   Ready now         — exact matches, then ready-with-in-stock-swap
//   Swaps to review   — one confirmation away from ready
//   Almost ready      — missing only 1–2 items (fewest first)
//   More possibilities— missing 3+ (closest first), collapsed by default
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

    var body: some View {
        StockedShell(showBack: true, titleText: title) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Based on what's currently logged")
                    .font(.system(size: 12))
                    .foregroundStyle(session.themeTextColor.opacity(0.45))
                    .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)

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
                    if focus != .morePossibilities {
                        moreSection(expanded: showMore)
                    }
                }

                Spacer(minLength: 20)
            }
            .navigationDestination(isPresented: $goRecipe) {
                if let openRecipe { UserRecipeDetailView(recipe: openRecipe) }
            }
            .navigationDestination(isPresented: $goRefresh) { RefreshKitchenView() }
        }
        .task { recompute() }
        .onChange(of: store.inventoryRevision) { _, _ in recompute() }
        .onChange(of: store.recipeRevision)    { _, _ in recompute() }
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

    private var isEmptyEverywhere: Bool {
        snapshot.readyNow.isEmpty && snapshot.needsReview.isEmpty
            && snapshot.almostReady.isEmpty && snapshot.morePossibilities.isEmpty
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
                    subtitle: "Missing only 1–2 items",
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
                    .a11yButton("Show more possibilities, \(snapshot.morePossibilities.count) recipes missing three or more items")
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
                    VStack(spacing: 10) {
                        ForEach(items.prefix(12)) { c in
                            CookRecipeCard(
                                title: c.recipe.title,
                                subtitle: rowSubtitle(c),
                                matchPercent: matchPercent(c),
                                imageURL: c.recipe.imageURL
                            ) {
                                openRecipe = c.recipe
                                goRecipe = true
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
        return lead
    }

    private func matchPercent(_ c: ClassifiedRecipe) -> Int {
        let required = c.resolutions.filter { if case .optional = $0.status { return false }; return true }
        guard !required.isEmpty else { return 0 }
        let resolved = required.count - c.missingCount - c.unconfirmedCount
        return Int(Double(max(0, resolved)) / Double(required.count) * 100)
    }
}
