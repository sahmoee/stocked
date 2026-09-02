// InterHubSystem.swift
// Typed, durable coordination shared by Home, Cook, Inventory, Recipes, Grocery,
// widgets, notifications, Spotlight, the share extension, and background services.
//
// This layer is deliberately additive. Existing deep links and NotificationCenter
// shims remain compatible while producers migrate to typed routes and operations.

import SwiftUI
import os

// MARK: - Typed routes, presentations, and durable intents

nonisolated enum InterHubTab: String, Codable, CaseIterable, Sendable {
    case home, cook, inventory, recipes, grocery

    @MainActor var stockedTab: StockedTab {
        switch self {
        case .home: .home
        case .cook: .cook
        case .inventory: .inventory
        case .recipes: .recipes
        case .grocery: .grocery
        }
    }

    @MainActor init(_ tab: StockedTab) {
        switch tab {
        case .home: self = .home
        case .cook: self = .cook
        case .inventory: self = .inventory
        case .recipes: self = .recipes
        case .grocery: self = .grocery
        }
    }
}

nonisolated enum CanonicalRecipeKind: String, Codable, CaseIterable, Sendable {
    case user, generated, online, web, cached, database, server
}

nonisolated enum InterHubScanKind: String, Codable, Sendable {
    case receipt, barcode, shelf, inventoryPhoto
}

nonisolated enum InterHubPresentation: String, Codable, Sendable, CaseIterable {
    case search, dailyBrief, addItems, quickUpdate, household, activity
    case notifications, dataStorage, transferKitchen, recipeSources, preferredStore
    case editProfile, importRecipe, homeWidgets
}

nonisolated enum InterHubRoute: Codable, Hashable, Sendable {
    case tab(InterHubTab)
    case recipe(id: String, kind: CanonicalRecipeKind)
    case inventoryItem(UUID)
    case groceryItem(UUID)
    case cook(recipeID: String?)
    case search(query: String?)
    case scan(InterHubScanKind)
    case presentation(InterHubPresentation)

    var tab: InterHubTab? {
        switch self {
        case .tab(let tab): tab
        case .recipe: .recipes
        case .inventoryItem: .inventory
        case .groceryItem: .grocery
        case .cook: .cook
        case .search, .scan, .presentation: nil
        }
    }

    var deduplicationKey: String {
        switch self {
        case .tab(let tab): "tab:\(tab.rawValue)"
        case .recipe(let id, let kind): "recipe:\(kind.rawValue):\(id)"
        case .inventoryItem(let id): "inventory:\(id.uuidString)"
        case .groceryItem(let id): "grocery:\(id.uuidString)"
        case .cook(let id): "cook:\(id ?? "new")"
        case .search(let query): "search:\(query ?? "")"
        case .scan(let kind): "scan:\(kind.rawValue)"
        case .presentation(let presentation): "presentation:\(presentation.rawValue)"
        }
    }
}

nonisolated enum InterHubIntentSource: String, Codable, Sendable {
    case app, home, cook, inventory, recipes, grocery, widget, notification
    case spotlight, deepLink, shareExtension, siri, keyboard, background, qa
}

nonisolated struct InterHubIntent: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var route: InterHubRoute
    var source: InterHubIntentSource
    var createdAt = Date()
    var attempts = 0
    var lastError: String?
}

/// An ordered, persisted intent inbox. A cold-launch notification, widget action,
/// Spotlight result, or share import cannot disappear before MainTabView is mounted.
@Observable @MainActor
final class InterHubIntentCenter {
    static let shared = InterHubIntentCenter()

    private let queueKey = "interhub.intent.queue.v1"
    private let deadLetterKey = "interhub.intent.dead.v1"
    private(set) var queue: [InterHubIntent]
    private(set) var active: InterHubIntent?
    private(set) var revision = 0
    private(set) var deadLetters: [InterHubIntent]

    private init() {
        queue = Self.load([InterHubIntent].self, key: queueKey) ?? []
        deadLetters = Self.load([InterHubIntent].self, key: deadLetterKey) ?? []
        repair()
    }

    @discardableResult
    func enqueue(_ route: InterHubRoute, source: InterHubIntentSource) -> UUID {
        if let existing = queue.first(where: {
            $0.route.deduplicationKey == route.deduplicationKey &&
            Date().timeIntervalSince($0.createdAt) < 30
        }) {
            return existing.id
        }
        let intent = InterHubIntent(route: route, source: source)
        queue.append(intent)
        trimAndPersist()
        revision &+= 1
        return intent.id
    }

    func claimNext() -> InterHubIntent? {
        guard active == nil, !queue.isEmpty else { return active }
        queue[0].attempts += 1
        active = queue[0]
        persist()
        revision &+= 1
        return active
    }

    func complete(_ id: UUID) {
        queue.removeAll { $0.id == id }
        if active?.id == id { active = nil }
        persist()
        revision &+= 1
    }

    func fail(_ id: UUID, error: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else {
            if active?.id == id { active = nil }
            return
        }
        queue[index].lastError = error
        if queue[index].attempts >= 3 {
            deadLetters.insert(queue.remove(at: index), at: 0)
            deadLetters = Array(deadLetters.prefix(25))
        } else {
            let retry = queue.remove(at: index)
            queue.append(retry)
        }
        active = nil
        persist()
        revision &+= 1
    }

    func retryDeadLetters() {
        let retries = deadLetters.map {
            InterHubIntent(route: $0.route, source: $0.source, attempts: 0, lastError: nil)
        }
        deadLetters.removeAll()
        queue.append(contentsOf: retries)
        trimAndPersist()
        revision &+= 1
    }

    private func repair() {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        queue = queue.filter { $0.createdAt >= cutoff }
        var keys = Set<String>()
        queue = queue.filter { keys.insert($0.route.deduplicationKey).inserted }
        queue = Array(queue.prefix(50))
        persist()
    }

    private func trimAndPersist() {
        queue = Array(queue.suffix(50))
        persist()
    }

    private func persist() {
        Self.save(queue, key: queueKey)
        Self.save(deadLetters, key: deadLetterKey)
    }

    private nonisolated static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// MainActor delivery point for the next claimed intent. MainTabView is the only
/// consumer; producers never need to know whether the UI currently exists.
@Observable @MainActor
final class InterHubCoordinator {
    static let shared = InterHubCoordinator()
    private(set) var request: InterHubIntent?
    private(set) var revision = 0
    private let inbox = InterHubIntentCenter.shared

    private init() {}

    @discardableResult
    func open(_ route: InterHubRoute, source: InterHubIntentSource = .app) -> UUID {
        let id = inbox.enqueue(route, source: source)
        activateNext()
        return id
    }

    func activateNext() {
        guard request == nil else { return }
        request = inbox.claimNext()
        revision &+= 1
    }

    func completeCurrent() {
        guard let request else { return }
        inbox.complete(request.id)
        self.request = nil
        revision &+= 1
        activateNext()
    }

    func failCurrent(_ error: String) {
        guard let request else { return }
        inbox.fail(request.id, error: error)
        self.request = nil
        revision &+= 1
        activateNext()
    }
}

// MARK: - Cross-hub handoff context

nonisolated struct HubHandoffContext: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var origin: InterHubTab
    var destination: InterHubTab
    var title: String
    var detail: String
    var recipeID: String?
    var inventoryItemID: UUID?
    var groceryItemIDs: [UUID] = []
    var createdAt = Date()
}

@Observable @MainActor
final class HubHandoffCenter {
    static let shared = HubHandoffCenter()
    private(set) var current: HubHandoffContext?
    private var returnRoute: InterHubRoute?

    private init() {}

    func begin(_ context: HubHandoffContext, returnTo route: InterHubRoute?) {
        current = context
        returnRoute = route
        InterHubCoordinator.shared.open(.tab(context.destination), source: .app)
    }

    func finish(returning: Bool = true) {
        let route = returnRoute
        current = nil
        returnRoute = nil
        if returning, let route { InterHubCoordinator.shared.open(route, source: .app) }
    }
}

// MARK: - Reusable action registry

nonisolated enum StockedActionID: String, Codable, CaseIterable, Sendable {
    case search, scanReceipt, scanBarcode, addInventory, openInventory, findRecipe
    case cookNow, cookLater, openGrocery, importRecipe, showBrief, editWidgets
}

nonisolated struct StockedActionDescriptor: Identifiable, Codable, Hashable, Sendable {
    var id: StockedActionID
    var title: String
    var subtitle: String
    var symbol: String
    var route: InterHubRoute
}

nonisolated enum StockedActionRegistry {
    static let all: [StockedActionDescriptor] = [
        .init(id: .search, title: "Search everything", subtitle: "Kitchen, recipes, meals, and actions", symbol: "magnifyingglass", route: .search(query: nil)),
        .init(id: .scanReceipt, title: "Scan receipt", subtitle: "Review purchases before adding", symbol: "doc.text.viewfinder", route: .scan(.receipt)),
        .init(id: .scanBarcode, title: "Scan barcode", subtitle: "Identify and add one product", symbol: "barcode.viewfinder", route: .scan(.barcode)),
        .init(id: .addInventory, title: "Add kitchen items", subtitle: "Add one or several items", symbol: "plus.circle", route: .presentation(.addItems)),
        .init(id: .openInventory, title: "Open inventory", subtitle: "See what is on hand", symbol: "archivebox", route: .tab(.inventory)),
        .init(id: .findRecipe, title: "Find a recipe", subtitle: "Search the complete catalogue", symbol: "fork.knife", route: .tab(.recipes)),
        .init(id: .cookNow, title: "Cook now", subtitle: "Use what is available", symbol: "flame", route: .cook(recipeID: nil)),
        .init(id: .cookLater, title: "Cook later", subtitle: "Plan, shop, prep, and cook", symbol: "calendar.badge.plus", route: .tab(.cook)),
        .init(id: .openGrocery, title: "Open grocery list", subtitle: "Shop and check off items", symbol: "cart", route: .tab(.grocery)),
        .init(id: .importRecipe, title: "Import recipe", subtitle: "URL, share, social, or screenshot", symbol: "square.and.arrow.down", route: .presentation(.importRecipe)),
        .init(id: .showBrief, title: "Daily Brief", subtitle: "See what needs attention", symbol: "sun.max", route: .presentation(.dailyBrief)),
        .init(id: .editWidgets, title: "Edit widgets", subtitle: "Reorder and resize Home", symbol: "square.grid.2x2", route: .presentation(.homeWidgets)),
    ]

    static func descriptor(for id: StockedActionID) -> StockedActionDescriptor? {
        all.first { $0.id == id }
    }

    @MainActor static func perform(_ id: StockedActionID, source: InterHubIntentSource = .app) {
        guard let action = descriptor(for: id) else { return }
        InterHubCoordinator.shared.open(action.route, source: source)
    }
}

// MARK: - Typed compatibility notifications

extension Notification.Name {
    static let stockedInterHubRoute = Notification.Name("stockedInterHubRoute")
    static let stockedOpenRecipe = Notification.Name("stockedOpenRecipe")
    static let stockedOpenGroceryItem = Notification.Name("stockedOpenGroceryItem")
    static let stockedOpenRecipeImport = Notification.Name("stockedOpenRecipeImport")
}

// MARK: - One recipe contract for every producer and consumer

/// Loss-minimising recipe value used at hub boundaries. Source-specific models remain free to
/// evolve, while save/plan/shop/cook/search code consumes this stable representation.
nonisolated struct CanonicalRecipeDescriptor: Identifiable, Codable, Sendable, Equatable {
    var stableID: String
    var kind: CanonicalRecipeKind
    var title: String
    var summary: String = ""
    var ingredients: [RecipeIngredient] = []
    var steps: [String] = []
    var servings: Int = 4
    var prepTime: String = ""
    var cookTime: String = ""
    var cuisine: String = ""
    var categories: [String] = []
    var tags: [String] = []
    var imageURL: String?
    var imageData: Data?
    var sourceName: String?
    var sourceURL: String?

    var id: String { "\(kind.rawValue):\(stableID)" }
    var normalizedTitle: String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var userRecipe: UserRecipe {
        UserRecipe(
            title: title, description: summary, cookTime: cookTime, prepTime: prepTime,
            servings: max(1, servings), cuisine: cuisine, tags: tags,
            ingredients: ingredients, instructions: steps, imageData: imageData,
            imageURL: imageURL, sourceURL: sourceURL, sourceName: sourceName,
            categories: categories.isEmpty ? nil : categories
        )
    }

    init(_ recipe: UserRecipe) {
        stableID = recipe.id.uuidString; kind = .user; title = recipe.title
        summary = recipe.description; ingredients = recipe.ingredients; steps = recipe.instructions
        servings = recipe.servings; prepTime = recipe.prepTime; cookTime = recipe.cookTime
        cuisine = recipe.cuisine; categories = recipe.categories ?? []; tags = recipe.tags
        imageURL = recipe.imageURL; imageData = recipe.imageData
        sourceName = recipe.sourceName; sourceURL = recipe.sourceURL
    }

    init(_ recipe: GeneratedRecipe) {
        stableID = recipe.id.uuidString; kind = .generated; title = recipe.title
        summary = recipe.tips
        ingredients = recipe.ingredients.map { RecipeIngredient(name: $0.name, amount: $0.amount) }
        steps = recipe.steps; servings = recipe.servings; cookTime = recipe.cookTime
        cuisine = recipe.cuisine; categories = recipe.mealCategory.isEmpty ? [] : [recipe.mealCategory]
        imageURL = recipe.imageURL; imageData = recipe.imageData; sourceName = "Stocked"
    }

    init(_ recipe: OnlineRecipe) {
        stableID = recipe.id; kind = .online; title = recipe.title
        ingredients = recipe.ingredientLines.map { RecipeIngredient(name: $0.ingredient, amount: $0.measure) }
        steps = Self.splitSteps(recipe.instructions); cuisine = recipe.area
        categories = recipe.category.isEmpty ? [] : [recipe.category]
        imageURL = recipe.imageURL; sourceName = recipe.source
    }

    init(_ recipe: CachedRecipe) {
        stableID = recipe.mealID; kind = .cached; title = recipe.title
        summary = recipe.description ?? ""; ingredients = recipe.ingredients.map(Self.ingredient)
        steps = recipe.steps; servings = Self.firstInteger(recipe.servings) ?? 4
        prepTime = recipe.prepTime ?? ""; cookTime = recipe.cookTime ?? ""
        cuisine = recipe.cuisine ?? recipe.area; categories = recipe.category.isEmpty ? [] : [recipe.category]
        tags = recipe.tags; imageURL = recipe.imageURL; sourceName = recipe.source; sourceURL = recipe.sourceURL
    }

    init(_ recipe: WebRecipe) {
        stableID = recipe.id.uuidString; kind = .web; title = recipe.title; summary = recipe.description
        ingredients = recipe.ingredients.map(Self.ingredient); steps = recipe.steps.map(\.text)
        servings = Self.firstInteger(recipe.servings) ?? 4; prepTime = recipe.prepTime; cookTime = recipe.cookTime
        cuisine = recipe.cuisine; categories = recipe.category.isEmpty ? [] : [recipe.category]
        tags = recipe.tags; imageURL = recipe.imageURL; sourceName = recipe.sourceName; sourceURL = recipe.sourceURL
    }

    init(_ recipe: RecipeDatabaseEntry) {
        stableID = recipe.id.uuidString; kind = .database; title = recipe.title; summary = recipe.description
        ingredients = recipe.ingredients.map(Self.ingredient); steps = recipe.steps
        servings = Self.firstInteger(recipe.servings) ?? 4; prepTime = recipe.prepTime; cookTime = recipe.cookTime
        cuisine = recipe.cuisine; categories = recipe.category.isEmpty ? [] : [recipe.category]
        tags = recipe.tags; imageURL = recipe.imageURL.isEmpty ? nil : recipe.imageURL
        sourceName = recipe.sourceName; sourceURL = recipe.sourceURL.isEmpty ? nil : recipe.sourceURL
    }

    private static func ingredient(_ raw: String) -> RecipeIngredient {
        RecipeIngredient(name: raw.trimmingCharacters(in: .whitespacesAndNewlines), amount: "")
    }
    private static func firstInteger(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        return raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first
    }
    private static func splitSteps(_ raw: String) -> [String] {
        raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

nonisolated enum CanonicalRecipeValidationError: LocalizedError, Equatable {
    case missingTitle, missingImage, missingIngredients, missingSteps
    var errorDescription: String? {
        switch self {
        case .missingTitle: "The recipe needs a title."
        case .missingImage: "The recipe needs a usable image."
        case .missingIngredients: "The recipe needs ingredients."
        case .missingSteps: "The recipe needs cooking steps."
        }
    }
}

@MainActor enum CanonicalRecipeActions {
    static func validate(_ recipe: CanonicalRecipeDescriptor) throws {
        if recipe.normalizedTitle.isEmpty { throw CanonicalRecipeValidationError.missingTitle }
        if recipe.imageData == nil && (recipe.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw CanonicalRecipeValidationError.missingImage
        }
        if recipe.ingredients.isEmpty { throw CanonicalRecipeValidationError.missingIngredients }
        if recipe.steps.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw CanonicalRecipeValidationError.missingSteps
        }
    }

    /// Idempotent save used by URL, share, web, online, server, AI, and manual imports.
    @discardableResult static func save(_ recipe: CanonicalRecipeDescriptor, to store: GuestDataStore) throws -> UUID {
        try validate(recipe)
        if let sourceURL = recipe.sourceURL?.lowercased(),
           let existing = store.userRecipes.first(where: { $0.sourceURL?.lowercased() == sourceURL }) { return existing.id }
        if let existing = store.userRecipes.first(where: {
            CanonicalRecipeDescriptor($0).normalizedTitle == recipe.normalizedTitle
        }) { return existing.id }
        var saved = recipe.userRecipe
        if let sourceID = UUID(uuidString: recipe.stableID) { saved.id = sourceID }
        store.addUserRecipe(saved)
        return saved.id
    }
}

// MARK: - Grocery writes with structured outcomes and provenance

nonisolated enum GroceryProvenanceReason: String, Codable, Sendable {
    case manual, lowStock, recipe, plannedMeal, substitution, usual, scan, serverSuggestion
}

nonisolated struct GroceryMutationRequest: Sendable, Equatable {
    var name: String
    var quantity = 1
    var sizeText = ""
    var recommended = false
    var recipeSource = ""
    var recipeID = ""
    var reason: GroceryProvenanceReason = .manual
    var dependencyIDs: [String] = []
}

nonisolated enum GroceryMutationOutcome: Sendable, Equatable {
    case added(UUID), consolidated(UUID, quantity: Int), unchanged(UUID), rejected(String)
}

nonisolated struct GroceryProvenanceRecord: Codable, Sendable, Equatable {
    var itemID: UUID
    var reasons: [GroceryProvenanceReason]
    var dependencyIDs: [String]
    var updatedAt: Date
}

@Observable @MainActor final class GroceryProvenanceCenter {
    static let shared = GroceryProvenanceCenter()
    private(set) var records: [UUID: GroceryProvenanceRecord]
    private let key = "grocery.provenance.v1"
    private init() {
        records = (try? JSONDecoder().decode([UUID: GroceryProvenanceRecord].self,
            from: UserDefaults.standard.data(forKey: key) ?? Data())) ?? [:]
    }
    func record(itemID: UUID, request: GroceryMutationRequest) {
        var value = records[itemID] ?? .init(itemID: itemID, reasons: [], dependencyIDs: [], updatedAt: .now)
        if !value.reasons.contains(request.reason) { value.reasons.append(request.reason) }
        value.dependencyIDs = Array(Set(value.dependencyIDs + request.dependencyIDs)).sorted()
        value.updatedAt = .now; records[itemID] = value; persist()
    }
    func prune(validIDs: Set<UUID>) { records = records.filter { validIDs.contains($0.key) }; persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: key) }
    }
}

@MainActor enum GroceryMutationService {
    @discardableResult static func apply(_ request: GroceryMutationRequest, to store: GuestDataStore) -> GroceryMutationOutcome {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .rejected("Item name is empty") }
        let key = GroceryConsolidator.normalizeKey(name)
        if let index = store.groceryItems.firstIndex(where: { GroceryConsolidator.normalizeKey($0.name) == key }) {
            let old = store.groceryItems[index].quantity
            let increment = max(0, request.quantity)
            if increment > 0 { store.groceryItems[index].quantity = max(1, old + increment) }
            if store.groceryItems[index].recipeSource.isEmpty { store.groceryItems[index].recipeSource = request.recipeSource }
            if store.groceryItems[index].recipeId.isEmpty { store.groceryItems[index].recipeId = request.recipeID }
            if store.groceryItems[index].sizeText.isEmpty { store.groceryItems[index].sizeText = request.sizeText }
            store.groceryItems[index].isRecommended = store.groceryItems[index].isRecommended || request.recommended
            let id = store.groceryItems[index].id
            GroceryProvenanceCenter.shared.record(itemID: id, request: request)
            return increment == 0 ? .unchanged(id) : .consolidated(id, quantity: store.groceryItems[index].quantity)
        }
        let item = LocalGroceryItem(quantity: max(1, request.quantity), name: name, isChecked: false,
            isRecommended: request.recommended, recipeSource: request.recipeSource,
            recipeId: request.recipeID, sizeText: request.sizeText)
        store.groceryItems.append(item)
        GroceryProvenanceCenter.shared.record(itemID: item.id, request: request)
        return .added(item.id)
    }

    static func apply(_ requests: [GroceryMutationRequest], to store: GuestDataStore) -> [GroceryMutationOutcome] {
        requests.map { apply($0, to: store) }
    }
}

// MARK: - Shared availability and dependency revisions

nonisolated enum IngredientAvailabilityState: String, Codable, Sendable {
    case confirmed, probable, uncertain, missing, expired
}
nonisolated struct KitchenIngredientAvailability: Identifiable, Sendable, Equatable {
    var id: String { ingredient.id.uuidString }
    var ingredient: RecipeIngredient
    var state: IngredientAvailabilityState
    var inventoryItemID: UUID?
}
nonisolated struct KitchenAvailabilitySnapshot: Sendable, Equatable {
    var recipeID: String
    var inventoryRevision: Int
    var ingredients: [KitchenIngredientAvailability]
    var makeable: Bool { ingredients.allSatisfy { $0.state == .confirmed || $0.state == .probable } }
}

@MainActor enum KitchenAvailabilityService {
    static func snapshot(for recipe: CanonicalRecipeDescriptor, store: GuestDataStore) -> KitchenAvailabilitySnapshot {
        let values = recipe.ingredients.map { ingredient -> KitchenIngredientAvailability in
            let needle = GroceryConsolidator.normalizeKey(ingredient.name)
            let match = store.inventoryItems.first { item in
                let candidate = GroceryConsolidator.normalizeKey(item.name)
                return candidate == needle || candidate.contains(needle) || needle.contains(candidate)
            }
            guard let match else { return .init(ingredient: ingredient, state: .missing) }
            let state: IngredientAvailabilityState
            if match.isExpired { state = .expired }
            else { switch match.confidence {
                case .confirmed: state = .confirmed
                case .probable: state = .probable
                case .unknown: state = .uncertain
                case .possiblyExpired: state = .expired
                case .outOfStock: state = .missing
            }}
            return .init(ingredient: ingredient, state: state, inventoryItemID: match.id)
        }
        return .init(recipeID: recipe.id, inventoryRevision: store.inventoryRevision, ingredients: values)
    }
}

nonisolated enum HubDependency: String, CaseIterable, Sendable { case inventory, grocery, recipes, plan, profile }
nonisolated enum HubDependencyGraph {
    static let dependencies: [InterHubTab: Set<HubDependency>] = [
        .home: [.inventory, .grocery, .recipes, .plan], .cook: [.inventory, .recipes, .plan, .profile],
        .inventory: [.inventory, .grocery], .recipes: [.recipes, .inventory, .profile],
        .grocery: [.grocery, .inventory, .recipes, .plan]
    ]
}

// MARK: - One background-work policy (coalescing, retry, progress, cancellation)

actor InterHubBackgroundCoordinator {
    static let shared = InterHubBackgroundCoordinator()
    private var tasks: [String: Task<Void, Never>] = [:]

    func schedule(key: String, title: String, maximumAttempts: Int = 3,
                  operation: @escaping @Sendable () async throws -> Void) {
        guard tasks[key] == nil else { return }
        tasks[key] = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled && attempt < max(1, maximumAttempts) {
                do { try await operation(); break }
                catch {
                    attempt += 1
                    guard attempt < maximumAttempts else { break }
                    try? await Task.sleep(for: .milliseconds(300 * (1 << min(attempt, 4))))
                }
            }
            await self?.finished(key)
        }
    }
    func cancel(key: String) { tasks.removeValue(forKey: key)?.cancel() }
    private func finished(_ key: String) { tasks[key] = nil }
}

// MARK: - Cross-hub search

nonisolated struct InterHubSearchResult: Identifiable, Sendable, Equatable {
    var id: String { route.deduplicationKey }
    var title: String
    var subtitle: String
    var symbol: String
    var route: InterHubRoute
}

@MainActor enum InterHubSearchService {
    static func localResults(for rawQuery: String, store: GuestDataStore, limit: Int = 30) -> [InterHubSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return StockedActionRegistry.all.prefix(limit).map {
            .init(title: $0.title, subtitle: $0.subtitle, symbol: $0.symbol, route: $0.route)
        }}
        var results: [InterHubSearchResult] = []
        results += store.inventoryItems.filter { $0.name.lowercased().contains(query) }.map {
            .init(title: $0.name, subtitle: "Inventory", symbol: "archivebox", route: .inventoryItem($0.id))
        }
        results += store.groceryItems.filter { $0.name.lowercased().contains(query) }.map {
            .init(title: $0.name, subtitle: "Grocery list", symbol: "cart", route: .groceryItem($0.id))
        }
        results += store.userRecipes.filter { $0.title.lowercased().contains(query) }.map {
            .init(title: $0.title, subtitle: "Saved recipe", symbol: "fork.knife", route: .recipe(id: $0.id.uuidString, kind: .user))
        }
        results += StockedActionRegistry.all.filter {
            $0.title.lowercased().contains(query) || $0.subtitle.lowercased().contains(query)
        }.map { .init(title: $0.title, subtitle: $0.subtitle, symbol: $0.symbol, route: $0.route) }
        return Array(results.prefix(limit))
    }
}
