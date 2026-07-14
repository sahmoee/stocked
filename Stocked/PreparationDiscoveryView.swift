// PreparationDiscoveryView.swift
// ─────────────────────────────────────────────────────────────────
// Standalone-preparation discovery, scoped by the session's intent. This is
// where a chicken search returns standalone chicken preparations — not only
// complete chicken dinners. Each card is a preparation the user can cook and
// STOP at; sides are never auto-attached.
//
// Cards classify by DishRole (added to UserRecipe in batch 6) with a heuristic
// fallback for legacy recipes, and by readiness through CookNowEngine so the
// feed honestly shows what's makeable. Intent shapes the pool:
//   justMakeThis      → standalone entrées/sides/components using the anchor
//   buildFullMeal     → full-meal roles
//   trySomethingNew   → prefer roles/cuisines outside the user's usual
//   useWhatIHave      → ready-first ordering
//   useItUp           → prefer recipes using expiring items
//   addSomething      → scoped to the add-on (sides/components), keeps it light
//
// Choosing a preparation records it on the session and moves to method
// comparison. Replaces the Batch 7 stub of the same name.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

struct PreparationDiscoveryView: View {
    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var snapshot = CookNowCompute.Output.empty
    @State private var goMethod = false
    @State private var goRecipe = false
    @State private var chosen: UserRecipe? = nil

    private var anchor: String { cookSession?.anchorItem ?? "" }
    private var intent: CookIntent { cookSession?.intent ?? .justMakeThis }

    var body: some View {
        StockedShell(showBack: true, titleText: title) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if results.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 12) {
                        ForEach(results) { c in
                            prepCard(c)
                        }
                    }
                    .padding(.horizontal, CookStyle.screenHPad)
                }
                affirmation
                Spacer(minLength: 20)
            }
            .navigationDestination(isPresented: $goMethod) {
                if let cs = cookSession { CookingMethodComparisonView().environment(cs) }
            }
            .navigationDestination(isPresented: $goRecipe) {
                if let chosen, let cs = cookSession { UserRecipeDetailView(recipe: chosen).environment(cs) }
            }
        }
        .task { recompute() }
        .onChange(of: store.inventoryRevision) { _, _ in recompute() }
        .onChange(of: store.recipeRevision)    { _, _ in recompute() }
    }

    private func recompute() {
        snapshot = CookNowCompute.run(store: store, session: cookSession)
    }

    // MARK: Filtering by intent + dish role

    private var results: [ClassifiedRecipe] {
        var pool = snapshot.classified.filter { $0.readiness != .excluded }

        // Anchor scoping: prep must use the anchor when we have one.
        if !anchor.isEmpty {
            pool = pool.filter { c in c.recipe.ingredients.contains { looseContains($0.name, anchor) } || looseContains(c.recipe.title, anchor) }
        }

        switch intent {
        case .buildFullMeal:
            pool = pool.filter { role($0.recipe) == .fullMeal || role($0.recipe) == .unspecified }
        case .addSomething:
            // Keep it light: sides and components only.
            pool = pool.filter { role($0.recipe) == .side || role($0.recipe) == .component }
        case .justMakeThis, .trySomethingNew, .useWhatIHave, .useItUp, .alreadyKnowPlan:
            // Standalone preparations lead; full meals still allowed but sink.
            break
        }

        // Ordering by intent.
        switch intent {
        case .useWhatIHave:
            pool.sort { $0.readiness < $1.readiness }
        case .useItUp:
            let expiring = Set(store.inventoryItems.filter { $0.effectiveLevel > 0 && $0.isExpiringSoonOrExpired }.map { $0.name.lowercased() })
            pool.sort { a, b in
                usesExpiring(a, expiring) == usesExpiring(b, expiring) ? a.readiness < b.readiness : usesExpiring(a, expiring)
            }
        case .trySomethingNew:
            // Prefer recipes the user cooks less often.
            pool.sort { ($0.recipe.cookCount, $1.readiness.rawValue) < ($1.recipe.cookCount, $0.readiness.rawValue) }
        default:
            // Standalone roles first, then readiness.
            pool.sort { a, b in
                let aStand = role(a.recipe).isStandalone
                let bStand = role(b.recipe).isStandalone
                return aStand == bStand ? a.readiness < b.readiness : aStand
            }
        }

        return Array(pool.prefix(12))
    }

    /// Dish role, with a heuristic fallback for legacy recipes (unspecified).
    private func role(_ r: UserRecipe) -> DishRole {
        if r.dishRole != .unspecified { return r.dishRole }
        let t = r.title.lowercased()
        let sideWords = ["salad", "rice", "potato", "vegetable", "slaw", "bread", "roll", "side"]
        let sauceWords = ["sauce", "dressing", "marinade", "glaze", "dip", "gravy"]
        let mealWords = ["bowl", "tacos", "stir-fry", "stir fry", "sandwich", "wrap", "soup", "stew", "casserole", "pasta"]
        if sauceWords.contains(where: { t.contains($0) }) { return .component }
        if mealWords.contains(where: { t.contains($0) }) { return .fullMeal }
        if sideWords.contains(where: { t.contains($0) }) { return .side }
        return .entree
    }

    private func usesExpiring(_ c: ClassifiedRecipe, _ expiring: Set<String>) -> Bool {
        c.resolutions.contains { r in
            if case .inStock = r.status { return expiring.contains { looseContains(r.name, $0) } }
            return false
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
                .fixedSize(horizontal: false, vertical: true)
            Text(subheading)
                .font(.system(size: 13.5))
                .foregroundStyle(session.themeTextColor.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
    }

    // MARK: Preparation card

    private func prepCard(_ c: ClassifiedRecipe) -> some View {
        Button { open(c.recipe) } label: {
            VStack(alignment: .leading, spacing: 0) {
                MealHeroImage(recipeName: c.recipe.title, imageData: c.recipe.imageData)
                    .frame(height: 130).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(roleBadge(c.recipe))
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.stockedGold)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.stockedGold.opacity(0.12)).clipShape(Capsule())
                        Spacer()
                        readinessBadge(c)
                    }
                    Text(c.recipe.title)
                        .font(.system(size: 16, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                        .lineLimit(2)
                    HStack(spacing: 12) {
                        if !c.recipe.cookTime.isEmpty { metaLabel("clock", c.recipe.cookTime) }
                        if !c.recipe.difficulty.isEmpty { metaLabel("flame", c.recipe.difficulty) }
                        if role(c.recipe).isStandalone { metaLabel("checkmark.circle", "no sides needed") }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                .padding(.top, 10)
            }
            .padding(12)
            .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        }
        .buttonStyle(.plain)
        .a11yButton("\(c.recipe.title). \(roleBadge(c.recipe)). \(c.readiness.statusLabel)")
    }

    private func roleBadge(_ r: UserRecipe) -> String { role(r).label.uppercased() }

    private func readinessBadge(_ c: ClassifiedRecipe) -> some View {
        let (color, text): (Color, String) = {
            switch c.readiness {
            case .exact:           return (Color.stockedGreen, "Ready")
            case .readyWithSwap:   return (Color.stockedGreen, "Ready +swap")
            case .swapNeedsReview: return (Color.stockedGold, "Review swap")
            case .missingOne:      return (Color.stockedGold, "Missing 1")
            case .missingTwo:      return (Color.stockedGold, "Missing 2")
            case .missingMany:     return (Color.stockedGold, "Missing \(c.missingCount)")
            case .excluded:        return (Color.stockedError, "—")
            }
        }()
        return Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.12)).clipShape(Capsule())
    }

    private func metaLabel(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) { Image(systemName: icon); Text(text) }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "fork.knife").font(.system(size: 36)).foregroundStyle(session.themeTextColor.opacity(0.3))
            Text(anchor.isEmpty ? "Nothing matches yet" : "No \(anchor.displayNormalized) preparations yet")
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            Text("Try a different intent, or start with another item.")
                .font(.system(size: 13))
                .foregroundStyle(session.themeTextColor.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
        .padding(.horizontal, CookStyle.screenHPad)
    }

    // MARK: Actions

    private func open(_ recipe: UserRecipe) {
        guard let cs = cookSession else { return }
        cs.setPreparation(recipe.title)
        cs.recipeID = recipe.id
        chosen = recipe
        HapticManager.light()
        // "Already know" and standalone intents go straight to method; others
        // can view the full recipe first.
        if intent == .alreadyKnowPlan {
            cs.setStatus(.selectingMethod)
            goMethod = true
        } else {
            goRecipe = true
        }
    }

    // MARK: Copy

    private var title: String {
        switch intent {
        case .buildFullMeal:   return "Meal Ideas"
        case .trySomethingNew: return "Something New"
        case .useItUp:         return "Use It Up"
        case .addSomething:    return "Add Something"
        default:               return "Preparations"
        }
    }
    private var heading: String {
        if anchor.isEmpty { return "What can you make?" }
        switch intent {
        case .justMakeThis:    return "Ways to make \(anchor.displayNormalized)"
        case .addSomething:    return "Light additions"
        case .buildFullMeal:   return "Full meals with \(anchor.displayNormalized)"
        case .trySomethingNew: return "New ways with \(anchor.displayNormalized)"
        case .useWhatIHave:    return "Most makeable with \(anchor.displayNormalized)"
        case .useItUp:         return "Use up \(anchor.displayNormalized)"
        case .alreadyKnowPlan: return anchor.displayNormalized
        }
    }
    private var subheading: String {
        switch intent {
        case .justMakeThis:    return "Standalone preparations. Cook one and stop — no sides required."
        case .addSomething:    return "Low-effort sides and components that keep the star simple."
        case .buildFullMeal:   return "Complete meal structures around your anchor."
        case .trySomethingNew: return "Preparations outside your usual rotation."
        case .useWhatIHave:    return "Ranked by what you can cook right now."
        case .useItUp:         return "Prioritizing what's expiring or already open."
        case .alreadyKnowPlan: return "Pick your preparation and we'll set up the cook."
        }
    }

    private var affirmation: some View {
        Text("Every one of these is a complete cook on its own. Add more only if you want to.")
            .font(.system(size: 12))
            .foregroundStyle(session.themeTextColor.opacity(0.5))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, CookStyle.screenHPad + 8)
    }

    private func looseContains(_ a: String, _ b: String) -> Bool {
        let na = a.lowercased(), nb = b.lowercased()
        guard na.count > 2, nb.count > 2 else { return na == nb }
        return na.contains(nb) || nb.contains(na)
    }
}
