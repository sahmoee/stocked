//
//  LogMealClient.swift
//  Stocked
//
//  Client for the LogMeal Food AI API (food image recognition + nutrition).
//  Natural home: receipt/food photo scanning, to recognize dishes from a photo.
//  Results are cached by image content hash so re-scanning the same photo is free.
//
//  Docs: https://docs.logmeal.com
//  Auth header: Authorization: Bearer <APIUser token>
//  Flow: POST an image to segmentation/complete, then request nutritional info by imageId.
//

import Foundation
import CryptoKit

// MARK: - Public models

nonisolated struct LogMealDish: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(name)-\(Int(probability * 1000))" }
    let name: String
    let probability: Double
}

nonisolated struct LogMealResult: Codable, Hashable, Sendable {
    let imageId: Int
    let dishes: [LogMealDish]
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
}

// MARK: - Client

actor LogMealClient {

    static let shared = LogMealClient()

    private let session = NutritionAPISession.make()
    private let cache = APIResponseCache.shared
    private let ttl: TimeInterval = 60 * 60 * 24 * 30   // 30 days; recognition of same image is stable

    private enum Route {
        static let base = "https://api.logmeal.com/v2"
        static let segmentation = base + "/image/segmentation/complete"
        static func nutrition(imageId: Int) -> String { base + "/nutrition/recipe/nutritionalInfo/\(imageId)" }
    }

    /// Recognizes dishes in the given image (JPEG data) and fetches nutrition. Cached by image hash.
    func recognize(imageData: Data) async throws -> LogMealResult {
        let hash = Self.hash(imageData)
        let cacheKey = "logmeal.recognize.\(hash)"
        if let hit = await cache.value(for: cacheKey, as: LogMealResult.self) { return hit }

        guard let token = NutritionAPIConfig.logMealToken else {
            throw NutritionAPIError.missingKey("LogMealAPIToken")
        }

        let (imageId, dishes) = try await segment(imageData: imageData, token: token)
        let nutrients = try await nutrition(imageId: imageId, token: token)

        let result = LogMealResult(
            imageId: imageId,
            dishes: dishes,
            calories: nutrients.calories,
            protein: nutrients.protein,
            carbs: nutrients.carbs,
            fat: nutrients.fat
        )
        await cache.store(result, for: cacheKey, ttl: ttl)
        return result
    }

    // MARK: Segmentation

    private func segment(imageData: Data, token: String) async throws -> (Int, [LogMealDish]) {
        guard let url = URL(string: Route.segmentation) else { throw NutritionAPIError.invalidRequest }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(imageData: imageData, boundary: boundary)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NutritionAPIError.decoding }
        guard (200...299).contains(http.statusCode) else {
            throw NutritionAPIError.badResponse(http.statusCode)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imageId = root["imageId"] as? Int else {
            throw NutritionAPIError.decoding
        }

        return (imageId, Self.parseDishes(root))
    }

    // MARK: Nutrition

    private struct Nutrients {
        var calories: Double?
        var protein: Double?
        var carbs: Double?
        var fat: Double?
    }

    private func nutrition(imageId: Int, token: String) async throws -> Nutrients {
        guard let url = URL(string: Route.nutrition(imageId: imageId)) else {
            throw NutritionAPIError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            // Nutrition is best-effort; recognition already succeeded.
            return Nutrients()
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Nutrients()
        }

        let totals = (root["nutritional_info"] as? [String: Any])?["totalNutrients"] as? [String: Any]
            ?? root["totalNutrients"] as? [String: Any]
            ?? [:]

        return Nutrients(
            calories: Self.nutrientValue(root["nutritional_info"] as? [String: Any], key: "calories")
                ?? Self.number(root["calories"]),
            protein: Self.nutrientValue(totals, key: "PROCNT"),
            carbs: Self.nutrientValue(totals, key: "CHOCDF"),
            fat: Self.nutrientValue(totals, key: "FAT")
        )
    }

    // MARK: Helpers

    private static func parseDishes(_ root: [String: Any]) -> [LogMealDish] {
        // segmentation_results -> [ { recognition_results: [ { name, prob } ] } ]
        guard let segments = root["segmentation_results"] as? [[String: Any]] else { return [] }

        var dishes: [LogMealDish] = []
        for segment in segments {
            guard let results = segment["recognition_results"] as? [[String: Any]] else { continue }
            for result in results {
                guard let name = result["name"] as? String else { continue }
                let prob = Self.number(result["prob"]) ?? 0
                dishes.append(LogMealDish(name: name, probability: prob))
            }
        }
        return dishes.sorted { $0.probability > $1.probability }
    }

    private static func multipartBody(imageData: Data, boundary: String) -> Data {
        var body = Data()
        let boundaryPrefix = "--\(boundary)\r\n"
        body.append(boundaryPrefix.data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"scan.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private static func nutrientValue(_ dict: [String: Any]?, key: String) -> Double? {
        guard let dict else { return nil }
        if let direct = number(dict[key]) { return direct }
        if let nested = dict[key] as? [String: Any] {
            return number(nested["quantity"]) ?? number(nested["value"])
        }
        return nil
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func hash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
