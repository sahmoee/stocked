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

    @State private var resolvedURL: String? = nil
    @State private var resolving = false

    var body: some View {
        ZStack {
            if let data = imageData, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill().clipped()
            } else if let urlStr = imageURL, !urlStr.isEmpty {
                CachedAsyncImage(url: urlStr, imageData: nil, height: 220)
            } else if let resolved = resolvedURL {
                CachedAsyncImage(url: resolved, imageData: nil, height: 220)
            } else {
                // No stored image — resolve one online by recipe name, show a placeholder meanwhile.
                ZStack {
                    Color.stockedGold
                    Image(systemName: resolving ? "photo" : "photo.badge.magnifyingglass")
                        .font(.system(size: 32)).foregroundStyle(Color.stockedWhite)
                }
                .task { await resolveImageIfNeeded() }
            }
        }
    }

    private func resolveImageIfNeeded() async {
        guard resolvedURL == nil, !resolving,
              (imageURL?.isEmpty ?? true), imageData == nil else { return }
        resolving = true
        if let url = await RecipeImageResolver.shared.imageURL(for: recipeName, category: category) {
            resolvedURL = url.absoluteString
        }
        resolving = false
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
            }
        }
        // Implemented via `id` so associated values (UserRecipe / RecipeDatabaseEntry)
        // don't need to be Hashable themselves — their stable ids already uniquely
        // identify each destination.
        static func == (lhs: RecipeNavTarget, rhs: RecipeNavTarget) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }
    @State private var navTarget: RecipeNavTarget? = nil

    let tabNames = ["Ready to Cook Now", "My Collection", "Browse", "For You ✦"]

    private var greeting: String { StockedFormatters.timeOfDayGreeting }
    private var subtitle: String {
        switch selectedTab {
        case 0: return "Based on what's in your kitchen"
        case 1: return "Your recipes and meal history"
        case 3: return "AI recipes built around you — coming soon"
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
                            count: session.guestStore.userRecipes.filter(\.isFavorited).count,
                            unit: "recipes", label: "Favorites") { navTarget = .favorites }
                    hubCard(icon: "checkmark.circle.fill", tint: Color.stockedGreen,
                            count: session.guestStore.userRecipes.filter { $0.cookCount > 0 }.count,
                            unit: "recipes", label: "Cooked") { navTarget = .cooked }
                    hubCard(icon: "bookmark.fill", tint: Color.stockedInfo,
                            count: session.guestStore.userRecipes.count,
                            unit: "recipes", label: "Saved") { navTarget = .saved }
                    hubCard(icon: "folder.fill", tint: Color.stockedGold,
                            count: Set(session.guestStore.userRecipes.map(\.cuisine).filter { !$0.isEmpty }).count,
                            unit: "cuisines", label: "Collections") { navTarget = .collections }
                }
                .padding(.horizontal, 20).padding(.bottom, 10)
                .coachmarkAnchor("recipes.hub")

                // Categories — browse online recipes by cuisine. Full-width card so it
                // reads as a peer of the four hub cards above (and is fully separate
                // from the Discover hero, so taps can't fall through to a recipe).
                hubActionCard(icon: "square.grid.2x2.fill", tint: Color.stockedGold,
                              label: "Categories",
                              subtitle: "Browse by cuisine") { navTarget = .cuisineBrowse }
                    .padding(.horizontal, 20).padding(.bottom, 14)
                    .coachmarkAnchor("recipes.categories")

                // ── #240 — Recently Viewed (mockup rail) ────────────────
                let recents = session.recentlyViewedRecipeIDs.compactMap { id in
                    session.guestStore.userRecipes.first(where: { $0.id == id })
                }
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
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 14)
                }

                // ── #244 — Top Categories (mockup) ──────────────────────
                let cuisineCounts: [(String, Int)] = {
                    var counts: [String: Int] = [:]
                    for r in session.guestStore.userRecipes where !r.cuisine.isEmpty {
                        counts[r.cuisine, default: 0] += 1
                    }
                    return counts.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, $0.value) }
                }()
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
            }
        }
        .onAppear {
            selectedTab = session.preferredRecipeTab
            onlineLoader.loadIfNeeded(profile: session.guestStore.cookingProfile)  // #248
            consumePendingImportIfNeeded()
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

    private var discoverPool: [OnlineRecipe] {
        // De-duplicate by normalized title AND drop recipes with no real step-by-step
        // instructions (or link-only "instructions" from sources like Edamam). The
        // loader pulls from several feeds and the same dish can come back from more
        // than one with different ids — which is why the same recipe showed twice.
        var seen = Set<String>()
        var out: [OnlineRecipe] = []
        for r in onlineLoader.recipes
            where !r.imageURL.isEmpty && OnlineRecipeFacts.hasRealInstructions(r.instructions) {
            let key = OnlineRecipeFacts.normalizedTitle(r.title)
            if seen.insert(key).inserted { out.append(r) }
        }
        return out
    }
    // #251 — pantry + saved snapshots reused by every Discover card's badges.
    private var discoverInStock: Set<String> { session.guestStore.inStockNameSet }
    private var discoverSavedTitles: Set<String> { session.guestStore.savedRecipeTitles }

    /// Splits the pool into (hero, popular, dinners, sweets) with no recipe repeated.
    /// "Popular right now" is ordered by what this user actually opens (#6) — recipes whose
    /// category/area match the user's interest profile float to the front.
    private var discoverSplit: (hero: OnlineRecipe?, popular: [OnlineRecipe], dinners: [OnlineRecipe], sweets: [OnlineRecipe]) {
        var pool = discoverPool
        let hero = pool.first
        if hero != nil { pool.removeFirst() }

        let sweetCats  = ["dessert", "breakfast"]
        let dinnerCats = ["beef", "chicken", "pasta", "pork", "lamb", "seafood", "vegetarian", "vegan", "side"]

        var used = Set<String>()
        func take(_ n: Int, where match: (OnlineRecipe) -> Bool) -> [OnlineRecipe] {
            var out: [OnlineRecipe] = []
            for r in pool where out.count < n && !used.contains(r.id) && match(r) {
                out.append(r); used.insert(r.id)
            }
            return out
        }
        let sweets  = take(8) { sweetCats.contains($0.category.lowercased()) }
        let dinners = take(8) { dinnerCats.contains($0.category.lowercased()) }
        // Popular: take a wider slice, then sort by interest score so the user's taste leads.
        var popular = take(12) { _ in true }
        popular.sort { RecipeInterest.shared.score(category: $0.category, area: $0.area)
                     > RecipeInterest.shared.score(category: $1.category, area: $1.area) }
        popular = Array(popular.prefix(8))
        return (hero, popular, dinners, sweets)
    }

    /// One-tap open that also teaches the interest profile (#6).
    private func openOnlineRecipe(_ recipe: OnlineRecipe) {
        RecipeInterest.shared.record(category: recipe.category, area: recipe.area)
        navTarget = .online(recipe)
    }

    @ViewBuilder
    private var discoverSections: some View {
        let split = discoverSplit

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Discover")
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 8)

            if discoverPool.isEmpty {
                if onlineLoader.isLoading {
                    discoverSkeleton
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Couldn't reach online recipes right now. You're still able to browse anything saved to your kitchen.")
                            .font(.system(size: 13))
                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                        Button {
                            onlineLoader.forceRefresh(profile: session.guestStore.cookingProfile)
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
            }
        }
        .padding(.bottom, 6)
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

    private func discoverRail(_ title: String, _ recipes: [OnlineRecipe]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(session.themeTextColor.opacity(0.7))
                .padding(.horizontal, 24)
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
                .padding(.horizontal, 24)
            }
        }
        .padding(.bottom, 14)
    }

    // MARK: - #251 Discover badges (shared by hero + rails)

    // "Can I make this?" — Ready / N missing, computed live against the pantry. Shows
    // nothing when the kitchen is empty (no honest signal to give).
    @ViewBuilder
    private func onlineStatusBadge(_ recipe: OnlineRecipe, light: Bool) -> some View {
        switch OnlineRecipeMatch.status(recipe, inStock: discoverInStock) {
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
                    .padding(.horizontal, 24)
                }
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
                // #9 fuzzy matching: title/cuisine/category fuzzily, ingredients by substring;
                // ranked by best title relevance.
                dbResults = snap.filter {
                    FuzzyMatch.matches(trimmed, $0.title) ||
                    FuzzyMatch.matches(trimmed, $0.cuisine) ||
                    FuzzyMatch.matches(trimmed, $0.category) ||
                    $0.ingredients.contains { $0.localizedCaseInsensitiveContains(trimmed) }
                }
                .sorted { FuzzyMatch.score(trimmed, $0.title) > FuzzyMatch.score(trimmed, $1.title) }
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

// MARK: - My Collection Tab
private struct RecipeMyCollectionView: View {
    @Environment(AppSession.self) var session
    @Binding var showCreate: Bool
    @Binding var showBrowse: Bool
    @State private var mergeCandidate: (UserRecipe, UserRecipe)? = nil
    @State private var showMergeSheet = false
    @State private var showPastMeals  = true    // collapsible past meals section
    @State private var cookableSort   = false   // #2 — rank by what's in stock right now

    // Fuzzy duplicate: same normalised title (lowercase, drop punctuation)
    private func duplicatePairs(_ recipes: [UserRecipe]) -> [(UserRecipe, UserRecipe)] {
        var pairs: [(UserRecipe, UserRecipe)] = []
        let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace } }
        for i in recipes.indices {
            for j in (i+1)..<recipes.count {
                let a = norm(recipes[i].title), b = norm(recipes[j].title)
                let sim = a == b || a.contains(b) || b.contains(a)
                    || (Set(a.components(separatedBy: " ")).intersection(Set(b.components(separatedBy: " "))).count >= 3)
                if sim { pairs.append((recipes[i], recipes[j])) }
            }
        }
        return pairs
    }

    var body: some View {
        let store = session.guestStore
        let raw = store.userRecipes
        // #2 cook-what-you-have: rank by % of ingredients in stock; #1 profile boost breaks ties.
        let recipes: [UserRecipe] = cookableSort
            ? raw.sorted { a, b in
                let ma = store.stockMatch(for: a), mb = store.stockMatch(for: b)
                let ra = ma.total == 0 ? 0 : Double(ma.have) / Double(ma.total)
                let rb = mb.total == 0 ? 0 : Double(mb.have) / Double(mb.total)
                if ra != rb { return ra > rb }
                return store.profileBoost(for: a) > store.profileBoost(for: b)
            }
            : raw
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recipes you've saved or created")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(session.themeTextColor)
                Spacer()
                // Duplicate merge badge
                let dups = duplicatePairs(recipes)
                if !dups.isEmpty {
                    Button {
                        mergeCandidate = dups.first
                        showMergeSheet = true
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

            if recipes.isEmpty {
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
                    ForEach(Array(recipes.enumerated()), id: \.element.id) { idx, recipe in
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
                                let match = session.guestStore.stockMatch(for: recipe)
                                let conflicts = session.guestStore.allergenConflicts(in: recipe)
                                HStack(spacing: 4) {
                                    if match.total > 0 {
                                        Text("\(match.have)/\(match.total) in stock")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(match.have == match.total ? Color.stockedGreen : session.themeTextColor.opacity(0.6))
                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(.ultraThinMaterial, in: Capsule())
                                    }
                                    if !conflicts.isEmpty {
                                        Label(conflicts.joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
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
                        .springIn(delay: Double(idx) * 0.04)
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
        .sheet(isPresented: $showMergeSheet) {
            if let (a, b) = mergeCandidate {
                RecipeMergeSheet(recipeA: a, recipeB: b)
                    .environment(session)
            }
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
        var counts: [String: Int] = [:]
        for r in session.guestStore.userRecipes where !r.cuisine.isEmpty {
            counts[r.cuisine, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
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
                               recipes: session.guestStore.userRecipes.filter { $0.cuisine == selectedCuisine })
                    .environment(session)
            }
        }
    }
}
