// SocialImportDetector.swift — RL-009: recognize social recipe links (TikTok / Instagram /
// YouTube / Pinterest) inside the SAME import entry points as website recipes.
// ─────────────────────────────────────────────────────────────────────────────
// Social posts don't publish Schema.org Recipe JSON-LD, so the standard web importer
// returns nothing for them. This detector lets the pipeline branch early: a matched URL
// goes through SocialImportFetcher (og:tags + caption text) → the existing Worker
// recipeImport route, instead of the doomed JSON-LD scrape.
//
// Also owns URL normalization for duplicate detection: the same TikTok can arrive as
// vm.tiktok.com/XYZ (share sheet), m.tiktok.com/… or with a wall of tracking params —
// normalizedKey collapses those so "already imported" checks actually match.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Platform

nonisolated enum SocialPlatform: String, Codable, Sendable, CaseIterable {
    case tiktok, instagram, youtube, pinterest

    var displayName: String {
        switch self {
        case .tiktok:    return "TikTok"
        case .instagram: return "Instagram"
        case .youtube:   return "YouTube"
        case .pinterest: return "Pinterest"
        }
    }

    /// SF Symbol for the preview header (no brand assets in the bundle).
    var iconSystemName: String {
        switch self {
        case .tiktok:    return "music.note"
        case .instagram: return "camera"
        case .youtube:   return "play.rectangle"
        case .pinterest: return "pin"
        }
    }
}

// MARK: - Detector

nonisolated enum SocialImportDetector {

    /// Which platform a URL belongs to, or nil for ordinary websites. Matches full hosts,
    /// subdomains (m., vm., www.) and the short/share domains each platform hands out.
    static func platform(for urlString: String) -> SocialPlatform? {
        guard let host = host(of: urlString) else { return nil }
        // Exact short domains first — suffix matching would misread e.g. "notpin.it".
        switch host {
        case "vm.tiktok.com", "vt.tiktok.com":            return .tiktok
        case "youtu.be", "youtube-nocookie.com":          return .youtube
        case "instagr.am", "ig.me":                       return .instagram
        case "pin.it":                                    return .pinterest
        default: break
        }
        if matches(host, domain: "tiktok.com")    { return .tiktok }
        if matches(host, domain: "instagram.com") { return .instagram }
        if matches(host, domain: "youtube.com")   { return .youtube }
        if matches(host, domain: "pinterest.com") { return .pinterest }
        // Pinterest country TLDs (pinterest.co.uk, pinterest.de, pinterest.com.au …).
        if host == "pinterest" || host.hasPrefix("pinterest.")
            || host.contains(".pinterest.") { return .pinterest }
        return nil
    }

    static func isSocialURL(_ urlString: String) -> Bool { platform(for: urlString) != nil }

    /// Canonical key for duplicate detection. Lowercased host with www./m./mobile. stripped,
    /// no fragment, no trailing slash, and the query reduced to the parameters that actually
    /// identify content (YouTube's v=; everything else — utm_*, igsh, share ids — dropped).
    /// Short-link hosts are kept as-is: their path IS the identity.
    static func normalizedKey(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed), let rawHost = comps.host else {
            return trimmed.lowercased()
        }
        var host = rawHost.lowercased()
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        comps.host = host
        comps.scheme = "https"
        comps.port = nil
        comps.fragment = nil
        // Keep only content-identifying query items.
        let keep: Set<String> = ["v", "list"]   // YouTube video / playlist ids
        let kept = (comps.queryItems ?? []).filter { keep.contains($0.name.lowercased()) }
        comps.queryItems = kept.isEmpty ? nil : kept
        var path = comps.path
        if path.hasSuffix("/") && path.count > 1 { path = String(path.dropLast()) }
        comps.path = path
        return comps.string?.lowercased() ?? trimmed.lowercased()
    }

    // MARK: Duplicate detection against saved recipes

    /// Saved imports record their origin in `notes` ("Saved from TikTok: https://…"), the
    /// same convention WebRecipeDetailView uses for website saves. This scans those notes
    /// for a URL whose normalized key matches the candidate — so pasting the same link
    /// twice (even with different tracking params) is caught before a duplicate save.
    static func existingImport(of urlString: String, in recipes: [UserRecipe]) -> UserRecipe? {
        let key = normalizedKey(urlString)
        guard !key.isEmpty else { return nil }
        for recipe in recipes {
            for candidate in urls(in: recipe.notes) where normalizedKey(candidate) == key {
                return recipe
            }
        }
        return nil
    }

    /// Pull URL-looking substrings out of free text (recipe notes).
    private static func urls(in text: String) -> [String] {
        guard !text.isEmpty, text.contains("http") else { return [] }
        var found: [String] = []
        var remainder = Substring(text)
        while let range = remainder.range(of: #"https?://[^\s"']+"#, options: .regularExpression) {
            found.append(String(remainder[range]))
            remainder = remainder[range.upperBound...]
        }
        return found
    }

    // MARK: Helpers

    private static func host(of urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let raw = url.host else { return nil }
        return raw.lowercased()
    }

    private static func matches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}
