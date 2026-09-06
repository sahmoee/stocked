import Foundation

/// Shared recipe presentation hygiene for every iPhone and iPad recipe source.
nonisolated enum RecipeDisplayPolicy {
    static func cleanedTitle(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
        value = value.replacingOccurrences(
            of: #"^\s*(?:#?\d+[.)\]:-]?\s+|(?:best|easy|quick|amazing|delicious|ultimate|perfect)\s+)"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        value = value.replacingOccurrences(
            of: #"(?:\s+|\s*[-–—|:]\s*)(?:recipe\s+id\s*|id\s*)?\d{5,}\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        )
        value = value.replacingOccurrences(of: #"^[\p{P}\p{S}\s]+|[\p{P}\p{S}\s]+$"#,
                                            with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|:")))
    }

    static func titleSortKey(_ raw: String) -> String {
        let title = cleanedTitle(raw).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let start = title.firstIndex { $0.isLetter || $0.isNumber } ?? title.startIndex
        return String(title[start...])
    }

    static func isLikelyRecipeImageURL(_ raw: String, sourceURL: String? = nil) -> Bool {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else { return false }
        if let sourceURL, URL(string: sourceURL)?.standardized == url.standardized { return false }
        let token = (url.lastPathComponent + " " + url.path).lowercased()
        let branding = ["logo", "favicon", "app-icon", "appicon", "site-icon", "default-og", "og-default", "placeholder", "stocked-social", "stocked-logo"]
        return !branding.contains { token.contains($0) }
    }

    static func isPresentable(title: String, imageURL: String?, imageData: Data? = nil,
                              ingredients: Int, steps: Int, sourceURL: String? = nil) -> Bool {
        guard RecipeQuality.hasMeaningfulTitle(cleanedTitle(title)), ingredients >= 3, steps > 0 else { return false }
        if let imageData, !imageData.isEmpty { return true }
        guard let imageURL else { return false }
        return isLikelyRecipeImageURL(imageURL, sourceURL: sourceURL)
    }

    static func isDrink(title: String, categories: [String], tags: [String]) -> Bool {
        let text = ([title] + categories + tags).joined(separator: " ").lowercased()
        return ["drink", "beverage", "cocktail", "mocktail", "smoothie", "juice", "lemonade",
                "coffee", "tea", "punch", "shake"].contains { text.contains($0) }
    }
}
