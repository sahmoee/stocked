// ReadyToCookView.swift — "Ready to Cook Now" tab. Extracted from RecipeVaultViews.swift
import SwiftUI
import PhotosUI

struct ReadyToCoookNowView: View {
    var onBrowseOnline: () -> Void = {}
    var onAddRecipe: () -> Void = {}
    @Environment(AppSession.self) var session

    // Async ready recipes — computed in background, not on main thread (#18)
    @State private var cachedReadyRecipes: [(title: String, ingredients: [String], source: String, score: Int, missing: [String])] = []
    @State private var isComputingReady = false
    @State private var isGeneratingRecipe = false
    @State private var generationMessage: String?

    // Trigger recompute when anything that affects readiness changes. Item IDs alone aren't
    // enough — readiness is computed from the pantry NAMES (pantrySet) and the recipe
    // collections, so editing/restocking an item or adding a recipe must also refresh.
    private var inventoryFingerprint: String {
        let pantry = session.guestStore.pantrySet.sorted().joined(separator: ",")
        let recipeCounts = "\(session.guestStore.userRecipes.count)-\(session.guestStore.savedGeneratedRecipes.count)"
        let browseCount = OnlineRecipesLoader.shared.recipes.count
        return "\(pantry)|\(recipeCounts)|\(browseCount)"
    }

    // #12: lastComputedFingerprint guards against recompute when nothing changed
    @State private var lastComputedFingerprint: String = ""

    func computeReadyRecipes() async {
        let fp = inventoryFingerprint
        guard !isComputingReady, fp != lastComputedFingerprint else { return }
        isComputingReady = true
        defer { isComputingReady = false; lastComputedFingerprint = fp }
        let pantrySet = session.guestStore.pantrySet
        guard !pantrySet.isEmpty else { cachedReadyRecipes = []; return }

        var result: [(title: String, ingredients: [String], source: String, score: Int, missing: [String])] = []

        // 1. User recipes — ALL included, no isReady gate
        for r in session.guestStore.userRecipes {
            let ings = r.ingredientNames
            guard !ings.isEmpty else { continue }
            let match = IngredientMatcher.score(recipeIngredients: ings, pantrySet: pantrySet)
            result.append((r.title, ings, "My Recipes", match.score, match.missing))
        }

        // 2. Saved generated recipes — ALL included
        for r in session.guestStore.savedGeneratedRecipes {
            let ings = r.ingredients.map { $0.name }
            guard !ings.isEmpty else { continue }
            let match = IngredientMatcher.score(recipeIngredients: ings, pantrySet: pantrySet)
            result.append((r.title, ings, "AI Generated", match.score, match.missing))
        }

        // 3. Browse recipes — the SAME online pool the Browse tab shows (OnlineRecipesLoader),
        // filtered to ones you can actually cook now (missing at most a couple of ingredients).
        // Snapshot the array ONCE into a local so we don't read the @Observable repeatedly (which
        // can register a SwiftUI dependency that re-triggers this view and feeds an allocation loop).
        let browseSnapshot = OnlineRecipesLoader.shared.recipes
        for r in browseSnapshot {
            guard !r.ingredients.isEmpty else { continue }
            let match = IngredientMatcher.score(recipeIngredients: r.ingredients, pantrySet: pantrySet)
            // Only surface Browse recipes you have (most of) the ingredients for.
            guard match.missing.count <= 2 else { continue }
            result.append((r.title, r.ingredients, r.source, match.score, match.missing))
        }

        // 4. Smart combos — ALL included
        let combos: [(String, [String])] = [
            ("Quick Stir Fry",       ["chicken","garlic","soy sauce","oil","vegetables"]),
            ("Pasta Aglio e Olio",   ["pasta","garlic","olive oil","parsley"]),
            ("Fried Rice",           ["rice","eggs","soy sauce","garlic","oil"]),
            ("Scrambled Eggs",       ["eggs","butter","salt"]),
            ("Omelette",             ["eggs","butter","cheese"]),
            ("Pan-Seared Steak",     ["beef","butter","garlic","salt"]),
            ("Simple Tomato Soup",   ["tomato","broth","onion","garlic"]),
            ("Dal",                  ["lentils","onion","garlic","turmeric","cumin"]),
            ("Bean Quesadilla",      ["tortillas","black beans","cheese","salsa"]),
            ("Avocado Toast",        ["bread","avocado","lemon","salt"]),
            ("Pesto Pasta",          ["pasta","basil","garlic","olive oil","parmesan"]),
            ("Chicken Salad",        ["chicken","lettuce","olive oil","lemon"]),
        ]
        for (title, reqs) in combos {
            let match = IngredientMatcher.score(recipeIngredients: reqs, pantrySet: pantrySet)
            result.append((title, reqs.map { $0.capitalized }, "Suggested", match.score, match.missing))
        }

        // Sort by score descending (most ingredients available first); de-duplicate
        // with fuzzy matching so a "Suggested" combo never doubles a real DB recipe (#18).
        // Uses RecipeDedup.dedupe, which parses each recipe's ingredient names ONCE and
        // reuses them across the O(n²) comparisons — the inline version here re-parsed on
        // every comparison, which was a major source of the runaway-memory allocations.
        let sorted = result.sorted { $0.score > $1.score }
        let deduped = RecipeDedup.dedupe(sorted, title: { $0.title }, ingredients: { $0.ingredients })

        await MainActor.run { cachedReadyRecipes = deduped }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.guestStore.inventoryItems.isEmpty {
                StockedEmptyState(
                    icon: "🧊", title: "Pantry is empty",
                    subtitle: "Add a recipe, or add items to your inventory and we'll find matching recipes.",
                    ctaLabel: "Add Recipe", onCTA: { onAddRecipe() },
                    tips: ["Scan a barcode to add items instantly",
                           "Use the receipt scanner after grocery shopping",
                           "Manually add staples like rice, pasta and oil"]
                ).padding(.top, 16)
            } else {
                ReadyToCoookContent(
                    cachedReadyRecipes: cachedReadyRecipes,
                    isComputingReady: isComputingReady,
                    isGeneratingRecipe: isGeneratingRecipe,
                    generationMessage: generationMessage,
                    onGenerateRecipe: generateRecipe,
                    onBrowseOnline: onBrowseOnline
                )
            }
        }
        // Single source of truth for (re)computing: .task(id:) runs once on appear and
        // re-runs ONLY when the inventory fingerprint actually changes, automatically
        // cancelling any in-flight run. This replaces the old .task + .onChange(+Task)
        // pair, which could feed back into itself (render → onChange → Task → state change
        // → render …) and allocate unbounded memory until the OS killed the app on iPad.
        .task(id: inventoryFingerprint) {
            await computeReadyRecipes()
            // Ensure the Browse pool is loaded so Ready to Cook reflects the same recipes. When
            // it populates, the fingerprint (which includes the Browse count) changes and this
            // task re-runs once to fold the now-makeable recipes in.
            if OnlineRecipesLoader.shared.recipes.isEmpty {
                OnlineRecipesLoader.shared.loadIfNeeded()
            }
        }
    }

    private func generateRecipe() {
        guard !isGeneratingRecipe else { return }
        isGeneratingRecipe = true
        generationMessage = nil
        Task {
            let savedID = await MealsReadyNowGenerator.shared.generateAndStore(in: session.guestStore)
            generationMessage = savedID == nil
                ? "Couldn't create a recipe right now. Check your connection and try again."
                : "Created and saved a recipe from your inventory."
            isGeneratingRecipe = false
        }
    }
}

// MARK: - Ready to Cook content (extracted to fix type-check timeout)
private struct ReadyToCoookContent: View {
    @Environment(AppSession.self) var session
    let cachedReadyRecipes: [(title: String, ingredients: [String], source: String, score: Int, missing: [String])]
    let isComputingReady: Bool
    let isGeneratingRecipe: Bool
    let generationMessage: String?
    let onGenerateRecipe: () -> Void
    let onBrowseOnline: () -> Void

    private var readyNow: Int { cachedReadyRecipes.filter { $0.missing.isEmpty }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(readyNow) ready now · \(cachedReadyRecipes.count) total")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                    Text("Sorted by most ingredients available")
                        .font(.system(size: 11))
                        .foregroundStyle(session.themeTextColor.opacity(0.35))
                }
                Spacer()
                if isComputingReady {
                    ProgressView().tint(Color.stockedGold).scaleEffect(0.75)
                }
                Button(action: onGenerateRecipe) {
                    Label(isGeneratingRecipe ? "Creating…" : "Create from inventory",
                          systemImage: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stockedGold)
                .disabled(isGeneratingRecipe)
            }
            .padding(.horizontal, 24).padding(.bottom, 10)

            if let generationMessage {
                Text(generationMessage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            if cachedReadyRecipes.isEmpty && !isComputingReady {
                StockedEmptyState(
                    icon: "🔍", title: "No matches yet",
                    subtitle: "Add more pantry items or browse Search to find something to cook.",
                    ctaLabel: "Browse Online", onCTA: onBrowseOnline,
                    tips: ["Add pantry items to see matching recipes",
                           "Tap Browse Online to find something new"]
                ).padding(.top, 16)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        // Unique id per row (title+source+index) — duplicate titles across
                        // sources would otherwise collide as SwiftUI IDs and thrash diffing.
                        ForEach(Array(cachedReadyRecipes.enumerated()), id: \.offset) { _, recipe in
                            ReadyToCoookRecipeRow(recipe: recipe)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }
}

// MARK: - Resolved food-image thumbnail for list rows
// Shows a real food image resolved by recipe title (CachedAsyncImage's built-in resolver:
// TheMealDB → Spoonacular → category-matched Foodish). Falls to a clean placeholder only
// while resolving / if everything fails. A small checkmark badge marks "ready now" so we
// keep that status cue without replacing the whole thumbnail with a checkmark.
private struct ReadyToCookThumb: View {
    @Environment(AppSession.self) var session
    let recipeName: String
    let isReady: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CachedAsyncImage(url: nil, imageData: nil, height: 52, resolveName: recipeName)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                .overlay(
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                        .stroke(Color.stockedCharcoal.opacity(0.08), lineWidth: 1)
                )
            if isReady {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.stockedGreen)
                    .background(Circle().fill(Color.stockedWhite).frame(width: 16, height: 16))
                    .padding(3)
            }
        }
    }
}

// MARK: - Individual ready-to-cook recipe row
private struct ReadyToCoookRecipeRow: View {
    @Environment(AppSession.self) var session
    let recipe: (title: String, ingredients: [String], source: String, score: Int, missing: [String])
    @State private var addedToList: Int? = nil   // #3 feedback

    private var isReady: Bool { recipe.missing.isEmpty }
    private var pct: Int {
        guard !recipe.ingredients.isEmpty else { return 100 }
        return Int(finite: safeDivide(Double(recipe.ingredients.count - recipe.missing.count), by: Double(recipe.ingredients.count)) * 100, fallback: 100)
    }

    var body: some View {
        NavigationLink(destination: RecipeOverviewView(
            title: recipe.title, servings: 2, ingredients: recipe.ingredients)
        ) {
            HStack(spacing: 14) {
                iconView
                infoView
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(14)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .overlay(rowOverlay)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconView: some View {
        ReadyToCookThumb(recipeName: recipe.title, isReady: isReady)
    }

    private var infoView: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Title + source
            HStack(spacing: 6) {
                Text(recipe.title)
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .lineLimit(1)
                Text(recipe.source)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.stockedGold)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.stockedGold.opacity(0.12))
                    .clipShape(Capsule())
            }
            // Progress bar + pill
            HStack(spacing: 8) {
                // Fixed 70pt track — fill sized directly from pct (no GeometryReader)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.stockedCharcoal.opacity(0.12))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isReady ? Color.stockedGold : Color.stockedGold.opacity(0.5))
                        .frame(width: max(0, 70 * CGFloat(pct) / 100))
                }
                .frame(width: 70, height: 4)

                statusPill
            }
            // Missing ingredients
            if !recipe.missing.isEmpty {
                let shown = recipe.missing.prefix(2).joined(separator: ", ")
                let extra = recipe.missing.count > 2 ? " +\(recipe.missing.count - 2)" : ""
                Text("Need: \(shown)\(extra)")
                    .font(.system(size: 10))
                    .foregroundStyle(session.themeTextColor.opacity(0.38))
                    .lineLimit(1)
                // #3 — one-tap add missing ingredients to grocery.
                Button {
                    var added = 0
                    for ing in recipe.missing {
                        let n = ing.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty,
                              !session.guestStore.groceryItems.contains(where: { $0.name.lowercased() == n.lowercased() })
                        else { continue }
                        session.guestStore.addToGroceryIfMissing(n, recommended: true, recipeSource: recipe.title)
                        added += 1
                    }
                    addedToList = added
                    HapticManager.success()
                } label: {
                    Label(addedToList == nil ? "Add \(recipe.missing.count) to list" : "Added ✓",
                          systemImage: addedToList == nil ? "cart.badge.plus" : "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.stockedGold)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    private var statusPill: some View {
        Group {
            if isReady {
                Text("Ready Now")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.stockedGold)
                    .clipShape(Capsule())
            } else {
                Text("Missing \(recipe.missing.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.stockedCharcoal.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
    }

    private var rowBackground: Color {
        if isReady {
            return session.isDarkMode ? Color.stockedGold.opacity(0.08) : Color.stockedGold.opacity(0.07)
        }
        return session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3)
    }

    @ViewBuilder
    private var rowOverlay: some View {
        if isReady {
            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                .stroke(Color.stockedGold.opacity(0.3), lineWidth: 1)
        }
    }
}
