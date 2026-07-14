// SmartRecommendationView.swift
// ─────────────────────────────────────────────────────────────────
// "Tonight's Pick" — the single confident recommendation every Cook Now
// pathway converges on. Instead of dropping the user into a long list after
// they choose an ingredient (or ask to be surprised), Stocked presents its
// strongest match first, explains why it fits, and offers Try Another and
// See All as follow-ups.
//
// Contract (from the Cook Now spec):
//   • One shared recommendation brain: ranking = readiness tier first
//     (exact → confirmed swaps → swaps to review → missing 1 → missing 2),
//     then only signals that really exist — expiring-ingredient usage,
//     profile cuisine boost, favorites, repetition avoidance via lastCooked,
//     and inventory coverage.
//   • Try Another preserves the selected ingredient, servings, filters, and
//     session context, and excludes the current pick via the session's
//     bounded ring so it never ping-pongs between two meals while more exist.
//   • When no alternative exists, the refresh is replaced by an intentional
//     "strongest match" state with useful exits — never a broken button.
//   • Substitution status is explicit: ready with an in-stock swap vs a swap
//     that still needs review — never a bare "1 substitution".
//   • The serving control is interactive and session-scoped.
//
// Header rule (Part 4): the page title is the stable "Tonight's Pick";
// "Built around X" is contextual metadata, never the page title.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

struct SmartRecommendationView: View {

    /// Where the recommendation request came from — shapes the context line
    /// and the candidate pool, never the underlying intelligence.
    enum Mode: Equatable {
        case best                       // dashboard "what should I make"
        case ingredient(String)         // Build Around Food / chips
        case surprise                   // Surprise Me
    }

    let mode: Mode
    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var candidates: [ClassifiedRecipe] = []
    @State private var pick: ClassifiedRecipe? = nil
    @State private var exhausted = false          // Try Another ran out of alternatives
    @State private var goRecipe = false
    @State private var goAll = false
    @State private var goRefreshKitchen = false
    @State private var goMood = false
    @State private var loading = true

    var body: some View {
        StockedShell(showBack: true, titleText: "Tonight's Pick") {
            VStack(alignment: .leading, spacing: 16) {
                contextLine

                if loading {
                    loadingState
                } else if let pick {
                    recommendationCard(pick)
                    whyWePicked(pick)
                    actionRow(pick)
                } else {
                    noMatchState
                }

                Spacer(minLength: 20)
            }
            .navigationDestination(isPresented: $goRecipe) {
                if let pick { UserRecipeDetailView(recipe: pick.recipe) }
            }
            .navigationDestination(isPresented: $goAll) {
                CookNowResultsView(focus: .readyFirst)
            }
            .navigationDestination(isPresented: $goRefreshKitchen) { RefreshKitchenView() }
            .navigationDestination(isPresented: $goMood) { MatchMyMoodFlowView() }
        }
        .task { recommend(excludingCurrent: false) }
        .onChange(of: store.inventoryRevision) { _, _ in recommend(excludingCurrent: false) }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            goRecipe = false; goAll = false; goRefreshKitchen = false; goMood = false
        }
    }

    // MARK: Recommendation

    private func recommend(excludingCurrent: Bool) {
        loading = candidates.isEmpty
        if case .ingredient(let ing) = mode { cookSession?.selectedIngredient = ing }

        var pool = CookNowCompute.run(store: store, session: cookSession).classified
            .filter { $0.readiness != .excluded && $0.readiness != .missingMany }

        // Scope by the chosen ingredient: the recipe must actually use it.
        if case .ingredient(let ing) = mode {
            pool = pool.filter { c in
                c.recipe.ingredients.contains { looseContains($0.name, ing) }
            }
        }

        // Rank: readiness tier first, then real signals only.
        let expiring = Set(store.inventoryItems
            .filter { $0.effectiveLevel > 0 && $0.isExpiringSoonOrExpired }
            .map { $0.name.lowercased() })

        func score(_ c: ClassifiedRecipe) -> Double {
            var s = 0.0
            // Uses expiring items → strong waste-nothing boost.
            let usesExpiring = c.resolutions.contains { r in
                if case .inStock = r.status {
                    return expiring.contains { looseContains(r.name, $0) }
                }
                return false
            }
            if usesExpiring { s += 3 }
            s += Double(store.profileBoost(for: c.recipe))          // cuisine prefs
            if c.recipe.isFavorited { s += 2 }
            // Repetition avoidance: cooked in the last 4 days sinks.
            if let last = c.recipe.lastCooked,
               Date().timeIntervalSince(last) < 4 * 86_400 { s -= 3 }
            // Coverage nudge inside the tier.
            let total = max(1, c.resolutions.count)
            s += Double(c.exactCount) / Double(total)
            return s
        }

        var ranked = pool.sorted {
            $0.readiness == $1.readiness ? score($0) > score($1) : $0.readiness < $1.readiness
        }

        // Surprise keeps the same intelligence but shuffles within the best
        // available readiness band, so "surprise" genuinely varies between
        // visits without ever recommending something less ready than it could.
        if mode == .surprise, let bestTier = ranked.first?.readiness {
            let band = ranked.filter { $0.readiness == bestTier }.shuffled()
            let rest = ranked.filter { $0.readiness != bestTier }
            ranked = band + rest
        }

        // Try Another: deprioritize the session's exclusion ring (most recent
        // first) instead of hard-dropping, so exhausting alternatives cycles
        // gracefully instead of dead-ending.
        if let cs = cookSession, !cs.excludedRecipeIDs.isEmpty {
            let excluded = cs.excludedRecipeIDs
            ranked.sort { a, b in
                let ia = excluded.firstIndex(of: a.recipe.id)
                let ib = excluded.firstIndex(of: b.recipe.id)
                switch (ia, ib) {
                case (nil, nil): return false          // keep prior order
                case (nil, _):   return true           // non-excluded first
                case (_, nil):   return false
                case (let x?, let y?): return x > y    // least-recently shown first
                }
            }
        }

        candidates = ranked
        if excludingCurrent, let current = pick {
            cookSession?.excludeFromNext(current.recipe.id)
            let next = ranked.first { $0.recipe.id != current.recipe.id }
            if let next {
                exhausted = false
                withAnimation(.spring(response: 0.3)) { pick = next }
            } else {
                exhausted = true    // intentional strongest-match state
            }
        } else {
            pick = ranked.first
            exhausted = false
        }
        cookSession?.recipeID = pick?.recipe.id
        loading = false
    }

    private func looseContains(_ a: String, _ b: String) -> Bool {
        let na = a.lowercased(), nb = b.lowercased()
        return na.contains(nb) || nb.contains(na)
    }

    // MARK: Context line

    private var contextLine: some View {
        Group {
            switch mode {
            case .ingredient(let ing):
                Label("Built around \(ing.displayNormalized)", systemImage: "sparkles")
            case .surprise:
                Label("A surprise from your kitchen", systemImage: "gift")
            case .best:
                Label("Best pick for you", systemImage: "sparkles")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.stockedGold)
        .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
    }

    // MARK: Recommendation card

    private func recommendationCard(_ c: ClassifiedRecipe) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MealHeroImage(recipeName: c.recipe.title, imageData: c.recipe.imageData)
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))

            VStack(alignment: .leading, spacing: 8) {
                Text(c.recipe.title)
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                if !c.recipe.description.isEmpty {
                    Text(c.recipe.description)
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .lineLimit(2)
                }

                HStack(spacing: 14) {
                    if !c.recipe.cookTime.isEmpty {
                        Label(c.recipe.cookTime, systemImage: "clock")
                    }
                    servingControl
                    if !c.recipe.difficulty.isEmpty {
                        Label(c.recipe.difficulty, systemImage: "flame")
                    }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(session.themeTextColor.opacity(0.65))

                readinessLine(c)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, CookStyle.screenHPad)
        .id(c.recipe.id)   // animate card swap on Try Another
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .opacity))
    }

    /// Interactive session-scoped serving control ("Serves N" with steppers).
    private var servingControl: some View {
        HStack(spacing: 6) {
            Button { adjustServings(-1) } label: {
                Image(systemName: "minus.circle").font(.system(size: 14))
            }.buttonStyle(.plain)
            Text("Serves \(cookSession?.servings ?? max(1, store.cookingProfile.householdSize))")
                .font(.system(size: 12.5, weight: .semibold))
                .contentTransition(.numericText())
            Button { adjustServings(+1) } label: {
                Image(systemName: "plus.circle").font(.system(size: 14))
            }.buttonStyle(.plain)
        }
        .foregroundStyle(Color.stockedGold)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Serves \(cookSession?.servings ?? 1). Adjustable for this session.")
    }

    private func adjustServings(_ delta: Int) {
        guard let cs = cookSession else { return }
        withAnimation(.spring(response: 0.25)) { cs.setServings(cs.servings + delta) }
        HapticManager.select()
    }

    /// Explicit readiness + substitution status. Never a bare "1 substitution".
    private func readinessLine(_ c: ClassifiedRecipe) -> some View {
        let (icon, color, text): (String, Color, String) = {
            switch c.readiness {
            case .exact:
                return ("checkmark.circle.fill", Color.stockedGreen, "Ready now — everything's in stock")
            case .readyWithSwap:
                return ("arrow.triangle.swap", Color.stockedGreen,
                        "Ready with \(c.substitutionCount) in-stock swap\(c.substitutionCount == 1 ? "" : "s")")
            case .swapNeedsReview:
                return ("exclamationmark.triangle.fill", Color.stockedGold,
                        "\(c.reviewCount) substitution\(c.reviewCount == 1 ? "" : "s") to review")
            case .missingOne, .missingTwo:
                return ("cart.badge.plus", Color.stockedGold,
                        "Missing \(c.missingCount) item\(c.missingCount == 1 ? "" : "s")")
            case .missingMany:
                return ("cart", Color.stockedGold, "Needs a few more items")
            case .excluded:
                return ("nosign", Color.stockedError, "Not a fit for your preferences")
            }
        }()
        return HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 12.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
        .accessibilityLabel(text)
    }

    // MARK: Why we picked this

    private func whyWePicked(_ c: ClassifiedRecipe) -> some View {
        let reasons = pickReasons(c)
        return Group {
            if !reasons.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why we picked this")
                        .font(.system(size: 14, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    ForEach(reasons, id: \.self) { r in
                        HStack(spacing: 8) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.stockedGold)
                            Text(r)
                                .font(.system(size: 12.5))
                                .foregroundStyle(session.themeTextColor.opacity(0.7))
                        }
                    }
                }
                .padding(.horizontal, CookStyle.screenHPad)
            }
        }
    }

    /// Only reasons the data actually supports — never invented.
    private func pickReasons(_ c: ClassifiedRecipe) -> [String] {
        var out: [String] = []
        let expiring = Set(store.inventoryItems
            .filter { $0.effectiveLevel > 0 && $0.isExpiringSoonOrExpired }
            .map { $0.name.lowercased() })
        let usesExpiring = c.resolutions.contains { r in
            if case .inStock = r.status { return expiring.contains { looseContains(r.name, $0) } }
            return false
        }
        if usesExpiring { out.append("Uses items you'll want to use soon") }
        if c.readiness == .exact { out.append("Great match for your ingredients") }
        if c.readiness == .readyWithSwap { out.append("Works with a swap you already have") }
        if store.profileBoost(for: c.recipe) > 0 { out.append("Matches your cuisine preferences") }
        if c.recipe.isFavorited { out.append("One of your favorites") }
        if c.recipe.cookCount > 2 { out.append("A meal you come back to") }
        return Array(out.prefix(3))
    }

    // MARK: Actions

    private func actionRow(_ c: ClassifiedRecipe) -> some View {
        VStack(spacing: 10) {
            if exhausted {
                strongestMatchNotice
            }
            Button { goRecipe = true; HapticManager.light() } label: {
                Text("View Recipe")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(dark ? Color.darkSurface : Color.stockedCharcoal)
                    .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                        .stroke(dark ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }
            .buttonStyle(.plain)
            .a11yButton("View recipe for \(c.recipe.title)")

            HStack(spacing: 10) {
                Button { recommend(excludingCurrent: true); HapticManager.light() } label: {
                    Label("Try Another", systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }
                .buttonStyle(.plain)
                .a11yButton("Try another recommendation")

                Button { goAll = true } label: {
                    Text("See All Options")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }
                .buttonStyle(.plain)
                .a11yButton("See all matching recipes")
            }
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    /// Intentional no-alternative state — the refresh never looks broken.
    private var strongestMatchNotice: some View {
        VStack(spacing: 4) {
            Text("That's the strongest match we found.")
                .font(.system(size: 13.5, weight: .semibold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            Text("No other recipes fit your current ingredients and preferences.")
                .font(.system(size: 12))
                .foregroundStyle(session.themeTextColor.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(Color.stockedGold.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }

    // MARK: Empty / loading

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Finding the best recipe for you…")
                .font(.system(size: 13))
                .foregroundStyle(session.themeTextColor.opacity(0.5))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    private var noMatchState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("We couldn't find a match yet.")
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            Text(noMatchDetail)
                .font(.system(size: 13.5))
                .foregroundStyle(session.themeTextColor.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            Button { goAll = true } label: {
                Text("View More Possibilities")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(dark ? Color.darkSurface : Color.stockedCharcoal)
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }.buttonStyle(.plain)
            Button { goRefreshKitchen = true } label: {
                Text("Refresh Kitchen")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }.buttonStyle(.plain)
            Button { goMood = true } label: {
                Text("Match My Mood")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    private var noMatchDetail: String {
        if case .ingredient(let ing) = mode {
            return "None of your saved recipes use \(ing.displayNormalized) with what's currently logged. Try another ingredient, refresh your kitchen, or browse more possibilities."
        }
        return "Nothing fits your current ingredients and preferences yet. Refresh your kitchen or browse more possibilities."
    }
}
