import SwiftUI

@Observable @MainActor final class RecipeFinderSession {
  var flow = FinderFlow()
  var hits: [FinderHit] = []
  private var requestState = FinderRequestState()
  var count: Int { requestState.count }
  var canReportCount: Bool {
    requestState.canReportCount(catalogueLoading: HarvestRecipeSync.shared.refreshingCatalogue,
                               query: flow.filters.query)
  }
  var countIsFinal: Bool { requestState.phase == .ready }
  /// Blocking initial load. Once a preview has real matches, the result screen is
  /// ready even if optional sources are still being checked in the background.
  var loading: Bool { requestState.isBlocking }
  var enriching: Bool { requestState.isWorking && !requestState.isBlocking }
  private var working: Bool { requestState.isWorking }
  var error: Bool { requestState.phase == .failed }
  var catalogueUnavailable = false
  var alternatives: [FinderAlternative] = []
  var webUnavailable = false
  var limit = 30
  private var request: Task<Void, Never>?
  private var completedKey: String?
  private var requestedKey: String?
  private var requestedFilters: FinderFilters?
  private var webCache: WebRecipeFetcher.DiscoveryBatch?
  private var webKey = ""
  private var webAt = Date.distantPast

  func refresh(store: GuestDataStore, force: Bool = false) {
    guard store.hasCompletedInitialHydration else {
      _ = requestState.begin()
      return
    }
    let key =
      "\(ConnectivityMonitor.isOnlineFlag)|\(store.recipeRevision)|\(store.inventoryRevision)|\(store.pastMealsRevision)|\(RecipeDatabaseManager.shared.recipesVersion)|\(RecipeDatabaseManager.shared.catalogueRevision)|\(limit)|\(store.cookingProfile.allergens.sorted())"
    if !force, requestState.phase == .ready, completedKey == key, completedFilters == flow.filters { return }
    if !force, working, requestedKey == key, requestedFilters == flow.filters { return }
    request?.cancel()
    if requestedFilters != flow.filters {
      hits = []
      alternatives = []
    }
    requestedKey = key
    requestedFilters = flow.filters
    let current = requestState.begin()
    let filters = flow.filters
    let limit = limit
    let saved = store.userRecipes
    let history = store.pastMeals
    let inventory = store.inventoryItems
    let allergens = store.cookingProfile.allergens
    let online = ConnectivityMonitor.isOnlineFlag
    webUnavailable = false
    catalogueUnavailable = false
    let now = Date()
    let pantrySeeds = KitchenAvailability.availableItems(in: inventory)
      .filter { $0.quantity > 0 && ($0.expirationDate == nil || $0.expirationDate! >= now) }
      .prefix(3).map { IngredientMatcher.canonical($0.name) }
    let terms = FinderWebPolicy.terms(filters, inventoryNames: pantrySeeds)
    let searchKey = terms.joined(separator: "|")
    let cached =
      !force && webKey == searchKey && Date().timeIntervalSince(webAt) < 600 ? webCache : nil
    request = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(300))
        QARecorder.shared.record(.note, screen: "Recipe Results", label: "Recipe search started")
        // Web retrieval and disk search overlap. A slow publisher must never
        // hold cached recipes behind a full-screen skeleton (STK-89-0140/41).
        async let discovery = Self.discover(terms: terms, cached: cached, online: online)
        let publish: @Sendable (FinderResponse) async -> Void = { [weak self] response in
          await self?.acceptPreview(response, token: current)
        }
        let worker = Task.detached(priority: .utility) {
          try await FinderService.query(
            filters: filters, saved: saved, history: history,
            inventory: inventory, allergens: allergens, limit: limit, onProgress: publish)
        }
        let local: FinderResponse
        do {
          local = try await withTaskCancellationHandler {
            try await worker.value
          } onCancel: {
            worker.cancel()
          }
        } catch is CancellationError { throw CancellationError() } catch {
          local = FinderResponse(hits: [], count: 0, catalogueUnavailable: true)
        }
        await publish(local)
        let batch = await discovery
        try Task.checkCancellation()
        let merger = Task.detached(priority: .utility) {
          let web = try FinderService.webQuery(
            batch?.recipes ?? [], filters: filters,
            saved: saved, history: history, inventory: inventory, allergens: allergens)
          return FinderService.merge(local: local, web: web, filters: filters, limit: limit)
        }
        let response = try await withTaskCancellationHandler {
          try await merger.value
        } onCancel: {
          merger.cancel()
        }
        try Task.checkCancellation()
        if response.count == 0 && local.catalogueUnavailable { throw CocoaError(.fileReadUnknown) }
        guard let self, requestState.complete(current, count: response.count) else { return }
        mergeVisible(response.hits)
        catalogueUnavailable = response.catalogueUnavailable
        alternatives = response.alternatives
        webUnavailable = online && (batch?.reachedSources ?? 0) == 0
        if let batch {
          webCache = batch
          webKey = searchKey
          webAt = Date()
        }
        completedKey = key
        completedFilters = filters
        QARecorder.shared.record(
          .success, screen: "Recipe Results", label: "Recipe search completed",
          detail:
            "\(count) matches; partial catalogue: \(catalogueUnavailable); web unavailable: \(webUnavailable)"
        )
        if count == 0 { AppAnalytics.shared.log(.finderNoResults) }
      } catch is CancellationError {} catch {
        guard let self, requestState.fail(current) else { return }
        QARecorder.shared.record(
          .failure, screen: "Recipe Results", label: "Recipe search failed",
          detail: "Filters preserved; retry available")
      }
    }
  }
  private func acceptPreview(_ response: FinderResponse, token: Int) {
    guard requestState.preview(token, count: response.count) else { return }
    mergeVisible(response.hits)
    catalogueUnavailable = response.catalogueUnavailable
  }
  /// Preserve card identity and position while a running query discovers more rows.
  /// Existing cards receive fresher data; genuinely new cards append into free slots.
  private func mergeVisible(_ incoming: [FinderHit]) {
    let presentable = incoming.filter {
      RecipeDisplayPolicy.isPresentable(
        title: $0.recipe.title, imageURL: $0.recipe.imageURL, imageData: $0.recipe.imageData,
        ingredients: $0.recipe.ingredients.count, steps: $0.recipe.instructions.count,
        sourceURL: $0.recipe.sourceURL)
    }
    let updates = Dictionary(presentable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var merged = hits.compactMap { updates[$0.id] ?? $0 }
    var known = Set(merged.map(\.id))
    for hit in presentable where known.insert(hit.id).inserted && merged.count < limit {
      merged.append(hit)
    }
    hits = merged
  }
  nonisolated private static func discover(
    terms: [String], cached: WebRecipeFetcher.DiscoveryBatch?, online: Bool
  ) async -> WebRecipeFetcher.DiscoveryBatch? {
    guard online else { return nil }
    if let cached { return cached }
    return try? await WebRecipeFetcher.shared.discover(terms: terms)
  }
  func cancel() {
    request?.cancel()
    request = nil
    if working { requestState.cancel() }
  }
  private var completedFilters: FinderFilters?
}

struct RecipeFinderView: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize
  @Bindable var model: RecipeFinderSession
  @State private var showFilters = false
  @State private var showSort = false
  @State private var sortAfterFilters = false
  @State private var draftSort = FinderSort.bestMatch
  @State private var selected: FinderHit?
  @State private var preview: FinderHit?
  @State private var cuisineQuery = ""
  @FocusState private var searchFocused: Bool
  private var surface: Color { RecipeCardStyle.surface(isDark: session.isDarkMode) }
  private var categories: [FinderCategory] { FinderCategory.allCases }
  private var showCount: String { model.loading ? "Finding matches…" : "See recipes" }

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
    .stockedScreen()
    .toolbar(.hidden, for: .navigationBar)
    .sheet(
      isPresented: $showFilters,
      onDismiss: {
        logStep()
        if sortAfterFilters {
          sortAfterFilters = false
          showSort = true
        }
      }
    ) { filterSheet }
    .sheet(isPresented: $showSort, onDismiss: { logStep() }) { sortSheet }
    .sheet(item: $preview, onDismiss: { logStep() }) { hit in
      RecipeFinderPreview(hit: hit).environment(session)
    }
    .alert("Clear your choices?", isPresented: $model.flow.needsClearConfirmation) {
      Button("Keep choices", role: .cancel) {}
      Button("Clear all", role: .destructive) {
        model.flow.clear()
        AppAnalytics.shared.log(.finderCleared)
      }
    } message: {
      Text("This will remove everything you’ve selected.")
    }
    .navigationDestination(item: $selected) { hit in
      if let entry = hit.databaseEntry {
        RecipeOverviewView(
          title: entry.title, servings: Int(entry.servings) ?? 4,
          ingredients: entry.ingredients, steps: entry.steps, cookTime: entry.cookTime,
          prepTime: entry.prepTime)
      } else {
        UserRecipeDetailView(recipe: hit.recipe)
      }
    }
    .onAppear {
      // Download lifecycle is independent of each filter/search pass. Its completion
      // may refresh results once, but a result query must never start it again.
      HarvestRecipeSync.shared.refreshFullCatalogue()
      refresh()
      logStep()
    }
    .onDisappear { model.cancel() }
    .onChange(of: model.flow.filters) { _, _ in
      model.limit = 30
      refresh()
    }
    .onChange(of: model.flow.phase) { _, _ in
      searchFocused = false
      refresh()
      logStep()
    }
    .onChange(of: session.guestStore.inventoryRevision) { _, _ in
      // Eligibility must remain safe when the user requires available ingredients.
      if model.flow.filters.usesInventory { refresh() }
    }
    // Recipe enrichment, individual pages, and download completion do not restart
    // a visible query. Typing or an explicit filter/retry reads newly stored rows.
    .onChange(of: ConnectivityMonitor.shared.isOnline) { _, _ in refresh() }
    .onChange(of: session.guestStore.cookingProfile.allergens) { _, _ in refresh() }
    .onChange(of: session.guestStore.hasCompletedInitialHydration) { _, _ in refresh() }
  }

  private var header: some View {
    HStack {
      Button {
        if model.flow.back() { dismiss() }
      } label: {
        Image(systemName: "chevron.left").frame(width: 44, height: 44)
      }
      .accessibilityLabel("Back")
      Text("Find a Recipe").font(.stockedSerif(22, weight: .bold, relativeTo: .title2))
        .frame(maxWidth: .infinity)
      Button("Clear") { model.flow.requestClear() }.frame(minWidth: 44, minHeight: 44)
        .foregroundStyle(session.themeContrastAccent)
    }.font(.stocked(.body)).padding(.horizontal, 12)
      .padding(.top, StockedChrome.headerTopPadding).padding(
        .bottom, StockedChrome.headerBottomPadding)
  }

  private func progress(_ index: Int) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("\(index) of 7").font(.stocked(.subheadline))
      ProgressView(value: Double(index), total: 7).tint(session.themeContrastAccent)
        .accessibilityLabel("Quiz progress").accessibilityValue("\(index) of 7")
    }
  }
  private func heading(_ text: String) -> some View {
    Text(text).font(.stockedSerif(30, weight: .bold, relativeTo: .title)).fixedSize(
      horizontal: false, vertical: true)
  }
  private func primary(_ text: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(text).font(.stocked(.headline)).multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 48).padding(8)
        .foregroundStyle(Color.selectedTabForeground(session.isDarkMode)).background(
          Color.selectedTabBackground, in: RoundedRectangle(cornerRadius: 18))
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
        Button("Skip") {
          model.flow.next(skip: true)
          AppAnalytics.shared.log(.finderStepSkipped)
        }
        .font(.stocked(.headline)).frame(minWidth: 70, minHeight: 48)
        primary(model.flow.editingReview ? "Save choices" : "Next") { model.flow.next() }
      }
    }
  }
  private var dietNote: some View {
    Text(
      "Nutrition and allergen-free filters aren’t available because recipe data cannot reliably verify them. Dietary labels are not an allergy-safety guarantee; check the original recipe and ingredient labels."
    )
    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
  }
  private var kitchenNote: some View {
    Text(
      "Mostly means at least 70% of required ingredients. Full matches require confirmed amounts for the recipe’s stated servings. Unknown quantities are never counted as fully ready."
    )
    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
  }
  @ViewBuilder private func options(_ category: FinderCategory) -> some View {
    if category == .cuisine {
      TextField("Search cuisines", text: $cuisineQuery).font(.stocked(.body))
        .padding(12).frame(minHeight: 48).background(
          surface, in: RoundedRectangle(cornerRadius: 14)
        )
        .accessibilityLabel("Search cuisine options")
    }
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], spacing: 12) {
      ForEach(
        category.options.filter {
          category != .cuisine || cuisineQuery.isEmpty || $0.isNeutral || $0.isDiscovery
            || FinderQuery.normalize($0.label).contains(FinderQuery.normalize(cuisineQuery))
        }
      ) { choice in
        let selected = model.flow.filters[category].contains(choice)
        Button {
          model.flow.filters.toggle(choice, in: category)
          AppAnalytics.shared.log(selected ? .finderOptionDeselected : .finderOptionSelected)
          UIAccessibility.post(
            notification: .announcement,
            argument: "\(choice.label), \(selected ? "not selected" : "selected")")
        } label: {
          VStack(spacing: 12) {
            if category == .meal { Image(systemName: choice.icon).font(.stocked(.title)) }
            HStack {
              Text(choice.label).font(.stocked(.body).weight(.semibold)).fixedSize(
                horizontal: false, vertical: true)
              if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(session.accentColor)
              }
            }
          }
          .frame(maxWidth: .infinity, minHeight: category == .meal ? 100 : 48).padding(12)
          .foregroundStyle(selected ? Color.selectedTabForeground(session.isDarkMode) : session.themeTextColor)
          .background(
            selected ? Color.stockedCharcoal : surface, in: RoundedRectangle(cornerRadius: 18)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 18).strokeBorder(
              selected ? session.themeContrastAccent : session.themeSecondaryText.opacity(0.2),
              lineWidth: selected ? 2 : 1))
        }.buttonStyle(.plain)
          .accessibilityLabel(choice.label).accessibilityValue(
            selected ? "Selected" : "Not selected"
          )
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
              if choices.isEmpty {
                Text("Any").font(.stocked(.body)).foregroundStyle(session.themeSecondaryText)
              }
              ForEach(choices) { choice in
                Text(choice.label).font(.stocked(.subheadline)).padding(.horizontal, 10).padding(
                  .vertical, 6
                )
                .background(session.themeBgColor, in: Capsule())
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
          Button("Edit") {
            model.flow.edit(category)
            AppAnalytics.shared.log(.finderReviewEdited)
          }
          .frame(minWidth: 44, minHeight: 44).foregroundStyle(session.themeContrastAccent)
          .accessibilityLabel("Edit \(category.title)")
        }.padding(16).background(surface, in: RoundedRectangle(cornerRadius: 20))
      }
      if model.error { errorState } else if model.canReportCount && model.count == 0 { noMatchGuidance }
      sourceNotice
      primary(showCount) {
        model.flow.phase = .results
        AppAnalytics.shared.log(.finderCompleted)
      }
      Button("Start over") { model.flow.requestClear() }.frame(maxWidth: .infinity, minHeight: 44)
        .foregroundStyle(session.themeContrastAccent)
    }
  }
  private func summary(_ category: FinderCategory) -> String {
    let selected = category.options.filter { model.flow.filters[category].contains($0) }.map(
      \.label)
    return selected.isEmpty ? "Any" : selected.joined(separator: ", ")
  }
  private var noMatchGuidance: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("No exact matches").font(.stocked(.headline))
      Text(
        "We haven’t found this combination. You can edit your choices or broaden a preference below. Dietary and kitchen requirements stay the same."
      )
      .font(.stocked(.body)).foregroundStyle(session.themeSecondaryText)
      ForEach(model.alternatives) { alternative in
        Button {
          model.flow.filters = alternative.filters
          AppAnalytics.shared.log(.finderFiltersChanged)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(alternative.label)
            Text("Show these recipes").fontWeight(.semibold)
          }.font(.stocked(.body)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }.foregroundStyle(session.themeContrastAccent)
          .accessibilityLabel(
            "\(alternative.label). Show recipes with these adjusted preferences.")
      }
    }.padding(16).background(surface, in: RoundedRectangle(cornerRadius: 18))
  }
  private var search: some View {
    HStack {
      Image(systemName: "magnifyingglass").accessibilityHidden(true)
      TextField("Search these results", text: $model.flow.filters.query)
        .font(.stocked(.body)).focused($searchFocused).submitLabel(.search)
        .onSubmit {
          searchFocused = false
          AppAnalytics.shared.log(.finderSearchSubmitted)
        }
        .accessibilityLabel("Search recipes or ingredients")
      if !model.flow.filters.query.isEmpty {
        Button {
          model.flow.filters.query = ""
        } label: {
          Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
        }
        .accessibilityLabel("Clear search")
      }
    }.padding(.horizontal, 12).frame(minHeight: 44).background(
      surface, in: RoundedRectangle(cornerRadius: 14))
  }
  private var results: some View {
    VStack(alignment: .leading, spacing: 16) {
      heading(model.loading && model.hits.isEmpty ? "Finding recipes for you" : "Recipes for you")
      search
      if !session.guestStore.cookingProfile.allergens.isEmpty {
        Text(
          "Your saved allergen exclusions remain active. Always check the source recipe and ingredient labels."
        )
        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack {
          ForEach(categories) { category in
            ForEach(
              category.options.filter { model.flow.filters[category].contains($0) && !$0.isNeutral }
            ) { choice in
              Button {
                model.flow.filters.remove(choice, in: category)
                AppAnalytics.shared.log(.finderFilterRemoved)
              } label: {
                Label(choice.label, systemImage: "xmark").font(.stocked(.subheadline)).padding(
                  .horizontal, 14
                ).frame(minHeight: 44)
                  .background(surface, in: Capsule())
              }.accessibilityLabel("Remove \(choice.label) filter")
            }
          }
          Button("Sort & Filter") { showFilters = true }.font(
            .stocked(.subheadline).weight(.semibold)
          )
          .padding(.horizontal, 14).frame(minHeight: 44).overlay(
            Capsule().stroke(session.themeTextColor))
        }.padding(2)
      }
      HStack {
        Button {
          draftSort = model.flow.filters.sort
          showSort = true
          AppAnalytics.shared.log(.finderSortOpened)
        } label: {
          Label(model.flow.filters.sort.label, systemImage: "slider.horizontal.3").font(
            .stocked(.headline)
          ).frame(minHeight: 44)
        }.accessibilityLabel("Sort recipes, \(model.flow.filters.sort.label)")
        Spacer()
        if model.loading { ProgressView().accessibilityLabel("Loading recipes") }
      }
      sourceNotice
      if model.error && !model.hits.isEmpty { errorState }
      if model.loading && model.hits.isEmpty {
        skeletons
      } else if model.hits.isEmpty && model.error {
        errorState
      } else if model.hits.isEmpty && !model.canReportCount {
        Text("Available matches will appear when loading finishes.")
          .font(.stocked(.body)).foregroundStyle(session.themeSecondaryText)
      } else if model.hits.isEmpty {
        emptyState
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 14)], spacing: 14) {
          ForEach(model.hits) { hit in
            Button {
              if hit.databaseEntry != nil { preview = hit } else { selected = hit }
              AppAnalytics.shared.log(.finderRecipeOpened)
            } label: {
              card(hit)
            }.buttonStyle(.plain)
          }
        }
        if model.canReportCount && model.hits.count < model.count {
          primary("Load more recipes") {
            model.limit += 30
            model.refresh(store: session.guestStore)
          }
        }
      }
    }
  }
  private func card(_ hit: FinderHit) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack(alignment: .topTrailing) {
        CachedAsyncImage(
          url: hit.recipe.imageURL ?? "", imageData: hit.recipe.imageData,
          height: RecipeCardStyle.imageHeight, resolveName: hit.recipe.title,
          resolveCategory: hit.recipe.cuisine)
        if let tag = FinderWebPolicy.cardTag(hit.record, filters: model.flow.filters) {
          Text(tag).font(.stocked(.caption).weight(.semibold)).padding(8)
            .background(surface, in: RoundedRectangle(cornerRadius: 10)).padding(8)
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(hit.recipe.title).font(
          .stockedSerif(RecipeCardStyle.titleSize, weight: .bold, relativeTo: .headline)
        ).fixedSize(horizontal: false, vertical: true)
        if let source = hit.recipe.sourceName, !source.isEmpty {
          Text(source).foregroundStyle(session.themeSecondaryText)
        }
        if let rating = hit.record.rating {
          Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(
            session.themeContrastAccent)
          if let count = hit.record.ratingCount {
            Text("\(count) \(hit.publisherRatingCount == nil ? "household" : "publisher") ratings")
          }
        }
        if !hit.recipe.cuisine.isEmpty { Text(hit.recipe.cuisine) }
        if let time = hit.record.totalMinutes { Label("\(time) min", systemImage: "clock") }
        if hit.recipe.isFavorited { Label("Saved", systemImage: "heart.fill") }
        if hit.record.required > 0 {
          Text("You have \(hit.record.have) of \(hit.record.required) ingredients")
          if hit.record.missing > 0 { Text("Missing \(hit.record.missing) ingredients") }
          if hit.record.uncertain > 0 { Text("Check \(hit.record.uncertain) quantities") }
        }
      }.font(.stocked(.caption)).padding(RecipeCardStyle.padding).frame(
        maxWidth: .infinity, alignment: .leading)
    }.background(surface, in: RoundedRectangle(cornerRadius: 18)).clipShape(
      RoundedRectangle(cornerRadius: 18)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18).strokeBorder(session.themeSecondaryText.opacity(0.2))
    )
    .accessibilityElement(children: .combine).accessibilityHint(
      hit.databaseEntry == nil
        ? "Open saved recipe" : "Preview recipe and choose view original or import")
  }

  private var sourceNotice: some View {
    VStack(alignment: .leading, spacing: 8) {
      if model.loading {
        Text(
          model.hits.isEmpty
            ? "Looking for matching recipes…"
            : "Finding more recipes… You can open these matches now.")
      } else if model.enriching {
        Text("Matches are ready. Checking optional recipe sources in the background.")
      }
      if model.webUnavailable {
        Text(
          "Some recipe websites couldn’t be reached. Available matches are shown with your filters unchanged."
        )
        Button("Try again") { model.refresh(store: session.guestStore, force: true) }.frame(
          minHeight: 44)
      }
      let sync = HarvestRecipeSync.shared
      if !sync.catalogueComplete {
        Text(
          ConnectivityMonitor.shared.isOnline
            ? "More saved recipe sources are still syncing. Current matches stay available."
            : "Offline matches include recipes already downloaded on this device.")
      }
      if sync.refreshingCatalogue {
        Button("Pause recipe download") { sync.stopCatalogueRefresh() }.frame(minHeight: 44)
      } else if sync.catalogueError && ConnectivityMonitor.shared.isOnline {
        Button("Retry recipe download") { sync.refreshFullCatalogue(force: true) }.frame(
          minHeight: 44)
      }
      if model.catalogueUnavailable { Text("Some downloaded recipes couldn’t be loaded.") }
    }.font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
  }
  private var skeletons: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155))]) {
      ForEach(0..<6) { _ in
        VStack(alignment: .leading, spacing: 12) {
          Rectangle().fill(surface).frame(height: RecipeCardStyle.imageHeight)
          Text("Recipe title").font(.stocked(.headline))
          Text("Cuisine · Total time").font(.stocked(.caption))
        }.padding(12).background(surface, in: RoundedRectangle(cornerRadius: 18)).redacted(
          reason: .placeholder)
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
        Button("Find a Recipe") {
          model.flow.enteredBySearch = false
          model.flow.phase = .quiz(0)
        }.frame(minHeight: 44)
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
          Button {
            showFilters = false
            draftSort = model.flow.filters.sort
            sortAfterFilters = true
            AppAnalytics.shared.log(.finderSortOpened)
          } label: {
            Label("Sort: \(model.flow.filters.sort.label)", systemImage: "slider.horizontal.3")
              .frame(minHeight: 44)
          }
          ForEach(categories) { category in
            DisclosureGroup {
              options(category)
              if category == .diet { dietNote }
              if category == .kitchen { kitchenNote }
            } label: {
              VStack(alignment: .leading) {
                Text(category.title).font(.stocked(.headline))
                Text(summary(category)).font(.stocked(.caption))
              }.padding(.vertical, 8)
            }
          }
          primary(showCount) {
            showFilters = false
            AppAnalytics.shared.log(.finderFiltersChanged)
          }
        }.padding(18)
      }.background(session.themeBgColor).foregroundStyle(session.themeTextColor)
        .navigationTitle("Filter recipes").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button("Clear all") { model.flow.filters = FinderFilters() }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button("Close", systemImage: "xmark") { showFilters = false }
          }
        }
    }.stockedPresentationSurface(width: .full).tint(session.themeContrastAccent)
      .qaScreen("Recipe Filters")
  }
  private var sortSheet: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 8) {
          ForEach(FinderSort.allCases) { sort in
            Button {
              draftSort = sort
            } label: {
              HStack(spacing: 14) {
                Image(systemName: draftSort == sort ? "largecircle.fill.circle" : "circle")
                  .foregroundStyle(
                    draftSort == sort ? session.themeContrastAccent : session.themeSecondaryText)
                Text(sort.label).font(.stocked(.body))
                Spacer()
              }.frame(minHeight: 48)
            }.buttonStyle(.plain).accessibilityValue(
              draftSort == sort ? "Selected" : "Not selected"
            )
            .accessibilityAddTraits(draftSort == sort ? .isSelected : [])
          }
          primary("Apply sort") {
            model.flow.filters.sort = draftSort
            showSort = false
            AppAnalytics.shared.log(.finderSortApplied)
          }
        }.padding(20)
      }.background(session.themeBgColor).foregroundStyle(session.themeTextColor)
        .navigationTitle("Sort recipes").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Close", systemImage: "xmark") { showSort = false }
          }
        }
    }.stockedPresentationSurface(width: .full).qaScreen("Recipe Sort")
  }
  private func refresh() {
    if case .quiz = model.flow.phase, !showFilters { return }
    model.refresh(store: session.guestStore)
  }
  private func logStep() {
    switch model.flow.phase {
    case .quiz(let index):
      QARecorder.shared.enteredScreen("Find a Recipe · \(categories[index].title)")
      AppAnalytics.shared.log(.finderStepViewed)
    case .review: QARecorder.shared.enteredScreen("Recipe Review")
    case .results: QARecorder.shared.enteredScreen("Recipe Results")
    }
  }
}

extension FinderHit: Hashable {
  static func == (lhs: FinderHit, rhs: FinderHit) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
