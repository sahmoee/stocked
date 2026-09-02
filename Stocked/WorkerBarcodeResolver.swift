// WorkerBarcodeResolver.swift — app adoption of the Worker's POST /barcodes/resolve.
//
// WHY (FUTURE_IDEAS.md): the old first-choice paths hit OpenFoodFacts/USDA directly from
// the device, and the last-resort path asked the LLM to guess a product from a UPC (which
// hallucinates). The Worker now centralizes the real-database lookup with a 30-day edge
// cache (and 24h negative cache), optionally merging retailer price data. The device tries
// the Worker FIRST — one fast, cached, keyless call — and only falls back to the local
// waterfall (device OpenFoodFacts → USDA → cache → UPCItemDB → AI) when the Worker is
// unreachable or has no match. Behavior is additive and fail-open.

import Foundation
import os

nonisolated enum WorkerBarcodeResolver {

    /// Wire shape of the Worker's resolved product (src/barcodes.js `normalize`).
    struct ResolvedProduct: Codable, Sendable {
        struct Nutrition: Codable, Sendable {
            var caloriesPer100g: Double?
            var proteinPer100g:  Double?
            var fatPer100g:      Double?
            var carbsPer100g:    Double?
            var sugarsPer100g:   Double?
            var sodiumPer100g:   Double?
        }
        var name: String
        var brand: String?
        var packageQuantity: String?
        var nutrition: Nutrition?
        var allergens: [String]?
        var category: String?
        var image: String?
        var suggestedZone: String?
        var price: Double?
    }

    private struct Envelope: Codable {
        var found: Bool
        var product: ResolvedProduct?
        var source: String?
    }

    /// Resolve a barcode through the Worker. Returns nil on miss OR any transport problem —
    /// callers treat nil as "fall back to the local waterfall". Never throws.
    static func resolve(_ code: String, includePrice: Bool = false,
                        timeout: TimeInterval = 6) async -> OpenFoodProduct? {
        guard let base = StockedWorkerClient.url() else { return nil }
        guard ConnectivityMonitor.isOnlineFlag else { return nil }

        var request = URLRequest(url: base.appendingPathComponent("barcodes/resolve"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&request)
        request.timeoutInterval = timeout
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "barcode": code, "includePrice": includePrice,
        ])

        let startedAt = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                await SourceHealth.shared.record("stocked-worker-barcode", success: false,
                                                 latency: Date().timeIntervalSince(startedAt))
                return nil
            }
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            // A valid not-found envelope is a healthy provider response, not an outage.
            await SourceHealth.shared.record("stocked-worker-barcode", success: true,
                                             latency: Date().timeIntervalSince(startedAt))
            guard env.found, let p = env.product, !p.name.isEmpty else { return nil }
            return OpenFoodProduct(
                barcode: code,
                name: p.name,
                brand: p.brand ?? "",
                imageURL: p.image,
                nutriScore: nil,
                allergens: p.allergens ?? [],
                nutrition: Self.mapNutrition(p.nutrition),
                quantity: p.packageQuantity,
                categories: p.category,
                labels: [],
                ingredientsText: nil,
                sourceName: env.source ?? "Stocked Worker"
            )
        } catch {
            await SourceHealth.shared.record("stocked-worker-barcode", success: false,
                                             latency: Date().timeIntervalSince(startedAt))
            Log.net.debug("Worker barcode resolve failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Map the Worker's per-100g nutrition into the app's NutritionFacts (per-100g basis,
    /// matching how OpenFoodFactsClient already populates it from the same upstream fields).
    private static func mapNutrition(_ n: ResolvedProduct.Nutrition?) -> NutritionFacts? {
        guard let n else { return nil }
        let hasAny = [n.caloriesPer100g, n.proteinPer100g, n.fatPer100g,
                      n.carbsPer100g, n.sugarsPer100g, n.sodiumPer100g]
            .contains { $0 != nil }
        guard hasAny else { return nil }
        var f = NutritionFacts()
        f.servingSize = "100 g"
        f.calories    = Int(n.caloriesPer100g ?? 0)
        f.protein     = n.proteinPer100g ?? 0
        f.totalFat    = n.fatPer100g ?? 0
        f.totalCarbs  = n.carbsPer100g ?? 0
        f.totalSugars = n.sugarsPer100g ?? 0
        f.sodium      = n.sodiumPer100g ?? 0
        return f
    }
}
