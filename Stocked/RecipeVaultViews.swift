// RecipeVaultViews.swift
import SwiftUI
import Combine
import PhotosUI

// MARK: - Hero image (user photo OR internet image auto-fetched)
struct RecipeHeroImage: View {
    let imageData:  Data?
    let imageURL:   String?
    let recipeName: String
    var category:   String? = nil
    var height:     CGFloat = 220

    var body: some View {
        // CachedAsyncImage now handles local JPEG decoding, URL loading, and name-based
        // fallback resolution off the render path. Keeping one path avoids repeated
        // UIImage(data:) work throughout recipe grids and details.
        CachedAsyncImage(
            url: imageURL,
            imageData: imageData,
            height: height,
            resolveName: recipeName,
            resolveCategory: category
        )
    }
}

// MARK: - RecipeVaultView
enum RecipeVaultSheet: Identifiable {
    case options, createRoute, browse
    var id: Int { switch self { case .options: return 0; case .createRoute: return 1; case .browse: return 2 } }
}

struct RecipeVaultView: View {
    @Environment(AppSession.self) var session
    @State private var selectedTab       = 0
    @State private var showBrowseOnline  = false
    @State private var showCreate        = false
    @State private var createRoute: RecipeCreateRoute? = nil
    @State private var recipeSearch      = ""
    @State private var showRecipeSearch  = false   // header search → recipe-only search
    @State private var dbResults: [RecipeDatabaseEntry] = []
    @State private var selectedDBEntry: RecipeDatabaseEntry? = nil
    @State private var navigateToDBRecipe = false
    // #248 — Discover (online recipes below the hub)
    @State private var onlineLoader = OnlineRecipesLoader.shared

    // #3 — prepared hub stats. Body re-runs on ANY @Observable store change (incl.
    // unrelated inventory updates); computing these counts inline meant filtering
    // userRecipes 3–4× per render. Instead compute once, in a single pass, only when
    // recipes / recently-viewed actually change.
    @State private var hubStats = RecipeHubStats()
    private struct RecipeHubStats {
        var favorites = 0, cooked = 0, saved = 0, cuisines = 0
        var recents: [UserRecipe] = []
    }
    private func recomputeHubStats() {
        let recipes = session.guestStore.userRecipes
        var fav = 0, cooked = 0
        var cuisineSet = Set<String>()
        for r in recipes {
            if r.isFavorited { fav += 1 }
            if r.cookCount > 0 { cooked += 1 }
            if !r.cuisine.isEmpty { cuisineSet.insert(r.cuisine) }
        }
        let recents = session.recentlyViewedRecipeIDs.compactMap { id in
            recipes.first(where: { $0.id == id })
        }
        hubStats = RecipeHubStats(favorites: fav, cooked: cooked, saved: recipes.count,
                                  cuisines: cuisineSet.count, recents: recents)
    }
    /// Cheap change signal for the hub stats: hashes only the fields the counts depend
    /// on (NOT imageData — a full [UserRecipe] Equatable compare would diff image blobs
    /// every render). onChange compares two Ints; recompute runs only when this shifts.
    private var hubStatsSignature: Int {
        var hasher = Hasher()
        for r in session.guestStore.userRecipes {
            hasher.combine(r.id); hasher.combine(r.isFavorited)
            hasher.combine(r.cookCount); hasher.combine(r.cuisine)
        }
        hasher.combine(session.recentlyViewedRecipeIDs)
        return hasher.finalize()
    }

    // SwiftUI gives undefined behavior when many .navigationDestination(isPresented:)
    // modifiers are stacked on one view — they collide, and toggling one bool can
    // trigger a different destination. That's why tapping Categories opened a recipe.
    // All push destinations now route through ONE enum-driven item destination.
    enum RecipeNavTarget: Identifiable, Hashable {
        case recent(UserRecipe)
        case saved
        case favorites
        case cooked
        case collections
        case savedCuisine(String)        // user's saved recipes filtered by cuisine
        case dbRecipe(RecipeDatabaseEntry)
        case browseAll
        case cuisineBrowse               // online recipes by cuisine (the Categories card)
        case online(OnlineRecipe)        // a tapped online/Discover recipe
        case sources                     // browse every recipe source
        case sourceRecipes(String)       // recipes from one source
        case drinks                      // the Drinks section
        var id: String {
            switch self {
            case .recent(let r):       return "recent-\(r.id)"
            case .saved:               return "saved"
            case .favorites:           return "favorites"
            case .cooked:              return "cooked"
            case .collections:         return "collections"
            case .savedCuisine(let c): return "savedCuisine-\(c)"
            case .dbRecipe(let e):     return "dbRecipe-\(e.id)"
            case .browseAll:           return "browseAll"
            case .cuisineBrowse:       return "cuisineBrowse"
            case .online(let r):       return "online-\(r.id)"
            case .sources:             return "sources"
            case .sourceRecipes(let s): return "sourceRecipes-\(s)"
            case .drinks:              return "drinks"
            }
        }
        // Implemented via `id` so associated values (UserRecipe / RecipeDatabaseEntry)
        // don't need to be Hashable themselves — their stable ids already uniquely
        // identify each destination.
        static func == (lhs: RecipeNavTarget, rhs: RecipeNavTarget) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }
    @State private var navTarget: RecipeNavTarget? = nil

    // Launch readiness 1.3 — the "For You ✦" fourth tab was removed for v1. A tappable
    // "Coming Soon" placeholder is a common App Review rejection (Guideline 2.3.2), and the
    // whole surface (ForYouView.swift) was already unreferenced after the hub redesign.
    // Reintroduce it only when the feature is real.
    let tabNames = ["Ready to Cook Now", "My Collection", "Browse"]

    private var greeting: String { StockedFormatters.timeOfDayGreeting }
    private var subtitle: String {
        switch selectedTab {
        case 0: return "Based on what's in your kitchen"
        case 1: return "Your recipes and meal history"
        default: return "Based on what's in your kitchen"
        }
    }

    // #238 — mockup hub card.
    private func hubCard(icon: String, tint: Color, count: Int, unit: String, label: String, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.15)).frame(width: 34, height: 34)
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13.5, weight: .bold)).foregroundStyle(session.themeTextColor)
                Text("\(count) \(unit)").font(.system(size: 11))
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
    }

    /// Same look as hubCard, but with a descriptive subtitle instead of a count and a
    /// trailing chevron — used for action cards like "Categories" that browse rather
    /// than show a saved count.
    private func hubActionCard(icon: String, tint: Color, label: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.15)).frame(width: 34, height: 34)
                    Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 13.5, weight: .bold)).foregroundStyle(session.themeTextColor)
                    Text(subtitle).font(.system(size: 11))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.35))
            }
            .padding(10)
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.40))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
    }

    // Recipe-only search (header magnifying glass). Unlike the global search, this
    // searches just the recipe database and shows only recipe results.
    private var recipeSearchSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RecipeSearchBar(recipeSearch: $recipeSearch, dbResults: $dbResults,
                                selectedDBEntry: $selectedDBEntry,
                                navigateToDBRecipe: $navigateToDBRecipe)
                    .padding(.top, 8)
                ScrollView {
                    if recipeSearch.trimmingCharacters(in: .whitespaces).count < 2 {
                        Text("Search your recipes by name or cuisine.")
                            .font(.system(size: 13))
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else if dbResults.isEmpty {
                        Text("No recipes found.")
                            .font(.system(size: 13))
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        RecipeSearchDropdown(dbResults: $dbResults,
                                             recipeSearch: $recipeSearch,
                                             selectedDBEntry: $selectedDBEntry,
                                             navigateToDBRecipe: $navigateToDBRecipe)
                            .padding(.horizontal, 20)
                    }
                }
                Spacer()
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Search Recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showRecipeSearch = false; recipeSearch = ""; dbResults = [] }
                        .foregroundStyle(Color.stockedGold)
                }
            }
        }
        .environment(session)
    }

    var body: some View {
        StockedShell(showBack: false, scrollDisabled: false,
                     titleText: "Recipes",
                     leadingTitle: true,
                     trailingIcon: "magnifyingglass", trailingLabel: "Search",
                     onTrailing: { showRecipeSearch = true }) {
            VStack(alignment: .leading, spacing: 0) {

                // ── #245 — mockup title ──
                Text("My Recipes")
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(session.isDarkMode ? session.accentColor : Color.stockedCharcoal)
                    .padding(.horizontal, 24).padding(.bottom, 14)

                // ── #238 — My Recipes hub (mockup 2×2) ──────────────────
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    hubCard(icon: "heart.fill", tint: Color.stockedGold,
                            count: hubStats.favorites,
                            unit: "recipes", label: "Favorites") { navTarget = .favorites }
                    hubCard(icon: "checkmark.circle.fill", tint: Color.stockedGreen,
                            count: hubStats.cooked,
                            unit: "recipes", label: "Cooked") { navTarget = .cooked }
                    hubCard(icon: "bookmark.fill", tint: Color.stockedInfo,
                            count: hubStats.saved,
                            unit: "recipes", label: "Saved") { navTarget = .saved }
                    hubCard(icon: "folder.fill", tint: Color.stockedGold,
                            count: hubStats.cuisines,
                            unit: "cuisines", label: "Collections") { navTarget = .collections }
                    hubActionCard(icon: "square.grid.2x2.fill", tint: Color.stockedGold,
                                  label: "Categories",
                                  subtitle: "Browse by cuisine") { navTarget = .cuisineBrowse }
                        .coachmarkAnchor("recipes.categories")
                    hubActionCard(icon: "sparkles", tint: Color.stockedGold,
                                  label: "Create with AI",
                                  subtitle: "Describe a recipe") { createRoute = .ai }
                        .coachmarkAnchor("recipes.createAI")
                    hubActionCard(icon: "globe", tint: Color.stockedInfo,
                                  label: "Sources",
                                  subtitle: "Browse by source") { navTarget = .sources }
                        .coachmarkAnchor("recipes.sources")
                    hubActionCard(icon: "wineglass", tint: Color.stockedGold,
                                  label: "Drinks",
                                  subtitle: "Cocktails, coffee & more") { navTarget = .drinks }
                        .coachmarkAnchor("recipes.drinks")
                }
                .padding(.horizontal, 20).padding(.bottom, 10)
                .coachmarkAnchor("recipes.hub")

                // ── #240 — Recently Viewed (mockup rail) ────────────────
                let recents = hubStats.recents
                if !recents.isEmpty {
                    HStack {
                        Text("Recently Viewed")
                            .font(.system(size: 15, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Spacer()
                        Button { navTarget = .saved } label: {
                            Text("View All").font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.stockedGold)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 8)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(recents.prefix(6)) { recipe in
                                Button { navTarget = .recent(recipe) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        CachedAsyncImage(url: recipe.imageURL, imageData: recipe.imageData,
                                                         height: 80, resolveName: recipe.title)
                                            .frame(width: 128, height: 80)
                                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                                        Text(recipe.title)
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundStyle(session.themeTextColor)
                                            .lineLimit(1)
                                        if !recipe.cookTime.isEmpty {
                                            Text(recipe.cookTime).font(.system(size: 10.5))
                                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                                        }
                                    }
                                    .frame(width: 128, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .stockedScrollTargetLayout()
                        .padding(.horizontal, 24)
                    }
                    .stockedHorizontalSnap()
                    .padding(.bottom, 14)
                }

                // ── #244 — Top Categories (mockup) ──────────────────────
                let cuisineCounts: [(String, Int)] = RecipeFacets.availableCuisines(in: session.guestStore.userRecipes)
                    .map { ($0, RecipeFacets.count(cuisine: $0, in: session.guestStore.userRecipes)) }
                    .sorted { $0.1 > $1.1 }
                    .prefix(4)
                    .map { ($0.0, $0.1) }
                if !cuisineCounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Categories")
                            .font(.system(size: 15, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        VStack(spacing: 8) {
                            ForEach(cuisineCounts, id: \.0) { name, count in
                                Button { navTarget = .savedCuisine(name) } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            Circle().fill(Color.stockedGold.opacity(0.14))
                                                .frame(width: 34, height: 34)
                                            Text(ImageFallbackService.emoji(for: name))
                                                .font(.system(size: 16))
                                        }
                                        Text(name)
                                            .font(.system(size: 14.5, weight: .semibold))
                                            .foregroundStyle(session.themeTextColor)
                                        Spacer()
                                        Text("\(count) recipe\(count == 1 ? "" : "s")")
                                            .font(.system(size: 12))
                                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(session.themeTextColor.opacity(0.3))
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.40))
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 14)
                }

                // ── #248 — Discover: recipes from online sources ─────────
                discoverSections

                Spacer(minLength: 24)
            }
        }
        // Both bools still exist (child views bind to them), but they feed ONE
        // .sheet(item:) — two stacked .sheet modifiers fire unreliably in SwiftUI.
        .sheet(item: Binding<RecipeVaultSheet?>(
            get: {
                if createRoute != nil { return .createRoute }
                if showCreate { return .options }
                if showBrowseOnline { return .browse }
                return nil
            },
            set: { newValue in
                if newValue == nil { showCreate = false; showBrowseOnline = false; createRoute = nil }
            }
        ), onDismiss: { }) { sheet in
            switch sheet {
            case .options:
                RecipeCreateOptionsSheet { route in
                    showCreate = false
                    // small delay so the options sheet fully dismisses before the next presents
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { createRoute = route }
                }.environment(session)
            case .createRoute:
                routeDestination(createRoute ?? .scratch)
            case .browse:
                RecipeBrowseOnlineSheet(showBrowseOnline: $showBrowseOnline)
            }
        }
        .navigationDestination(item: $navTarget) { target in
            switch target {
            case .recent(let recipe):
                UserRecipeDetailView(recipe: recipe)   // #240
            case .saved:
                RecipeListView(title: "Saved",
                               recipes: session.guestStore.userRecipes,
                               onCreate: { showCreate = true }).environment(session)
            case .favorites:
                RecipeListView(title: "Favorites",
                               recipes: session.guestStore.userRecipes.filter(\.isFavorited)).environment(session)
            case .cooked:
                RecipeListView(title: "Cooked",
                               recipes: session.guestStore.userRecipes.filter { $0.cookCount > 0 }).environment(session)
            case .collections:
                CollectionsListView().environment(session)
            case .savedCuisine(let cuisine):
                RecipeListView(title: cuisine,
                               recipes: session.guestStore.userRecipes.filter { $0.cuisine == cuisine })
                    .environment(session)
            case .dbRecipe(let entry):
                RecipeOverviewView(
                    title: entry.title,
                    servings: Int(entry.servings) ?? 2,
                    ingredients: entry.ingredients,
                    steps: entry.steps,
                    cookTime: entry.cookTime,
                    prepTime: entry.prepTime
                ).environment(session)
            case .browseAll:
                DiscoverBrowseAllView().environment(session)                  // #248
            case .cuisineBrowse:
                CuisineBrowseView().environment(session)
            case .online(let recipe):
                OnlineRecipeDetailView(recipe: recipe).environment(session)   // #248
            case .sources:
                SourcesBrowserView(pool: discoverSnapshot.pool,
                                   onOpenRecipe: { navTarget = .online($0) },
                                   onOpenSource: { navTarget = .sourceRecipes($0) })
                    .environment(session)
            case .sourceRecipes(let name):
                SourceRecipesView(sourceName: name, pool: onlineLoader.recipes,
                                  onOpenRecipe: { navTarget = .online($0) })
                    .environment(session)
            case .drinks:
                DrinksBrowseView(pool: onlineLoader.recipes,
                                 onOpenRecipe: { navTarget = .online($0) })
                    .environment(session)
            }
        }
        .onAppear {
            // Clamped: a user who saved tab 3 (the removed For You tab) as their preferred
            // start must not land on an index that no longer exists.
            selectedTab = min(session.preferredRecipeTab, tabNames.count - 1)
            onlineLoader.loadIfNeeded(profile: session.guestStore.cookingProfile, pantry: Array(session.guestStore.inStockNameSet).prefix(8).map { $0 })  // #248
            scheduleDiscoverSnapshotRebuild()
            consumePendingImportIfNeeded()
            recomputeHubStats()
        }
        .onChange(of: onlineLoader.revision) { _, _ in
            scheduleDiscoverSnapshotRebuild()
        }
        // #3 — recompute prepared hub stats only when their real inputs change (cheap
        // Int signature avoids comparing recipe image blobs every render).
        .onChange(of: hubStatsSignature) { _, _ in recomputeHubStats() }
        .onDisappear {
            discoverSnapshotTask?.cancel()
            discoverSnapshotTask = nil
        }
        .onChange(of: session.pendingRecipeImport) { _, pending in
            if pending { consumePendingImportIfNeeded() }
        }
        .onChange(of: navigateToDBRecipe) { _, go in
            // RecipeSearchDropdown still sets selectedDBEntry + this bool; bridge it
            // into the single enum-driven destination so it doesn't need its own
            // (colliding) navigationDestination.
            if go, let entry = selectedDBEntry {
                navigateToDBRecipe = false
                showRecipeSearch = false           // close the search sheet first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    navTarget = .dbRecipe(entry)
                }
            }
        }
        .sheet(isPresented: $showRecipeSearch) {
            recipeSearchSheet
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            navTarget = nil; navigateToDBRecipe = false   // iPad-safe pop-to-root
        }
        .coachmarks(page: .recipes, steps: RecipeCoachmarks.steps)
    }

    /// Drawer "Import Recipe" → open the URL import sheet exactly once. Clearing the
    /// flag FIRST means re-renders / repeat onAppear can't re-trigger it (which is
    /// what made the NotificationCenter version loop). The short delay lets any sheet
    /// that's currently dismissing (e.g. the create chooser) finish first.
    private func consumePendingImportIfNeeded() {
        guard session.pendingRecipeImport else { return }
        session.pendingRecipeImport = false
        guard createRoute == nil else { return }   // don't stack on an open sheet
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if createRoute == nil { createRoute = .url }
        }
    }

    // MARK: - #248 Discover (online sources)
    // Fills the area below the hub with live recipes: a featured hero card and
    // three rails, all from OnlineRecipesLoader (TheMealDB + the synced local
    // database) — cached instantly, refreshed in the background.

    // The old implementation rebuilt multiple full recipe scans from computed properties
    // during every SwiftUI body evaluation. This immutable snapshot is assembled off-main once
    // per loader revision and reused by every rail, badge, quick pick, and source destination.
    private nonisolated struct DiscoverSnapshot: Sendable {
        var pool: [OnlineRecipe] = []
        var hero: OnlineRecipe?
        var popular: [OnlineRecipe] = []
        var dinners: [OnlineRecipe] = []
        var sweets:  [OnlineRecipe] = []
        var drinks:  [OnlineRecipe] = []
        var statusByID: [String: OnlineRecipeMatch.Status] = [:]
        var isEmpty: Bool {
            hero == nil && popular.isEmpty && dinners.isEmpty && sweets.isEmpty
        }
    }

    @State private var discoverSnapshot = DiscoverSnapshot()
    @State private var discoverSnapshotTask: Task<Void, Never>?

    private var discoverSavedTitles: Set<String> {
        session.guestStore.savedRecipeTitles
    }

    private func scheduleDiscoverSnapshotRebuild() {
        discoverSnapshotTask?.cancel()

        let recipes = onlineLoader.recipes
        guard !recipes.isEmpty else {
            discoverSnapshot = DiscoverSnapshot()
            discoverSnapshotTask = nil
            return
        }
        let inStock = session.guestStore.inStockNameSet
        let interestWeights = RecipeInterest.shared.weights

        discoverSnapshotTask = Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.makeDiscoverSnapshot(
                    recipes: recipes,
                    inStock: inStock,
                    interestWeights: interestWeights
                )
            }.value
            guard !Task.isCancelled else { return }
            discoverSnapshot = snapshot
            discoverSnapshotTask = nil
        }
    }

    private nonisolated static func makeDiscoverSnapshot(
        recipes: [OnlineRecipe],
        inStock: Set<String>,
        interestWeights: [String: Double]
    ) -> DiscoverSnapshot {
        let drinkWords = ["cocktail", "drink", "beverage", "shake", "smoothie",
                          "coffee", "tea", "punch", "shot", "mocktail", "juice"]
        func isDrink(_ recipe: OnlineRecipe) -> Bool {
            let source = recipe.source.lowercased()
            if source.contains("cocktaildb") { return true }
            let category = recipe.category.lowercased()
            return drinkWords.contains { category.contains($0) }
        }

        var seenFood = Set<String>()
        var food: [OnlineRecipe] = []
        var seenDrinks = Set<String>()
        var drinks: [OnlineRecipe] = []

        for recipe in recipes
            where !recipe.imageURL.isEmpty
               && OnlineRecipeFacts.hasRealInstructions(recipe.instructions) {
            let key = OnlineRecipeFacts.normalizedTitle(recipe.title)
            guard !key.isEmpty else { continue }
            if isDrink(recipe) {
                if seenDrinks.insert(key).inserted, drinks.count < 8 {
                    drinks.append(recipe)
                }
            } else if seenFood.insert(key).inserted {
                food.append(recipe)
            }
        }

        var remaining = food
        let hero = remaining.first
        if hero != nil { remaining.removeFirst() }

        let sweetCategories: Set<String> = ["dessert", "breakfast"]
        let dinnerCategories: Set<String> = [
            "beef", "chicken", "pasta", "pork", "lamb",
            "seafood", "vegetarian", "vegan", "side"
        ]
        var statuses: [String: OnlineRecipeMatch.Status] = [:]

        func status(_ recipe: OnlineRecipe) -> OnlineRecipeMatch.Status {
            if let cached = statuses[recipe.id] { return cached }
            let computed = OnlineRecipeMatch.status(recipe, inStock: inStock)
            statuses[recipe.id] = computed
            return computed
        }

        func missingCount(_ recipe: OnlineRecipe) -> Int {
            if case .missing(let count) = status(recipe) { return count }
            return 0
        }

        var used = Set<String>()
        func take(_ count: Int, matching: (OnlineRecipe) -> Bool) -> [OnlineRecipe] {
            var result: [OnlineRecipe] = []
            for recipe in remaining
                where result.count < count && !used.contains(recipe.id) && matching(recipe) {
                result.append(recipe)
                used.insert(recipe.id)
            }
            return result.sorted { missingCount($0) < missingCount($1) }
        }

        let sweets = take(8) { sweetCategories.contains($0.category.lowercased()) }
        let dinners = take(8) { dinnerCategories.contains($0.category.lowercased()) }
        var popular = take(12) { _ in true }
        func interestScore(_ recipe: OnlineRecipe) -> Double {
            let category = recipe.category.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let area = recipe.area.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (interestWeights[category] ?? 0) + (interestWeights[area] ?? 0)
        }
        popular.sort {
            let lhs = interestScore($0)
            let rhs = interestScore($1)
            if lhs != rhs { return lhs > rhs }
            return missingCount($0) < missingCount($1)
        }
        popular = Array(popular.prefix(8))

        if let hero { _ = status(hero) }
        for recipe in drinks { _ = status(recipe) }

        return DiscoverSnapshot(
            pool: food,
            hero: hero,
            popular: popular,
            dinners: dinners,
            sweets: sweets,
            drinks: drinks,
            statusByID: statuses
        )
    }

    /// One-tap open that also teaches the interest profile (#6).
    private func openOnlineRecipe(_ recipe: OnlineRecipe) {
        RecipeInterest.shared.record(category: recipe.category, area: recipe.area)
        navTarget = .online(recipe)
    }

    @ViewBuilder
    private var discoverSections: some View {
        let split = discoverSnapshot

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Discover")
                    .font(.system(size: 19, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                // #FB — manual refresh; Discover otherwise only changes on re-entry.
                if onlineLoader.isLoading {
                    ProgressView().scaleEffect(0.7).tint(Color.stockedGold)
                } else {
                    Button {
                        onlineLoader.forceRefresh(profile: session.guestStore.cookingProfile,
                                                  pantry: Array(session.guestStore.inStockNameSet).prefix(8).map { $0 })
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold))
                            Text("Refresh").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Color.stockedGold)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.stockedGold.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh recipe ideas")
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 8)

            // #FB — quick-pick categories: Under 15 mins, One Pot, Feeling Lazy.
            quickPickChips

            if split.isEmpty {
                if onlineLoader.isLoading {
                    discoverSkeleton
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Couldn't reach online recipes right now. You're still able to browse anything saved to your kitchen.")
                            .font(.system(size: 13))
                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                        Button {
                            onlineLoader.forceRefresh(profile: session.guestStore.cookingProfile, pantry: Array(session.guestStore.inStockNameSet).prefix(8).map { $0 })
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold))
                                Text("Retry").font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(Color.stockedWhite)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Color.stockedCharcoal)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24).padding(.vertical, 10)
                }
            } else {
                if let hero = split.hero { discoverHero(hero).padding(.bottom, 16) }
                if !split.popular.isEmpty { discoverRail("Popular right now", split.popular) }
                if !split.dinners.isEmpty { discoverRail("Dinner ideas", split.dinners) }
                if !split.sweets.isEmpty  { discoverRail("Something sweet", split.sweets) }
                // #FB — drinks get a small, contained highlight of their own (never
                // mixed into the food rails; View All opens the full Drinks browser).
                if !split.drinks.isEmpty {
                    HStack {
                        HStack(spacing: 6) {
                            Text("🍹").font(.system(size: 14))
                            Text("Drinks")
                                .font(.system(size: 17, weight: .bold, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                        }
                        Spacer()
                        Button { navTarget = .drinks } label: {
                            Text("View All").font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.stockedGold)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 8)
                    discoverRail(nil, split.drinks)
                }
            }
        }
        .padding(.bottom, 6)
    }

    // #FB — quick-pick browse chips over the discover pool.
    private var quickPickChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                quickPickChip("Under 15 mins", icon: "bolt.fill")
                quickPickChip("One Pot", icon: "frying.pan.fill")
                quickPickChip("Feeling Lazy", icon: "moon.zzz.fill")
                quickPickChip("Comfort Food", icon: "heart.fill")
            }
            .stockedScrollTargetLayout()
            .padding(.horizontal, 24)
        }
        .stockedHorizontalSnap()
        .padding(.bottom, 12)
    }

    private func quickPickChip(_ title: String, icon: String) -> some View {
        NavigationLink {
            QuickPickListView(pick: title, pool: discoverSnapshot.pool,
                              onOpenRecipe: { openOnlineRecipe($0) })
                .environment(session)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(session.themeTextColor)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // Featured hero — big photo card with a gradient title plate.
    private func discoverHero(_ recipe: OnlineRecipe) -> some View {
        let saved = OnlineRecipeFacts.isSaved(recipe, savedTitles: discoverSavedTitles)
        return Button { openOnlineRecipe(recipe) } label: {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: recipe.imageURL, imageData: nil,
                                 height: 190, resolveName: recipe.title)
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.72)],
                               startPoint: .center, endPoint: .bottom)

                // Top-row badges: "can I make this?" + already-saved.
                VStack {
                    HStack(spacing: 6) {
                        onlineStatusBadge(recipe, light: true)
                        if saved { savedBadge(light: true) }
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)

                VStack(alignment: .leading, spacing: 3) {
                    Text("FROM THE WEB")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color.stockedGold)
                    Text(recipe.title)
                        .font(.system(size: 19, weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text([recipe.area, recipe.category, recipe.source].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                .padding(14)
            }
            .frame(height: 190)                                   // fixed height — no implicit growth
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
            .contentShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))  // hit area = visible card only
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
    }

    private func discoverRail(_ title: String?, _ recipes: [OnlineRecipe]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // #FB — bigger section headers so they hold their own against the cards.
            if let title {
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, 24)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(recipes) { recipe in
                        let saved = OnlineRecipeFacts.isSaved(recipe, savedTitles: discoverSavedTitles)
                        Button { openOnlineRecipe(recipe) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                ZStack(alignment: .topLeading) {
                                    CachedAsyncImage(url: recipe.imageURL, imageData: nil,
                                                     height: 84, resolveName: recipe.title)
                                        .frame(width: 134, height: 84)
                                        .clipped()
                                    HStack(spacing: 4) {
                                        onlineStatusBadge(recipe, light: true)
                                        if saved { savedBadge(light: true) }
                                    }
                                    .padding(6)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(recipe.title)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(session.themeTextColor)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(height: 30, alignment: .top)
                                    Text([recipe.area.isEmpty ? recipe.category : recipe.area, recipe.source]
                                            .filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                                        .lineLimit(1)
                                }
                                .padding(8)
                                .frame(width: 134, alignment: .leading)
                            }
                            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .stockedScrollTargetLayout()
                .padding(.horizontal, 24)
            }
            .stockedHorizontalSnap()
        }
        .padding(.bottom, 14)
    }

    // MARK: - #251 Discover badges (shared by hero + rails)

    // "Can I make this?" — Ready / N missing, computed live against the pantry. Shows
    // nothing when the kitchen is empty (no honest signal to give).
    @ViewBuilder
    private func onlineStatusBadge(_ recipe: OnlineRecipe, light: Bool) -> some View {
        switch discoverSnapshot.statusByID[recipe.id] ?? .unknown {
        case .ready:
            badgePill(text: "Ready", system: "checkmark.circle.fill",
                      fg: .white, bg: Color.stockedGreen)
        case .missing(let n):
            badgePill(text: n == 1 ? "1 missing" : "\(n) missing", system: nil,
                      fg: .white, bg: Color.stockedError.opacity(0.92))
        case .unknown:
            EmptyView()
        }
    }

    private func savedBadge(light: Bool) -> some View {
        badgePill(text: "Saved", system: "bookmark.fill", fg: .white, bg: Color.stockedGold.opacity(0.95))
    }

    private func badgePill(text: String, system: String?, fg: Color, bg: Color) -> some View {
        HStack(spacing: 3) {
            if let system { Image(systemName: system).font(.system(size: 8, weight: .bold)) }
            Text(text).font(.system(size: 9.5, weight: .bold))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(bg)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }

    // Quiet pulse placeholders while the first online batch arrives.
    private var discoverSkeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                .fill(Color.stockedWhite.opacity(0.35))
                .frame(height: 190)
                .padding(.horizontal, 24)
            ForEach(0..<2, id: \.self) { _ in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                                .fill(Color.stockedWhite.opacity(0.35))
                                .frame(width: 134, height: 128)
                        }
                    }
                    .stockedScrollTargetLayout()
                    .padding(.horizontal, 24)
                }
                .stockedHorizontalSnap()
                .disabled(true)
            }
        }
        .opacity(0.8)
    }

    // Maps a chosen create route to its destination view. Import routes hand back a parsed
    // AddRecipeForm via onParsed → we re-enter as .form(...) so everything lands in the
    // familiar CreateRecipeView for review before saving.
    @ViewBuilder
    private func routeDestination(_ route: RecipeCreateRoute) -> some View {
        switch route {
        case .scratch:
            CreateRecipeView().environment(session)
        case .ai:
            AIRecipeGeneratorView().environment(session)
        case .url:
            RecipeURLImportSheet { form, source in
                createRoute = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { createRoute = .form(form, source) }
            }.environment(session)
        case .screenshot:
            RecipeScreenshotImportSheet { form, source in
                createRoute = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { createRoute = .form(form, source) }
            }.environment(session)
        case .manual:
            RecipeManualTextSheet { form, source in
                createRoute = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { createRoute = .form(form, source) }
            }.environment(session)
        case .form(let form, let source):
            CreateRecipeView(prefill: form, prefillSource: source).environment(session)
        }
    }
}

// MARK: - Recipe Search Bar
private struct RecipeSearchBar: View {
    @Environment(AppSession.self) var session
    @Binding var recipeSearch: String
    @Binding var dbResults: [RecipeDatabaseEntry]
    @Binding var selectedDBEntry: RecipeDatabaseEntry?
    @Binding var navigateToDBRecipe: Bool
    // #8 perf: debounce search so we don't load + filter the snapshot on every keystroke.
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(session.themeTextColor.opacity(0.4))
            TextField("Search recipes by name or cuisine…", text: $recipeSearch)
                .foregroundStyle(session.isDarkMode ? Color.stockedWhite : .black)
                .tint(Color.stockedGold)
                .font(.system(size: 14))
                .autocorrectionDisabled()
            if !recipeSearch.isEmpty {
                Button { recipeSearch = ""; dbResults = [] } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .padding(.horizontal, 20).padding(.bottom, 14)
        .onChange(of: recipeSearch) { (_: String, q: String) in
            searchTask?.cancel()
            searchTask = Task { @MainActor in
                let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2 else { dbResults = []; return }
                // Wait briefly; if another keystroke arrives, this task is cancelled.
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard !Task.isCancelled else { return }
                let snap = await RecipeDatabaseManager.shared.loadSnapshot()
                guard !Task.isCancelled else { return }

                // Fuzzy matching and sorting the full writable snapshot used to resume on
                // MainActor and block typing/navigation. Keep only the small UI result set.
                let results = await Task.detached(priority: .userInitiated) {
                    Array(
                        snap.lazy.filter {
                            FuzzyMatch.matches(trimmed, $0.title) ||
                            FuzzyMatch.matches(trimmed, $0.cuisine) ||
                            FuzzyMatch.matches(trimmed, $0.category) ||
                            $0.ingredients.contains {
                                $0.localizedCaseInsensitiveContains(trimmed)
                            }
                        }
                        .sorted {
                            FuzzyMatch.score(trimmed, $0.title) >
                            FuzzyMatch.score(trimmed, $1.title)
                        }
                        .prefix(40)
                    )
                }.value
                guard !Task.isCancelled else { return }
                dbResults = results
            }
        }
    }
}

// MARK: - Recipe Search Dropdown
private struct RecipeSearchDropdown: View {
    @Environment(AppSession.self) var session
    @Binding var dbResults: [RecipeDatabaseEntry]
    @Binding var recipeSearch: String
    @Binding var selectedDBEntry: RecipeDatabaseEntry?
    @Binding var navigateToDBRecipe: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(dbResults.prefix(8))) { entry in
                Button {
                    selectedDBEntry = entry
                    navigateToDBRecipe = true
                    recipeSearch = ""
                    dbResults = []
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "book.fill")
                            .font(.system(size: 13)).foregroundStyle(Color.stockedGold)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                                .font(.system(size: 13, weight: .semibold, design: .serif))
                                .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                                .lineLimit(1)
                            let sub = [entry.cuisine, entry.category]
                                .filter { !$0.isEmpty }.prefix(2).joined(separator: " · ")
                            if !sub.isEmpty {
                                Text(sub).font(.system(size: 11))
                                    .foregroundStyle(session.themeTextColor.opacity(0.45))
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                if entry.id != Array(dbResults.prefix(8)).last?.id {
                    Divider().padding(.leading, 50)
                }
            }
        }
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite)
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
    }
}

// MARK: - Browse Online Sheet
// MARK: - #248 Discover "See All" — the full searchable online browser, pushed.
struct DiscoverBrowseAllView: View {
    @Environment(AppSession.self) var session

    var body: some View {
        StockedShell(showBack: true, scrollDisabled: true) {
            OnlineRecipesView()
        }
    }
}

private struct RecipeBrowseOnlineSheet: View {
    @Environment(AppSession.self) var session
    @Binding var showBrowseOnline: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                OnlineRecipesView()
            }
            .navigationTitle("Browse Recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(session.themeBgColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(session.isDarkMode ? .dark : .light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showBrowseOnline = false }
                        .foregroundStyle(Color.stockedGold)
                }
            }
        }
        .environment(session)
    }
}

// MARK: - My Collection snapshot
private nonisolated struct RecipeCollectionEntry: Identifiable, Sendable {
    let recipe: UserRecipe
    let stockHave: Int
    let stockTotal: Int
    let allergenConflicts: [String]
    let profileBoost: Int

    var id: UUID { recipe.id }
}

private nonisolated struct RecipeDuplicatePair: Sendable {
    let first: UserRecipe
    let second: UserRecipe
}

private nonisolated struct RecipeDuplicateSummary: Sendable {
    let count: Int
    let firstPair: RecipeDuplicatePair?

    static let empty = RecipeDuplicateSummary(count: 0, firstPair: nil)
}

private nonisolated struct RecipeCollectionSnapshot: Sendable {
    let entries: [RecipeCollectionEntry]
    let duplicates: RecipeDuplicateSummary

    static let empty = RecipeCollectionSnapshot(entries: [], duplicates: .empty)
}

private nonisolated struct EntityRevisionToken: Hashable, Sendable {
    let id: UUID
    let updatedAt: Double
}

private nonisolated struct RecipeProfileRevision: Hashable, Sendable {
    let allergens: [String]
    let cuisinePrefs: [String]
}

private nonisolated struct RecipeCollectionSnapshotBuilder {
    static func build(
        recipes: [UserRecipe],
        inventory: [LocalInventoryItem],
        allergens: [String],
        cuisinePrefs: [String],
        cookableSort: Bool
    ) -> RecipeCollectionSnapshot {
        let inStockNames = inventory
            .filter { $0.effectiveLevel > 0 }
            .map(\.name)
        let normalizedAllergens = allergens.filter { !$0.isEmpty }
        let normalizedPrefs = cuisinePrefs.map { $0.lowercased() }

        var entries = recipes.map { recipe -> RecipeCollectionEntry in
            let needed = recipe.ingredients.filter { !$0.isOptional }
            let have = needed.filter { ingredient in
                inStockNames.contains { looseMatch(ingredient.name, $0) }
            }.count

            var conflicts: Set<String> = []
            for ingredient in recipe.ingredients {
                for allergen in normalizedAllergens where looseMatch(ingredient.name, allergen) {
                    conflicts.insert(allergen)
                }
            }

            var boost = 0
            if !recipe.cuisine.isEmpty,
               normalizedPrefs.contains(recipe.cuisine.lowercased()) {
                boost += 2
            }
            let title = recipe.title.lowercased()
            if normalizedPrefs.contains(where: { !$0.isEmpty && title.contains($0) }) {
                boost += 1
            }

            return RecipeCollectionEntry(
                recipe: recipe,
                stockHave: have,
                stockTotal: needed.count,
                allergenConflicts: conflicts.sorted(),
                profileBoost: boost
            )
        }

        if cookableSort {
            entries.sort { lhs, rhs in
                let lhsRatio = lhs.stockTotal == 0 ? 0 : Double(lhs.stockHave) / Double(lhs.stockTotal)
                let rhsRatio = rhs.stockTotal == 0 ? 0 : Double(rhs.stockHave) / Double(rhs.stockTotal)
                if lhsRatio != rhsRatio { return lhsRatio > rhsRatio }
                if lhs.profileBoost != rhs.profileBoost { return lhs.profileBoost > rhs.profileBoost }
                return lhs.recipe.title.localizedCaseInsensitiveCompare(rhs.recipe.title) == .orderedAscending
            }
        }

        return RecipeCollectionSnapshot(
            entries: entries,
            duplicates: duplicateSummary(entries.map(\.recipe))
        )
    }

    // WAS: the third byte-identical copy of the substring matcher. NOW: shared.
    private static func looseMatch(_ a: String, _ b: String) -> Bool {
        KitchenAvailability.nameMatches(a, b)
    }

    private static func duplicateSummary(_ recipes: [UserRecipe]) -> RecipeDuplicateSummary {
        guard recipes.count > 1 else { return .empty }

        let normalized = recipes.map { recipe -> (title: String, words: Set<String>) in
            let title = recipe.title
                .lowercased()
                .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            let words = Set(title.split(separator: " ").map(String.init))
            return (title, words)
        }

        var count = 0
        var firstPair: RecipeDuplicatePair? = nil
        for i in recipes.indices {
            guard !Task.isCancelled else { break }
            for j in (i + 1)..<recipes.count {
                let lhs = normalized[i]
                let rhs = normalized[j]
                let sharedWords = lhs.words.count <= rhs.words.count
                    ? lhs.words.reduce(into: 0) { total, word in
                        if rhs.words.contains(word) { total += 1 }
                    }
                    : rhs.words.reduce(into: 0) { total, word in
                        if lhs.words.contains(word) { total += 1 }
                    }
                let isDuplicate = lhs.title == rhs.title
                    || (!lhs.title.isEmpty && !rhs.title.isEmpty
                        && (lhs.title.contains(rhs.title) || rhs.title.contains(lhs.title)))
                    || sharedWords >= 3
                if isDuplicate {
                    count += 1
                    if firstPair == nil {
                        firstPair = RecipeDuplicatePair(first: recipes[i], second: recipes[j])
                    }
                }
            }
        }
        return RecipeDuplicateSummary(count: count, firstPair: firstPair)
    }
}

// MARK: - My Collection Tab
private struct RecipeMyCollectionView: View {
    @Environment(AppSession.self) var session
    @Binding var showCreate: Bool
    @Binding var showBrowse: Bool
    // Identity-driven merge payload — .sheet(item:) presents reliably on the first tap.
    private struct MergePayload: Identifiable { let id = UUID(); let a: UserRecipe; let b: UserRecipe }
    @State private var mergePayload: MergePayload? = nil
    @State private var showPastMeals  = false   // accordions start collapsed
    @State private var cookableSort   = false   // #2 — rank by what's in stock right now

    @State private var collectionSnapshot: RecipeCollectionSnapshot = .empty
    @State private var isBuildingSnapshot = true
    @State private var snapshotTask: Task<Void, Never>? = nil
    @State private var snapshotGeneration = 0

    // Lightweight change tokens avoid SwiftUI comparing full recipe and inventory values,
    // including embedded photo Data, every time this view redraws.
    private var recipeRevision: [EntityRevisionToken] {
        session.guestStore.userRecipes.map { EntityRevisionToken(id: $0.id, updatedAt: $0.updatedAt) }
    }

    private var inventoryRevision: [EntityRevisionToken] {
        session.guestStore.inventoryItems.map { EntityRevisionToken(id: $0.id, updatedAt: $0.updatedAt) }
    }

    private var profileRevision: RecipeProfileRevision {
        let profile = session.guestStore.cookingProfile
        return RecipeProfileRevision(allergens: profile.allergens, cuisinePrefs: profile.cuisinePrefs)
    }

    private func rebuildCollectionSnapshot() {
        snapshotTask?.cancel()
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        let store = session.guestStore
        let recipes = store.userRecipes
        let inventory = store.inventoryItems
        let allergens = store.cookingProfile.allergens
        let cuisinePrefs = store.cookingProfile.cuisinePrefs
        let shouldSort = cookableSort

        if collectionSnapshot.entries.isEmpty { isBuildingSnapshot = true }
        snapshotTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                RecipeCollectionSnapshotBuilder.build(
                    recipes: recipes,
                    inventory: inventory,
                    allergens: allergens,
                    cuisinePrefs: cuisinePrefs,
                    cookableSort: shouldSort
                )
            }.value
            guard !Task.isCancelled, generation == snapshotGeneration else { return }
            collectionSnapshot = result
            isBuildingSnapshot = false
        }
    }

    var body: some View {
        let entries = collectionSnapshot.entries
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recipes you've saved or created")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(session.themeTextColor)
                Spacer()
                // Duplicate merge badge
                let dups = collectionSnapshot.duplicates
                if dups.count > 0 {
                    Button {
                        if let pair = dups.firstPair {
                            mergePayload = MergePayload(a: pair.first, b: pair.second)
                        }
                    } label: {
                        Label("\(dups.count) duplicate\(dups.count == 1 ? "" : "s")", systemImage: "arrow.triangle.merge")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                    }.buttonStyle(.plain)
                }
                // #2 — sort by what you can cook right now
                Button { withAnimation(.spring(response: 0.3)) { cookableSort.toggle() } } label: {
                    Label("Cookable", systemImage: cookableSort ? "flame.fill" : "flame")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(cookableSort ? Color.stockedGreen : session.themeTextColor.opacity(0.5))
                }.buttonStyle(.plain)
                // Browse online
                Button { showBrowse = true } label: {
                    Label("Browse", systemImage: "safari")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.stockedGold)
                }.buttonStyle(.plain)
                // Create
                Button { showCreate = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18)).foregroundStyle(Color.stockedGold)
                }.buttonStyle(.plain).padding(.leading, 4)
            }.padding(.horizontal, 24).padding(.bottom, 12)

            if entries.isEmpty && isBuildingSnapshot {
                HStack(spacing: 10) {
                    ProgressView().tint(Color.stockedGold)
                    Text("Loading collection…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else if entries.isEmpty {
                StockedEmptyState(
                    icon: "📖", title: "Collection is empty",
                    subtitle: "Create a recipe or save one from Search.",
                    ctaLabel: "Create Recipe", onCTA: { showCreate = true }
                ).padding(.top, 16)
            } else {
                // #8 iPad: 3 columns to use the wider canvas; 2 on iPhone.
                let colCount = UIDevice.current.userInterfaceIdiom == .pad ? 3 : 2
                let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: colCount)
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(entries) { entry in
                        let recipe = entry.recipe
                        ZStack(alignment: .topTrailing) {
                            NavigationLink(destination: UserRecipeDetailView(recipe: recipe).environment(session)) {
                                UserRecipeCard(recipe: recipe)
                            }.buttonStyle(.plain)
                            .contextMenu {
                                NavigationLink(destination: UserRecipeDetailView(recipe: recipe).environment(session)) {
                                    Label("Open recipe", systemImage: "book")
                                }
                            } preview: {
                                RecipePreviewCard(recipe: recipe).environment(session)
                            }
                            // #2 in-stock badge + #1 allergen warning (bottom-leading, clear of the delete button)
                            .overlay(alignment: .bottomLeading) {
                                HStack(spacing: 4) {
                                    if entry.stockTotal > 0 {
                                        Text("\(entry.stockHave)/\(entry.stockTotal) in stock")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(entry.stockHave == entry.stockTotal ? Color.stockedGreen : session.themeTextColor.opacity(0.6))
                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(.ultraThinMaterial, in: Capsule())
                                    }
                                    if !entry.allergenConflicts.isEmpty {
                                        Label(entry.allergenConflicts.joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.orange)
                                            .lineLimit(1)
                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(.ultraThinMaterial, in: Capsule())
                                    }
                                }
                                .padding(6)
                            }
                            Button {
                                withAnimation(.spring(response: 0.3)) {
                                    session.guestStore.userRecipes.removeAll { $0.id == recipe.id }
                                }
                            } label: {
                                ZStack {
                                    Circle().fill(Color.red).frame(width: 24, height: 24)
                                    Image(systemName: "minus").font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                            }
                            .buttonStyle(.plain).padding(6)
                        }
                    }
                }.padding(.horizontal, 20)
            }

            // ── Past Meals collapsible section ────────────────────
            Divider().padding(.horizontal, 24).padding(.top, 20)

            Button {
                withAnimation(.spring(response: 0.3)) { showPastMeals.toggle() }
            } label: {
                HStack {
                    Text("Past Meals")
                        .font(.system(size: 14, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    let count = session.guestStore.pastMeals.count
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(session.accentColor)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(session.accentColor.opacity(0.12)).clipShape(Capsule())
                    }
                    Image(systemName: showPastMeals ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.4))
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if showPastMeals {
                if session.guestStore.pastMeals.isEmpty {
                    Text("No meals logged yet. Cook a recipe and rate it to start your history.")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28).padding(.bottom, 16)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 8) {
                        ForEach(session.guestStore.pastMeals) { meal in
                            PastMealRow(meal: meal)
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 16)
                    .transition(.opacity)
                }
            }
        }
        .task { rebuildCollectionSnapshot() }
        .onChange(of: recipeRevision)   { _, _ in rebuildCollectionSnapshot() }
        .onChange(of: inventoryRevision) { _, _ in rebuildCollectionSnapshot() }
        .onChange(of: profileRevision)  { _, _ in rebuildCollectionSnapshot() }
        .onChange(of: cookableSort)     { _, _ in rebuildCollectionSnapshot() }
        .onDisappear { snapshotTask?.cancel() }
        .sheet(item: $mergePayload) { payload in
            RecipeMergeSheet(recipeA: payload.a, recipeB: payload.b)
                .environment(session)
        }
    }
}

// MARK: - Recipe Merge Sheet
private struct RecipeMergeSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    let recipeA: UserRecipe
    let recipeB: UserRecipe

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                    .frame(width: 40, height: 4).padding(.top, 12).padding(.bottom, 16)
                Text("Possible Duplicate")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor).padding(.bottom, 8)
                Text("These two recipes look similar. Keep one, or keep both.")
                    .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    .multilineTextAlignment(.center).padding(.horizontal, 28).padding(.bottom, 24)

                VStack(spacing: 12) {
                    mergeOption(recipe: recipeA, keepLabel: "Keep this, delete other") {
                        session.guestStore.deleteUserRecipe(id: recipeB.id)
                        dismiss()
                    }
                    mergeOption(recipe: recipeB, keepLabel: "Keep this, delete other") {
                        session.guestStore.deleteUserRecipe(id: recipeA.id)
                        dismiss()
                    }
                    Button("Keep Both") { dismiss() }
                        .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.5))
                        .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                Spacer()
            }
        }
        .presentationDetents([.medium])
    }

    private func mergeOption(recipe: UserRecipe, keepLabel: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recipe.title)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            Text("\(recipe.ingredients.count) ingredients · Made \(recipe.cookCount)×")
                .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
            Button(action: action) {
                Text(keepLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
            }.buttonStyle(.plain)
        }
        .padding(14)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }
}

// MARK: - Browse Tab — opens online recipe browser directly
private struct RecipeBrowseTabView: View {
    @Environment(AppSession.self) var session
    @Binding var showBrowseOnline: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Hero prompt
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(session.accentColor.opacity(0.12))
                        .frame(width: 90, height: 90)
                    Image(systemName: "safari.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(session.accentColor)
                }
                Text("Browse Online Recipes")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Text("Import recipes from 20+ trusted cooking sites.\nPaste a URL or search by cuisine.")
                    .font(.system(size: 14))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button { showBrowseOnline = true } label: {
                Text("Open Recipe Browser")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(session.themeButtonColor)
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)

            Spacer()
        }
    }
}

// MARK: - Past Meals Tab — now embedded in My Collection
private struct RecipePastMealsView: View {
    @Environment(AppSession.self) var session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your meal history")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(session.themeTextColor)
                .padding(.horizontal, 24).padding(.bottom, 12)

            if session.guestStore.pastMeals.isEmpty {
                StockedEmptyState(
                    icon: "🍽️", title: "No meals logged yet",
                    subtitle: "Cook a recipe and rate it to start building your meal history.",
                    ctaLabel: "Cook Something", onCTA: {}
                ).padding(.top, 16)
            } else {
                VStack(spacing: 8) {
                    ForEach(session.guestStore.pastMeals) { meal in
                        PastMealRow(meal: meal)
                    }
                }.padding(.horizontal, 20)
            }
        }
    }
}

private struct PastMealRow: View {
    @Environment(AppSession.self) var session
    let meal: LocalPastMeal

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Rectangle().fill(Color.stockedWhite.opacity(0.6)).frame(width: 80, height: 72)
                Image(systemName: "fork.knife").font(.system(size: 20))
                    .foregroundStyle(session.themeTextColor.opacity(0.25))
            }
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(Color.stockedGold)
                VStack(alignment: .leading) {
                    Text(meal.title)
                        .font(.system(size: 13, design: .serif)).foregroundStyle(Color.stockedWhite)
                        .padding(.leading, 12).padding(.top, 10).lineLimit(2)
                    Spacer()
                }
                Text(meal.date)
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.stockedCharcoal).clipShape(Capsule()).padding(6)
            }.frame(maxWidth: .infinity).frame(height: 72)
            Button {
                withAnimation(.spring(response: 0.3)) {
                    session.guestStore.pastMeals.removeAll { $0.id == meal.id }
                }
            } label: {
                ZStack {
                    Color.red.frame(width: 56, height: 72)
                    Image(systemName: "trash.fill").font(.system(size: 16)).foregroundStyle(.white)
                }
            }.buttonStyle(.plain)
        }
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)).clipped()
    }
}

// MARK: - For You (Premium full tab)


// MARK: - Recipe Preview Card (#13 long-press popover preview)
struct RecipePreviewCard: View {
    @Environment(AppSession.self) var session
    let recipe: UserRecipe

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Image (photo data, URL, or resolved by title)
            CachedAsyncImage(
                url: recipe.imageURL,
                imageData: recipe.imageData,
                height: 160,
                resolveName: recipe.title
            )
            .frame(width: 300, height: 160)
            .clipped()

            VStack(alignment: .leading, spacing: 8) {
                Text(recipe.title.displayNormalized)
                    .font(.system(size: 17, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .lineLimit(2)

                // Flag a recipe that is missing important parts (few/no steps or ingredients, no
                // image) so the user knows it may need a look. Only shown when low-quality.
                if RecipeQuality.badge(for: RecipeQuality.score(
                        title: recipe.title,
                        ingredients: recipe.ingredients.map { $0.name },
                        steps: recipe.instructions,
                        imageURL: recipe.imageURL ?? "")) == .needsReview {
                    SourceBadgeView(badge: .needsReview)
                }

                if !recipe.cookTime.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(Color.stockedGold)
                        Text(recipe.cookTime).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.6))
                    }
                }

                if !recipe.ingredients.isEmpty {
                    Text("\(recipe.ingredients.count) ingredients")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(recipe.ingredients.prefix(5)) { ing in
                            Text("• \(ing.name.displayNormalized)")
                                .font(.system(size: 12))
                                .foregroundStyle(session.themeTextColor.opacity(0.75))
                                .lineLimit(1)
                        }
                        if recipe.ingredients.count > 5 {
                            Text("+ \(recipe.ingredients.count - 5) more")
                                .font(.system(size: 11))
                                .foregroundStyle(session.themeTextColor.opacity(0.45))
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 300)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite)
    }
}


// MARK: - #245 — Recipe list (hub destinations) + Collections
struct RecipeListView: View {
    @Environment(AppSession.self) var session
    let title: String
    let recipes: [UserRecipe]
    var onCreate: (() -> Void)? = nil
    @State private var selected: UserRecipe? = nil
    @State private var goDetail = false

    var body: some View {
        StockedShell(showBack: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("\(recipes.count) recipe\(recipes.count == 1 ? "" : "s")")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                    Spacer()
                }
                .padding(.horizontal, 24).padding(.bottom, 12)

                if recipes.isEmpty {
                    StockedEmptyState(icon: "📖",
                                      title: "Nothing here yet",
                                      subtitle: "Recipes you save will show up in \(title).")
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(recipes) { recipe in
                            Button { selected = recipe; goDetail = true } label: {
                                HStack(spacing: 12) {
                                    CachedAsyncImage(url: recipe.imageURL, imageData: recipe.imageData,
                                                     height: 52, resolveName: recipe.title)
                                        .frame(width: 52, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(recipe.title)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(session.themeTextColor)
                                            .lineLimit(1)
                                        if !recipe.cookTime.isEmpty {
                                            Text(recipe.cookTime).font(.system(size: 12))
                                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                                }
                                .padding(12)
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.40))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }

                if let onCreate {
                    Button(action: onCreate) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                            Text("New Recipe").font(.system(size: 14, weight: .bold, design: .serif))
                        }
                        .foregroundStyle(Color.stockedWhite)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(Color.stockedCharcoal)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                }
            }
        }
        .navigationDestination(isPresented: $goDetail) {
            if let selected { UserRecipeDetailView(recipe: selected) }
        }
    }
}

struct CollectionsListView: View {
    @Environment(AppSession.self) var session
    @State private var selectedCuisine: String? = nil
    @State private var goList = false

    private var cuisines: [(String, Int)] {
        RecipeFacets.availableCuisines(in: session.guestStore.userRecipes)
            .map { ($0, RecipeFacets.count(cuisine: $0, in: session.guestStore.userRecipes)) }
            .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        StockedShell(showBack: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Collections")
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("\(cuisines.count) collection\(cuisines.count == 1 ? "" : "s")")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                    Spacer()
                }
                .padding(.horizontal, 24).padding(.bottom, 12)

                if cuisines.isEmpty {
                    StockedEmptyState(icon: "🗂️",
                                      title: "No collections yet",
                                      subtitle: "Recipes with a cuisine set group themselves into collections.")
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(cuisines, id: \.0) { name, count in
                            Button { selectedCuisine = name; goList = true } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle().fill(Color.stockedGold.opacity(0.14))
                                            .frame(width: 36, height: 36)
                                        Text(ImageFallbackService.emoji(for: name))
                                            .font(.system(size: 17))
                                    }
                                    Text(name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(session.themeTextColor)
                                    Spacer()
                                    Text("\(count) recipe\(count == 1 ? "" : "s")")
                                        .font(.system(size: 12))
                                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                                }
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.40))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
        .navigationDestination(isPresented: $goList) {
            if let selectedCuisine {
                RecipeListView(title: selectedCuisine,
                               recipes: session.guestStore.userRecipes.filter { RecipeFacets.matches($0, cuisine: selectedCuisine) })
                    .environment(session)
            }
        }
    }
}
