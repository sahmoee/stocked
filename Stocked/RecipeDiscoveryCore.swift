import Foundation

nonisolated enum FinderSourceMode: String, Sendable { case web, database }

nonisolated enum FinderResultSource: Equatable, Sendable {
    case web, database, offline, webUnavailable, noWebMatches
    var isWeb: Bool { self == .web }
    var label: String { isWeb ? "From recipe websites" : "Database backup" }
    var explanation: String {
        switch self {
        case .web: "Live matches from supported publisher websites. Counts cover the recipes found, not the whole internet."
        case .database: "Searching the full downloaded database and bundled catalogue. New server pages join the backup as they sync."
        case .offline: "You’re offline. Showing matching recipes from the database stored on this device."
        case .webUnavailable: "Recipe websites couldn’t be reached. Showing matching database recipes with your filters unchanged."
        case .noWebMatches: "No verified web matches for these choices. Showing database matches with your filters unchanged."
        }
    }
}

nonisolated enum FinderWebPolicy {
    /// A title is not an identity: personal recipes with equal titles stay distinct.
    static func recipeIdentity(sourceURL: String?, id: UUID) -> String {
        guard let sourceURL, !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "saved:" + id.uuidString
        }
        return identity(sourceURL)
    }

    /// Include identities from ALL local matches, not just the visible top-N window.
    static func mergedCount(localCount: Int, localIdentities: Set<String>, webIdentities: Set<String>) -> Int {
        localCount + webIdentities.subtracting(localIdentities).count
    }

    /// Retrieval hints are not eligibility rules. OR choices generate separate seeds;
    /// the shared FinderQuery still enforces EVERY category against actual recipe data.
    /// Bounded discovery is deliberately not advertised as an exhaustive internet count.
    static func terms(_ filters: FinderFilters, inventoryNames: [String] = []) -> [String] {
        let query = FinderQuery.normalize(filters.query)
        if !query.isEmpty { return [String(query.prefix(180))] }
        func labels(_ category: FinderCategory) -> [String] {
            category.options.filter { filters.active(category).contains($0) && !$0.isDiscovery }.map(\.label)
        }
        var ingredients = labels(.ingredient)
        let cuisines = labels(.cuisine)
        if ingredients.isEmpty, filters[.kitchen].contains(.useWhatIHave) || filters[.kitchen].contains(.mostlyHave) {
            ingredients = Array(inventoryNames.filter { !$0.isEmpty }.prefix(3))
        }
        if !ingredients.isEmpty || !cuisines.isEmpty {
            let left = cuisines.isEmpty ? [""] : cuisines
            let right = ingredients.isEmpty ? [""] : ingredients
            return Array(left.flatMap { cuisine in right.map { [cuisine, $0].filter { !$0.isEmpty }.joined(separator: " ") } }.prefix(4))
        }
        let other = labels(.mood) + labels(.diet) + labels(.meal)
        return Array((other.isEmpty ? ["recipes"] : other).prefix(4))
    }

    static func identity(_ raw: String) -> String {
        guard var url = URLComponents(string: raw) else { return FinderQuery.normalize(raw) }
        url.scheme = "https"; url.host = url.host?.lowercased().replacingOccurrences(of: "www.", with: "")
        url.fragment = nil
        url.queryItems = url.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && !["fbclid", "gclid"].contains($0.name.lowercased()) }
        if url.queryItems?.isEmpty == true { url.query = nil }
        if url.path.hasSuffix("/") { url.path.removeLast() }
        return url.string ?? raw
    }

    /// At most one fact tag. No inferred "healthy", difficulty from duration, or
    /// fabricated protein/nutrition claims. Style facets come from source metadata.
    static func cardTag(_ record: FinderRecord, filters: FinderFilters) -> String? {
        let styles: [FinderChoice] = [.airFryer, .onePot, .slowCooker, .grilled, .baked, .noCook, .mealPrep, .comfort]
        if let style = styles.first(where: { filters.active(.mood).contains($0) && record.facets[.mood, default: []].contains($0) }) { return style.label }
        if let time = record.totalMinutes, time > 0, time <= 30 { return "Under 30 Min" }
        return styles.first(where: { record.facets[.mood, default: []].contains($0) })?.label
    }
}

/// Search pages contain navigation, RSS, category and account links before their
/// recipes. Only anchors in the main content are candidates; query-relevant slugs
/// come first. A candidate is still required to parse as an actual Recipe later.
nonisolated enum FinderPublisherLinks {
    static func candidates(html: String, baseURL: URL, domain: String, query: String = "") -> [String] {
        var content = html
        if let start = content.range(of: "<main", options: .caseInsensitive),
           let end = content.range(of: "</main>", options: .caseInsensitive, range: start.lowerBound..<content.endIndex) {
            content = String(content[start.lowerBound..<end.upperBound])
        }
        guard let regex = try? NSRegularExpression(pattern: #"<a\b[^>]*?\bhref\s*=\s*["']([^"'#]+)["']"#, options: .caseInsensitive) else { return [] }
        let blocked = ["/search", "/category", "/categories", "/tag/", "/tags/", "/author/", "/about", "/contact", "/privacy", "/terms", "/shop", "/books", "/login", "/account", "/newsletter", "/page/", "/wp-content/", "/cdn-cgi/", "/feed", "/comments", "/wp-json", "/xmlrpc", "/join", "/index", "/random"]
        let extensions = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".pdf", ".css", ".js", ".xml"]
        let host = domain.lowercased().replacingOccurrences(of: "www.", with: "")
        let words = FinderQuery.normalize(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var seen = Set<String>(), result: [(url: String, score: Int, order: Int)] = []
        for match in regex.matches(in: content, range: NSRange(content.startIndex..., in: content)).prefix(1000) {
            guard let range = Range(match.range(at: 1), in: content),
                  let url = URL(string: String(content[range]).replacingOccurrences(of: "&amp;", with: "&"), relativeTo: baseURL)?.absoluteURL,
                  let safe = RecipeBrowserPolicy.url(url.absoluteString),
                  let target = safe.host?.lowercased().replacingOccurrences(of: "www.", with: ""),
                  target == host || target.hasSuffix("." + host) else { continue }
            let path = safe.path.lowercased()
            guard path.count > 2, !["/recipes", "/recipes/"].contains(path),
                  !blocked.contains(where: path.contains), !extensions.contains(where: path.hasSuffix),
                  seen.insert(FinderWebPolicy.identity(safe.absoluteString)).inserted else { continue }
            let score = words.filter { path.contains($0) }.count * 10 + (path.contains("recipe") ? 1 : 0)
            result.append((safe.absoluteString, score, result.count))
        }
        return result.sorted { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }.prefix(24).map(\.url)
    }
}

/// Opaque server cursor; an empty/unchanged cursor may never masquerade as completion.
nonisolated enum RecipeCataloguePaging {
    static func next(current: String?, complete: Bool?, next: String?) throws -> String? {
        if complete == true { return nil }
        guard complete == false, let next, !next.isEmpty, next != current else { throw CocoaError(.fileReadCorruptFile) }
        return next
    }
}
