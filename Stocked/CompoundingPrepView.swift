// CompoundingPrepView.swift
// -----------------------------------------------------------------
// Surfaces overlapping-prep opportunities during a cook. "You're already
// cutting onions. Two upcoming meals also need them. Prepare extra?"
//
// For each opportunity it shows which upcoming meals will use the ingredient,
// storage-life guidance, and an honest note that cut styles may differ. The
// user opts in per ingredient; opting in records a prep-ahead intent on the
// session (as selected sides / prep) so the rest of the workspace knows. This
// never forces extra work - it's an offer, hidden entirely at bare-minimum
// effort or when there's no real overlap.
// -----------------------------------------------------------------

import SwiftUI

struct CompoundingPrepView: View {
    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    @Environment(\.dismiss) private var dismiss
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var accepted: Set<String> = []

    private var effort: CookEffortLevel { cookSession?.effort ?? .normal }

    /// Ingredients the current cook is prepping - from the session's readiness
    /// prep keys and the anchor, falling back to the linked recipe's ingredients.
    private var currentIngredients: [String] {
        var names: [String] = []
        if let anchor = cookSession?.anchorItem { names.append(anchor) }
        if let rid = cookSession?.recipeID, let r = store.cookCatalog.first(where: { $0.id == rid }) {
            names.append(contentsOf: r.ingredients.map { $0.name })
        }
        // Common aromatics that a Before You Start prep would include.
        names.append(contentsOf: ["onion", "garlic"])
        return names
    }

    private var upcomingMeals: [PlannedMeal] {
        // Meals beyond today, not already cooked, excluding the one being cooked.
        store.plannedMeals.filter { $0.dayIndex >= 1 && !$0.isCooked && $0.id != cookSession?.plannedMealID }
    }

    private var opportunities: [CompoundingOpportunity] {
        CompoundingPrepEngine.opportunities(currentIngredients: currentIngredients,
                                            upcoming: upcomingMeals,
                                            allowCompounding: effort.allowsCompounding)
    }

    var body: some View {
        StockedShell(showBack: true, titleText: "Prep Ahead") {
            VStack(alignment: .leading, spacing: 16) {
                header
                if opportunities.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 12) {
                        ForEach(opportunities) { opp in
                            opportunityCard(opp)
                        }
                    }
                    .padding(.horizontal, CookStyle.screenHPad)
                }
                Spacer(minLength: 20)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Get ahead while you're at it")
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            Text("You're already prepping these. Upcoming meals need them too - prep extra now to save a step later.")
                .font(.system(size: 13.5))
                .foregroundStyle(session.themeTextColor.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 34)).foregroundStyle(session.themeTextColor.opacity(0.3))
            Text(effort == .bareMinimum ? "Keeping it minimal" : "No overlap to prep ahead")
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            Text(effort == .bareMinimum
                 ? "You picked bare minimum - no extra prep suggested."
                 : "Nothing you're prepping now shows up in your upcoming meals.")
                .font(.system(size: 13))
                .foregroundStyle(session.themeTextColor.opacity(0.5))
                .multilineTextAlignment(.center).padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
        .padding(.horizontal, CookStyle.screenHPad)
    }

    private func opportunityCard(_ opp: CompoundingOpportunity) -> some View {
        let isAccepted = accepted.contains(opp.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(ImageFallbackService.emoji(for: opp.ingredient)).font(.system(size: 20))
                Text(opp.ingredient.displayNormalized)
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                Text("\(opp.mealCount) more meal\(opp.mealCount == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.stockedGold)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.stockedGold.opacity(0.12)).clipShape(Capsule())
            }

            // Which meals
            VStack(alignment: .leading, spacing: 4) {
                ForEach(opp.upcomingMeals) { ref in
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").font(.system(size: 10)).foregroundStyle(session.themeTextColor.opacity(0.4))
                        Text("\(ref.title) - \(dayLabel(ref.dayIndex))")
                            .font(.system(size: 12))
                            .foregroundStyle(session.themeTextColor.opacity(0.6))
                    }
                }
            }

            // Storage guidance + cut-style caveat
            Label(opp.storageLife, systemImage: "refrigerator")
                .font(.system(size: 11.5))
                .foregroundStyle(session.themeTextColor.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            Text("Heads up: different meals may want different cuts - check before prepping one way.")
                .font(.system(size: 11))
                .foregroundStyle(Color.stockedGold.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                toggle(opp)
            } label: {
                Label(isAccepted ? "Prepping extra" : "Prep extra now",
                      systemImage: isAccepted ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isAccepted ? Color.stockedGreen : Color.stockedCharcoal)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(isAccepted ? Color.stockedGreen.opacity(0.14) : Color.stockedGold.opacity(0.18))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .a11yButton("Prep extra \(opp.ingredient) for \(opp.mealCount) upcoming meals")
        }
        .padding(14)
        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
    }

    private func toggle(_ opp: CompoundingOpportunity) {
        if accepted.contains(opp.id) {
            accepted.remove(opp.id)
            cookSession?.removeSide("Prep extra \(opp.ingredient.displayNormalized)")
        } else {
            accepted.insert(opp.id)
            // Record as a session prep-ahead intent.
            cookSession?.addSide("Prep extra \(opp.ingredient.displayNormalized)")
            cookSession?.setReadinessDone("compound::\(opp.id)", done: true)
        }
        HapticManager.select()
    }

    private func dayLabel(_ idx: Int) -> String {
        switch idx { case 0: return "today"; case 1: return "tomorrow"; default: return "day \(idx + 1)" }
    }
}
