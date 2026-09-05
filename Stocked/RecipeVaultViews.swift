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
    @Environment(\.stockedLayout) private var layoutMetrics
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.stockedMotion) private var motion
    @Environment(\.stockedScrollActivity) private var pageScrollActivity
    @State private var selectedTab       = 0
    @State private var showBrowseOnline  = false
    @State private var showCreate        = false
    @State private var createRoute: RecipeCreateRoute? = nil
    @State private var recipeSearch      = ""
    @State private var showRecipeSearch  = false   // header search → recipe-only search
    @State var finder = RecipeFinderSession()
    init(finder: RecipeFinderSession = RecipeFinderSession()) {
        _finder = State(initialValue: finder)
    }
    @State private var dbResults: [RecipeDatabaseEntry] = []
    @State private var selectedDBEntry: RecipeDatabaseEntry? = nil
    @State private var navigateToDBRecipe = false
    // A stable, per-rail identity lets SwiftUI keep the same card centered while the
    // backing loader publishes a refresh. It also means returning from a detail view
    // lands on the card the user opened instead of resetting every rail to its start.
    @State private var recipeRailPositions: [String: String] = [:]
    @State private var recipeRailActivities: [String: StockedScrollActivity] = [:]
    @State private var prefetchScope = UUID().uuidString
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
        case finder
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
            case .finder:              return "finder"
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
        default: return "Discover recipes from trusted sources"
        }
    }

    // #238 — mockup hub card.
    private func hubCard(icon: String, tint: Color, count: Int, unit: String, label: String, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.15)).frame(width: 34, height: 34)
                Image(systemName: icon).scaledFont(14).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label).scaledFont(13.5, weight: .bold).foregroundStyle(session.themeTextColor)
                Text("\(count) \(unit)").scaledFont(11)
                    .foregroundStyle(session.themeSecondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(session.themeCardColor)
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
                    Image(systemName: icon).scaledFont(14).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).scaledFont(13.5, weight: .bold).foregroundStyle(session.themeTextColor)
                    Text(subtitle).scaledFont(11)
                        .foregroundStyle(session.themeSecondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").scaledFont(12, weight: .semibold)
                    .foregroundStyle(session.themeTextColor.opacity(0.35))
            }
            .padding(10)
            .background(session.themeCardColor)
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
                            .font(.stockedSans(13, relativeTo: .footnote))
                            .foregroundStyle(session.themeSecondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else if dbResults.isEmpty {
                        Text("No recipes found.")
                            .font(.stockedSans(13, relativeTo: .footnote))
                            .foregroundStyle(session.themeSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
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
                        .foregroundStyle(session.accentColor)
                }
            }
        }
        .environment(session)
    }

    private var referenceRecipesPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            referenceRecipeHero
            referenceRecipeDestinations
            referenceAICard
            findRecipeCard
            Spacer(minLength: 24)
        }
        .stockedSnapTargetLayout()
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var referenceRecipeHero: some View {
        HStack(alignment: .bottom, spacing: max(8, 12 / min(layoutMetrics.textScale, 1.5))) {
            referenceRecipeHeroContent
        }
    }

    private func openFinder(search: Bool) {
        finder.flow.start(search: search)
        finder.flow.editingReview = false
        finder.shouldFocusSearch = search
        if !search { finder.flow.phase = .quiz(0); AppAnalytics.shared.log(.finderStarted) }
        navTarget = .finder
    }

    private var findRecipeCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Find a Recipe").font(.stockedSerif(28, weight: .bold, relativeTo: .title))
                    Text("Tell us what you’re craving and we’ll narrow it down.")
                        .font(.stocked(.body)).foregroundStyle(session.themeSecondaryText)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize {
                    Image("recipes_hero").resizable().scaledToFit().frame(width: 100).accessibilityHidden(true)
                }
            }
            Button { openFinder(search: false) } label: {
                Text("Start finding").font(.stocked(.headline)).frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(Color.selectedTabForeground(session.isDarkMode))
                    .background(Color.selectedTabBackground, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.plain)
            Button { openFinder(search: true) } label: {
                Label("Search recipes or ingredients", systemImage: "magnifyingglass")
                    .font(.stocked(.body)).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .padding(.horizontal, 14).overlay(RoundedRectangle(cornerRadius: 18).stroke(session.themeSecondaryText.opacity(0.3)))
            }.buttonStyle(.plain)
        }.padding(20).foregroundStyle(session.themeTextColor)
            .background(RecipeCardStyle.surface(isDark: session.isDarkMode), in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder private var referenceRecipeHeroContent: some View {
            VStack(alignment: .leading, spacing: 9) {
                Text("YOUR RECIPE BOOK")
                    .font(.stockedSans(10, weight: .bold, relativeTo: .caption2))
                    .tracking(2.2)
                    .foregroundStyle(session.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text("What are you\nlooking for?")
                    .font(.stockedSerif(31, weight: .bold, relativeTo: .title))
                    .foregroundStyle(session.themeTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your recipes, past meals,\nand ideas for what to make next.")
                    .font(.stockedSerif(13, relativeTo: .footnote))
                    .foregroundStyle(session.themeSecondaryText)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image("recipes_hero")
                .resizable().scaledToFit()
                .frame(width: min(180, max(86, layoutMetrics.contentWidth * 0.30 / min(layoutMetrics.textScale, 1.6))))
                .layoutPriority(0)
                .accessibilityHidden(true)
    }

    private var referenceRecipeDestinations: some View {
        LazyVGrid(
            columns: layoutMetrics.gridColumns(minimum: 105, maximum: 3, spacing: 7),
            spacing: 10
        ) {
            referenceDestinationCards
        }
    }

    @ViewBuilder private var referenceDestinationCards: some View {
        referenceDestinationCard(image: "recipes_collection", title: "My Collection",
                                 subtitle: "Recipes you’ve saved,\ncreated & loved.",
                                 detail: "\(hubStats.saved) recipe\(hubStats.saved == 1 ? "" : "s")") {
            navTarget = .saved
        }
        referenceDestinationCard(image: "recipes_ready", title: "Ready to Cook",
                                 subtitle: "Recipes that match\nyour kitchen.", detail: nil) {
            navTarget = .browseAll
        }
        referenceDestinationCard(image: "recipes_past", title: "Past Meals",
                                 subtitle: "Find something\nworth making again.", detail: nil) {
            navTarget = .cooked
        }
    }

    private func referenceDestinationCard(image: String, title: String, subtitle: String,
                                          detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                StockedKitchenArtwork(asset: image)
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? 56 : 72)
                    .frame(maxWidth: .infinity)
                Text(title).font(.stockedSans(13, weight: .bold, relativeTo: .footnote)).foregroundStyle(session.themeTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.stockedSans(10.5, relativeTo: .caption2)).foregroundStyle(session.themeSecondaryText).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let detail { Text(detail).font(.stockedSans(10, weight: .semibold, relativeTo: .caption2)).foregroundStyle(session.accentColor).fixedSize(horizontal: false, vertical: true) }
                    Spacer()
                    Image(systemName: "chevron.right").font(.stockedSans(11, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(session.themeTextColor)
                        .frame(minWidth: 25, minHeight: 25).padding(4)
                        .background(session.accentColor.opacity(0.12)).clipShape(Circle())
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: RecipeCardStyle.destinationHeight(
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize),
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .padding(10)
            .background(session.themeCardColor)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(session.themeTextColor.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.07), radius: 6, y: 3)
        }.buttonStyle(.plain)
    }

    private var referenceAICard: some View {
        Button { createRoute = .ai } label: {
            referenceAIHorizontalContent
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.stockedCharcoal)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(true)
        .a11yButton("Create with Stocked AI, Coming Soon")
        .coachmarkAnchor("recipes.createAI")
    }

    private var referenceAIHorizontalContent: some View {
        HStack(spacing: 10) {
            referenceAIIcon
            referenceAICopy
            Spacer(minLength: 8)
            referenceAIAction
        }
    }

    private var referenceAIIcon: some View {
        ZStack {
            Circle().stroke(session.accentColor, lineWidth: 1)
            Image(systemName: "sparkles")
                .font(.stockedSans(16, weight: .semibold, relativeTo: .body))
                .foregroundStyle(session.accentColor)
        }
        .frame(width: 38, height: 38)
        .accessibilityHidden(true)
    }

    private var referenceAICopy: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Create with Stocked AI")
                .font(.stockedSerif(16, weight: .semibold, relativeTo: .headline))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text("Coming Soon")
                .font(.stockedSans(11, relativeTo: .caption))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var referenceAIAction: some View {
        Text("Coming Soon")
            .font(.stockedSans(11, weight: .bold, relativeTo: .caption))
            .foregroundStyle(Color.stockedCharcoal)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(session.accentColor)
            .clipShape(Capsule())
            .fixedSize(horizontal: true, vertical: true)
    }

    private var referenceMoodRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            referenceSectionHeader("Discover by mood", actionTitle: "See all") { navTarget = .browseAll }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 9) {
                    referenceMoodChip("Quick", icon: "bolt.fill")
                    referenceMoodChip("Comfort", icon: "heart.fill")
                    referenceMoodChip("One Pot", icon: "frying.pan.fill")
                    referenceMoodChip("Feeling Lazy", icon: "moon.zzz.fill")
                    referenceMoodChip("Surprise Me", icon: "sparkles")
                }
                .stockedScrollTargetLayout()
            }
            .stockedHorizontalSnap()
            .contentMargins(.horizontal, 1, for: .scrollContent)
        }
    }

    private func referenceMoodChip(_ title: String, icon: String) -> some View {
        NavigationLink {
            QuickPickListView(pick: title, pool: discoverSnapshot.pool, onOpenRecipe: { openOnlineRecipe($0) }).environment(session)
        } label: {
            HStack(spacing: 8) { Image(systemName: icon); Text(title) }
                .font(.stockedSans(13, weight: .medium, relativeTo: .footnote)).foregroundStyle(session.themeTextColor)
                .padding(.horizontal, 17).padding(.vertical, 10)
                .background(session.themeCardColor)
                .clipShape(Capsule()).overlay(Capsule().stroke(session.themeTextColor.opacity(0.12)))
                .fixedSize(horizontal: true, vertical: true)
        }
        .buttonStyle(.plain)
        .id(title)
    }

    @ViewBuilder private var referenceRecipeRails: some View {
        let firstRail = Array(discoverSnapshot.popular.prefix(3))
        let firstIDs = Set(firstRail.map(\.id))
        let secondRail = Array(
            Self.uniqueRecipes(discoverSnapshot.dinners + discoverSnapshot.sweets + discoverSnapshot.pool)
                .filter { !firstIDs.contains($0.id) }
                .prefix(3)
        )
        referenceRecipeRail(title: "For you", recipes: firstRail)
        referenceRecipeRail(title: "More to explore", recipes: secondRail)
    }

    @ViewBuilder private func referenceRecipeRail(title: String, recipes: [OnlineRecipe]) -> some View {
        if !recipes.isEmpty {
            let railKey = "reference.\(title)"
            let scrollPosition = recipeRailPosition(for: railKey)
            let cardWidth = layoutMetrics.wideRailCardWidth(
                itemCount: recipes.count,
                preferred: dynamicTypeSize.isAccessibilitySize ? 240 : 168,
                minimum: dynamicTypeSize.isAccessibilitySize ? 220 : 144,
                maximum: dynamicTypeSize.isAccessibilitySize ? 300 : 220,
                spacing: 10
            )
            let imageHeight = RecipeCardStyle.imageHeight
            let railMargin = layoutMetrics.horizontalPadding
            VStack(alignment: .leading, spacing: 9) {
                referenceSectionHeader(title, actionTitle: "See all") { navTarget = .browseAll }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(recipes) { recipe in
                            Button {
                                centerRecipe(recipe.id, in: railKey)
                                openOnlineRecipe(recipe)
                            } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    CachedAsyncImage(url: recipe.imageURL, imageData: nil, height: imageHeight, resolveName: recipe.title)
                                        .frame(width: cardWidth, height: imageHeight).clipped()
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(recipe.title)
                                            .font(.stockedSerif(RecipeCardStyle.titleSize, weight: .semibold, relativeTo: .headline))
                                            .foregroundStyle(session.themeTextColor)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text([recipe.area, recipe.category].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.stockedSans(RecipeCardStyle.metadataSize, relativeTo: .caption)).foregroundStyle(session.themeSecondaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }.padding(RecipeCardStyle.padding)
                                }.frame(width: cardWidth).background(session.themeCardColor)
                                    .clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(session.themeTextColor.opacity(0.16)))
                            }
                            .buttonStyle(.plain)
                            .id(recipe.id)
                        }
                    }
                    .stockedScrollTargetLayout()
                }
                .stockedCardRailSnap()
                .scrollPosition(id: scrollPosition, anchor: .leading)
                .contentMargins(.horizontal, railMargin, for: .scrollContent)
                .onAppear {
                    prefetchRecipeRail(
                        recipes,
                        around: scrollPosition.wrappedValue,
                        scope: railKey,
                        activity: recipeRailActivities[railKey] ?? .idle
                    )
                }
                .onChange(of: scrollPosition.wrappedValue) { _, focusedID in
                    prefetchRecipeRail(
                        recipes,
                        around: focusedID,
                        scope: railKey,
                        activity: recipeRailActivities[railKey] ?? .idle
                    )
                }
                .onChange(of: recipes.map(\.id)) { _, ids in
                    preserveRecipeRailPosition(railKey, validIDs: ids)
                    prefetchRecipeRail(
                        recipes,
                        around: recipeRailPositions[railKey],
                        scope: railKey,
                        activity: recipeRailActivities[railKey] ?? .idle
                    )
                }
                .stockedOnScrollActivityChange { activity in
                    recipeRailActivities[railKey] = activity
                    prefetchRecipeRail(
                        recipes,
                        around: scrollPosition.wrappedValue,
                        scope: railKey,
                        activity: activity
                    )
                }
            }
        }
    }

    private var referenceBrowseRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            referenceSectionHeader("Browse recipes", actionTitle: "Browse all") { navTarget = .browseAll }
            Text("Explore by cuisine, meal type, dietary needs, ingredients, and more.")
                .font(.stockedSans(12, relativeTo: .caption)).foregroundStyle(session.themeSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    referenceBrowseButton("Cuisine", "globe") { navTarget = .cuisineBrowse }
                    referenceBrowseButton("Meal Type", "frying.pan") { navTarget = .browseAll }
                    referenceBrowseButton("Dietary", "leaf") { navTarget = .browseAll }
                    referenceBrowseButton("Ingredient", "carrot") { navTarget = .browseAll }
                    referenceBrowseButton("Occasion", "gift") { navTarget = .browseAll }
                    referenceBrowseButton("Source", "book.closed") { navTarget = .sources }
                    referenceBrowseButton("Drinks", "mug") { navTarget = .drinks }
                }
                .stockedScrollTargetLayout()
            }
            .stockedHorizontalSnap()
        }
    }

    private func referenceBrowseButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) { Image(systemName: icon); Text(title) }
                .font(.stockedSans(12, weight: .medium, relativeTo: .caption)).foregroundStyle(session.themeTextColor)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(session.themeCardColor)
                .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(session.themeTextColor.opacity(0.13)))
                .fixedSize(horizontal: true, vertical: true)
        }
        .buttonStyle(.plain)
        .id(title)
    }

    private func referenceSectionHeader(_ title: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            referenceSectionHeaderContent(title, actionTitle: actionTitle, action: action)
        }
    }

    @ViewBuilder private func referenceSectionHeaderContent(_ title: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        Text(title).font(.stockedSerif(20, weight: .bold, relativeTo: .title3)).foregroundStyle(session.themeTextColor)
            .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Button(action: action) {
            HStack(spacing: 5) { Text(actionTitle); Image(systemName: "chevron.right") }
                .font(.stockedSans(13, weight: .bold, relativeTo: .footnote)).foregroundStyle(Color.stockedGold)
                .fixedSize(horizontal: true, vertical: true)
        }.buttonStyle(.plain)
    }

    var body: some View {
        StockedShell(showBack: false, scrollDisabled: false,
                     titleText: "Stocked.",
                     trailingIcon: "magnifyingglass", trailingLabel: "Search",
                     onTrailing: { openFinder(search: true) }) {
            referenceRecipesPage
            if false {
            VStack(alignment: .leading, spacing: 0) {

                // ── #245 — mockup title ──
                Text("My Recipes")
                    .scaledFont(24, weight: .bold, design: .serif)
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
                                  subtitle: "Coming Soon") { createRoute = .ai }
                        .disabled(true)
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
                            .scaledFont(15, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        Spacer()
                        Button { navTarget = .saved } label: {
                            Text("View All").scaledFont(12.5, weight: .semibold)
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
                                            .scaledFont(12.5, weight: .semibold)
                                            .foregroundStyle(session.themeTextColor)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if !recipe.cookTime.isEmpty {
                                            Text(recipe.cookTime).scaledFont(10.5)
                                                .foregroundStyle(session.themeSecondaryText)
                                        }
                                    }
                                    .frame(width: 128, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .stockedScrollTargetLayout()
                    }
                    .stockedCardRailSnap()
                    .contentMargins(
                        .horizontal,
                        layoutMetrics.horizontalPadding,
                        for: .scrollContent
                    )
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
                            .scaledFont(15, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        VStack(spacing: 8) {
                            ForEach(cuisineCounts, id: \.0) { name, count in
                                Button { navTarget = .savedCuisine(name) } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            Circle().fill(Color.stockedGold.opacity(0.14))
                                                .frame(width: 34, height: 34)
                                            Text(ImageFallbackService.emoji(for: name))
                                                .scaledFont(16)
                                        }
                                        Text(name)
                                            .scaledFont(14.5, weight: .semibold)
                                            .foregroundStyle(session.themeTextColor)
                                        Spacer()
                                        Text("\(count) recipe\(count == 1 ? "" : "s")")
                                            .scaledFont(12)
                                            .foregroundStyle(session.themeSecondaryText)
                                        Image(systemName: "chevron.right")
                                            .scaledFont(12, weight: .semibold)
                                            .foregroundStyle(session.themeTextColor.opacity(0.3))
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                    .background(session.themeCardColor)
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
            case .finder:
                RecipeFinderView(model: finder).environment(session)
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
            consumePendingImportIfNeeded()
            recomputeHubStats()
        }
        // The visible Recipes root is now the destination grid + Find a Recipe.
        // Do not hydrate and classify the retired Discover rails behind `if false`
        // when the tab appears; their actual destination owns loading on demand.
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
    @State private var discoverVisitSeed: UInt64 = 0
    @State private var didBuildDiscoverSnapshotForVisit = false
    @State private var lastDiscoverVisitRefresh = Date.distantPast

    private nonisolated static func uniqueRecipes(_ recipes: [OnlineRecipe]) -> [OnlineRecipe] {
        var seen = Set<String>()
        return recipes.filter { seen.insert($0.id).inserted }
    }

    private var discoverSavedTitles: Set<String> {
        session.guestStore.savedRecipeTitles
    }

    private func beginDiscoverVisit() {
        // A tab selection can deliver both onAppear and the root-tab activation
        // notification in the same transition. Treat that pair as one visit so the
        // shared recipe database is read once, while later visits still reroll rails.
        let now = Date()
        guard now.timeIntervalSince(lastDiscoverVisitRefresh) > 0.5 else { return }
        lastDiscoverVisitRefresh = now
        discoverVisitSeed &+= 1
        didBuildDiscoverSnapshotForVisit = false
        // Fold all database work completed since the previous visit into one loader
        // refresh. Observing every individual mutation made long-running sync/backfill
        // jobs rebuild the rails indefinitely.
        onlineLoader.refreshFromSharedDatabase(profile: session.guestStore.cookingProfile)
    }

    private func manuallyRefreshDiscover() {
        discoverVisitSeed &+= 1
        didBuildDiscoverSnapshotForVisit = false
        onlineLoader.forceRefresh(
            profile: session.guestStore.cookingProfile,
            pantry: Array(session.guestStore.inStockNameSet).prefix(8).map { $0 }
        )
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
        // The privacy control returns an empty map while personalization is disabled, preserving
        // neutral catalogue order without deleting the user's prior opt-in learning.
        let interestWeights = RecipeInterest.shared.personalizationWeights
        let visitSeed = discoverVisitSeed

        discoverSnapshotTask = Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.makeDiscoverSnapshot(
                    recipes: recipes,
                    inStock: inStock,
                    interestWeights: interestWeights,
                    visitSeed: visitSeed
                )
            }.value
            guard !Task.isCancelled else { return }
            discoverSnapshot = snapshot
            didBuildDiscoverSnapshotForVisit = true
            discoverSnapshotTask = nil
        }
    }

    private nonisolated static func makeDiscoverSnapshot(
        recipes: [OnlineRecipe],
        inStock: Set<String>,
        interestWeights: [String: Double],
        visitSeed: UInt64
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

        // Rotate the verified pool on every page visit. The seed is captured before
        // detached work begins, so switching away and back yields fresh rails without
        // introducing a timer, network loop, or unstable SwiftUI identity.
        func rotated(_ values: [OnlineRecipe], multiplier: UInt64) -> [OnlineRecipe] {
            guard values.count > 1 else { return values }
            let offset = Int((visitSeed &* multiplier) % UInt64(values.count))
            guard offset > 0 else { return values }
            return Array(values[offset...]) + Array(values[..<offset])
        }
        food = rotated(food, multiplier: 7)
        drinks = rotated(drinks, multiplier: 3)

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

    /// Each horizontal recipe rail owns a distinct scroll binding. `scrollPosition`
    /// writes the currently centered card back to this dictionary while the user drags,
    /// so replacing the recipe array does not implicitly jump the rail to its leading edge.
    private func recipeRailPosition(for key: String) -> Binding<String?> {
        Binding(
            get: { recipeRailPositions[key] },
            set: { newValue in
                if let newValue {
                    recipeRailPositions[key] = newValue
                } else {
                    recipeRailPositions.removeValue(forKey: key)
                }
            }
        )
    }

    private func centerRecipe(_ id: String, in railKey: String) {
        motion.animate(.selection, intent: .spatial) {
            recipeRailPositions[railKey] = id
        }
    }

    /// Keep an existing center when its recipe survives a refresh. If a source/filter
    /// removes that item, settle on the new first complete card instead of retaining an
    /// invalid identity that can leave the rail between targets.
    private func preserveRecipeRailPosition(_ key: String, validIDs: [String]) {
        guard let current = recipeRailPositions[key] else { return }
        guard !validIDs.contains(current) else { return }
        if let first = validIDs.first {
            recipeRailPositions[key] = first
        } else {
            recipeRailPositions.removeValue(forKey: key)
        }
    }

    /// Lazy stacks defer off-screen image views. Prefetch only the focused card and a
    /// small neighbor window so a single swipe reveals decoded photos without starting
    /// every image request in a long rail at once.
    private func prefetchRecipeRail(
        _ recipes: [OnlineRecipe],
        around focusedID: String?,
        scope railKey: String,
        activity: StockedScrollActivity
    ) {
        guard !recipes.isEmpty else { return }
        let effectiveActivity = activity.isScrolling
            ? activity
            : pageScrollActivity.isScrolling ? pageScrollActivity : activity
        let policy = StockedImageWorkPolicy()
        let directive = policy.directive(
            for: .init(source: .remote, purpose: .prefetch),
            activity: effectiveActivity,
            remoteAccessAllowed: ConnectivityMonitor.isOnlineFlag
        )
        let scopedID = "\(prefetchScope).\(railKey)"
        guard case let .loadNow(priority) = directive else {
            ImageCache.shared.cancelScheduledPrefetch(scope: scopedID)
            return
        }
        let focus = focusedID.flatMap { id in recipes.firstIndex { $0.id == id } } ?? 0
        let visibleRange = focus..<min(recipes.endIndex, focus + 1)
        let indexes = policy.candidateIndices(
            itemCount: recipes.count,
            visibleRange: visibleRange,
            axis: .horizontal,
            activity: effectiveActivity
        )
        ImageCache.shared.schedulePrefetch(
            scope: scopedID,
            urls: indexes.map { recipes[$0].imageURL }.filter { !$0.isEmpty },
            priority: priority.taskPriority
        )
    }

    @ViewBuilder
    private var discoverSections: some View {
        let split = discoverSnapshot

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Discover")
                    .scaledFont(19, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                // #FB — manual refresh; Discover otherwise only changes on re-entry.
                if onlineLoader.isLoading {
                    ProgressView().scaleEffect(0.7).tint(Color.stockedGold)
                } else {
                    Button {
                        manuallyRefreshDiscover()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise").scaledFont(10, weight: .bold)
                            Text("Refresh").scaledFont(12, weight: .semibold)
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
                            .scaledFont(13)
                            .foregroundStyle(session.themeSecondaryText)
                        Button {
                            manuallyRefreshDiscover()
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "arrow.clockwise").scaledFont(12, weight: .bold)
                                Text("Retry").scaledFont(13, weight: .semibold)
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
                            Text("🍹").scaledFont(14)
                            Text("Drinks")
                                .scaledFont(17, weight: .bold, design: .serif)
                                .foregroundStyle(session.themeTextColor)
                        }
                        Spacer()
                        Button { navTarget = .drinks } label: {
                            Text("View All").scaledFont(12.5, weight: .semibold)
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
                Image(systemName: icon).scaledFont(10)
                Text(title).scaledFont(12.5, weight: .semibold)
            }
            .foregroundStyle(session.themeTextColor)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(session.themeCardColor)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // Featured hero — big photo card with a gradient title plate.
    private func discoverHero(_ recipe: OnlineRecipe) -> some View {
        let saved = OnlineRecipeFacts.isSaved(recipe, savedTitles: discoverSavedTitles)
        let heroMinimumHeight = layoutMetrics.recipeFeatureHeroMinimumHeight
        return Button { openOnlineRecipe(recipe) } label: {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: recipe.imageURL, imageData: nil,
                                 height: heroMinimumHeight, resolveName: recipe.title)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: heroMinimumHeight)
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
                        .scaledFont(10, weight: .bold)
                        .tracking(1.2)
                        .foregroundStyle(Color.stockedGold)
                    Text(recipe.title)
                        .scaledFont(19, weight: .bold, design: .serif)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Text([recipe.area, recipe.category, recipe.source].filter { !$0.isEmpty }.joined(separator: " · "))
                        .scaledFont(12)
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
            .frame(minHeight: heroMinimumHeight)
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
            .contentShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))  // hit area = visible card only
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
    }

    private func discoverRail(_ title: String?, _ recipes: [OnlineRecipe]) -> some View {
        let railKey = "discover.\(title ?? "drinks")"
        let scrollPosition = recipeRailPosition(for: railKey)
        return VStack(alignment: .leading, spacing: 8) {
            // #FB — bigger section headers so they hold their own against the cards.
            if let title {
                Text(title)
                    .scaledFont(17, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, 24)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(recipes) { recipe in
                        let saved = OnlineRecipeFacts.isSaved(recipe, savedTitles: discoverSavedTitles)
                        Button {
                            centerRecipe(recipe.id, in: railKey)
                            openOnlineRecipe(recipe)
                        } label: {
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
                                        .scaledFont(12.5, weight: .semibold)
                                        .foregroundStyle(session.themeTextColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                        .frame(minHeight: 30, alignment: .top)
                                    Text([recipe.area.isEmpty ? recipe.category : recipe.area, recipe.source]
                                            .filter { !$0.isEmpty }.joined(separator: " · "))
                                        .scaledFont(10.5)
                                        .foregroundStyle(session.themeSecondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(8)
                                .frame(width: 134, alignment: .leading)
                            }
                            .background(session.themeCardColor)
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        }
                        .buttonStyle(.plain)
                        .id(recipe.id)
                    }
                }
                .stockedScrollTargetLayout()
            }
            .stockedCardRailSnap()
            .scrollPosition(id: scrollPosition, anchor: .leading)
            .contentMargins(
                .horizontal,
                layoutMetrics.horizontalPadding,
                for: .scrollContent
            )
            .onAppear {
                prefetchRecipeRail(
                    recipes,
                    around: scrollPosition.wrappedValue,
                    scope: railKey,
                    activity: recipeRailActivities[railKey] ?? .idle
                )
            }
            .onChange(of: scrollPosition.wrappedValue) { _, focusedID in
                prefetchRecipeRail(
                    recipes,
                    around: focusedID,
                    scope: railKey,
                    activity: recipeRailActivities[railKey] ?? .idle
                )
            }
            .onChange(of: recipes.map(\.id)) { _, ids in
                preserveRecipeRailPosition(railKey, validIDs: ids)
                prefetchRecipeRail(
                    recipes,
                    around: recipeRailPositions[railKey],
                    scope: railKey,
                    activity: recipeRailActivities[railKey] ?? .idle
                )
            }
            .stockedOnScrollActivityChange { activity in
                recipeRailActivities[railKey] = activity
                prefetchRecipeRail(
                    recipes,
                    around: scrollPosition.wrappedValue,
                    scope: railKey,
                    activity: activity
                )
            }
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
            if let system { Image(systemName: system).scaledFont(8, weight: .bold) }
            Text(text).scaledFont(9.5, weight: .bold)
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
                .fill(session.themeCardColor)
                .frame(height: 190)
                .padding(.horizontal, 24)
            ForEach(0..<2, id: \.self) { _ in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                                .fill(session.themeCardColor)
                                .frame(width: 134, height: 128)
                        }
                    }
                    .stockedScrollTargetLayout()
                    .padding(.horizontal, 24)
                }
                .stockedCardRailSnap()
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
            AIRecipeGeneratorSheet().environment(session)
        case .url:
            RecipeURLImportSheet { form, source in
                createRoute = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { createRoute = .form(form, source) }
            }.environment(session)
        case .browser:
            RecipeBrowserView().environment(session)
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
                .foregroundStyle(session.themeSecondaryText)
            TextField("Search recipes by name or cuisine…", text: $recipeSearch)
                .foregroundStyle(session.isDarkMode ? Color.stockedWhite : .black)
                .tint(Color.stockedGold)
                .scaledFont(14)
                .autocorrectionDisabled()
            if !recipeSearch.isEmpty {
                Button { recipeSearch = ""; dbResults = [] } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(session.themeCardColor)
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
                            .scaledFont(13).foregroundStyle(Color.stockedGold)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                                .scaledFont(13, weight: .semibold, design: .serif)
                                .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                                .fixedSize(horizontal: false, vertical: true)
                            let sub = [entry.cuisine, entry.category]
                                .filter { !$0.isEmpty }.prefix(2).joined(separator: " · ")
                            if !sub.isEmpty {
                                Text(sub).scaledFont(11)
                                    .foregroundStyle(session.themeSecondaryText)
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
        .background(session.themeCardColor)
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
    @Environment(\.stockedLayout) private var layoutMetrics
    @Environment(\.stockedMotion) private var motion
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
                    .scaledFont(14, weight: .bold).foregroundStyle(session.themeTextColor)
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
                            .scaledFont(11, weight: .semibold)
                            .foregroundStyle(.orange)
                    }.buttonStyle(.plain)
                }
                // #2 — sort by what you can cook right now
                Button { motion.animate(.standard, intent: .spatial) { cookableSort.toggle() } } label: {
                    Label("Cookable", systemImage: cookableSort ? "flame.fill" : "flame")
                        .scaledFont(12, weight: .semibold)
                        .foregroundStyle(cookableSort ? Color.stockedGreen : session.themeTextColor.opacity(0.5))
                }.buttonStyle(.plain)
                // Browse online
                Button { showBrowse = true } label: {
                    Label("Browse", systemImage: "safari")
                        .scaledFont(12, weight: .semibold).foregroundStyle(Color.stockedGold)
                }.buttonStyle(.plain)
                // Create
                Button { showCreate = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .scaledFont(18).foregroundStyle(Color.stockedGold)
                }.buttonStyle(.plain).padding(.leading, 4)
            }.padding(.horizontal, 24).padding(.bottom, 12)

            if entries.isEmpty && isBuildingSnapshot {
                HStack(spacing: 10) {
                    ProgressView().tint(Color.stockedGold)
                    Text("Loading collection…")
                        .scaledFont(13, weight: .medium)
                        .foregroundStyle(session.themeSecondaryText)
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
                // Container-driven columns adapt through rotation, Split View, Stage Manager,
                // and accessibility text without relying on a physical-device check.
                let cols = layoutMetrics.gridColumns(minimum: 160, maximum: 3, spacing: 12)
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
                                            .scaledFont(9, weight: .bold)
                                            .foregroundStyle(entry.stockHave == entry.stockTotal ? Color.stockedGreen : session.themeTextColor.opacity(0.6))
                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(.ultraThinMaterial, in: Capsule())
                                    }
                                    if !entry.allergenConflicts.isEmpty {
                                        Label(entry.allergenConflicts.joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                                            .scaledFont(9, weight: .bold)
                                            .foregroundStyle(.orange)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(.ultraThinMaterial, in: Capsule())
                                    }
                                }
                                .padding(6)
                            }
                            Button {
                                motion.animate(.standard, intent: .spatial) {
                                    session.guestStore.userRecipes.removeAll { $0.id == recipe.id }
                                }
                            } label: {
                                ZStack {
                                    Circle().fill(Color.red).frame(width: 24, height: 24)
                                    Image(systemName: "minus").scaledFont(11, weight: .bold)
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
                motion.animate(.standard, intent: .spatial) { showPastMeals.toggle() }
            } label: {
                HStack {
                    Text("Past Meals")
                        .scaledFont(14, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    let count = session.guestStore.pastMeals.count
                    if count > 0 {
                        Text("\(count)")
                            .scaledFont(11, weight: .bold)
                            .foregroundStyle(session.accentColor)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(session.accentColor.opacity(0.12)).clipShape(Capsule())
                    }
                    Image(systemName: showPastMeals ? "chevron.up" : "chevron.down")
                        .scaledFont(11).foregroundStyle(session.themeSecondaryText)
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if showPastMeals {
                if session.guestStore.pastMeals.isEmpty {
                    Text("No meals logged yet. Cook a recipe and rate it to start your history.")
                        .scaledFont(13)
                        .foregroundStyle(session.themeSecondaryText)
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
                    .scaledFont(20, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor).padding(.bottom, 8)
                Text("These two recipes look similar. Keep one, or keep both.")
                    .scaledFont(13).foregroundStyle(session.themeSecondaryText)
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
                        .scaledFont(14).foregroundStyle(session.themeSecondaryText)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                Spacer()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func mergeOption(recipe: UserRecipe, keepLabel: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recipe.title)
                .scaledFont(15, weight: .semibold, design: .serif)
                .foregroundStyle(session.themeTextColor)
            Text("\(recipe.ingredients.count) ingredients · Made \(recipe.cookCount)×")
                .scaledFont(12).foregroundStyle(session.themeSecondaryText)
            Button(action: action) {
                Text(keepLabel)
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
            }.buttonStyle(.plain)
        }
        .padding(14)
        .background(session.themeCardColor)
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
                        .scaledFont(38)
                        .foregroundStyle(session.accentColor)
                }
                Text("Browse Online Recipes")
                    .scaledFont(22, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                Text("Import recipes from 20+ trusted cooking sites.\nPaste a URL or search by cuisine.")
                    .scaledFont(14)
                    .foregroundStyle(session.themeSecondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button { showBrowseOnline = true } label: {
                Text("Open Recipe Browser")
                    .scaledFont(17, weight: .semibold, design: .serif)
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
                .scaledFont(14, weight: .bold).foregroundStyle(session.themeTextColor)
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
    @Environment(\.stockedMotion) private var motion
    let meal: LocalPastMeal

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Rectangle().fill(session.themeCardColor).frame(width: 80, height: 72)
                Image(systemName: "fork.knife").scaledFont(20)
                    .foregroundStyle(session.themeTextColor.opacity(0.25))
            }
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(Color.stockedGold)
                VStack(alignment: .leading) {
                    Text(meal.title)
                        .scaledFont(13, design: .serif).foregroundStyle(Color.stockedWhite)
                        .padding(.leading, 12).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                Text(meal.date)
                    .scaledFont(9, weight: .semibold).foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.stockedCharcoal).clipShape(Capsule()).padding(6)
            }.frame(maxWidth: .infinity).frame(height: 72)
            Button {
                motion.animate(.standard, intent: .spatial) {
                    session.guestStore.pastMeals.removeAll { $0.id == meal.id }
                }
            } label: {
                ZStack {
                    Color.red.frame(width: 56, height: 72)
                    Image(systemName: "trash.fill").scaledFont(16).foregroundStyle(.white)
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
                    .scaledFont(17, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                    .fixedSize(horizontal: false, vertical: true)

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
                        Image(systemName: "clock").scaledFont(12).foregroundStyle(Color.stockedGold)
                        Text(recipe.cookTime).scaledFont(12).foregroundStyle(session.themeSecondaryText)
                    }
                }

                if !recipe.ingredients.isEmpty {
                    Text("\(recipe.ingredients.count) ingredients")
                        .scaledFont(12, weight: .semibold)
                        .foregroundStyle(session.themeSecondaryText)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(recipe.ingredients.prefix(5)) { ing in
                            Text("• \(ing.name.displayNormalized)")
                                .scaledFont(12)
                                .foregroundStyle(session.themeSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if recipe.ingredients.count > 5 {
                            Text("+ \(recipe.ingredients.count - 5) more")
                                .scaledFont(11)
                                .foregroundStyle(session.themeSecondaryText)
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 300)
        .background(session.themeCardColor)
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd, style: .continuous)
                .stroke(session.themeContrastAccent.opacity(0.34), lineWidth: 1.25)
        }
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
                        .scaledFont(24, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text("\(recipes.count) recipe\(recipes.count == 1 ? "" : "s")")
                        .scaledFont(13)
                        .foregroundStyle(session.themeSecondaryText)
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
                                            .scaledFont(15, weight: .semibold)
                                            .foregroundStyle(session.themeTextColor)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if !recipe.cookTime.isEmpty {
                                            Text(recipe.cookTime).scaledFont(12)
                                                .foregroundStyle(session.themeSecondaryText)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .scaledFont(12, weight: .semibold)
                                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                                }
                                .padding(12)
                                .background(session.themeCardColor)
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
                            Image(systemName: "plus").scaledFont(14, weight: .bold)
                            Text("New Recipe").scaledFont(14, weight: .bold, design: .serif)
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
                        .scaledFont(24, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text("\(cuisines.count) collection\(cuisines.count == 1 ? "" : "s")")
                        .scaledFont(13)
                        .foregroundStyle(session.themeSecondaryText)
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
                                            .scaledFont(17)
                                    }
                                    Text(name)
                                        .scaledFont(15, weight: .semibold)
                                        .foregroundStyle(session.themeTextColor)
                                    Spacer()
                                    Text("\(count) recipe\(count == 1 ? "" : "s")")
                                        .scaledFont(12)
                                        .foregroundStyle(session.themeSecondaryText)
                                    Image(systemName: "chevron.right")
                                        .scaledFont(12, weight: .semibold)
                                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                                }
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .background(session.themeCardColor)
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
