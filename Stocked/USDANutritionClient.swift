// USDANutritionClient.swift
// USDA FoodData Central nutrition and branded-product fallback with persistent API caching.
import Foundation
import os

actor USDANutritionClient {
    static let shared = USDANutritionClient()
    private init() {
        memory = Self.migrateLegacyCache()
    }

    private let base = "https://api.nal.usda.gov/fdc/v1"
    private var apiKey: String { BuildConfig.usdaAPIKey }
    private let cacheTTL: TimeInterval = 60 * 60 * 24 * 30
    private let negativeCacheTTL: TimeInterval = 60 * 60 * 24 * 7
    private let cooldownKey = "usdaNutritionClient.cooldownUntil.v1"
    private let negativePrefix = "usda:nutrition-negative:"
    private var memory: [String: NutritionFacts] = [:]
    private var negativeMemory: [String: Date] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache.shared
        return URLSession(configuration: configuration)
    }()

    func facts(for name: String) async -> NutritionFacts? {
        guard let key = normalizedSearchTerm(name, minimumLength: 2) else { return nil }
        if let local = NutritionDatabase.facts(for: key) { return local }
        if let cached = memory[key] { return cached }
        guard shouldAttemptLookup(for: key) else { return nil }

        let cacheKey = "usda:nutrition:\(key)"
        if let cached = await APIResponseCache.shared.value(for: cacheKey, as: NutritionFacts.self) {
            memory[key] = cached
            return cached
        }
        guard let first = await searchFoods(
            query: key,
            dataTypes: "Branded,Foundation,Survey (FNDDS),SR Legacy",
            pageSize: 5
        ).first,
              let facts = parseFood(first) else {
            markNegativeLookup(for: key)
            return nil
        }
        memory[key] = facts
        await APIResponseCache.shared.store(facts, for: cacheKey, ttl: cacheTTL)
        return facts
    }

    /// Branded-food fallback for UPC scans. Open Food Facts remains first because it usually
    /// has images and labels; USDA fills brand, ingredients, serving size and nutrition gaps.
    func lookupProduct(barcode: String) async -> OpenFoodProduct? {
        let cleaned = normalizedBarcode(barcode)
        guard !cleaned.isEmpty, hasUsableAPIKey, !isCoolingDown else { return nil }
        let cacheKey = "usda:barcode:\(cleaned)"
        if let cached = await APIResponseCache.shared.value(for: cacheKey, as: OpenFoodProduct.self) {
            return cached
        }

        let foods = await searchFoods(query: cleaned, dataTypes: "Branded", pageSize: 10)
        guard let food = foods.first(where: {
            normalizedBarcode(string($0["gtinUpc"])) == cleaned
        }) ?? foods.first else { return nil }

        let name = string(food["description"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let serving = servingText(food)
        let result = OpenFoodProduct(
            barcode: cleaned,
            name: name,
            brand: firstNonEmpty(string(food["brandName"]), string(food["brandOwner"])),
            imageURL: nil,
            nutriScore: nil,
            allergens: [],
            nutrition: parseFood(food, servingSize: serving ?? "100 g"),
            quantity: serving,
            categories: firstNonEmpty(string(food["foodCategory"]), string(food["marketCountry"])).nilIfEmpty,
            labels: ["USDA Branded Food"],
            ingredientsText: string(food["ingredients"]).nilIfEmpty,
            sourceName: "USDA FoodData Central"
        )
        await APIResponseCache.shared.store(result, for: cacheKey, ttl: cacheTTL)
        return result
    }

    private func searchFoods(query: String, dataTypes: String, pageSize: Int) async -> [[String: Any]] {
        guard hasUsableAPIKey, !isCoolingDown else { return [] }
        guard var components = URLComponents(string: "\(base)/foods/search") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "dataType", value: dataTypes),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "api_key", value: apiKey)
        ]
        guard let url = components.url else { return [] }
        let startedAt = Date()
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                await SourceHealth.shared.record("usda", success: false,
                                                 latency: Date().timeIntervalSince(startedAt))
                noteHTTPFailure(http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                Log.net.error("USDA lookup failed (HTTP \(http.statusCode, privacy: .public)); cooling down upstream lookups")
                return []
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                await SourceHealth.shared.record("usda", success: false,
                                                 latency: Date().timeIntervalSince(startedAt))
                return []
            }
            await SourceHealth.shared.record("usda", success: true,
                                             latency: Date().timeIntervalSince(startedAt))
            return json["foods"] as? [[String: Any]] ?? []
        } catch {
            await SourceHealth.shared.record("usda", success: false,
                                             latency: Date().timeIntervalSince(startedAt))
            return []
        }
    }

    private var hasUsableAPIKey: Bool {
        let cleaned = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        let upper = cleaned.uppercased()
        return upper != "DEMO_KEY" && upper != "YOUR_USDA_API_KEY" && upper != "$(USDA_API_KEY)"
    }

    private var isCoolingDown: Bool {
        guard let until = UserDefaults.standard.object(forKey: cooldownKey) as? Date else { return false }
        return until > Date()
    }

    private func shouldAttemptLookup(for key: String) -> Bool {
        guard hasUsableAPIKey, !isCoolingDown else { return false }
        if let until = negativeMemory[key], until > Date() { return false }
        if let until = UserDefaults.standard.object(forKey: negativePrefix + key) as? Date, until > Date() {
            negativeMemory[key] = until
            return false
        }
        return true
    }

    private func markNegativeLookup(for key: String) {
        let until = Date().addingTimeInterval(negativeCacheTTL)
        negativeMemory[key] = until
        UserDefaults.standard.set(until, forKey: negativePrefix + key)
    }

    private func noteHTTPFailure(_ statusCode: Int, retryAfter: String?) {
        let retryAfterSeconds = NetworkRetryPolicy.retryAfterSeconds(retryAfter) ?? 0
        let cooldown: TimeInterval
        switch statusCode {
        case 400, 401, 403:
            cooldown = max(retryAfterSeconds, 12 * 60 * 60)
        case 429:
            cooldown = max(retryAfterSeconds, 60 * 60)
        case 500..<600:
            cooldown = max(retryAfterSeconds, 5 * 60)
        default:
            cooldown = retryAfterSeconds
        }
        guard cooldown > 0 else { return }
        UserDefaults.standard.set(Date().addingTimeInterval(cooldown), forKey: cooldownKey)
    }

    private func normalizedSearchTerm(_ value: String, minimumLength: Int) -> String? {
        let collapsed = value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 &+'-]", with: " ", options: .regularExpression)
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count >= minimumLength else { return nil }
        guard collapsed.rangeOfCharacter(from: .letters) != nil else { return nil }
        return String(collapsed.prefix(96))
    }

    private func parseFood(_ food: [String: Any], servingSize: String = "100 g") -> NutritionFacts? {
        guard let nutrients = food["foodNutrients"] as? [[String: Any]] else { return nil }
        var byID: [Int: Double] = [:]
        var byName: [String: Double] = [:]
        for nutrient in nutrients {
            let value = number(nutrient["value"])
            if let id = integer(nutrient["nutrientId"]) { byID[id] = value }
            let name = string(nutrient["nutrientName"]).lowercased()
            if !name.isEmpty { byName[name] = value }
        }
        func nutrient(_ id: Int, names: [String] = []) -> Double {
            if let value = byID[id] { return value }
            for name in names {
                if let pair = byName.first(where: { $0.key.contains(name) }) { return pair.value }
            }
            return 0
        }
        let calories = Int(nutrient(1008, names: ["energy"]).rounded())
        guard calories > 0 else { return nil }
        return NutritionFacts(
            servingSize: servingSize,
            calories: calories,
            totalFat: nutrient(1004, names: ["total lipid", "total fat"]),
            saturatedFat: nutrient(1258, names: ["saturated"]),
            transFat: nutrient(1257, names: ["trans"]),
            cholesterol: nutrient(1253, names: ["cholesterol"]),
            sodium: nutrient(1093, names: ["sodium"]),
            totalCarbs: nutrient(1005, names: ["carbohydrate"]),
            dietaryFiber: nutrient(1079, names: ["fiber"]),
            totalSugars: nutrient(2000, names: ["sugars, total", "total sugars"]),
            addedSugars: nutrient(1235, names: ["added sugars"]),
            protein: nutrient(1003, names: ["protein"]),
            vitaminD: nutrient(1114, names: ["vitamin d"]),
            calcium: nutrient(1087, names: ["calcium"]),
            iron: nutrient(1089, names: ["iron"]),
            potassium: nutrient(1092, names: ["potassium"])
        )
    }

    private func servingText(_ food: [String: Any]) -> String? {
        let household = string(food["householdServingFullText"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !household.isEmpty { return household }
        let amount = number(food["servingSize"])
        let unit = string(food["servingSizeUnit"])
        guard amount > 0 else { return nil }
        return "\(amount.formatted(.number.precision(.fractionLength(0...2)))) \(unit)".trimmingCharacters(in: .whitespaces)
    }

    private func normalizedBarcode(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        let withoutLeadingZeros = digits.drop(while: { $0 == "0" })
        return withoutLeadingZeros.isEmpty ? digits : String(withoutLeadingZeros)
    }

    private func string(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
    private func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }
    private func number(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }
    private func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private nonisolated static func migrateLegacyCache() -> [String: NutritionFacts] {
        let key = "usdaCache_v1"
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: CodableNutritionFacts].self, from: data) else {
            return [:]
        }
        UserDefaults.standard.removeObject(forKey: key)
        return decoded.mapValues { $0.toFacts() }
    }
}

nonisolated private struct CodableNutritionFacts: Codable {
    var calories, totalFat, saturatedFat, transFat, cholesterol, sodium, totalCarbs,
        dietaryFiber, totalSugars, addedSugars, protein, vitaminD, calcium, iron, potassium: Double

    func toFacts() -> NutritionFacts {
        NutritionFacts(
            servingSize: "100 g", calories: Int(calories), totalFat: totalFat,
            saturatedFat: saturatedFat, transFat: transFat, cholesterol: cholesterol,
            sodium: sodium, totalCarbs: totalCarbs, dietaryFiber: dietaryFiber,
            totalSugars: totalSugars, addedSugars: addedSugars, protein: protein,
            vitaminD: vitaminD, calcium: calcium, iron: iron, potassium: potassium
        )
    }
}

nonisolated private extension String {
    var nilIfEmpty: String? {
        let cleaned = trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
