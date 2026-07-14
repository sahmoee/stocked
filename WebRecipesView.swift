// WebRecipesView.swift
// Replaces OnlineRecipesView — shows complete recipes from qualified publisher libraries.
// Supports: source filtering, category tabs, full step-by-step detail,
// prep/cook time, servings, ratings, tags, and ingredient→grocery integration.

import SwiftUI

// MARK: - Main Web Recipes View
enum WebSheet: Identifiable {
    case detail(recipe: WebRecipe)
    case sourcePicker
    case importURL
    case manageSources
    var id: String {
        switch self {
        case .detail(let r): return "detail-\(r.id)"
        case .sourcePicker:  return "source"
        case .importURL:     return "import"
        case .manageSources: return "manage"
        }
    }
}

struct WebRecipesView: View {
    @Environment(AppSession.self) var session
    @State private var manager       = WebRecipeManager.shared
    @State private var searchText    = ""
    @State private var selectedSource: RecipeSource? = nil
    @State private var selectedCategory: RecipeSource.SourceCategory? = nil
    @State private var activeSheet: WebSheet? = nil
    @State private var importURL = ""
    @State private var maxCookMinutes: Int? = nil   // #15 cook-time filter (nil = any)

    let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var qualifiedSources: [RecipeSource] {
        var seen = Set<String>()
        return manager.recipes.compactMap { recipe in
            guard seen.insert(recipe.sourceDomain).inserted else { return nil }
            return RecipeSourceRegistry.source(for: recipe.sourceDomain) ?? RecipeSource(
                id: UUID(),
                domain: recipe.sourceDomain,
                displayName: recipe.sourceName.isEmpty ? recipe.sourceDomain : recipe.sourceName,
                category: .homeCook,
                specialty: "20+ complete cached recipes",
                iconEmoji: "🌐"
            )
        }
        .sorted { $0.displayName < $1.displayName }
    }

    // MARK: Filtered recipes
    var displayRecipes: [WebRecipe] {
        var base: [WebRecipe]
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            base = manager.recipes
        } else {
            // #14 fuzzy search across fields + relevance ranking by title.
            base = manager.recipes.filter { r in
                FuzzyMatch.matches(q, r.title) ||
                FuzzyMatch.matches(q, r.cuisine) ||
                FuzzyMatch.matches(q, r.category) ||
                FuzzyMatch.matches(q, r.sourceName) ||
                r.tags.contains { FuzzyMatch.matches(q, $0) } ||
                r.ingredients.contains { $0.lowercased().contains(q.lowercased()) }
            }
            .sorted { FuzzyMatch.score(q, $0.title) > FuzzyMatch.score(q, $1.title) }
        }
        if let src = selectedSource {
            base = base.filter { $0.sourceDomain == src.domain }
        } else if let cat = selectedCategory {
            base = base.filter {
                RecipeSourceRegistry.source(for: $0.sourceDomain)?.category == cat
            }
        }
        // #15 max cook-time filter (when set).
        if let maxMin = maxCookMinutes {
            base = base.filter { ($0.totalMinutes ?? $0.cookMinutes ?? 0) <= maxMin || ($0.totalMinutes == nil && $0.cookMinutes == nil) }
        }
        // #5 cross-source de-duplication so the same dish from two sites collapses.
        return RecipeDedup.dedupe(base, title: { $0.title }, ingredients: { $0.ingredients })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recipe Websites")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(session.themeTextColor)
                    Text("\(manager.recipes.count) recipes · \(qualifiedSources.count) qualified sources")
                        .font(.system(size: 10))
                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                }
                Spacer()
                HStack(spacing: 12) {
                    if manager.isLoading {
                        ProgressView().scaleEffect(0.7).tint(Color.stockedGold)
                    } else {
                        Button {
                            manager.forceRefreshAll(query: searchText)
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .font(.system(size: 12)).foregroundStyle(Color.stockedGold)
                        }.buttonStyle(.plain)
                    }
                    Button { activeSheet = .importURL } label: {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 14)).foregroundStyle(Color.stockedGold)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 10)

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                TextField("Search recipes, cuisines, ingredients…", text: $searchText)
                    .font(.system(size: 14)).foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(session.themeTextColor.opacity(0.35))
                    }
                }
            }
            .padding(10)
            .background(Color.stockedWhite.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .padding(.horizontal, 24).padding(.bottom, 10)

            // Category filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(
                        label: "All",
                        emoji: "🍽️",
                        isSelected: selectedCategory == nil && selectedSource == nil
                    ) {
                        selectedCategory = nil
                        selectedSource   = nil
                    }
                    ForEach(RecipeSource.SourceCategory.allCases, id: \.self) { cat in
                        FilterChip(
                            label: cat.rawValue,
                            emoji: categoryEmoji(cat),
                            isSelected: selectedCategory == cat && selectedSource == nil
                        ) {
                            selectedCategory = cat
                            selectedSource   = nil
                        }
                    }
                    Button {
                        activeSheet = .sourcePicker
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "slider.horizontal.3")
                            Text(selectedSource?.displayName ?? "Sources")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(selectedSource != nil ? Color.stockedGold : Color.stockedWhite.opacity(0.3))
                        .foregroundStyle(selectedSource != nil ? session.themeTextColor : session.themeTextColor.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                    }.buttonStyle(.plain)
                }
                .stockedScrollTargetLayout()
                .padding(.horizontal, 24)
            }
            .stockedHorizontalSnap()
            .padding(.bottom, 8)

            // #15 cook-time quick filters
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(label: "Any time", emoji: "⏱️", isSelected: maxCookMinutes == nil) {
                        maxCookMinutes = nil
                    }
                    FilterChip(label: "≤ 15 min", emoji: "⚡", isSelected: maxCookMinutes == 15) {
                        maxCookMinutes = maxCookMinutes == 15 ? nil : 15
                    }
                    FilterChip(label: "≤ 30 min", emoji: "🕧", isSelected: maxCookMinutes == 30) {
                        maxCookMinutes = maxCookMinutes == 30 ? nil : 30
                    }
                    FilterChip(label: "≤ 60 min", emoji: "🕐", isSelected: maxCookMinutes == 60) {
                        maxCookMinutes = maxCookMinutes == 60 ? nil : 60
                    }
                }
                .stockedScrollTargetLayout()
                .padding(.horizontal, 24)
            }
            .stockedHorizontalSnap()
            .padding(.bottom, 12)

            // Content
            if manager.recipes.isEmpty && manager.isLoading {
                SkeletonListView(count: 6).padding(.top, 10)
            } else if let err = manager.error, manager.recipes.isEmpty, !manager.isLoading {
                errorState(err)
            } else if displayRecipes.isEmpty && !manager.isLoading {
                emptyState
            } else {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(displayRecipes) { recipe in
                        Button { activeSheet = .detail(recipe: recipe) } label: {
                            WebRecipeCard(recipe: recipe)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, 20)
                .animation(.easeInOut(duration: 0.25), value: displayRecipes.count)
            }
        }
        .onAppear { manager.loadIfNeeded() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case let .detail(recipe):
                WebRecipeDetailView(recipe: recipe).environment(session)
            case .sourcePicker:
                SourcePickerSheet(
                    selected: $selectedSource,
                    sources: qualifiedSources,
                    onManageSources: { activeSheet = .manageSources }
                )
                    .environment(session)
            case .manageSources:
                RecipeSourcesManagerView().environment(session)
            case .importURL:
                URLImportSheet { url in
                    Task {
                        if let r = try? await manager.importFromURL(url) {
                            activeSheet = .detail(recipe: r)
                        }
                    }
                    if case .importURL = activeSheet { activeSheet = nil }
                }
                .environment(session)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "globe").font(.system(size: 36))
                .foregroundStyle(session.themeTextColor.opacity(0.2))
            Text("No qualified recipe sources yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(session.themeTextColor.opacity(0.5))
            Text("Tap Refresh to build complete source libraries. A website appears only after 20 unique full recipes are cached.")
                .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.4))
                .multilineTextAlignment(.center)
            Button { manager.forceRefreshAll() } label: {
                Text("Load Recipes")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(Color.stockedCharcoal).clipShape(Capsule())
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    // #16 distinct error state — separates "couldn't load" from "no matches".
    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 36))
                .foregroundStyle(Color.stockedError.opacity(0.7))
            Text("Couldn't load recipes")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(session.themeTextColor.opacity(0.6))
            Text(message)
                .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.4))
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button { manager.forceRefreshAll(query: searchText) } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(Color.stockedCharcoal).clipShape(Capsule())
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    private func categoryEmoji(_ cat: RecipeSource.SourceCategory) -> String {
        switch cat {
        case .flagship:      return "⭐"
        case .network:       return "📺"
        case .homeCook:      return "🏠"
        case .baking:        return "🥧"
        case .healthy:       return "💚"
        case .budget:        return "💰"
        case .world:         return "🌏"
        case .creative:      return "🎨"
        case .professional:  return "👨‍🍳"
        case .international: return "🗺️"
        }
    }
}

// MARK: - Filter Chip
struct FilterChip: View {
    @Environment(AppSession.self) var session
    let label:      String
    let emoji:      String
    let isSelected: Bool
    let action:     () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(emoji).font(.system(size: 11))
                Text(label).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(isSelected ? Color.stockedGold : Color.stockedWhite.opacity(0.3))
            .foregroundStyle(isSelected ? session.themeTextColor : session.themeTextColor.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        }.buttonStyle(.plain)
    }
}

// MARK: - Recipe Card
struct WebRecipeCard: View {
    @Environment(AppSession.self) var session
    let recipe: WebRecipe

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Image
CachedAsyncImage(url: recipe.imageURL.isEmpty ? nil : recipe.imageURL, imageData: nil, height: 120, resolveName: recipe.title, resolveCategory: recipe.category)
            .overlay(alignment: .topLeading) {
                // Source badge
                Text(sourceEmoji)
                    .font(.system(size: 14))
                    .padding(5)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if !recipe.displayTime.isEmpty {
                    let t = recipe.displayTime
                    Text(t)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.black.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(recipe.title)
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(recipe.sourceName)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.stockedGold)
                    if let r = recipe.rating {
                        Text("·")
                        Image(systemName: "star.fill").font(.system(size: 8))
                        Text(String(format: "%.1f", r))
                    }
                    Spacer()
                    if !recipe.difficulty.isEmpty {
                        Text(recipe.difficulty)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(difficultyColor)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(difficultyColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            .padding(10)
            .background(Color.stockedBg.opacity(0.6))
        }
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .shadow(color: .black.opacity(0.07), radius: 4, y: 2)
    }

    private var sourceEmoji: String {
        RecipeSourceRegistry.source(for: recipe.sourceDomain)?.iconEmoji ?? "🍽️"
    }

    private var sourceColorBlock: some View {
        ZStack {
            Color.stockedGold.opacity(0.8)
            VStack(spacing: 4) {
                Text(sourceEmoji).font(.system(size: 28))
                Text(recipe.sourceName).font(.system(size: 9)).foregroundStyle(.white)
            }
        }
        .frame(height: 120)
    }

    private var difficultyColor: Color {
        switch recipe.difficulty {
        case "Easy":    return .green
        case "Advanced": return .red
        default:        return .orange
        }
    }
}

// MARK: - Detail View
struct WebRecipeDetailView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    let recipe: WebRecipe

    @State private var addedIngredients   = false
    @State private var addedToCalendar    = false
    @State private var planningContext: CookLaterContext? = nil
    @State private var savedToCollection  = false
    @State private var activeTab: DetailTab = .steps
    @State private var startCooking       = false   // #15: Cook from WebRecipe

    enum DetailTab: String, CaseIterable {
        case steps       = "Steps"
        case ingredients = "Ingredients"
        case info        = "Info"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {

                        // Hero image
                        CachedAsyncImage(url: recipe.imageURL.isEmpty ? nil : recipe.imageURL, imageData: nil, height: 280, resolveName: recipe.title, resolveCategory: recipe.category)
                        .frame(maxWidth: .infinity).frame(height: 260)
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            // Source label overlay
                            HStack(spacing: 6) {
                                Text(RecipeSourceRegistry.source(for: recipe.sourceDomain)?.iconEmoji ?? "🍽️")
                                Text(recipe.sourceName)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            .padding(12)
                        }

                        // Title block
                        VStack(alignment: .leading, spacing: 10) {
                            Text(recipe.title)
                                .font(.system(size: 22, weight: .bold, design: .serif))
                                .foregroundStyle(session.themeTextColor)

                            if !recipe.description.isEmpty {
                                Text(recipe.description)
                                    .font(.system(size: 13))
                                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                                    .lineLimit(3)
                            }

                            // Quick-stat pills
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    if !recipe.displayTime.isEmpty {
                                        StatPill(icon: "clock", label: recipe.displayTime)
                                    }
                                    if !recipe.servings.isEmpty {
                                        StatPill(icon: "person.2", label: recipe.servings)
                                    }
                                    if !recipe.difficulty.isEmpty {
                                        StatPill(icon: "chart.bar", label: recipe.difficulty)
                                    }
                                    if let cal = recipe.calories, !cal.isEmpty {
                                        StatPill(icon: "flame", label: "\(cal) cal")
                                    }
                                    if let r = recipe.rating, let cnt = recipe.ratingCount {
                                        StatPill(icon: "star.fill", label: "\(String(format: "%.1f", r)) (\(cnt))")
                                    }
                                    if !recipe.cuisine.isEmpty {
                                        StatPill(icon: "globe", label: recipe.cuisine)
                                    }
                                }
                                .stockedScrollTargetLayout()
                            }
                            .stockedHorizontalSnap()
                        }
                        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)

                        // Action buttons
                        VStack(spacing: 10) {
                            Button {
                                autoFillIngredients()
                                withAnimation(.spring(response: 0.3)) { addedIngredients = true }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: addedIngredients ? "checkmark.circle.fill" : "cart.badge.plus")
                                    Text(addedIngredients ? "Added to grocery list!" : "Add missing ingredients to list")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(addedIngredients ? Color.stockedGreen : Color.stockedWhite)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(addedIngredients ? Color.stockedGreen.opacity(0.12) : Color.stockedCharcoal)
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                            }.disabled(addedIngredients)

                            // #15: Cook from this recipe — launches RecipeOverviewView
                            Button {
                                startCooking = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "flame.fill")
                                    Text("Start Cooking")
                                        .font(.system(size: 14, weight: .semibold, design: .serif))
                                }
                                .foregroundStyle(Color.stockedWhite)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Color.stockedGold)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }.buttonStyle(.plain)
                            .navigationDestination(isPresented: $startCooking) {
                                RecipeOverviewView(
                                    title:       recipe.title,
                                    servings:    Int(recipe.servings.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 4,
                                    ingredients: recipe.ingredients,
                                    steps:       recipe.steps.map { $0.text },
                                    cookTime:    recipe.cookTime,
                                    prepTime:    recipe.prepTime
                                ).environment(session)
                            }

                            Button {
                                let digits = recipe.servings.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                                planningContext = .recipe(
                                    title: recipe.title,
                                    ingredients: recipe.ingredients,
                                    servings: Int(digits) ?? max(1, session.guestStore.cookingProfile.householdSize),
                                    imageURL: recipe.imageURL,
                                    suggestedDay: 1
                                )
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: addedToCalendar ? "checkmark.circle.fill" : "calendar.badge.plus")
                                    Text(addedToCalendar ? "Planned in Cook Later" : "Plan in Cook Later")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(addedToCalendar ? Color.stockedGold : session.themeTextColor)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Color.stockedGold.opacity(addedToCalendar ? 0.18 : 0.10))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                                .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                                    .stroke(Color.stockedGold.opacity(0.4), lineWidth: 1))
                            }

                            // Save offline to My Collection
                            Button {
                                let ings = recipe.ingredients.map {
                                    RecipeIngredient(name: $0, amount: "")
                                }
                                var saved = UserRecipe(title: recipe.title)
                                saved.ingredients  = ings
                                saved.instructions = recipe.steps.map { $0.text }
                                saved.cookTime     = recipe.cookTime
                                saved.prepTime     = recipe.prepTime
                                saved.imageURL     = recipe.imageURL
                                saved.notes        = "Saved from \(recipe.sourceName): \(recipe.sourceURL)"
                                let srvDigits = recipe.servings.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                                if let n = Int(srvDigits), n > 0 { saved.servings = n }
                                session.guestStore.addUserRecipe(saved)
                                withAnimation(.spring(response: 0.3)) { savedToCollection = true }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: savedToCollection ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                                    Text(savedToCollection ? "Saved to My Collection!" : "Save to My Collection")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(savedToCollection ? Color.stockedGreen : Color.stockedWhite)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(savedToCollection ? Color.stockedGreen.opacity(0.12) : Color.stockedGold)
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                            }.disabled(savedToCollection)

                            // View on website
                            Link(destination: URL(string: recipe.sourceURL) ?? URL(string: "https://allrecipes.com")!) {
                                HStack(spacing: 8) {
                                    Image(systemName: "safari")
                                    Text("View on \(recipe.sourceName)")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .foregroundStyle(session.themeTextColor.opacity(0.6))
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color.stockedWhite.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 16)

                        // Tab selector
                        HStack(spacing: 0) {
                            ForEach(DetailTab.allCases, id: \.self) { tab in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab }
                                } label: {
                                    VStack(spacing: 4) {
                                        Text(tab.rawValue)
                                            .font(.system(size: 13, weight: activeTab == tab ? .semibold : .regular))
                                            .foregroundStyle(activeTab == tab ? Color.stockedGold : session.themeTextColor.opacity(0.5))
                                        Rectangle()
                                            .fill(activeTab == tab ? Color.stockedGold : Color.clear)
                                            .frame(height: 2)
                                    }
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 12)
                        .background(session.themeBgColor)

                        // Tab content
                        Group {
                            switch activeTab {
                            case .steps:       stepsTab
                            case .ingredients: ingredientsTab
                            case .info:        infoTab
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 50)
                    }
                }
            }
            .navigationTitle(recipe.sourceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.stockedGold)
                }
            }
        }
        .sheet(item: $planningContext) { context in
            NavigationStack {
                CookLaterWorkspaceView(context: context) {
                    withAnimation(.spring(response: 0.3)) { addedToCalendar = true }
                }
                .environment(session)
            }
        }
    }

    // MARK: Steps tab
    private var stepsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recipe.steps.isEmpty {
                Text("No step-by-step instructions available for this recipe. Tap \"View on \(recipe.sourceName)\" to see the full recipe.")
                    .font(.system(size: 14))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                    .padding(16)
                    .background(Color.stockedWhite.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                ForEach(recipe.steps) { step in
                    StepCard(step: step, themeColor: session.themeTextColor)
                }
            }
        }
    }

    // MARK: Ingredients tab
    private var ingredientsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            if recipe.ingredients.isEmpty {
                Text("Ingredients not available.")
                    .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    .padding(16).background(Color.stockedWhite.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                let inventoryLower = Set(session.guestStore.inventoryItems.map { $0.name.lowercased() })
                ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, ing in
                    let haveIt = inventoryLower.contains { $0.contains(ing.lowercased()) || ing.lowercased().contains($0) }
                    HStack(spacing: 12) {
                        Image(systemName: haveIt ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(haveIt ? Color.stockedGreen : Color.stockedGold.opacity(0.6))
                            .font(.system(size: 16))
                        Text(ing)
                            .font(.system(size: 14))
                            .foregroundStyle(haveIt ? session.themeTextColor.opacity(0.5) : session.themeTextColor)
                        Spacer()
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .background(haveIt ? Color.stockedGreen.opacity(0.05) : Color.stockedWhite.opacity(0.3))
                    Divider().padding(.leading, 42)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Info tab
    private var infoTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            InfoRow(label: "Source",    value: recipe.sourceName)
            if !recipe.category.isEmpty { InfoRow(label: "Category", value: recipe.category) }
            if !recipe.cuisine.isEmpty  { InfoRow(label: "Cuisine",  value: recipe.cuisine)  }
            if let prep = recipe.prepMinutes { InfoRow(label: "Prep Time",  value: "\(prep) min") }
            if let cook = recipe.cookMinutes { InfoRow(label: "Cook Time",  value: "\(cook) min") }
            if let tot  = recipe.totalMinutes { InfoRow(label: "Total Time", value: "\(tot) min") }
            if !recipe.servings.isEmpty { InfoRow(label: "Servings", value: recipe.servings) }
            if !recipe.difficulty.isEmpty { InfoRow(label: "Difficulty", value: recipe.difficulty) }
            if let cal = recipe.calories   { InfoRow(label: "Calories",  value: cal) }
            if let r   = recipe.rating     { InfoRow(label: "Rating",    value: "\(String(format: "%.1f", r))/5") }

            if !recipe.tags.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tags").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                    WebRecipeFlowLayout(tags: recipe.tags)
                }
                .padding(14)
                .background(Color.stockedWhite.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            }
        }
    }

    // MARK: Helpers
    private func autoFillIngredients() {
        let stockedLower = Set(session.guestStore.inventoryItems.map { $0.name.lowercased() })
        for ing in recipe.ingredients {
            let key = ing.lowercased()
            let inStock = stockedLower.contains { $0.contains(key) || key.contains($0) }
            let inGrocery = session.guestStore.groceryItems.contains {
                $0.name.lowercased().contains(key)
            }
            if !inStock && !inGrocery {
                session.guestStore.addToGroceryIfMissing(ing, recommended: true, recipeSource: recipe.title)
            }
        }
    }

}

// MARK: - Supporting sub-views

struct StepCard: View {
    @Environment(AppSession.self) var session
    let step: WebRecipe.RecipeStep
    let themeColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.stockedGold)
                    .frame(width: 28, height: 28)
                Text("\(step.index + 1)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(session.themeTextColor)
            }
            VStack(alignment: .leading, spacing: 10) {
                if let name = step.name, !name.isEmpty {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                }
                Text(step.text)
                    .font(.system(size: 14))
                    .foregroundStyle(themeColor.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.stockedWhite.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }
}

struct StatPill: View {
    let icon:  String
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.stockedWhite.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.stockedWhite.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }
}

struct WebRecipeFlowLayout: View {
    let tags: [String]
    var body: some View {
        // Wrapping tag cloud — uses the Layout-protocol flow (no GeometryReader)
        StockedFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(tags, id: \.self) { tag in
                TagView(tag: tag)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TagView: View {
    let tag: String
    var body: some View {
        Text(tag)
            .font(.system(size: 11))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.stockedGold.opacity(0.12))
            .foregroundStyle(Color.stockedGold)
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
    }
}

// MARK: - Source Picker Sheet
struct SourcePickerSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @Binding var selected: RecipeSource?
    let sources: [RecipeSource]
    var onManageSources: () -> Void = {}

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                List {
                    Button("All Sources") {
                        selected = nil; dismiss()
                    }
                    .foregroundStyle(selected == nil ? Color.stockedGold : session.themeTextColor)

                    Button {
                        onManageSources()
                    } label: {
                        Label("Add or Manage Sources", systemImage: "plus.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.stockedGold)
                    }

                    if sources.isEmpty {
                        Text("No source has reached 20 complete recipes yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(session.themeSecondaryText)
                    }

                    ForEach(RecipeSource.SourceCategory.allCases, id: \.self) { cat in
                        let categorySources = sources.filter { $0.category == cat }
                        if !categorySources.isEmpty {
                            Section(cat.rawValue) {
                                ForEach(categorySources) { src in
                                    Button {
                                        selected = src; dismiss()
                                    } label: {
                                        HStack {
                                            Text(src.iconEmoji)
                                            VStack(alignment: .leading, spacing: 10) {
                                                Text(src.displayName).font(.system(size: 14, weight: .medium))
                                                Text(src.specialty).font(.system(size: 11)).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if selected?.domain == src.domain {
                                                Image(systemName: "checkmark").foregroundStyle(Color.stockedGold)
                                            }
                                        }
                                    }
                                    .foregroundStyle(session.themeTextColor)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Recipe Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.stockedGold)
                }
            }
        }
    }
}

// MARK: - URL Import Sheet
struct URLImportSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @State private var url = ""
    @State private var isLoading = false
    @State private var errorMsg: String?
    let onImport: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 20) {
                    Text("Paste a direct recipe URL from a site that publishes standard recipe data:")
                        .font(.system(size: 14))
                        .foregroundStyle(session.themeTextColor.opacity(0.7))

                    TextField("https://www.seriouseats.com/recipe-name", text: $url)
                                           .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                        .font(.system(size: 13))
                        .padding(12)
                        .background(Color.stockedWhite.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    if let err = errorMsg {
                        Text(err).font(.system(size: 12)).foregroundStyle(.red)
                    }

                    Button {
                        guard !url.isEmpty else { return }
                        isLoading = true; errorMsg = nil
                        onImport(url)
                    } label: {
                        HStack {
                            if isLoading { ProgressView().tint(Color.stockedWhite) }
                            Text(isLoading ? "Importing…" : "Import Recipe")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(url.isEmpty ? Color.stockedCharcoal.opacity(0.4) : Color.stockedCharcoal)
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    }
                    .disabled(url.isEmpty || isLoading)

                    Text("Imported recipes are saved locally. A website is added to the source browser only after it has 20 complete recipes.")
                        .font(.system(size: 10))
                        .foregroundStyle(session.themeTextColor.opacity(0.35))

                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Import Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.stockedGold)
                }
            }
        }
    }
}


#Preview { WebRecipesView().environment(AppSession()) }
