import Foundation
import Observation

@Observable
@MainActor
final class GlobalSearchController {
    private(set) var localResults: [GlobalSearchView.SearchResult] = []
    private(set) var onlineResults: [OnlineRecipe] = []
    private(set) var isSearchingLocal = false
    private(set) var isSearchingOnline = false
    private(set) var hasMore = false
    private(set) var hasStructuredQuery = false
    private(set) var suggestion: String?
    private(set) var onlineNotice: String?
    @ObservationIgnored private weak var store: GuestDataStore?
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var localGeneration = 0
    @ObservationIgnored private var onlineGeneration = 0
    @ObservationIgnored private var localTask: Task<Void, Never>?
    @ObservationIgnored private var localWorker: Task<GlobalSearchLocalOutput, Error>?
    @ObservationIgnored private var onlineTask: Task<Void, Never>?
    @ObservationIgnored private var onlineWorker: Task<[OnlineRecipe], Error>?

    func activate(store: GuestDataStore, query: String) {
        self.store = store
        isActive = true
        updateQuery(query)
    }

    func stop() {
        isActive = false
        localGeneration &+= 1
        onlineGeneration &+= 1
        localTask?.cancel(); localWorker?.cancel()
        onlineTask?.cancel(); onlineWorker?.cancel()
        isSearchingLocal = false; isSearchingOnline = false
    }

    func updateQuery(_ raw: String) {
        let next = GlobalSearchEngine.normalizedQuery(raw)
        if next != query {
            localResults = []; onlineResults = []
            hasMore = false; hasStructuredQuery = false; suggestion = nil; onlineNotice = nil
        }
        query = next
        guard isActive else { return }
        queueLocal()
        queueOnline()
    }

    func connectivityChanged() {
        guard isActive else { return }
        queueOnline()
    }

    private func queueLocal() {
        localTask?.cancel(); localWorker?.cancel()
        localGeneration &+= 1
        let generation = localGeneration
        let requestedQuery = query
        guard isActive, !requestedQuery.isEmpty else { localResults = []; isSearchingLocal = false; return }
        isSearchingLocal = true
        localTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.isActive, self.localGeneration == generation, let store = self.store else { return }
            let snapshot = withObservationTracking {
                // Observe authoritative domain revisions as well as the feature stores. Reads
                // copy array storage only; no filtering or sorting happens on the UI actor.
                _ = store.inventoryRevision; _ = store.groceryRevision; _ = store.recipeRevision
                _ = store.pastMealsRevision; _ = store.planRevision
                return GlobalSearchSnapshot(inventory: store.inventoryItems, groceries: store.groceryItems,
                    recipes: store.userRecipes, history: store.pastMeals, cached: OfflineRecipeCache.shared.recipes,
                    foods: StockedKnowledgeBase.shared.ingredients.map {
                        GlobalSearchFood(id: $0.id, name: $0.name, category: $0.category, emoji: $0.emoji,
                                         aliases: $0.aliases, searchCount: $0.searchCount, lastSearched: $0.lastSearched)
                    }, leftovers: LeftoversStore.shared.entries, labels: ContainerLabelStore.shared.labels,
                    meals: store.plannedMeals)
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.isActive, self.localGeneration == generation else { return }
                    self.queueLocal()
                }
            }
            let worker = Task.detached(priority: .utility) { try GlobalSearchEngine.search(requestedQuery, snapshot: snapshot) }
            self.localWorker = worker
            do {
                let output = try await worker.value
                guard !Task.isCancelled, self.isActive, self.localGeneration == generation, self.query == requestedQuery else { return }
                self.localResults = output.matches.map(Self.displayResult)
                self.hasMore = output.hasMore
                self.hasStructuredQuery = output.hasStructuredQuery
                self.suggestion = output.suggestion
                self.isSearchingLocal = false
                self.localWorker = nil
            } catch {
                guard !Task.isCancelled, self.localGeneration == generation else { return }
                self.isSearchingLocal = false
                self.localWorker = nil
            }
        }
    }

    private static func displayResult(_ match: GlobalSearchLocalMatch) -> GlobalSearchView.SearchResult {
        switch match {
        case .inventory(let value): return .inventoryItem(value)
        case .grocery(let value): return .groceryItem(value)
        case .recipe(let value): return .userRecipe(value)
        case .history(let value): return .pastMeal(value)
        case .cached(let value): return .cachedRecipe(value)
        case .food(let value): return .foodItem(IngredientEntry(name: value.name, category: value.category, emoji: value.emoji, synonyms: value.aliases))
        case .leftover(let value): return .leftover(value)
        case .label(let value): return .containerLabel(value)
        case .meal(let value): return .plannedMeal(value)
        case .tool(let value): return .tool(value)
        }
    }

    private func queueOnline() {
        onlineTask?.cancel(); onlineWorker?.cancel()
        onlineGeneration &+= 1
        let generation = onlineGeneration
        let requestedQuery = query
        guard isActive, requestedQuery.count >= 3 else { onlineResults = []; isSearchingOnline = false; onlineNotice = nil; return }
        isSearchingOnline = true
        onlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            let cached = await GlobalSearchResponseCache.shared.recipes(for: requestedQuery)
            guard let self, !Task.isCancelled, self.isActive, self.onlineGeneration == generation else { return }
            guard NetworkMonitor.shared.isOnline else {
                self.onlineResults = cached
                self.onlineNotice = cached.isEmpty ? "Offline — showing results from this device." : "Offline — showing local results and saved online matches."
                self.isSearchingOnline = false
                return
            }
            let parser = OnlineRecipesLoader.shared
            let worker = Task.detached(priority: .utility) { try await Self.fetchOnline(requestedQuery, parser: parser) }
            self.onlineWorker = worker
            do {
                let results = try await worker.value
                guard !Task.isCancelled, self.isActive, self.onlineGeneration == generation, self.query == requestedQuery else { return }
                self.onlineResults = results
                self.onlineNotice = nil
                self.isSearchingOnline = false
                self.onlineWorker = nil
                await GlobalSearchResponseCache.shared.save(results, query: requestedQuery)
            } catch {
                guard !Task.isCancelled, self.isActive, self.onlineGeneration == generation, self.query == requestedQuery else { return }
                self.onlineResults = cached
                self.onlineNotice = cached.isEmpty ? "Online search is unavailable. Your local results are still available." : "Online search is unavailable. Showing saved online matches with your local results."
                self.isSearchingOnline = false
                self.onlineWorker = nil
            }
        }
    }

    private nonisolated static func fetchOnline(_ query: String, parser: OnlineRecipesLoader) async throws -> [OnlineRecipe] {
        var components = URLComponents(string: "https://www.themealdb.com/api/json/v1/1/search.php")!
        components.queryItems = [URLQueryItem(name: "s", value: query)]
        guard let url = components.url else { throw URLError(.badURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let byteLimit = 2_000_000
        guard response.expectedContentLength <= byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            if data.count % 4096 == 0 { try Task.checkCancellation() }
            guard data.count < byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        // TheMealDB deliberately returns meals:null for a successful search with no matches.
        if json["meals"] is NSNull { return [] }
        guard let meals = json["meals"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        return meals.prefix(6).compactMap { parser.parseMealPublic($0) }
    }
}
