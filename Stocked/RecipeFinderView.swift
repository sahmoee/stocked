import SwiftUI

@Observable @MainActor final class RecipeFinderSession {
    var flow = FinderFlow()
    var hits: [FinderHit] = []
    private var requestState = FinderRequestState()
    var count: Int { requestState.count }
    var loading: Bool { requestState.phase == .loading }
    var error: Bool { requestState.phase == .failed }
    var catalogueUnavailable = false
    var alternatives: [FinderAlternative] = []
    var limit = 60
    var shouldFocusSearch = false
    private var request: Task<Void, Never>?
    private var completedKey: String?

    func refresh(store: GuestDataStore, force: Bool = false) {
        guard store.hasCompletedInitialHydration else { _ = requestState.begin(); return }
        let key = "\(store.recipeRevision)|\(store.inventoryRevision)|\(store.pastMealsRevision)|\(RecipeDatabaseManager.shared.recipesVersion)|\(limit)|\(store.cookingProfile.allergens.sorted())"
        if !force, !loading, !error, completedKey == key, completedFilters == flow.filters { return }
        request?.cancel()
        let current = requestState.begin(), filters = flow.filters, limit = limit
        let saved = store.userRecipes, history = store.pastMeals, inventory = store.inventoryItems
        let allergens = store.cookingProfile.allergens
        request = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                let worker = Task.detached(priority: .utility) {
                    try await FinderService.query(filters: filters, saved: saved, history: history, inventory: inventory, allergens: allergens, limit: limit)
                }
                let response = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, requestState.complete(current, count: response.count) else { return }
                hits = response.hits; catalogueUnavailable = response.catalogueUnavailable
                alternatives = response.alternatives
                completedKey = key; completedFilters = filters
                UIAccessibility.post(notification: .announcement, argument: "\(count) recipes found")
                if count == 0 { AppAnalytics.shared.log(.finderNoResults) }
            } catch is CancellationError { }
            catch {
                guard let self else { return }
                _ = requestState.fail(current)
            }
        }
    }
    func cancel() { request?.cancel(); request = nil; requestState.cancel() }
    private var completedFilters: FinderFilters?
}

struct RecipeFinderView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Bindable var model: RecipeFinderSession
    @State private var showFilters = false
    @State private var showSort = false
    @State private var draftSort = FinderSort.bestMatch
    @State private var selected: FinderHit?
    @State private var cuisineQuery = ""
    @FocusState private var searchFocused: Bool
    private var surface: Color { RecipeCardStyle.surface(isDark: session.isDarkMode) }
    private var categories: [FinderCategory] { FinderCategory.allCases }
    private var showCount: String { model.loading ? "Finding matches…" : model.error ? "Show recipes" : "Show \(model.count) recipes" }

    var body: some View {
        VStack(spacing: 0) {
            header
            OfflineBanner()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch model.flow.phase {
                    case .quiz(let index): quiz(index)
                    case .review: review
                    case .results: results
                    }
                }.padding(18).frame(maxWidth: 850).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .foregroundStyle(session.themeTextColor)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showFilters) { filterSheet }
        .sheet(isPresented: $showSort) { sortSheet }
        .alert("Clear your choices?", isPresented: $model.flow.needsClearConfirmation) {
            Button("Keep choices", role: .cancel) { }
            Button("Clear all", role: .destructive) { model.flow.clear(); AppAnalytics.shared.log(.finderCleared) }
        } message: { Text("This will remove everything you’ve selected.") }
        .navigationDestination(item: $selected) { hit in
            if let entry = hit.databaseEntry {
                RecipeOverviewView(title: entry.title, servings: Int(entry.servings) ?? 4,
                    ingredients: entry.ingredients, steps: entry.steps, cookTime: entry.cookTime, prepTime: entry.prepTime)
            } else { UserRecipeDetailView(recipe: hit.recipe) }
        }
        .onAppear {
            refresh(); logStep()
            if model.shouldFocusSearch { searchFocused = true; model.shouldFocusSearch = false }
        }
        .onDisappear { model.cancel() }
        .onChange(of: model.flow.filters) { _, _ in model.limit = 60; refresh() }
        .onChange(of: model.flow.phase) { _, _ in searchFocused = false; refresh(); logStep() }
        .onChange(of: session.guestStore.inventoryRevision) { _, _ in refresh() }
        .onChange(of: session.guestStore.recipeRevision) { _, _ in refresh() }
        .onChange(of: session.guestStore.pastMealsRevision) { _, _ in refresh() }
        .onChange(of: RecipeDatabaseManager.shared.recipesVersion) { _, _ in refresh() }
        .onChange(of: session.guestStore.cookingProfile.allergens) { _, _ in refresh() }
        .onChange(of: session.guestStore.hasCompletedInitialHydration) { _, _ in refresh() }
    }

    private var header: some View {
        HStack {
            Button { if model.flow.back() { dismiss() } } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("Back")
            Text("Find a Recipe").font(.stockedSerif(22, weight: .bold, relativeTo: .title2))
                .frame(maxWidth: .infinity)
            Button("Clear") { model.flow.requestClear() }.frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(session.themeContrastAccent)
        }.font(.stocked(.body)).padding(.horizontal, 12)
            .padding(.top, StockedChrome.headerTopPadding).padding(.bottom, StockedChrome.headerBottomPadding)
    }

    private func progress(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(index) of 7").font(.stocked(.subheadline))
            ProgressView(value: Double(index), total: 7).tint(session.themeContrastAccent)
                .accessibilityLabel("Quiz progress").accessibilityValue("\(index) of 7")
        }
    }
    private func heading(_ text: String) -> some View {
        Text(text).font(.stockedSerif(30, weight: .bold, relativeTo: .title)).fixedSize(horizontal: false, vertical: true)
    }
    private func primary(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.stocked(.headline)).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 48).padding(8)
                .foregroundStyle(Color.stockedWhite).background(Color.stockedCharcoal, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }
    private func quiz(_ index: Int) -> some View {
        let category = categories[index]
        return VStack(alignment: .leading, spacing: 24) {
            progress(index + 1)
            heading(category.question)
            Text(category.instruction).font(.stocked(.body)).foregroundStyle(session.themeSecondaryText)
            options(category)
            if category == .diet { dietNote }
            if category == .kitchen { kitchenNote }
            HStack(spacing: 20) {
                Button("Skip") { model.flow.next(skip: true); AppAnalytics.shared.log(.finderStepSkipped) }
                    .font(.stocked(.headline)).frame(minWidth: 70, minHeight: 48)
                primary(model.flow.editingReview ? "Save choices" : "Next") { model.flow.next() }
            }
        }
    }
    private var dietNote: some View {
        Text("Nutrition and allergen-free filters aren’t available because recipe data cannot reliably verify them. Dietary labels are not an allergy-safety guarantee; check the original recipe and ingredient labels.")
            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
    }
    private var kitchenNote: some View {
        Text("Mostly means at least 70% of required ingredients. Full matches require confirmed amounts for the recipe’s stated servings. Unknown quantities are never counted as fully ready.")
            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
    }
    @ViewBuilder private func options(_ category: FinderCategory) -> some View {
        if category == .cuisine {
            TextField("Search cuisines", text: $cuisineQuery).font(.stocked(.body))
                .padding(12).frame(minHeight: 48).background(surface, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("Search cuisine options")
        }
        LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(category.options.filter { category != .cuisine || cuisineQuery.isEmpty || $0.isNeutral || $0.isDiscovery || FinderQuery.normalize($0.label).contains(FinderQuery.normalize(cuisineQuery)) }) { choice in
                let selected = model.flow.filters[category].contains(choice)
                Button {
                    model.flow.filters.toggle(choice, in: category)
                    AppAnalytics.shared.log(selected ? .finderOptionDeselected : .finderOptionSelected)
                    UIAccessibility.post(notification: .announcement, argument: "\(choice.label), \(selected ? "not selected" : "selected")")
                } label: {
                    VStack(spacing: 12) {
                        if category == .meal { Image(systemName: choice.icon).font(.stocked(.title)) }
                        HStack {
                            Text(choice.label).font(.stocked(.body).weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.stockedGoldDark) }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: category == .meal ? 100 : 48).padding(12)
                    .foregroundStyle(selected ? Color.stockedWhite : session.themeTextColor)
                    .background(selected ? Color.stockedCharcoal : surface, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? session.themeContrastAccent : session.themeSecondaryText.opacity(0.2), lineWidth: selected ? 2 : 1))
                }.buttonStyle(.plain)
                    .accessibilityLabel(choice.label).accessibilityValue(selected ? "Selected" : "Not selected")
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 18) {
            progress(7)
            heading("How does this sound?")
            Text("Adjust anything before we find your matches.").font(.stocked(.body))
            ForEach(categories) { category in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: category.icon).frame(width: 30, height: 44).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.title).font(.stocked(.headline))
                        StockedFlowLayout(spacing: 6, lineSpacing: 6) {
                            let choices = category.options.filter { model.flow.filters[category].contains($0) }
                            if choices.isEmpty { Text("Any").font(.stocked(.body)).foregroundStyle(session.themeSecondaryText) }
                            ForEach(choices) { choice in
                                Text(choice.label).font(.stocked(.subheadline)).padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(session.themeBgColor, in: Capsule())
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("Edit") { model.flow.edit(category); AppAnalytics.shared.log(.finderReviewEdited) }
                        .frame(minWidth: 44, minHeight: 44).foregroundStyle(session.themeContrastAccent)
                        .accessibilityLabel("Edit \(category.title)")
                }.padding(16).background(surface, in: RoundedRectangle(cornerRadius: 20))
            }
            if model.error { errorState }
            else if !model.loading && model.count == 0 { noMatchGuidance }
            primary(showCount) { model.flow.phase = .results; AppAnalytics.shared.log(.finderCompleted) }
            Button("Start over") { model.flow.requestClear() }.frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(session.themeContrastAccent)
        }
    }
    private func summary(_ category: FinderCategory) -> String {
        let selected = category.options.filter { model.flow.filters[category].contains($0) }.map(\.label)
        return selected.isEmpty ? "Any" : selected.joined(separator: ", ")
    }
    private var noMatchGuidance: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No exact matches").font(.stocked(.headline))
            Text("Some combinations aren’t in the current catalogue. You can edit your choices or broaden a preference below. Dietary and kitchen requirements stay the same.")
                .font(.stocked(.body)).foregroundStyle(session.themeSecondaryText)
            ForEach(model.alternatives) { alternative in
                Button {
                    model.flow.filters = alternative.filters
                    AppAnalytics.shared.log(.finderFiltersChanged)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(alternative.label)
                        Text("Show \(alternative.count) recipes").fontWeight(.semibold)
                    }.font(.stocked(.body)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.foregroundStyle(session.themeContrastAccent)
                    .accessibilityLabel("\(alternative.label). Show \(alternative.count) recipes. Adjust these preferences.")
            }
        }.padding(16).background(surface, in: RoundedRectangle(cornerRadius: 18))
    }
    private var search: some View {
        HStack {
            Image(systemName: "magnifyingglass").accessibilityHidden(true)
            TextField("Search these results", text: $model.flow.filters.query)
                .font(.stocked(.body)).focused($searchFocused).submitLabel(.search)
                .onSubmit { searchFocused = false; AppAnalytics.shared.log(.finderSearchSubmitted) }
                .accessibilityLabel("Search recipes or ingredients")
            if !model.flow.filters.query.isEmpty {
                Button { model.flow.filters.query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel("Clear search")
            }
        }.padding(.horizontal, 16).frame(minHeight: 54).background(surface, in: RoundedRectangle(cornerRadius: 18))
    }
    private var results: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading(model.loading ? "Finding recipes for you" : model.error ? "Recipes for you" : "\(model.count) recipes for you")
            search
            if !session.guestStore.cookingProfile.allergens.isEmpty {
                Text("Your saved allergen exclusions remain active. Always check the source recipe and ingredient labels.")
                    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(categories) { category in
                        ForEach(category.options.filter { model.flow.filters[category].contains($0) && !$0.isNeutral }) { choice in
                            Button { model.flow.filters.remove(choice, in: category); AppAnalytics.shared.log(.finderFilterRemoved) } label: {
                                Label(choice.label, systemImage: "xmark").font(.stocked(.subheadline)).padding(.horizontal, 14).frame(minHeight: 44)
                                    .background(surface, in: Capsule())
                            }.accessibilityLabel("Remove \(choice.label) filter")
                        }
                    }
                    Button("All filters") { showFilters = true }.font(.stocked(.subheadline).weight(.semibold))
                        .padding(.horizontal, 14).frame(minHeight: 44).overlay(Capsule().stroke(session.themeTextColor))
                }.padding(2)
            }
            HStack {
                Button { draftSort = model.flow.filters.sort; showSort = true; AppAnalytics.shared.log(.finderSortOpened) } label: {
                    Label(model.flow.filters.sort.label, systemImage: "slider.horizontal.3").font(.stocked(.headline)).frame(minHeight: 44)
                }.accessibilityLabel("Sort recipes, \(model.flow.filters.sort.label)")
                Spacer()
                Text(model.loading ? "Updating…" : "\(model.count) results").font(.stocked(.subheadline))
            }
            Text(model.catalogueUnavailable ? "Showing available local recipes. Some catalogue results are unavailable." : "Searching recipes stored on this device, including the last synced catalogue. New online recipes may be unavailable offline.")
                .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
            if model.loading { skeletons }
            else if model.error { errorState }
            else if model.hits.isEmpty { emptyState }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 155), spacing: 14)], spacing: 14) {
                    ForEach(model.hits) { hit in
                        ZStack(alignment: .topTrailing) {
                            Button { selected = hit; AppAnalytics.shared.log(.finderRecipeOpened) } label: { card(hit) }.buttonStyle(.plain)
                            Button { save(hit) } label: {
                                Image(systemName: hit.recipe.isFavorited ? "heart.fill" : "heart")
                                    .font(.stocked(.body)).frame(width: 44, height: 44)
                                    .background(surface, in: Circle()).padding(6)
                            }.buttonStyle(.plain)
                                .accessibilityLabel("\(hit.recipe.isFavorited ? "Unfavorite" : "Save") \(hit.recipe.title)")
                        }
                    }
                }
                if model.hits.count < model.count {
                    primary("Load more recipes") { model.limit += 60; model.refresh(store: session.guestStore) }
                }
            }
        }
    }
    private func card(_ hit: FinderHit) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CachedAsyncImage(url: hit.recipe.imageURL ?? "", imageData: hit.recipe.imageData,
                height: RecipeCardStyle.imageHeight, resolveName: hit.recipe.title, resolveCategory: hit.recipe.cuisine)
            VStack(alignment: .leading, spacing: 6) {
                Text(hit.recipe.title).font(.stockedSerif(RecipeCardStyle.titleSize, weight: .bold, relativeTo: .headline)).fixedSize(horizontal: false, vertical: true)
                if let rating = hit.record.rating {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(session.themeContrastAccent)
                    if let count = hit.record.ratingCount { Text("\(count) household \(count == 1 ? "rating" : "ratings")") }
                }
                if !hit.recipe.cuisine.isEmpty { Text(hit.recipe.cuisine) }
                if let time = hit.record.totalMinutes { Label("\(time) min", systemImage: "clock") }
                if hit.recipe.isFavorited { Label("Saved", systemImage: "heart.fill") }
                if model.flow.filters.usesInventory {
                    Text("You have \(hit.record.have) of \(hit.record.required) ingredients")
                    if hit.record.missing > 0 { Text("Missing \(hit.record.missing) ingredients") }
                    if hit.record.uncertain > 0 { Text("Check \(hit.record.uncertain) quantities") }
                }
            }.font(.stocked(.caption)).padding(RecipeCardStyle.padding).frame(maxWidth: .infinity, alignment: .leading)
        }.background(surface, in: RoundedRectangle(cornerRadius: 18)).clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(session.themeSecondaryText.opacity(0.2)))
            .accessibilityElement(children: .combine).accessibilityHint("Open recipe details")
    }
    private var skeletons: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155))]) {
            ForEach(0..<6) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    Rectangle().fill(surface).frame(height: RecipeCardStyle.imageHeight)
                    Text("Recipe title").font(.stocked(.headline))
                    Text("Cuisine · Total time").font(.stocked(.caption))
                }.padding(12).background(surface, in: RoundedRectangle(cornerRadius: 18)).redacted(reason: .placeholder)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Loading recipes")
    }
    private var errorState: some View {
        VStack(spacing: 12) {
            Text("We couldn’t load these recipes.").font(.stocked(.headline))
            primary("Try again") { model.refresh(store: session.guestStore, force: true) }
        }.padding(20).background(surface, in: RoundedRectangle(cornerRadius: 18))
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.flow.filters.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                heading("No exact matches")
                Text("Try removing a filter or exploring the closest matches.")
            } else {
                heading("We couldn’t find anything for ‘\(model.flow.filters.query)’.")
                Text("Check the spelling or try another recipe or ingredient.")
                Button("Clear query") { model.flow.filters.query = "" }.frame(minHeight: 44)
                Button("Find a Recipe") { model.flow.enteredBySearch = false; model.flow.phase = .quiz(0) }.frame(minHeight: 44)
            }
            primary("Adjust filters") { showFilters = true }
            if !model.alternatives.isEmpty { noMatchGuidance }
            Button("Clear all") { model.flow.requestClear() }.frame(minHeight: 44)
        }.font(.stocked(.body)).padding(20).background(surface, in: RoundedRectangle(cornerRadius: 18))
    }
    private var filterSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(categories) { category in
                        DisclosureGroup {
                            options(category)
                            if category == .diet { dietNote }
                            if category == .kitchen { kitchenNote }
                        } label: {
                            VStack(alignment: .leading) { Text(category.title).font(.stocked(.headline)); Text(summary(category)).font(.stocked(.caption)) }.padding(.vertical, 8)
                        }
                    }
                    primary(showCount) { showFilters = false; AppAnalytics.shared.log(.finderFiltersChanged) }
                }.padding(18)
            }.background(session.themeBgColor).foregroundStyle(session.themeTextColor)
                .navigationTitle("Filter recipes").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Clear all") { model.flow.filters = FinderFilters() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("Close", systemImage: "xmark") { showFilters = false } }
                }
        }.tint(session.themeContrastAccent).presentationBackground(session.themeBgColor)
    }
    private var sortSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(FinderSort.allCases) { sort in
                        Button { draftSort = sort } label: {
                            HStack(spacing: 14) {
                                Image(systemName: draftSort == sort ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(draftSort == sort ? session.themeContrastAccent : session.themeSecondaryText)
                                Text(sort.label).font(.stocked(.body)); Spacer()
                            }.frame(minHeight: 48)
                        }.buttonStyle(.plain).accessibilityValue(draftSort == sort ? "Selected" : "Not selected")
                            .accessibilityAddTraits(draftSort == sort ? .isSelected : [])
                    }
                    primary("Apply sort") { model.flow.filters.sort = draftSort; showSort = false; AppAnalytics.shared.log(.finderSortApplied) }
                }.padding(20)
            }.background(session.themeBgColor).foregroundStyle(session.themeTextColor)
                .navigationTitle("Sort recipes").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close", systemImage: "xmark") { showSort = false } } }
        }.presentationBackground(session.themeBgColor)
    }
    private func refresh() {
        if case .quiz = model.flow.phase, !showFilters { return }
        model.refresh(store: session.guestStore)
    }
    private func save(_ hit: FinderHit) {
        if hit.databaseEntry == nil {
            var recipe = hit.recipe; recipe.isFavorited.toggle()
            session.guestStore.updateUserRecipe(recipe)
        } else if let entry = hit.databaseEntry {
            var recipe = FinderData.recipe(entry, parseAmounts: true); recipe.isFavorited = true
            session.guestStore.addUserRecipe(recipe)
        }
        AppAnalytics.shared.log(.recipeSaved)
    }
    private func logStep() { if case .quiz = model.flow.phase { AppAnalytics.shared.log(.finderStepViewed) } }
}

extension FinderHit: Hashable {
    static func == (lhs: FinderHit, rhs: FinderHit) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
