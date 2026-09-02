// ReadyToCookView.swift — "Ready to Cook Now" tab. Extracted from RecipeVaultViews.swift
import SwiftUI
import PhotosUI

private struct ReadyRecipe: Identifiable {
    let id: UUID
    let title: String
    let ingredients: [String]
    let source: String
    let score: Int
    let missing: [String]
    let substitutions: [String]
    let substitutionsNeedReview: Bool
}

struct ReadyToCoookNowView: View {
    var onBrowseOnline: () -> Void = {}
    var onAddRecipe: () -> Void = {}
    @Environment(AppSession.self) var session

    // Async ready recipes — computed in background, not on main thread (#18)
    @State private var cachedReadyRecipes: [ReadyRecipe] = []
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
        let substitutions = session.guestStore.userSubstitutions
            .map { "\($0.ingredient.lowercased())::\($0.substitute.lowercased())" }
            .sorted().joined(separator: ",")
        return "\(pantry)|\(recipeCounts)|\(browseCount)|\(substitutions)"
    }

    // #12: lastComputedFingerprint guards against recompute when nothing changed
    @State private var lastComputedFingerprint: String = ""

    func computeReadyRecipes() async {
        let fp = inventoryFingerprint
        guard !isComputingReady, fp != lastComputedFingerprint else { return }
        isComputingReady = true
        defer { isComputingReady = false; lastComputedFingerprint = fp }
        guard !session.guestStore.pantrySet.isEmpty else { cachedReadyRecipes = []; return }

        // Use the same full catalog and classifier as Cook Now. This automatically includes
        // saved recipes, newly generated recipes, and newly synced Mac/Discover recipes, and
        // resolves in-stock substitutions before deciding how many ingredients are missing.
        let snapshot = CookNowCompute.run(store: session.guestStore, session: nil)
        let ownIDs = Set(session.guestStore.userRecipes.map(\.id))
        let generatedIDs = Set(session.guestStore.savedGeneratedRecipes.map {
            RecipeAdapter.userRecipe(from: $0).id
        })
        let result = snapshot.classified.compactMap { classified -> ReadyRecipe? in
            guard classified.readiness != .excluded else { return nil }
            let unresolved = classified.resolutions.compactMap { resolution -> String? in
                switch resolution.status {
                case .missing, .unconfirmed: return resolution.name
                default: return nil
                }
            }
            guard unresolved.count <= 5 else { return nil }
            var substitutions: [String] = []
            var needsReview = false
            for resolution in classified.resolutions {
                switch resolution.status {
                case .substituted(let substitute):
                    substitutions.append("\(resolution.name) → \(substitute)")
                case .substituteNeedsReview(let suggestion):
                    substitutions.append("\(resolution.name) → \(suggestion)")
                    needsReview = true
                default: break
                }
            }
            let required = classified.resolutions.filter {
                if case .optional = $0.status { return false }
                return true
            }.count
            let score = required == 0 ? 0 : Int(Double(required - unresolved.count) / Double(required) * 100)
            let source: String
            if ownIDs.contains(classified.recipe.id) { source = "My Recipes" }
            else if generatedIDs.contains(classified.recipe.id) { source = "AI Generated" }
            else { source = "Recipe Database" }
            return ReadyRecipe(
                id: classified.recipe.id,
                title: classified.recipe.title,
                ingredients: classified.recipe.ingredientNames,
                source: source,
                score: score,
                missing: unresolved,
                substitutions: substitutions,
                substitutionsNeedReview: needsReview
            )
        }.sorted {
            if $0.missing.count != $1.missing.count { return $0.missing.count < $1.missing.count }
            return $0.score > $1.score
        }

        cachedReadyRecipes = result
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
    let cachedReadyRecipes: [ReadyRecipe]
    let isComputingReady: Bool
    let isGeneratingRecipe: Bool
    let generationMessage: String?
    let onGenerateRecipe: () -> Void
    let onBrowseOnline: () -> Void

    private var readyNow: Int { cachedReadyRecipes.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(readyNow) ready now · \(cachedReadyRecipes.count) total")
                        .scaledFont(13, weight: .bold)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                    Text("Sorted by most ingredients available")
                        .scaledFont(11)
                        .foregroundStyle(session.themeTextColor.opacity(0.35))
                }
                Spacer()
                if isComputingReady {
                    ProgressView().tint(Color.stockedGold).scaleEffect(0.75)
                }
                Button(action: onGenerateRecipe) {
                    Label(isGeneratingRecipe ? "Creating…" : "Create from inventory",
                          systemImage: "sparkles")
                        .scaledFont(12, weight: .bold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.stockedGold)
                .disabled(isGeneratingRecipe)
            }
            .padding(.horizontal, 24).padding(.bottom, 10)

            if let generationMessage {
                Text(generationMessage)
                    .scaledFont(11, weight: .semibold)
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
                        ForEach(cachedReadyRecipes) { recipe in
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

// MARK: - Consistent recipe icon for list rows
// This list deliberately avoids mixing food photography with ingredient emoji fallbacks.
// Every recipe receives the same neutral symbol so the visual hierarchy stays cohesive.
private struct ReadyToCookThumb: View {
    let isReady: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                .fill(Color.stockedGold.opacity(0.12))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "fork.knife")
                        .scaledFont(21, weight: .semibold)
                        .foregroundStyle(Color.stockedGold)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                        .stroke(Color.stockedGold.opacity(0.18), lineWidth: 1)
                }
            if isReady {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(16)
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
    let recipe: ReadyRecipe
    @State private var addedToList: Int? = nil   // #3 feedback

    private var isReady: Bool { recipe.missing.count <= 5 }
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
                    .scaledFont(12)
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
        ReadyToCookThumb(isReady: isReady)
    }

    private var infoView: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Title + source
            HStack(spacing: 6) {
                Text(recipe.title)
                    .scaledFont(15, weight: .semibold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text(recipe.source)
                    .scaledFont(9, weight: .bold)
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
                    .scaledFont(10)
                    .foregroundStyle(session.themeTextColor.opacity(0.38))
                    .fixedSize(horizontal: false, vertical: true)
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
                        .scaledFont(10, weight: .bold)
                        .foregroundStyle(Color.stockedGold)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            if !recipe.substitutions.isEmpty {
                Text((recipe.substitutionsNeedReview ? "Review swap: " : "Using swap: ")
                     + recipe.substitutions.prefix(2).joined(separator: ", "))
                    .scaledFont(10, weight: .semibold)
                    .foregroundStyle(Color.stockedGold)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusPill: some View {
        Group {
            if recipe.substitutionsNeedReview {
                Text("Review Swap")
                    .scaledFont(9, weight: .bold)
                    .foregroundStyle(Color.stockedGold)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.stockedGold.opacity(0.14))
                    .clipShape(Capsule())
            } else if isReady {
                Text(recipe.missing.isEmpty ? "Ready Now" : "Ready Now · Needs \(recipe.missing.count)")
                    .scaledFont(9, weight: .bold)
                    .foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.stockedGold)
                    .clipShape(Capsule())
            } else {
                Text("Missing \(recipe.missing.count)")
                    .scaledFont(9, weight: .semibold)
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
