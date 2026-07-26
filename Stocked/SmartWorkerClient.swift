// SmartWorkerClient.swift — typed client for the Worker's "smart" endpoints (v2026-07-17.2).
//
// One async method per Worker route. All are additive and non-fatal: any network/decode failure
// returns nil (or an empty result) so callers degrade gracefully. Auth matches the rest of the
// app (X-Stocked-Key via BuildConfig.authorizeWorkerRequest).

import Foundation

// MARK: - Response models

nonisolated struct SmartParsedQuantity: Codable, Sendable { let value: Double?; let unit: String; let ingredient: String }
nonisolated struct SmartPantryMatch: Codable, Sendable { let makeable: Bool; let score: Double; let have: [String]; let missing: [String] }
nonisolated struct SmartSubstitution: Codable, Sendable, Hashable { let sub: String; let ratio: String; let vegan: Bool?; let glutenFree: Bool? }
nonisolated struct SmartGroceryLine: Codable, Sendable, Hashable { let name: String; let aisle: String; let quantity: String }
nonisolated struct SmartNutritionItem: Codable, Sendable { let name: String; let grams: Int?; let kcal: Int? }
nonisolated struct SmartNutritionTotal: Codable, Sendable { let kcal: Int; let protein: Int; let carbs: Int; let fat: Int }
nonisolated struct SmartNutrition: Codable, Sendable { let items: [SmartNutritionItem]; let total: SmartNutritionTotal }
nonisolated struct SmartExpiry: Codable, Sendable { let category: String; let storage: String; let days: Int; let source: String? }
nonisolated struct SmartMealSuggestion: Codable, Sendable { let title: String; let makeable: Bool; let score: Double; let have: [String]; let missing: [String] }
nonisolated struct SmartBatchBarcode: Codable, Sendable { let code: String; let ok: Bool }

actor SmartClient {
    static let shared = SmartClient()

    private var base: URL? { StockedWorkerClient.url() ?? URL(string: BuildConfig.receiptWorkerURL) }

    // MARK: Public API (one per Worker route)

    /// /units/convert — value in `from` units → `to` units (density-aware for volume↔mass).
    func convertUnits(_ value: Double, from: String, to: String, ingredient: String? = nil) async -> Double? {
        var q = ["value": String(value), "from": from, "to": to]
        if let ingredient { q["ingredient"] = ingredient }
        return (await get("/units/convert", q, DoubleValue.self))?.value
    }

    /// /units/parse — "1 1/2 cups flour" → {value, unit, ingredient}.
    func parseQuantity(_ text: String) async -> SmartParsedQuantity? {
        (await get("/units/parse", ["q": text], ParseResp.self))?.parsed
    }

    /// /units/temperature — oven °F ↔ °C ↔ gas mark.
    func convertTemperature(_ value: Double, from: String, to: String) async -> Int? {
        (await get("/units/temperature", ["value": String(value), "from": from, "to": to], IntValue.self))?.value
    }

    /// /recipe/scale — scale ingredient lines by a factor (or targetServings/fromServings).
    func scaleRecipe(_ ingredients: [String], factor: Double) async -> [String] {
        (await post("/recipe/scale", ["ingredients": ingredients, "factor": factor], ScaleResp.self))?.ingredients ?? ingredients
    }
    func scaleRecipe(_ ingredients: [String], fromServings: Int, toServings: Int) async -> [String] {
        (await post("/recipe/scale", ["ingredients": ingredients, "from": fromServings, "to": toServings], ScaleResp.self))?.ingredients ?? ingredients
    }

    /// /recipe/pantry-match — makeability + missing given a pantry.
    func pantryMatch(pantry: [String], ingredients: [String]) async -> SmartPantryMatch? {
        await post("/recipe/pantry-match", ["pantry": pantry, "ingredients": ingredients], SmartPantryMatch.self)
    }

    /// /ingredients/normalize — canonical ingredient names.
    func normalize(_ names: [String]) async -> [String] {
        (await post("/ingredients/normalize", ["names": names], NamesResp.self))?.names ?? names
    }

    /// /ingredients/substitute — substitutions with ratios, optional dietary filter.
    ///
    /// Improvement #15: cached stale-while-revalidate. Substitution answers barely change, so a
    /// cached list is served instantly (including with no connection) while a refresh runs behind
    /// it. This is the difference between the Substitutions tool working offline and showing
    /// nothing at all.
    func substitutions(for name: String, diet: String? = nil) async -> [SmartSubstitution] {
        await SmartCached.value(endpoint: "/ingredients/substitute",
                                arguments: "\(name)|\(diet ?? "")") { [self] in
            var q = ["name": name]; if let diet { q["diet"] = diet }
            return (await get("/ingredients/substitute", q, SubsResp.self))?.substitutions
        } ?? []
    }

    /// /grocery/optimize — dedupe, merge quantities, aisle-sort a list.
    func optimizeGrocery(_ items: [String]) async -> [SmartGroceryLine] {
        (await post("/grocery/optimize", ["items": items], GroceryResp.self))?.list ?? []
    }

    /// /grocery/from-recipes — combined shopping list across recipes' ingredients.
    func groceryFromRecipes(_ recipeIngredients: [[String]]) async -> [SmartGroceryLine] {
        let recipes = recipeIngredients.map { ["ingredients": $0] }
        return (await post("/grocery/from-recipes", ["recipes": recipes], GroceryResp.self))?.list ?? []
    }

    /// /nutrition/estimate — kcal/macros estimate for ingredient lines.
    /// Cached (#15): the same ingredient list always estimates the same, so a repeat is free.
    func estimateNutrition(_ ingredients: [String]) async -> SmartNutrition? {
        await SmartCached.value(endpoint: "/nutrition/estimate",
                                arguments: ingredients.joined(separator: "\n")) { [self] in
            await post("/nutrition/estimate", ["ingredients": ingredients], SmartNutrition.self)
        }
    }

    /// /expiry/estimate — shelf-life days for an item + storage (crowd-aware server-side).
    /// Cached (#15): called once per line on every receipt scan, so this removes the single
    /// biggest source of repeat network traffic in the app.
    func expiryEstimate(name: String, storage: String = "fridge") async -> SmartExpiry? {
        await SmartCached.value(endpoint: "/expiry/estimate",
                                arguments: "\(name)|\(storage)") { [self] in
            await get("/expiry/estimate", ["name": name, "storage": storage], SmartExpiry.self)
        }
    }

    /// /season/produce — in-season produce for a month (defaults to current).
    /// Cached (#15): changes once a month at most.
    func seasonProduce(month: Int? = nil) async -> [String] {
        let m = month ?? Calendar.current.component(.month, from: Date())
        return await SmartCached.value(endpoint: "/season/produce", arguments: String(m)) { [self] in
            var q: [String: String] = [:]; if let month { q["month"] = String(month) }
            return (await get("/season/produce", q, SeasonResp.self))?.produce
        } ?? []
    }

    /// /meal-plan/suggest — meals mostly-makeable from a pantry.
    func mealPlanSuggest(pantry: [String], days: Int = 5) async -> [SmartMealSuggestion] {
        (await post("/meal-plan/suggest", ["pantry": pantry, "days": days], MealPlanResp.self))?.suggestions ?? []
    }

    /// /barcodes/batch — resolve up to 25 barcodes at once.
    func barcodesBatch(_ codes: [String]) async -> [SmartBatchBarcode] {
        (await post("/barcodes/batch", ["codes": Array(codes.prefix(25))], BatchResp.self))?.results ?? []
    }

    /// /experiment — deterministic A/B bucket for this session.
    func experiment(_ name: String, buckets: [String] = ["a", "b"]) async -> String? {
        (await get("/experiment", ["name": name, "buckets": buckets.joined(separator: ",")], ExperimentResp.self))?.variant
    }

    // MARK: Plumbing

    private func makeRequest(_ path: String, query: [String: String], post body: Data?) -> URLRequest? {
        guard let base else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent(String(path.dropFirst())), resolvingAgainstBaseURL: false)
        if !query.isEmpty { comps?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = body == nil ? "GET" : "POST"
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        BuildConfig.authorizeWorkerRequest(&req)
        return req
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String], _ type: T.Type) async -> T? {
        guard let req = makeRequest(path, query: query, post: nil) else { return nil }
        return await run(req, type)
    }
    private func post<T: Decodable>(_ path: String, _ body: [String: Any], _ type: T.Type) async -> T? {
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body),
              let req = makeRequest(path, query: [:], post: data) else { return nil }
        return await run(req, type)
    }
    private func run<T: Decodable>(_ req: URLRequest, _ type: T.Type) async -> T? {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        } catch { return nil }
    }

    // Small envelope helpers for `{ ok, value }` style responses.
    nonisolated private struct DoubleValue: Codable { let value: Double? }
    nonisolated private struct IntValue: Codable { let value: Int? }
    nonisolated private struct ParseResp: Codable { let parsed: SmartParsedQuantity }
    nonisolated private struct ScaleResp: Codable { let ingredients: [String] }
    nonisolated private struct NamesResp: Codable { let names: [String] }
    nonisolated private struct SubsResp: Codable { let substitutions: [SmartSubstitution] }
    nonisolated private struct GroceryResp: Codable { let list: [SmartGroceryLine] }
    nonisolated private struct SeasonResp: Codable { let produce: [String] }
    nonisolated private struct MealPlanResp: Codable { let suggestions: [SmartMealSuggestion] }
    nonisolated private struct BatchResp: Codable { let results: [SmartBatchBarcode] }
    nonisolated private struct ExperimentResp: Codable { let variant: String? }
}
