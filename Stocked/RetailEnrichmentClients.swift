import Foundation
import os

nonisolated struct StockedFoodRecall: Codable, Sendable, Identifiable {
    var id: String { recallNumber }
    let recallNumber: String
    let productDescription: String
    let reason: String?
    let recallingFirm: String?
    let classification: String?
    let status: String?
    let distribution: String?
    let reportDate: String?
}

private nonisolated struct RecallEnvelope: Decodable { let recalls: [StockedFoodRecall] }
private nonisolated struct FatSecretEnvelope: Decodable { let products: [FatSecretFood] }
private nonisolated struct FatSecretFood: Decodable {
    let name: String
    let brand: String?
    let nutrition: FatSecretNutrition?
}
private nonisolated struct FatSecretNutrition: Decodable {
    let calories: Double?
    let fat: Double?
    let carbohydrates: Double?
    let protein: Double?
    let servingDescription: String?
}

nonisolated enum RetailEnrichmentClient {
    static func fatSecretFacts(for query: String) async -> NutritionFacts? {
        guard let envelope: FatSecretEnvelope = await get(path: "/retail/fatsecret/foods",
                                                          query: ["query": query, "limit": "1"]) else { return nil }
        guard let nutrition = envelope.products.first?.nutrition,
              (nutrition.calories ?? 0) > 0 else { return nil }
        var facts = NutritionFacts()
        facts.servingSize = nutrition.servingDescription ?? ""
        facts.calories = Int((nutrition.calories ?? 0).rounded())
        facts.totalFat = nutrition.fat ?? 0
        facts.totalCarbs = nutrition.carbohydrates ?? 0
        facts.protein = nutrition.protein ?? 0
        return facts
    }

    static func reconciledFacts(for query: String, publisherFacts: NutritionFacts? = nil) async -> ReconciledNutrition? {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2 else { return nil }
        var candidates: [NutritionCandidate] = []
        if let publisherFacts, publisherFacts.calories > 0 {
            candidates.append(.init(facts: publisherFacts, source: "Publisher label",
                                    authority: 0.94, match: .brandedName))
        }
        async let usda = USDANutritionClient.shared.facts(for: cleaned)
        async let fatSecret = fatSecretFacts(for: cleaned)
        if let facts = await usda, facts.calories > 0 {
            candidates.append(.init(facts: facts, source: "USDA FoodData Central", authority: 0.98, match: .name))
        }
        if let facts = await fatSecret, facts.calories > 0 {
            candidates.append(.init(facts: facts, source: "FatSecret Platform API", authority: 0.82, match: .name))
        }
        let result = NutritionReconciler.reconcile(candidates)
        if let result { RetailNutritionCache.shared.store(result, for: cleaned) }
        return result
    }

    static func recalls(matching query: String, limit: Int = 5) async -> [StockedFoodRecall] {
        let envelope: RecallEnvelope? = await get(path: "/retail/recalls",
                                                  query: ["query": query, "limit": "\(limit)"])
        return envelope?.recalls ?? []
    }

    /// Reconcile a barcode/source result against authoritative USDA and the
    /// server-side FatSecret fallback. Unlike serving bases are never averaged.
    static func reconcile(product: OpenFoodProduct) async -> OpenFoodProduct {
        var candidates: [NutritionCandidate] = []
        if let current = product.nutrition, current.calories > 0 {
            candidates.append(.init(facts: current, source: product.sourceName,
                                    authority: 0.92, match: .barcode))
        }
        async let usda = USDANutritionClient.shared.facts(for: [product.brand, product.name]
            .filter { !$0.isEmpty }.joined(separator: " "))
        async let fatSecret = fatSecretFacts(for: [product.brand, product.name]
            .filter { !$0.isEmpty }.joined(separator: " "))
        if let facts = await usda, facts.calories > 0 {
            candidates.append(.init(facts: facts, source: "USDA FoodData Central",
                                    authority: 0.98, match: product.brand.isEmpty ? .name : .brandedName))
        }
        if let facts = await fatSecret, facts.calories > 0 {
            candidates.append(.init(facts: facts, source: "FatSecret Platform API",
                                    authority: 0.82, match: product.brand.isEmpty ? .name : .brandedName))
        }
        guard let result = NutritionReconciler.reconcile(candidates) else { return product }
        return OpenFoodProduct(barcode: product.barcode, name: product.name, brand: product.brand,
            imageURL: product.imageURL, nutriScore: product.nutriScore, allergens: product.allergens,
            nutrition: result.facts, quantity: product.quantity, categories: product.categories,
            labels: product.labels, ingredientsText: product.ingredientsText,
            sourceName: result.agreeingSources.count > 1
                ? "\(result.source) · confirmed by \(result.agreeingSources.count) sources"
                : result.source)
    }

    private static func get<T: Decodable>(path: String, query: [String: String]) async -> T? {
        guard ConnectivityMonitor.isOnlineFlag, let base = StockedWorkerClient.url() else { return nil }
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        parts?.queryItems = query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        guard let url = parts?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        BuildConfig.authorizeWorkerRequest(&request)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.net.notice("Retail enrichment unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Durable, bounded enrichment shared by inventory, grocery suggestions,
/// substitutions and serving calculations. It stores normalized facts only.
nonisolated final class RetailNutritionCache: @unchecked Sendable {
    static let shared = RetailNutritionCache()
    private struct Entry: Codable { let facts: NutritionFacts; let source: String; let confidence: Double; let savedAt: Date }
    private let lock = NSLock()
    private var entries: [String: Entry]
    private let key = "retailNutritionCache.v1"

    private init() {
        entries = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func facts(for name: String) -> NutritionFacts? {
        lock.withLock {
            guard let entry = entries[normalize(name)], Date().timeIntervalSince(entry.savedAt) < 30 * 86400 else { return nil }
            return entry.facts
        }
    }

    func store(_ result: ReconciledNutrition, for name: String) {
        lock.withLock {
            entries[normalize(name)] = Entry(facts: result.facts, source: result.source,
                                             confidence: result.confidence, savedAt: Date())
            if entries.count > 500 {
                let newest = entries.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(500)
                entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
            }
            if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    func calories(for name: String, servings: Double) -> Int? {
        guard let facts = facts(for: name), facts.calories > 0 else { return nil }
        return Int((Double(facts.calories) * max(0.25, servings)).rounded())
    }

    private func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
enum RetailEnrichmentMaintenance {
    private static let key = "retailEnrichmentMaintenance.lastRun.v2"
    private static let inventoryCursorKey = "retailEnrichmentMaintenance.inventoryCursor.v2"
    private static let groceryCursorKey = "retailEnrichmentMaintenance.groceryCursor.v2"

    static func runIfNeeded(store: GuestDataStore) {
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 24 * 3600 else { return }
        UserDefaults.standard.set(Date(), forKey: key)
        let inventory = rotatingBatch(store.inventoryItems, cursorKey: inventoryCursorKey, limit: 30)
        let grocery = rotatingBatch(store.groceryItems.filter { !$0.isChecked }, cursorKey: groceryCursorKey, limit: 20)
        Task(priority: .background) {
            let groceryAliases = await AppleOnDeviceAI.normalizeFoodNames(grocery.map(\.name))
            for item in inventory {
                await enrichInventoryItem(id: item.id, store: store)
            }
            for item in grocery {
                _ = await RetailEnrichmentClient.reconciledFacts(for: groceryAliases[item.name] ?? item.name)
            }
        }
    }

    /// Used by every future add/import path and by confirmed AI inventory edits.
    /// Calls are cheap to enqueue; the shared API caches and Worker rate limits
    /// prevent duplicate upstream work.
    static func enqueueInventoryItem(id: UUID, store: GuestDataStore) {
        Task(priority: .utility) { await enrichInventoryItem(id: id, store: store) }
    }

    static func enqueueInventoryItems(ids: [UUID], store: GuestDataStore) {
        Task(priority: .utility) {
            for id in ids {
                await enrichInventoryItem(id: id, store: store)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private static func enrichInventoryItem(id: UUID, store: GuestDataStore) async {
        guard let snapshot = store.inventoryItems.first(where: { $0.id == id }) else { return }
        var product: OpenFoodProduct?
        if let barcode = snapshot.barcode?.trimmingCharacters(in: .whitespacesAndNewlines), !barcode.isEmpty {
            product = await WorkerBarcodeResolver.resolve(barcode)
            if product == nil { product = await OpenFoodFactsClient.shared.lookup(barcode: barcode) }
        }
        let query = [snapshot.brand, snapshot.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let reconciled: OpenFoodProduct?
        if let product {
            reconciled = await RetailEnrichmentClient.reconcile(product: product)
        } else if let result = await RetailEnrichmentClient.reconciledFacts(for: query, publisherFacts: snapshot.nutrition) {
            reconciled = OpenFoodProduct(barcode: snapshot.barcode ?? "", name: snapshot.name, brand: snapshot.brand ?? "",
                imageURL: nil, nutriScore: nil, allergens: snapshot.productLabels ?? [], nutrition: result.facts,
                quantity: nil, categories: nil, labels: snapshot.productLabels ?? [],
                ingredientsText: snapshot.productIngredients, sourceName: result.source)
        } else {
            reconciled = nil
        }
        guard let enriched = reconciled, let index = store.inventoryItems.firstIndex(where: { $0.id == id }) else { return }
        if store.inventoryItems[index].brand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           !enriched.brand.isEmpty { store.inventoryItems[index].brand = enriched.brand }
        if let nutrition = enriched.nutrition, nutrition.calories > 0 {
            store.inventoryItems[index].nutrition = nutrition
            store.inventoryItems[index].nutritionSource = enriched.sourceName
        }
        if store.inventoryItems[index].productLabels?.isEmpty != false, !enriched.labels.isEmpty {
            store.inventoryItems[index].productLabels = enriched.labels
        }
        if store.inventoryItems[index].productIngredients?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let ingredients = enriched.ingredientsText?.trimmingCharacters(in: .whitespacesAndNewlines), !ingredients.isEmpty {
            store.inventoryItems[index].productIngredients = ingredients
        }
    }

    private static func rotatingBatch<T>(_ values: [T], cursorKey: String, limit: Int) -> [T] {
        guard !values.isEmpty else { return [] }
        let start = UserDefaults.standard.integer(forKey: cursorKey) % values.count
        let count = min(limit, values.count)
        let result = (0..<count).map { values[(start + $0) % values.count] }
        UserDefaults.standard.set((start + count) % values.count, forKey: cursorKey)
        return result
    }
}

actor FoodRecallMonitor {
    static let shared = FoodRecallMonitor()
    private let checkedKey = "foodRecallMonitor.lastCheck.v1"
    private let resultsKey = "foodRecallMonitor.matches.v1"

    func refreshIfNeeded(items: [LocalInventoryItem]) async {
        let last = UserDefaults.standard.object(forKey: checkedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 6 * 3600 else { return }
        let terms = Array(Set(items.compactMap { item -> String? in
            let value = [item.brand, item.name].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            return value.count >= 3 ? value : nil
        })).sorted().prefix(12)
        var matches: [StockedFoodRecall] = []
        for term in terms {
            matches.append(contentsOf: await RetailEnrichmentClient.recalls(matching: term, limit: 3))
        }
        matches = Dictionary(grouping: matches, by: \.recallNumber).compactMap { $0.value.first }
        if let data = try? JSONEncoder().encode(matches) { UserDefaults.standard.set(data, forKey: resultsKey) }
        UserDefaults.standard.set(Date(), forKey: checkedKey)
        if !matches.isEmpty { Log.data.notice("Food recall monitor matched \(matches.count, privacy: .public) inventory recall records") }
    }
}
