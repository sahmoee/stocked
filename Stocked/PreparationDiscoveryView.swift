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

    @State private var results: [ClassifiedRecipe] = []
    @State private var isLoading = true
    @State private var searchUnavailable = false
    @State private var goMethod = false
    @State private var goRecipe = false
    @State private var chosen: UserRecipe? = nil

    private var anchor: String { cookSession?.anchorItem ?? "" }
    private var intent: CookIntent { cookSession?.intent ?? .justMakeThis }

    var body: some View {
        StockedShell(showBack: true, titleText: title) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if isLoading {
                    ProgressView("Finding preparations…")
                        .tint(session.accentColor).padding(.horizontal, CookStyle.screenHPad)
                }
                if results.isEmpty && !isLoading {
                    emptyState
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(results) { c in
                            prepCard(c)
                        }
                    }
                    .padding(.horizontal, CookStyle.screenHPad)
                }
                affirmation
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
        .onChange(of: store.planRevision) { _, _ in recompute() }
        .onChange(of: OnlineRecipesLoader.shared.revision) { _, _ in recompute() }
        .onDisappear { classificationTask?.cancel() }
        .onChange(of: store.recipeRevision)    { _, _ in recompute() }
        .onChange(of: anchor) { _, _ in recompute() }
        .onChange(of: intent) { _, _ in recompute() }
        .onChange(of: cookSession?.addScope) { _, _ in recompute() }
        .onChange(of: RecipeDatabaseManager.shared.catalogueRevision) { _, _ in recompute() }
        .onChange(of: RecipeDatabaseManager.shared.recipesVersion) { _, _ in recompute() }
    }

    private func recompute() {
        classificationTask?.cancel()
        isLoading = true
        let currentAnchor = anchor, currentIntent = intent, scope = cookSession?.addScope
        searchUnavailable = false
        classificationTask = Task {
            defer { if !Task.isCancelled { isLoading = false } }
            guard let snapshot = await CookNowCompute.runYielding(store: store, session: cookSession),
                  !Task.isCancelled else { return }
            let expiring = Set(store.inventoryItems.filter { $0.effectiveLevel > 0 && $0.isExpiringSoonOrExpired }.map { $0.name.lowercased() })
            let saved = snapshot.classified.map(\.recipe)
            let inventory = store.inventoryItems
            let allergens = store.cookingProfile.allergens + FamilyProfileStore.shared.activeAllergens
            let dislikes = FamilyProfileStore.shared.profiles.filter(\.isPresent).flatMap(\.dislikes)
            let worker = Task.detached(priority: .userInitiated) {
                try await FinderService.query(filters: FinderFilters(), saved: saved, history: [],
                    inventory: inventory, allergens: allergens, limit: 80,
                    acceptsRecipe: { recipe in
                        guard RecipeDisplayPolicy.isPresentable(title: recipe.title, imageURL: recipe.imageURL,
                            imageData: recipe.imageData, ingredients: recipe.ingredients.count,
                            steps: recipe.instructions.count, sourceURL: recipe.sourceURL) else { return false }
                        guard !dislikes.contains(where: { dislike in
                            recipe.ingredients.contains { KitchenAvailability.nameMatches($0.name, dislike) }
                        }) else { return false }
                        return PreparationDiscoveryPolicy.accepts(title: recipe.title, ingredients: recipe.ingredients.map(\.name),
                            explicitRole: recipe.dishRole, anchor: currentAnchor, intent: currentIntent, scope: scope)
                    })
            }
            do {
                let found = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                searchUnavailable = found.catalogueUnavailable
                guard let classified = await CookNowCompute.classifyYielding(recipes: found.hits.map(\.recipe), store: store, session: cookSession),
                      !Task.isCancelled else { return }
                results = Self.selectResults(snapshot: classified, anchor: currentAnchor, intent: currentIntent, scope: scope, expiring: expiring)
            } catch {
                guard !Task.isCancelled else { return }
                searchUnavailable = true
                results = Self.selectResults(snapshot: snapshot, anchor: currentAnchor, intent: currentIntent, scope: scope, expiring: expiring)
            }
        }
    }

    @State private var classificationTask: Task<Void, Never>?

    // MARK: Filtering by intent + dish role

    nonisolated private static func selectResults(snapshot: CookNowCompute.Output, anchor: String,
                                                  intent: CookIntent, scope: AddSomethingScope?, expiring: Set<String>) -> [ClassifiedRecipe] {
        var pool = snapshot.classified.filter { $0.readiness != .excluded }

        pool = pool.filter {
            PreparationDiscoveryPolicy.accepts(title: $0.recipe.title, ingredients: $0.recipe.ingredients.map(\.name),
                explicitRole: $0.recipe.dishRole, anchor: anchor, intent: intent, scope: scope)
        }

        // Ordering by intent.
        switch intent {
        case .addSomething:
            pool.sort { a, b in
                let ar = PreparationDiscoveryPolicy.additionRank(title: a.recipe.title, scope: scope,
                    usesExpiring: usesExpiring(a, expiring))
                let br = PreparationDiscoveryPolicy.additionRank(title: b.recipe.title, scope: scope,
                    usesExpiring: usesExpiring(b, expiring))
                return ar == br ? a.readiness < b.readiness : ar < br
            }
        case .buildFullMeal:
            pool.sort { a, b in
                let aMeal = role(a.recipe) == .fullMeal, bMeal = role(b.recipe) == .fullMeal
                return aMeal == bMeal ? a.readiness < b.readiness : aMeal
            }
        case .useWhatIHave:
            pool.sort { $0.readiness < $1.readiness }
        case .useItUp:
            let uses = Set(pool.filter { usesExpiring($0, expiring) }.map(\.id))
            pool.sort { a, b in
                uses.contains(a.id) == uses.contains(b.id) ? a.readiness < b.readiness : uses.contains(a.id)
            }
        case .trySomethingNew:
            // Prefer recipes the user cooks less often.
            pool.sort { ($0.recipe.cookCount, $0.readiness.rawValue) < ($1.recipe.cookCount, $1.readiness.rawValue) }
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
    nonisolated private static func role(_ r: UserRecipe) -> DishRole {
        PreparationDiscoveryPolicy.role(title: r.title, explicit: r.dishRole)
    }

    nonisolated private static func usesExpiring(_ c: ClassifiedRecipe, _ expiring: Set<String>) -> Bool {
        c.resolutions.contains { r in
            if case .inStock = r.status { return expiring.contains { looseContains(r.name, $0) } }
            return false
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .scaledFont(20, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
                .fixedSize(horizontal: false, vertical: true)
            Text(subheading)
                .scaledFont(13.5)
                .foregroundStyle(session.themeSecondaryText)
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
                            .scaledFont(9.5, weight: .bold)
                            .foregroundStyle(Color.stockedAccentInk)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.stockedGold.opacity(0.12)).clipShape(Capsule())
                        Spacer()
                        readinessBadge(c)
                    }
                    Text(c.recipe.title.recipeDisplayTitle)
                        .scaledFont(16, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        if !c.recipe.cookTime.isEmpty { metaLabel("clock", c.recipe.cookTime) }
                        if !c.recipe.difficulty.isEmpty { metaLabel("flame", c.recipe.difficulty) }
                        if intent != .buildFullMeal && Self.role(c.recipe).isStandalone { metaLabel("checkmark.circle", "no sides needed") }
                    }
                    .scaledFont(11.5)
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

    private func roleBadge(_ r: UserRecipe) -> String { Self.role(r).label.uppercased() }

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
            .scaledFont(10, weight: .bold)
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
            Image(systemName: "fork.knife").scaledFont(36).foregroundStyle(session.themeTextColor.opacity(0.3))
            Text(anchor.isEmpty ? "Nothing matches yet" : "No \(anchor.displayNormalized) preparations yet")
                .scaledFont(16, weight: .semibold, design: .serif)
                .foregroundStyle(session.themeTextColor)
            Text(searchUnavailable ? "Some recipe sources couldn’t be loaded. Try again." : "No matching recipes in the downloaded library. Try another ingredient or intent.")
                .scaledFont(13)
                .foregroundStyle(session.themeSecondaryText)
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
        case .buildFullMeal:   return "Choose a main or a complete dish to build your meal around."
        case .trySomethingNew: return "Preparations outside your usual rotation."
        case .useWhatIHave:    return "Ranked by what you can cook right now."
        case .useItUp:         return "Prioritizing what's expiring or already open."
        case .alreadyKnowPlan: return "Pick your preparation and we'll set up the cook."
        }
    }

    private var affirmation: some View {
        Text("Every one of these is a complete cook on its own. Add more only if you want to.")
            .scaledFont(12)
            .foregroundStyle(session.themeSecondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, CookStyle.screenHPad + 8)
    }

    // Shared matcher — was a sixth copy of the substring rule.
    nonisolated private static func looseContains(_ a: String, _ b: String) -> Bool {
        KitchenAvailability.nameMatches(a, b)
    }
}
