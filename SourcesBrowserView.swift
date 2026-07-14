// SourcesBrowserView.swift — browse every recipe source, drill into any one, and the new
// Drinks section. All three views read from the same shared pool (Discover loader + the
// on-device database), so what appears here matches what search, the mood finder, and cook
// ranking see.
import SwiftUI

// MARK: - Sources list

struct SourcesBrowserView: View {
    @Environment(AppSession.self) private var session
    let pool: [OnlineRecipe]
    let onOpenRecipe: (OnlineRecipe) -> Void
    let onOpenSource: (String) -> Void

    @State private var query = ""
    @State private var showManage = false
    // The on-device database joins the loader pool so every ingested or imported recipe
    // counts toward its source. Loaded once per appearance.
    @State private var dbPool: [OnlineRecipe] = []

    private var mergedPool: [OnlineRecipe] { pool + dbPool }

    private var listings: [RecipeSourceHub.SourceListing] {
        let all = RecipeSourceHub.allSources(pool: mergedPool)
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return all }
        return all.filter { FuzzyMatch.matches(query, $0.name) || FuzzyMatch.matches(query, $0.specialty) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                let feeds = listings.filter { $0.isLiveFeed }
                let sites = listings.filter { !$0.isLiveFeed }

                Text("Sources appear after at least 20 unique, complete recipes are available. Counts are live.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(session.themeSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !feeds.isEmpty {
                    sectionLabel("Live Feeds")
                    ForEach(feeds) { row(for: $0) }
                }
                if !sites.isEmpty {
                    sectionLabel("Websites With Recipes")
                    ForEach(sites) { row(for: $0) }
                }
                if feeds.isEmpty && sites.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 28))
                            .foregroundStyle(session.themeSecondaryText.opacity(0.5))
                        Text(query.isEmpty ? "No qualified sources yet" : "No matching qualified sources")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                        Text("A source is shown only after Stocked has cached 20 complete recipes from it.")
                            .font(.system(size: 12))
                            .foregroundStyle(session.themeSecondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }

                Button { showManage = true } label: {
                    Label("Add or Manage Sources", systemImage: "plus.circle")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                            .fill(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.40)))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Recipe Sources")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search sources")
        .task {
            let entries = await RecipeDatabaseManager.shared.loadSnapshot()
            dbPool = RecipeSourceHub.poolEntries(from: entries)
        }
        .refreshable {
            let entries = await RecipeDatabaseManager.shared.loadSnapshot()
            dbPool = RecipeSourceHub.poolEntries(from: entries)
        }
        .sheet(isPresented: $showManage) {
            RecipeSourcesManagerView().environment(session)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(session.themeSecondaryText)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }

    private func row(for src: RecipeSourceHub.SourceListing) -> some View {
        Button {
            HapticManager.light()
            onOpenSource(src.name)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.stockedGold.opacity(0.14)).frame(width: 38, height: 38)
                    Text(src.emoji).font(.system(size: 17))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(src.name)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                            .lineLimit(1)
                        if src.isCustom {
                            Text("Yours")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.stockedGold.opacity(0.2)))
                                .foregroundStyle(Color.stockedGold)
                        }
                    }
                    Text(src.specialty)
                        .font(.system(size: 11.5))
                        .foregroundStyle(session.themeSecondaryText)
                        .lineLimit(1)
                }
                Spacer()
                if src.recipeCount > 0 {
                    Text("\(src.recipeCount)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.stockedGold)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                .fill(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.40)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(src.name), \(src.recipeCount) recipes available")
    }
}

// MARK: - Recipes from one source

struct SourceRecipesView: View {
    @Environment(AppSession.self) private var session
    let sourceName: String
    let pool: [OnlineRecipe]
    let onOpenRecipe: (OnlineRecipe) -> Void

    @State private var dbPool: [OnlineRecipe] = []

    private var recipes: [OnlineRecipe] {
        // Loader pool + database, deduplicated by normalized title so the same dish
        // ingested earlier doesn't show twice.
        var seen = Set<String>()
        var out: [OnlineRecipe] = []
        for r in RecipeSourceHub.recipes(from: sourceName, pool: pool + dbPool) {
            let key = OnlineRecipeFacts.normalizedTitle(r.title)
            if seen.insert(key).inserted { out.append(r) }
        }
        return out
    }

    var body: some View {
        ScrollView {
            if recipes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 34))
                        .foregroundStyle(session.themeSecondaryText.opacity(0.5))
                    Text("Nothing from \(sourceName) yet")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Recipes from this source appear here as they're pulled into Discover or imported. Pull down on the Recipes tab to refresh, or import any recipe by URL.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(session.themeSecondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                    ForEach(recipes) { r in
                        Button {
                            HapticManager.light()
                            onOpenRecipe(r)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CachedAsyncImage(url: r.imageURL, imageData: nil,
                                                 height: 110, resolveName: r.title)
                                    .frame(height: 110)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                                Text(r.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(session.themeTextColor)
                                    .lineLimit(2, reservesSpace: true)
                                    .multilineTextAlignment(.leading)
                                if !r.category.isEmpty {
                                    Text(r.category)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(session.themeSecondaryText)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle(sourceName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let entries = await RecipeDatabaseManager.shared.loadSnapshot()
            dbPool = RecipeSourceHub.poolEntries(from: entries)
        }
    }
}

// MARK: - Drinks section

struct DrinksBrowseView: View {
    @Environment(AppSession.self) private var session
    let pool: [OnlineRecipe]
    let onOpenRecipe: (OnlineRecipe) -> Void

    @State private var loaded: [OnlineRecipe] = []
    @State private var isLoading = false

    private var drinks: [OnlineRecipe] {
        // Pool drinks + any freshly fetched batch, deduplicated by id.
        var seen = Set<String>()
        var out: [OnlineRecipe] = []
        for r in RecipeSourceHub.drinks(pool: pool) + loaded where seen.insert(r.id).inserted {
            out.append(r)
        }
        return out
    }

    private var groups: [(String, [OnlineRecipe])] {
        // Group drinks by their category (Cocktail, Shake, Coffee / Tea, …).
        var buckets: [String: [OnlineRecipe]] = [:]
        for d in drinks {
            let key = d.category.isEmpty ? "Other" : d.category
            buckets[key, default: []].append(d)
        }
        return buckets.sorted { $0.value.count > $1.value.count }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if drinks.isEmpty && isLoading {
                    HStack {
                        Spacer()
                        ProgressView("Pouring the drinks list…")
                            .font(.system(size: 12.5))
                            .padding(.top, 60)
                        Spacer()
                    }
                } else if drinks.isEmpty {
                    VStack(spacing: 10) {
                        Text("🍹").font(.system(size: 40))
                        Text("No drinks yet")
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text("Pull down to fetch cocktails, mocktails, shots, and more from TheCocktailDB, the IBA official list, Open Drinks, and API Ninjas.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(session.themeSecondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 70)
                } else {
                    ForEach(groups, id: \.0) { name, items in
                        Text(name)
                            .font(.system(size: 15, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                            .padding(.horizontal, 24)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(items) { d in
                                    Button {
                                        HapticManager.light()
                                        onOpenRecipe(d)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            CachedAsyncImage(url: d.imageURL, imageData: nil,
                                                             height: 96, resolveName: d.title)
                                                .frame(width: 132, height: 96)
                                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                                            Text(d.title)
                                                .font(.system(size: 12.5, weight: .semibold))
                                                .foregroundStyle(session.themeTextColor)
                                                .lineLimit(2, reservesSpace: true)
                                                .multilineTextAlignment(.leading)
                                        }
                                        .frame(width: 132, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .stockedScrollTargetLayout()
                            .padding(.horizontal, 24)
                        }
                        .stockedHorizontalSnap()
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Drinks")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMoreDrinks() }
        .refreshable { await loadMoreDrinks() }
    }

    private func loadMoreDrinks() async {
        isLoading = true
        // Fan out to every drink source in parallel: TheCocktailDB, IBA Official,
        // Open Drinks, and API Ninjas (when keyed).
        let fresh = await DrinkSourcesPlus.fetchAllDrinks()
        // Cross-source sync: freshly fetched drinks join the shared on-device database
        // so search, the mood finder, and Discover's offline seed see them too.
        RecipeSourceHub.ingestIntoDatabase(fresh)
        loaded = fresh
        isLoading = false
    }
}
