// USDANutritionClient.swift
// ─────────────────────────────────────────────────────────────────────────────
// Live nutrition lookup via USDA FoodData Central API.
// Free, no key required for basic use (demo key: DEMO_KEY, 30 req/hour).
//
// Usage:
//   let facts = await USDANutritionClient.shared.lookup("chicken breast")
//
// Integration:
//   NutritionDatabase.facts(for:) checks static DB first, then falls back
//   to this client for any ingredient not found locally. Results are cached
//   in UserDefaults (key: "usdaCache_v1") so each ingredient is only fetched once.
//
// API Docs: https://fdc.nal.usda.gov/api-guide.html
// ─────────────────────────────────────────────────────────────────────────────
import Foundation
import os

@MainActor
final class USDANutritionClient {

    static let shared = USDANutritionClient()
    private init() { loadCache() }

    // USDA FoodData Central — survey foods endpoint. Key comes from BuildConfig
    // (Info.plist USDAAPIKey), falling back to DEMO_KEY for development.
    private let base    = "https://api.nal.usda.gov/fdc/v1"
    private var apiKey: String { BuildConfig.usdaAPIKey }

    private var cache: [String: NutritionFacts] = [:]
    private let cacheKey = "usdaCache_v1"

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    // MARK: - Main lookup (static DB first, then USDA)
    func facts(for name: String) async -> NutritionFacts? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)

        // 1. Static database (instant, offline)
        if let local = NutritionDatabase.facts(for: key) { return local }

        // 2. In-memory / UserDefaults cache
        if let cached = cache[key] { return cached }

        // 3. USDA live lookup
        return await fetchFromUSDA(query: key)
    }

    // MARK: - USDA search + first result nutrient parse
    private func fetchFromUSDA(query: String) async -> NutritionFacts? {
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "\(base)/foods/search?query=\(enc)&dataType=Survey%20%28FNDDS%29,SR%20Legacy&pageSize=1&api_key=\(apiKey)") else { return nil }

        guard let (data, response) = try? await session.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // 429 = over rate limit (common with DEMO_KEY), 403 = bad/blocked key.
            Log.net.error("USDA lookup failed (HTTP \(http.statusCode, privacy: .public)) for \(query, privacy: .public)")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let foods = json["foods"] as? [[String: Any]],
              let first = foods.first else { return nil }

        guard let facts = parseFood(first) else { return nil }
        let key = query.lowercased()
        cache[key] = facts
        persistCache()
        return facts
    }

    // MARK: - Nutrient extraction
    private func parseFood(_ food: [String: Any]) -> NutritionFacts? {
        guard let nutrients = food["foodNutrients"] as? [[String: Any]] else { return nil }

        // USDA nutrient IDs we care about
        // 1008=Energy(kcal), 1003=Protein, 1004=Fat, 1005=Carbs,
        // 1079=Fiber, 2000=Sugars, 1093=Sodium, 1088=Cholesterol
        // 1258=SatFat, 1087=Calcium, 1089=Iron, 1092=Potassium
        var map: [Int: Double] = [:]
        for n in nutrients {
            if let id = n["nutrientId"] as? Int,
               let val = n["value"] as? Double {
                map[id] = val
            }
        }

        let cal = Int(map[1008] ?? 0)
        guard cal > 0 else { return nil }

        return NutritionFacts(
            servingSize:  "100g",
            calories:     cal,
            totalFat:     map[1004] ?? 0,
            saturatedFat: map[1258] ?? 0,
            transFat:     0,
            cholesterol:  map[1088] ?? 0,
            sodium:       map[1093] ?? 0,
            totalCarbs:   map[1005] ?? 0,
            dietaryFiber: map[1079] ?? 0,
            totalSugars:  map[2000] ?? 0,
            addedSugars:  0,
            protein:      map[1003] ?? 0,
            vitaminD:     map[1114] ?? 0,
            calcium:      map[1087] ?? 0,
            iron:         map[1089] ?? 0,
            potassium:    map[1092] ?? 0
        )
    }

    // MARK: - Cache persistence
    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([String: CodableNutritionFacts].self, from: data)
        else { return }
        cache = decoded.mapValues { $0.toFacts() }
    }

    private func persistCache() {
        let encodable = cache.mapValues { CodableNutritionFacts(from: $0) }
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
}

// MARK: - Codable wrapper for NutritionFacts (Codable not on the model)
private struct CodableNutritionFacts: Codable {
    var servingSize, calories, totalFat, saturatedFat, transFat,
        cholesterol, sodium, totalCarbs, dietaryFiber, totalSugars,
        addedSugars, protein, vitaminD, calcium, iron, potassium: Double

    init(from f: NutritionFacts) {
        servingSize = 0; calories = Double(f.calories)
        totalFat = f.totalFat; saturatedFat = f.saturatedFat; transFat = f.transFat
        cholesterol = f.cholesterol; sodium = f.sodium; totalCarbs = f.totalCarbs
        dietaryFiber = f.dietaryFiber; totalSugars = f.totalSugars; addedSugars = f.addedSugars
        protein = f.protein; vitaminD = f.vitaminD; calcium = f.calcium
        iron = f.iron; potassium = f.potassium
    }

    func toFacts() -> NutritionFacts {
        NutritionFacts(servingSize: "100g", calories: Int(calories),
            totalFat: totalFat, saturatedFat: saturatedFat, transFat: transFat,
            cholesterol: cholesterol, sodium: sodium, totalCarbs: totalCarbs,
            dietaryFiber: dietaryFiber, totalSugars: totalSugars, addedSugars: addedSugars,
            protein: protein, vitaminD: vitaminD, calcium: calcium,
            iron: iron, potassium: potassium)
    }
}
