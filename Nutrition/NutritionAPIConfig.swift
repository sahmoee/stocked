//
//  NutritionAPIConfig.swift
//  Stocked
//
//  Central lookup for the API credentials used by the nutrition/recipe clients.
//  Keys are read from Info.plist, which in turn resolves them from Secrets.xcconfig
//  (for example Info.plist key ChompAPIKey = $(CHOMP_API_KEY)). Never hard-code keys here.
//

import Foundation

nonisolated enum NutritionAPIConfig {

    /// Info.plist key names. The plist values must reference Secrets.xcconfig build settings.
    private enum PlistKey {
        static let chomp = "ChompAPIKey"
        static let suggestic = "SuggesticAPIToken"
        static let logMeal = "LogMealAPIToken"
    }

    /// Chomp Food Database API key (branded foods, barcodes, ingredients).
    static var chompAPIKey: String? { string(for: PlistKey.chomp) }

    /// Suggestic GraphQL API token (recipes, meal plans).
    static var suggesticToken: String? { string(for: PlistKey.suggestic) }

    /// LogMeal API user token (food image recognition).
    static var logMealToken: String? { string(for: PlistKey.logMeal) }

    /// Reads a non-empty string from Info.plist, or nil when missing/blank.
    private static func string(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Errors surfaced by the nutrition/recipe API clients.
nonisolated enum NutritionAPIError: Error, LocalizedError {
    case missingKey(String)
    case badResponse(Int)
    case decoding
    case invalidRequest

    var errorDescription: String? {
        switch self {
        case .missingKey(let name):
            return "Missing API credential: \(name). Add it to Secrets.xcconfig and Info.plist."
        case .badResponse(let code):
            return "The service returned an unexpected status (\(code))."
        case .decoding:
            return "The response could not be read."
        case .invalidRequest:
            return "The request could not be built."
        }
    }
}

/// Builds a URLSession carrying Stocked's User-Agent and JSON Accept headers.
/// copyWithUA() is fileprivate to RecipeSourcesPlus.swift, so clients build their own here.
nonisolated enum NutritionAPISession {
    static func make() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Stocked/1.0 (iOS; nutrition-api-client)",
            "Accept": "application/json"
        ]
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }
}
