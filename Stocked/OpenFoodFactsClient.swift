// OpenFoodFactsClient.swift
// ─────────────────────────────────────────────────────────────────────────────
// Live product lookup via the Open Food Facts public API (no key required).
// Used by BarcodeScannerView to enrich scanned products with:
//   • Full product name + brand
//   • Nutrition facts (per 100g) — mapped to NutritionFacts model
//   • Allergen list
//   • Nutri-Score grade (A–E)
//   • Product image URL
//
// Fallback: if the barcode isn't found, returns nil so the scanner
// can fall back to manual entry gracefully.
// ─────────────────────────────────────────────────────────────────────────────
import Foundation

struct OpenFoodProduct {
    let barcode:     String
    let name:        String
    let brand:       String
    let imageURL:    String?
    let nutriScore:  String?
    let allergens:   [String]
    let nutrition:   NutritionFacts?
    let quantity:    String?
    let categories:  String?      // OFF categories_tags field

    // Inferred storage zone from OFF category data
    var suggestedZone: String {
        let cat = (categories ?? "").lowercased()
        let nm  = name.lowercased()
        if cat.contains("frozen") || nm.contains("frozen") { return "Freezer" }
        if cat.contains("fresh") || cat.contains("meat") || cat.contains("dairy") ||
           cat.contains("fish") || cat.contains("produce") || cat.contains("yogurt") ||
           cat.contains("milk") || nm.contains("juice") || cat.contains("egg") { return "Fridge" }
        if cat.contains("spice") || cat.contains("condiment") || cat.contains("sauce") ||
           cat.contains("vinegar") || cat.contains("sugar") || cat.contains("salt") ||
           cat.contains("baking") { return "Staples" }
        return "Pantry"
    }

    // Estimated shelf life in days from OFF categories
    var estimatedShelfDays: Int {
        let cat = (categories ?? "").lowercased()
        let nm  = name.lowercased()
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

@MainActor
final class OpenFoodFactsClient {

    static let shared = OpenFoodFactsClient()
    private init() {}

    private let base = "https://world.openfoodfacts.org/api/v2/product"
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    // MARK: - Main lookup
    func lookup(barcode: String) async -> OpenFoodProduct? {
        let fields = "product_name,product_name_en,brands,image_front_url," +
                     "nutriscore_grade,allergens_tags,quantity,categories_tags," +
                     "nutriments"
        guard let url = URL(string: "\(base)/\(barcode).json?fields=\(fields)") else { return nil }

        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let product = json["product"] as? [String: Any] else { return nil }

        // Name — prefer English
        let name = nonEmpty(product["product_name_en"]) ??
                   nonEmpty(product["product_name"])    ?? ""
        guard !name.isEmpty else { return nil }

        let brand    = nonEmpty(product["brands"]) ?? ""
        let imageURL = nonEmpty(product["image_front_url"])
        let grade    = nonEmpty(product["nutriscore_grade"])?.uppercased()
        let qty      = nonEmpty(product["quantity"])
        let catTags  = (product["categories_tags"] as? [String] ?? [])
            .map { $0.hasPrefix("en:") ? String($0.dropFirst(3)) : $0 }
            .joined(separator: ",")

        // Allergens — strip "en:" prefix
        let allergenTags = product["allergens_tags"] as? [String] ?? []
        let allergens = allergenTags.map { tag in
            tag.hasPrefix("en:") ? String(tag.dropFirst(3)) : tag
        }.map { $0.replacingOccurrences(of: "-", with: " ").capitalized }

        // Nutrition (per 100g)
        let facts = parseNutrition(product["nutriments"] as? [String: Any])

        return OpenFoodProduct(
            barcode:    barcode,
            name:       name,
            brand:      brand,
            imageURL:   imageURL,
            nutriScore: grade,
            allergens:  allergens,
            nutrition:  facts,
            quantity:   qty,
            categories: catTags.isEmpty ? nil : catTags
        )
    }

    // MARK: - Nutriments → NutritionFacts
    private func parseNutrition(_ n: [String: Any]?) -> NutritionFacts? {
        guard let n else { return nil }
        func d(_ key: String) -> Double { n["\(key)_100g"] as? Double ?? 0 }
        let cal = Int(d("energy-kcal"))
        guard cal > 0 else { return nil }
        return NutritionFacts(
            servingSize:  "100g",
            calories:     cal,
            totalFat:     d("fat"),
            saturatedFat: d("saturated-fat"),
            transFat:     d("trans-fat"),
            cholesterol:  d("cholesterol") * 1000,   // OFF stores in g, model uses mg
            sodium:       d("sodium") * 1000,
            totalCarbs:   d("carbohydrates"),
            dietaryFiber: d("fiber"),
            totalSugars:  d("sugars"),
            addedSugars:  0,
            protein:      d("proteins"),
            vitaminD:     0,
            calcium:      d("calcium") * 1000,
            iron:         d("iron") * 1000,
            potassium:    d("potassium") * 1000
        )
    }

    private func nonEmpty(_ val: Any?) -> String? {
        guard let s = val as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
