// GlobalSearchView.swift — Unified search: inventory, recipes, grocery, food database, online
import SwiftUI

struct GlobalSearchView: View {
    @Environment(AppSession.self) var session
    @State private var query = ""
    @State private var onlineResults:    [OnlineRecipe] = []
    @State private var isSearchingOnline = false
    @State private var searchTask: Task<Void, Never>?   // #2 — cancel stale searches
    @State private var isOffline         = false
    @State private var offlineResultsCache: [String: [OnlineRecipe]] = [:]
    private let offlineCacheKey = "globalSearchOfflineCache_v1"
    @FocusState private var focused: Bool
    @Environment(\.dismiss) var dismiss
    // This view is shown via overlaySheet, where the native dismiss is a no-op; overlaySheet
    // injects stockedDismiss instead. Prefer it, fall back to native dismiss for any sheet use.
    @Environment(\.stockedDismiss) var stockedDismiss
    private func close() { if let stockedDismiss { stockedDismiss() } else { dismiss() } }
    @State private var selectedOnline: OnlineRecipe?
    @State private var selectedUserRecipe: UserRecipe?
    @State private var selectedFood: IngredientEntry?

    private var store: GuestDataStore { session.guestStore }
    private let cache = OfflineRecipeCache.shared

    enum SearchResult: Identifiable {
        case inventoryItem(LocalInventoryItem)
        case groceryItem(LocalGroceryItem)
        case userRecipe(UserRecipe)
        case pastMeal(LocalPastMeal)
        case cachedRecipe(CachedRecipe)
        case foodItem(IngredientEntry)
        case onlineRecipe(OnlineRecipe)
        // Improvement #10 — the app grew four whole data domains that search couldn't see.
        case tool(ToolboxTool)
        case leftover(LeftoverEntry)
        case containerLabel(ContainerLabel)
        case plannedMeal(PlannedMeal)

        var id: String {
            switch self {
            case .inventoryItem(let i):  return "inv_\(i.id)"
            case .groceryItem(let i):    return "groc_\(i.id)"
            case .userRecipe(let r):     return "urec_\(r.id)"
            case .pastMeal(let m):       return "past_\(m.id)"
            case .cachedRecipe(let r):   return "cache_\(r.id)"
            case .foodItem(let f):       return "food_\(f.id)"
            case .onlineRecipe(let r):   return "online_\(r.id)"
            case .tool(let t):           return "tool_\(t.rawValue)"
            case .leftover(let l):       return "left_\(l.id)"
            case .containerLabel(let c): return "label_\(c.id)"
            case .plannedMeal(let m):    return "meal_\(m.id)"
            }
        }
        var title: String {
            switch self {
            case .inventoryItem(let i):  return i.name
            case .groceryItem(let i):    return i.name
            case .userRecipe(let r):     return r.title
            case .pastMeal(let m):       return m.title
            case .cachedRecipe(let r):   return r.title
            case .foodItem(let f):       return f.name
            case .onlineRecipe(let r):   return r.title
            case .tool(let t):           return t.title
            case .leftover(let l):       return l.title
            case .containerLabel(let c): return c.contents
            case .plannedMeal(let m):    return m.title
            }
        }
        var subtitle: String {
            switch self {
            case .inventoryItem(let i):  return "\(i.zone) · \(Int(i.effectiveLevel * 100))% stocked"
            case .groceryItem(let i):    return i.isChecked ? "Checked off" : "On your list"
            case .userRecipe(let r):     return r.description.isEmpty ? "My Recipe" : r.description
            case .pastMeal(let m):       return "Cooked \(m.date)"
            case .cachedRecipe(let r):   return "\(r.area) · \(r.source)"
            case .foodItem(let f):       return f.category
            case .onlineRecipe(let r):   return "\(r.area) · \(r.category)"
            case .tool(let t):           return t.subtitle
            case .leftover(let l):       return l.isExpired ? "Past date" : "\(l.portions) portion\(l.portions == 1 ? "" : "s") · \(l.daysLeft)d left"
            case .containerLabel(let c): return "\(c.storage) · labelled \(c.filledOn.formatted(date: .abbreviated, time: .omitted))"
            case .plannedMeal(let m):    return m.isCooked ? "Cooked" : "\(m.mealType) · day \(m.dayIndex)"
            }
        }
        var icon: String {
            switch self {
            case .inventoryItem:  return "refrigerator.fill"
            case .groceryItem:    return "cart.fill"
            case .userRecipe:     return "book.fill"
            case .pastMeal:       return "clock.arrow.circlepath"
            case .cachedRecipe:   return "globe"
            case .foodItem:       return "leaf.fill"
            case .onlineRecipe:   return "network"
            case .tool(let t):    return t.icon
            case .leftover:       return "takeoutbag.and.cup.and.straw"
            case .containerLabel: return "qrcode"
            case .plannedMeal:    return "calendar"
            }
        }
        var sourceLabel: String {
            switch self {
            case .inventoryItem:      return "Pantry"
            case .groceryItem:        return "Grocery"
            case .userRecipe:         return "My Recipes"
            case .pastMeal:           return "History"
            case .cachedRecipe(let r): return r.source
            case .foodItem:           return "Food DB"
            case .onlineRecipe:       return "Online"
            case .tool:               return "Toolbox"
            case .leftover:           return "Leftovers"
            case .containerLabel:     return "Labels"
            case .plannedMeal:        return "Meal Plan"
            }
        }
        var sourceTint: Color {
            switch self {
            case .inventoryItem:  return Color.stockedGreen
            case .groceryItem:    return Color.stockedInfo
            case .userRecipe:     return Color.stockedCharcoal
            case .pastMeal:       return Color.orange
            case .cachedRecipe:   return Color.stockedGold
            case .foodItem:       return Color.stockedSuccess
            case .onlineRecipe:   return Color.purple
            case .tool:           return Color.stockedGold
            case .leftover:       return Color.orange
            case .containerLabel: return Color.stockedInfo
            case .plannedMeal:    return Color.stockedGreen
            }
        }
    }

    // ── NL-parsed query ────────────────────────────────────────────────
    private var parsedQuery: ParsedQuery { NLQueryParser.parse(query) }

    // ── Did You Mean — fuzzy match against KB ──────────────────────────
    private var didYouMean: String? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 3, localResults.isEmpty && onlineResults.isEmpty else { return nil }
        // Find closest ingredient/recipe name by character overlap
        let kb = StockedKnowledgeBase.shared.ingredients.map { $0.name.lowercased() }
        return kb.first { name in
            let overlap = Set(q).intersection(Set(name))
            return overlap.count >= min(q.count, name.count) - 1 && abs(q.count - name.count) <= 2
        }?.capitalized
    }

    private var localResults: [SearchResult] {
        let q  = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let pq = parsedQuery
        var scored: [(result: SearchResult, score: Int)] = []

        func s(_ item: SearchResult, _ boost: Int) { scored.append((item, boost)) }

        // Exact title matches → score 100
        store.inventoryItems.filter { $0.name.lowercased() == q }.forEach { s(.inventoryItem($0), 100) }
        store.userRecipes.filter { $0.title.lowercased() == q }.forEach { s(.userRecipe($0), 100) }

        // Contains match on pantry
        store.inventoryItems.filter { $0.name.lowercased().contains(q) && $0.name.lowercased() != q }
            .forEach { s(.inventoryItem($0), 80) }
        // Grocery
        store.groceryItems.filter { $0.name.lowercased().contains(q) }.forEach { s(.groceryItem($0), 70) }
        // User recipes (title)
        store.userRecipes.filter { $0.title.lowercased().contains(q) && $0.title.lowercased() != q }
            .forEach { s(.userRecipe($0), 75) }
        // User recipes (ingredient)
        store.userRecipes.filter { $0.ingredients.contains { $0.name.lowercased().contains(q) } }
            .forEach { s(.userRecipe($0), 60) }
        // Past meals
        store.pastMeals.filter { $0.title.lowercased().contains(q) }.forEach { s(.pastMeal($0), 65) }
        // Cached online — apply NL filters
        let cachedHits = cache.search(q)
        let filtered = cachedHits.filter { r in
            guard pq.hasStructure else { return true }
            // Convert CachedRecipe → temp RecipeDatabaseEntry for NL filter
            let classification = RecipeClassifier.classify(
                title: r.title,
                rawCuisine: r.area,
                rawCategory: r.category,
                keywords: [],
                ingredients: r.ingredients.map { RecipeIngredient(name: $0, amount: "") },
                instructions: r.steps
            )
            let tmp = RecipeDatabaseEntry(
                title: r.title, description: "", sourceURL: "", sourceName: r.source,
                prepTime: r.prepTime ?? "", cookTime: r.cookTime ?? "", totalTime: r.totalTime ?? "",
                servings: "", category: classification.category, cuisine: classification.cuisine, tags: classification.tags,
                ingredients: r.ingredients, steps: r.steps, imageURL: r.imageURL, cachedAt: r.cachedAt
            )
            return NLQueryParser.matches(tmp, query: pq)
        }
        filtered.prefix(8).forEach { s(.cachedRecipe($0), 50) }
        // KB food items
        StockedKnowledgeBase.shared.suggestIngredients(prefix: q, limit: 6)
            .forEach { s(.foodItem($0.asIngredientEntry), 30) }

        // ── Improvement #10 ─────────────────────────────────────────────────
        // Four domains search couldn't previously see at all. Scored against the existing ladder:
        // a leftover about to go off outranks a pantry substring match, because it's the more
        // urgent answer; tools sit just under recipes since "where is that thing" is the query
        // they answer.
        LeftoversStore.shared.queue
            .filter { $0.title.lowercased().contains(q) }
            .forEach { s(.leftover($0), $0.daysLeft <= 1 ? 90 : 68) }

        // Tools are matched fuzzily — the toolbox already uses FuzzyMatch, and a user searching
        // "convert" should find "Unit Converter".
        ToolboxTool.allCases
            .filter { FuzzyMatch.matches(q, $0.title) || $0.subtitle.lowercased().contains(q) }
            .prefix(5)
            .forEach { s(.tool($0), $0.title.lowercased() == q ? 95 : 55) }

        store.plannedMeals
            .filter { !$0.isBuilding && $0.title.lowercased().contains(q) }
            .forEach { s(.plannedMeal($0), 72) }

        ContainerLabelStore.shared.byAge
            .filter { $0.contents.lowercased().contains(q) }
            .forEach { s(.containerLabel($0), 66) }

        // Deduplicate by id, sort by score descending
        var seen = Set<String>()
        return scored
            .sorted { $0.score > $1.score }
            .compactMap { item -> SearchResult? in
                let key = item.result.id
                guard seen.insert(key).inserted else { return nil }
                return item.result
            }
    }

    // Grouped results by type (#19)
    private var groupedResults: [(String, [SearchResult])] {
        let all = allResults
        let pantry    = all.filter { if case .inventoryItem = $0 { return true }; return false }
        let grocery   = all.filter { if case .groceryItem   = $0 { return true }; return false }
        let recipes   = all.filter {
            if case .userRecipe   = $0 { return true }
            if case .pastMeal     = $0 { return true }
            if case .cachedRecipe = $0 { return true }
            return false
        }
        let online    = all.filter { if case .onlineRecipe = $0 { return true }; return false }
        let foods     = all.filter { if case .foodItem     = $0 { return true }; return false }
        // #10 — the four new domains.
        let leftovers = all.filter { if case .leftover      = $0 { return true }; return false }
        let meals     = all.filter { if case .plannedMeal   = $0 { return true }; return false }
        let tools     = all.filter { if case .tool          = $0 { return true }; return false }
        let labels    = all.filter { if case .containerLabel = $0 { return true }; return false }

        var groups: [(String, [SearchResult])] = []
        if !pantry.isEmpty    { groups.append(("In Your Pantry", pantry)) }
        // Leftovers sit directly under the pantry: they're food you have, just in a different form.
        if !leftovers.isEmpty { groups.append(("Leftovers", leftovers)) }
        if !labels.isEmpty    { groups.append(("Labelled Containers", labels)) }
        if !grocery.isEmpty   { groups.append(("Grocery List", grocery)) }
        if !meals.isEmpty     { groups.append(("Planned Meals", meals)) }
        if !recipes.isEmpty   { groups.append(("Recipes", recipes)) }
        if !tools.isEmpty     { groups.append(("Tools", tools)) }
        if !online.isEmpty    { groups.append(("Online", online)) }
        if !foods.isEmpty     { groups.append(("Ingredients", foods)) }
        return groups
    }

    private var allResults: [SearchResult] {
        var out = localResults
        out += onlineResults.prefix(6).map { .onlineRecipe($0) }
        return out
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(session.themeTextColor.opacity(0.4))
                        TextField("Recipes, ingredients, pantry items…", text: $query)
                            .font(.system(size: 15))
                            .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                            .focused($focused)
                            .onChange(of: query) { _, new in searchOnline(new) }
                        if !query.isEmpty {
                            Button { query = ""; onlineResults = [] } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(session.themeTextColor.opacity(0.3))
                            }
                        }
                        if isSearchingOnline {
                            ProgressView().scaleEffect(0.6).tint(Color.stockedGold)
                        }
                        if isOffline {
                            Image(systemName: "wifi.slash").font(.system(size: 12))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(12).background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: 14))
                    Button("Cancel") {
                        focused = false                       // dismiss the keyboard first
                        query = ""
                        onlineResults = []
                        close()
                    }
                        .font(.system(size: 15)).foregroundStyle(Color.stockedGold)
                }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 14)
                    .padding(.top, StockedScreen.safeTopInset)

                // Section label
                if !query.isEmpty {
                    HStack {
                        Text("\(allResults.count) result\(allResults.count == 1 ? "" : "s")\(parsedQuery.hasStructure ? " · filtered" : "")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                        Spacer()
                    }.padding(.horizontal, 20).padding(.bottom, 4)
                }

                if allResults.isEmpty && !query.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.system(size: 32))
                            .foregroundStyle(session.themeTextColor.opacity(0.2))
                        Text("No results for \"\(query)\"")
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        if let suggestion = didYouMean {
                            Button { query = suggestion } label: {
                                HStack(spacing: 4) {
                                    Text("Did you mean").font(.system(size: 13))
                                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                                    Text(suggestion).font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Color.stockedGold)
                                    Text("?").font(.system(size: 13))
                                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                                }
                            }.buttonStyle(.plain)
                        } else {
                            Text("Try: \"quick chicken\", \"no dairy pasta\", \"Indian breakfast\"")
                                .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.45))
                                .multilineTextAlignment(.center)
                        }
                    }.padding(.top, 48)
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groupedResults, id: \.0) { section, results in
                                Text(section)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.stockedGold)
                                    .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
                                ForEach(results) { r in rowView(r) }
                            }
                            Color.clear.frame(height: 40)
                        }
                    }
                    .scrollDismissesKeyboard(.immediately)
                }
            }
        }
        .onAppear {
            focused = true
            loadOfflineCache()
            // Preload meal plan recipes in background (#20)
            Task { await preloadMealPlanRecipes() }
        }
        .presentationDetents([.large])
        .sheet(item: $selectedOnline) { recipe in
            OnlineRecipeDetailView(recipe: recipe).environment(session)
        }
        .sheet(item: $selectedUserRecipe) { recipe in
            NavigationStack { UserRecipeDetailView(recipe: recipe).environment(session) }
        }
        .sheet(item: $selectedFood) { food in
            IngredientInfoSheet(entry: food).environment(session)
        }
    }

    private func loadOfflineCache() {
        guard let data    = UserDefaults.standard.data(forKey: offlineCacheKey),
              let decoded = try? JSONDecoder().decode([String: [OnlineRecipe]].self, from: data)
        else { return }
        offlineResultsCache = decoded
    }

    private func saveOfflineCache(_ results: [OnlineRecipe], for query: String) {
        offlineResultsCache[query.lowercased()] = results
        if let data = try? JSONEncoder().encode(offlineResultsCache) {
            UserDefaults.standard.set(data, forKey: offlineCacheKey)
        }
    }

    /// Dismiss the search sheet and switch to the given tab (used when a tapped result lives
    /// in one of the main tabs, e.g. a pantry or grocery item).
    private func navigate(to tab: StockedTab) {
        focused = false
        NotificationCenter.default.post(name: .stockedSwitchTab, object: tab)
    }

    private var cachedOfflineResults: [OnlineRecipe] {
        let lower = query.lowercased()
        return (offlineResultsCache[lower] ??
                offlineResultsCache.first { $0.key.contains(lower) }?.value ?? [])
            .prefix(8).map { $0 }
    }

    private func preloadMealPlanRecipes() async {
        let snap = await RecipeDatabaseManager.shared.loadSnapshot()
        let urls = snap.prefix(20).compactMap { $0.imageURL.isEmpty ? nil : $0.imageURL }
        ImageCache.shared.prefetch(urls: urls)
    }

    private func searchOnline(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        // #2 — cancel any in-flight/obsolete search so a slow older keystroke can't
        // overwrite newer results or waste the network.
        searchTask?.cancel()
        guard trimmed.count >= 3 else { onlineResults = []; isSearchingOnline = false; return }
        isSearchingOnline = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // debounce 0.5s
            if Task.isCancelled { return }
            guard query.trimmingCharacters(in: .whitespaces) == trimmed else { return }
            let enc = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/search.php?s=\(enc)"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let meals = json["meals"] as? [[String: Any]] else {
                if Task.isCancelled { return }
                // Network failed — serve offline cache
                await MainActor.run {
                    isSearchingOnline = false
                    isOffline = true
                    if onlineResults.isEmpty { onlineResults = cachedOfflineResults }
                }
                return
            }
            if Task.isCancelled { return }
            let loader = OnlineRecipesLoader()
            let parsed = meals.compactMap { loader.parseMealPublic($0) }
            if Task.isCancelled { return }
            await MainActor.run {
                onlineResults = parsed
                isSearchingOnline = false
                isOffline = false
                saveOfflineCache(parsed, for: trimmed)
            }
        }
    }

    private func handleSelect(_ r: SearchResult) {
        // Track open for popularity ranking (#19)
        if case .cachedRecipe(let recipe) = r {
            Task { await RecipeDatabaseManager.shared.recordOpen(id: recipe.id) }
        }
    }

    @ViewBuilder
    private func rowView(_ r: SearchResult) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(r.sourceTint.opacity(0.15)).frame(width: 42, height: 42)
                    Image(systemName: r.icon).font(.system(size: 16)).foregroundStyle(r.sourceTint)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(r.title).font(.system(size: 14, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text(r.subtitle).font(.system(size: 12))
                        .foregroundStyle(session.themeTextColor.opacity(0.45)).lineLimit(1)
                }
                Spacer()
                Text(r.sourceLabel).font(.system(size: 9, weight: .bold))
                    .foregroundStyle(r.sourceTint)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(r.sourceTint.opacity(0.12)).clipShape(Capsule())
            }
            .padding(.horizontal, 20).padding(.vertical, 11).contentShape(Rectangle())
            .onTapGesture {
                focused = false
                switch r {
                case .onlineRecipe(let recipe):
                    selectedOnline = recipe
                case .cachedRecipe(let recipe):
                    // Cached recipes carry the same fields as an online recipe — present them
                    // through the same detail view.
                    selectedOnline = OnlineRecipe(
                        id: recipe.mealID,
                        title: recipe.title,
                        category: recipe.category,
                        area: recipe.area,
                        instructions: recipe.steps.joined(separator: "\n"),
                        imageURL: recipe.imageURL,
                        ingredients: recipe.ingredients,
                        measures: Array(repeating: "", count: recipe.ingredients.count),
                        source: recipe.source)
                case .userRecipe(let recipe):
                    selectedUserRecipe = recipe
                case .foodItem(let food):
                    selectedFood = food          // "learn more" about an ingredient
                case .inventoryItem:
                    close(); navigate(to: .inventory)
                case .groceryItem:
                    close(); navigate(to: .grocery)
                case .pastMeal:
                    close(); navigate(to: .recipes)
                // ── Improvement #10 ─────────────────────────────────────────
                // Leftovers and labels both live under Inventory; planned meals under Cook.
                // Tools deep-link into the Toolbox via the existing tab-switch notification,
                // so no new navigation plumbing is needed.
                case .leftover, .containerLabel:
                    close(); navigate(to: .inventory)
                case .plannedMeal:
                    close(); navigate(to: .cook)
                case .tool:
                    close(); navigate(to: .home)
                }
            }
            Divider().padding(.leading, 76)
        }
    }
}

// MARK: - Ingredient info ("learn more" for a food-database item)
// Shown when the user taps a food-database result in Global Search — especially useful for
// an ingredient they've never used and want to learn about.
struct IngredientInfoSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    let entry: IngredientEntry

    private var shelfText: String {
        if entry.typicalShelfDays >= 365 { return "About a year or more (shelf-stable)" }
        if entry.typicalShelfDays >= 30  { return "About \(entry.typicalShelfDays / 30) month\(entry.typicalShelfDays / 30 == 1 ? "" : "s")" }
        return "About \(entry.typicalShelfDays) day\(entry.typicalShelfDays == 1 ? "" : "s")"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        Text(entry.emoji).font(.system(size: 44))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.system(size: 24, weight: .bold, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                            Text(entry.category)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.stockedGold)
                        }
                    }

                    infoRow(icon: "calendar", title: "Typical shelf life", value: shelfText)
                    infoRow(icon: entry.isPerishable ? "thermometer.snowflake" : "shippingbox",
                            title: "Storage",
                            value: entry.isPerishable ? "Perishable — keep refrigerated or use soon" : "Shelf-stable — store in the pantry")
                    if let g = entry.averageWeightG {
                        infoRow(icon: "scalemass", title: "Average weight", value: "≈ \(Int(g)) g each")
                    }
                    if !entry.synonyms.isEmpty {
                        infoRow(icon: "textformat", title: "Also known as", value: entry.synonyms.joined(separator: ", "))
                    }

                    Button {
                        dismiss()
                        NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.inventory)
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add to my kitchen")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(session.themeButtonColor)
                        .clipShape(Capsule())
                    }.buttonStyle(.plain).padding(.top, 4)
                }
                .padding(20)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.stockedGold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Color.stockedGold).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.5))
                Text(value).font(.system(size: 14)).foregroundStyle(session.themeTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}
