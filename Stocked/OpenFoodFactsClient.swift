// OpenFoodFactsClient.swift
// Cached branded-food lookup using Open Food Facts, with nutrition, labels and ingredients.
import Foundation

nonisolated struct OpenFoodProduct: Codable, Sendable, Equatable {
    let barcode: String
    let name: String
    let brand: String
    let imageURL: String?
    let nutriScore: String?
    let allergens: [String]
    let nutrition: NutritionFacts?
    let quantity: String?
    let categories: String?
    let labels: [String]
    let ingredientsText: String?
    let sourceName: String

    var suggestedZone: String {
        let cat = (categories ?? "").lowercased()
        let nm = name.lowercased()
        if cat.contains("frozen") || nm.contains("frozen") { return "Freezer" }
        if cat.contains("fresh") || cat.contains("meat") || cat.contains("dairy") ||
            cat.contains("fish") || cat.contains("produce") || cat.contains("yogurt") ||
            cat.contains("milk") || nm.contains("juice") || cat.contains("egg") { return "Fridge" }
        if cat.contains("spice") || cat.contains("condiment") || cat.contains("sauce") ||
            cat.contains("vinegar") || cat.contains("sugar") || cat.contains("salt") ||
            cat.contains("baking") { return "Staples" }
        return "Pantry"
    }

    var estimatedShelfDays: Int {
        let cat = (categories ?? "").lowercased()
        let nm = name.lowercased()
        if cat.contains("frozen") { return 180 }
        if cat.contains("fresh-meat") || cat.contains("fresh-fish") { return 3 }
        if cat.contains("dairy") || cat.contains("milk") || cat.contains("yogurt") { return 10 }
        if cat.contains("produce") || cat.contains("fresh") { return 7 }
        if nm.contains("bread") || nm.contains("bakery") { return 5 }
        if cat.contains("canned") || cat.contains("tinned") { return 730 }
        if cat.contains("spice") || cat.contains("condiment") { return 365 }
        if cat.contains("snack") || cat.contains("cereal") || cat.contains("pasta") { return 270 }
        return 90
    }
}

actor OpenFoodFactsClient {
    static let shared = OpenFoodFactsClient()
    private init() {}

    private let base = "https://world.openfoodfacts.org/api/v2/product"
    private let cacheTTL: TimeInterval = 60 * 60 * 24 * 30
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache.shared
        return URLSession(configuration: configuration)
    }()

    func lookup(barcode: String) async -> OpenFoodProduct? {
        let cleaned = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let cacheKey = "openfoodfacts:barcode:\(cleaned)"
        if let cached = await APIResponseCache.shared.value(for: cacheKey, as: OpenFoodProduct.self) {
            return cached
        }

        let fields = [
            "product_name", "product_name_en", "brands", "image_front_url",
            "nutriscore_grade", "allergens_tags", "quantity", "categories_tags",
            "labels_tags", "ingredients_text", "ingredients_text_en", "serving_size",
            "nutriments"
        ].joined(separator: ",")
        guard var components = URLComponents(string: "\(base)/\(cleaned).json") else { return nil }
        components.queryItems = [URLQueryItem(name: "fields", value: fields)]
        guard let url = components.url else { return nil }

        let startedAt = Date()
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
                await SourceHealth.shared.record("open-food-facts", success: false,
                                                 latency: Date().timeIntervalSince(startedAt))
                return nil
            }
            await SourceHealth.shared.record("open-food-facts", success: true,
                                             latency: Date().timeIntervalSince(startedAt))
            guard let result = parseProduct(data, barcode: cleaned) else { return nil }
            await APIResponseCache.shared.store(result, for: cacheKey, ttl: cacheTTL)
            return result
        } catch {
            await SourceHealth.shared.record("open-food-facts", success: false,
                                             latency: Date().timeIntervalSince(startedAt))
            return nil
        }
    }

    /// All JSON-dictionary work happens here — nonisolated + synchronous — so the non-Sendable
    /// `[String: Any]` values are born and consumed in one place and never cross an isolation
    /// boundary (fixes the "sending 'product'/'nutrients' risks data races" errors).
    nonisolated private func parseProduct(_ data: Data, barcode cleaned: String) -> OpenFoodProduct? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["status"] as? NSNumber)?.intValue != 0,
              let product = json["product"] as? [String: Any] else { return nil }

        let name = nonEmpty(product["product_name_en"]) ?? nonEmpty(product["product_name"]) ?? ""
        guard !name.isEmpty else { return nil }

        let categoryTags = normalizedTags(product["categories_tags"])
        return OpenFoodProduct(
            barcode: cleaned,
            name: name,
            brand: nonEmpty(product["brands"]) ?? "",
            imageURL: nonEmpty(product["image_front_url"]),
            nutriScore: nonEmpty(product["nutriscore_grade"])?.uppercased(),
            allergens: normalizedTags(product["allergens_tags"]).map { $0.capitalized },
            nutrition: parseNutrition(
                product["nutriments"] as? [String: Any],
                servingSize: nonEmpty(product["serving_size"])
            ),
            quantity: nonEmpty(product["quantity"]),
            categories: categoryTags.isEmpty ? nil : categoryTags.joined(separator: ","),
            labels: normalizedTags(product["labels_tags"]).map { $0.capitalized },
            ingredientsText: nonEmpty(product["ingredients_text_en"]) ?? nonEmpty(product["ingredients_text"]),
            sourceName: "Open Food Facts"
        )
    }

    nonisolated private func parseNutrition(_ nutrients: [String: Any]?, servingSize: String?) -> NutritionFacts? {
        guard let nutrients else { return nil }
        let useServing = servingSize != nil && numeric(nutrients["energy-kcal_serving"]) > 0
        let suffix = useServing ? "_serving" : "_100g"
        func value(_ key: String) -> Double { numeric(nutrients[key + suffix]) }
        let calories = Int(value("energy-kcal").rounded())
        guard calories > 0 else { return nil }
        return NutritionFacts(
            servingSize: useServing ? (servingSize ?? "Serving") : "100 g",
            calories: calories,
            totalFat: value("fat"),
            saturatedFat: value("saturated-fat"),
            transFat: value("trans-fat"),
            cholesterol: value("cholesterol") * 1000,
            sodium: value("sodium") * 1000,
            totalCarbs: value("carbohydrates"),
            dietaryFiber: value("fiber"),
            totalSugars: value("sugars"),
            addedSugars: value("added-sugars"),
            protein: value("proteins"),
            vitaminD: value("vitamin-d") * 1_000_000,
            calcium: value("calcium") * 1000,
            iron: value("iron") * 1000,
            potassium: value("potassium") * 1000
        )
    }

    nonisolated private func normalizedTags(_ value: Any?) -> [String] {
        (value as? [String] ?? []).map { raw in
            let withoutLocale = raw.contains(":") ? String(raw.split(separator: ":", maxSplits: 1).last ?? "") : raw
            return withoutLocale.replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    nonisolated private func numeric(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }

    nonisolated private func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
