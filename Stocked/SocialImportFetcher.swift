// SocialImportFetcher.swift — RL-009: pull the PUBLIC text out of a social recipe post.
// ─────────────────────────────────────────────────────────────────────────────
// Social platforms serve rich Open Graph metadata to plain HTTP fetches even when the full
// page needs JavaScript: og:title, og:description (usually the whole caption, which is where
// creators put the actual recipe), and og:image. This fetcher grabs exactly that — with a
// short timeout — and hands the VERBATIM extracted text to the caller, which forwards it to
// the Worker's recipeImport route just like a website import.
//
// Hard rule: nothing here invents recipe data. If the caption has no quantities, the
// structured result has no quantities — the preview UI flags them "Needs review" instead.
// Private/deleted posts are detected and reported as a clear error, never a fake recipe.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import os

// MARK: - Result / error types (Sendable DTOs)

nonisolated struct SocialPageContent: Sendable {
    let platform: SocialPlatform
    /// The URL the user shared/pasted — preserved onto the saved recipe.
    let sourceURL: String
    let title: String
    /// og:description / caption text, verbatim (entities decoded, nothing added).
    let caption: String
    let imageURL: String
    /// Heuristic: the caption appears to contain more than one recipe. The import uses the
    /// whole text (the model structures the first); the preview surfaces a note about the rest.
    let looksLikeMultipleRecipes: Bool

    /// The raw text handed to the Worker for structuring — title + caption, nothing else.
    var combinedText: String {
        [title, caption]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

nonisolated enum SocialImportError: Error, Sendable {
    case offline
    case privateOrDeleted(SocialPlatform)
    case insufficientContent(SocialPlatform)
    case transport(String)

    var userMessage: String {
        switch self {
        case .offline:
            return "You're offline — connect and try again."
        case .privateOrDeleted(let p):
            return "That \(p.displayName) post looks private or deleted. Only public posts can be imported — nothing was made up in its place."
        case .insufficientContent(let p):
            return "That \(p.displayName) post doesn't include enough public text to build a recipe from."
        case .transport(let detail):
            return "Couldn't reach that page. \(detail)"
        }
    }
}

// MARK: - Fetcher

nonisolated enum SocialImportFetcher {

    private static let timeout: TimeInterval = 10

    /// Fetch the post's public metadata. Throws a specific SocialImportError; never returns
    /// fabricated content.
    static func fetch(_ urlString: String, platform: SocialPlatform) async throws -> SocialPageContent {
        guard ConnectivityMonitor.isOnlineFlag else { throw SocialImportError.offline }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only plain web links: a crafted share must never point URLSession at file:, ftp: or
        // a custom scheme just because its host looks like a social domain.
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            throw SocialImportError.transport("That doesn't look like a valid link.")
        }

        var request = URLRequest(url: url)
        // Same mobile-Safari UA the web-recipe fallback uses; social CDNs serve og: tags to it.
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SocialImportError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            // Gone or gated content answers 404/410 (deleted) or 403/401 (private).
            if [401, 403, 404, 410].contains(http.statusCode) {
                throw SocialImportError.privateOrDeleted(platform)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SocialImportError.transport("The page returned HTTP \(http.statusCode).")
            }
        }
        // Same bound as website imports: og: tags live in <head>, and running the meta regexes
        // over a multi-megabyte page only burns CPU and memory.
        guard data.count <= RecipePageResponsePolicy.maximumHTMLBytes else {
            throw SocialImportError.transport("The page was too large to read.")
        }
        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw SocialImportError.transport("The page couldn't be read as text.")
        }

        let title   = decodeEntities(metaContent(in: html, property: "og:title") ?? "")
        let caption = decodeEntities(metaContent(in: html, property: "og:description") ?? "")
        // og:image is page-controlled: keep it only as an absolute https URL (relative paths
        // resolved against the post, http upgraded, javascript:/data:/file: dropped).
        let image   = sanitizedImageURL(decodeEntities(metaContent(in: html, property: "og:image") ?? ""),
                                        relativeTo: response.url ?? url) ?? ""

        // Private/deleted posts that still answer 200 render a login wall or an
        // "unavailable" shell — recognizable from the metadata itself.
        if looksGated(title: title, caption: caption, html: html) {
            throw SocialImportError.privateOrDeleted(platform)
        }

        // Too little public text to structure anything from. The caller offers manual
        // completion / AI-labeled drafting; we do NOT pad the text ourselves.
        let combined = (title + "\n" + caption).trimmingCharacters(in: .whitespacesAndNewlines)
        guard combined.count >= 24 else {
            throw SocialImportError.insufficientContent(platform)
        }

        return SocialPageContent(platform: platform,
                                 sourceURL: trimmed,
                                 title: cleanedTitle(title, platform: platform),
                                 caption: caption,
                                 imageURL: image,
                                 looksLikeMultipleRecipes: detectMultipleRecipes(in: caption))
    }

    // MARK: - Extraction helpers

    /// Read a `<meta property="og:x" content="…">` value, tolerating either attribute order.
    /// Quote-aware: a double-quoted value may contain apostrophes ("Mom's pasta") and a
    /// single-quoted one may contain double quotes — the old `[^"']*` stopped at either and
    /// truncated captions at the first apostrophe.
    static func metaContent(in html: String, property: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let value = #"(?:"([^"]*)"|'([^']*)')"#
        let patterns = [
            // property first, then content
            "<meta[^>]*?(?:property|name)\\s*=\\s*[\"']\(escaped)[\"'][^>]*?content\\s*=\\s*\(value)",
            // content first, then property
            "<meta[^>]*?content\\s*=\\s*\(value)[^>]*?(?:property|name)\\s*=\\s*[\"']\(escaped)[\"']",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else { continue }
            for group in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: group), in: html) else { continue }
                let value = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Decode the entities social pages actually emit in og: content, including numeric ones
    /// (Instagram encodes emoji/newlines as &#x…;). Single left-to-right pass, so "&amp;lt;"
    /// stays the literal text "&lt;" instead of being decoded twice into "<", and the work is
    /// linear (the old loop rescanned from the start for every entity). NUL, surrogate and
    /// out-of-range code points become a space.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
                                       "nbsp": " ", "frac12": "½", "frac14": "¼", "frac34": "¾"]
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") else {
                out.append(s[i]); i = s.index(after: i); continue
            }
            let body = s[s.index(after: i)..<semi]
            var replacement: String?
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let value: UInt32?
                if digits.hasPrefix("x") || digits.hasPrefix("X") {
                    value = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    value = UInt32(digits)
                }
                if let v = value {
                    if v != 0, let scalar = Unicode.Scalar(v) { replacement = String(Character(scalar)) }
                    else { replacement = " " }
                }
            } else {
                replacement = named[String(body)]
            }
            if let replacement {
                out += replacement
                i = s.index(after: semi)
            } else {
                out.append(s[i]); i = s.index(after: i)
            }
        }
        return out
    }

    /// Absolute https image URL, or nil. Relative og:image values resolve against the page.
    static func sanitizedImageURL(_ raw: String, relativeTo base: URL?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_096,
              let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              var comps = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              comps.host?.isEmpty == false, comps.user == nil, comps.password == nil else { return nil }
        comps.scheme = "https"   // ATS blocks plain http image loads anyway
        return comps.url?.absoluteString
    }

    /// Drop the platform's boilerplate suffixes from og:title ("… | TikTok", "… - YouTube").
    private static func cleanedTitle(_ title: String, platform: SocialPlatform) -> String {
        var t = title
        for suffix in [" | TikTok", " - YouTube", " • Instagram", " | Instagram", " | Pinterest"] {
            if t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Login walls and tombstone pages, per platform. Checked on the metadata (cheap and
    /// reliable) with a couple of body markers as backup.
    private static func looksGated(title: String, caption: String, html: String) -> Bool {
        let t = title.lowercased()
        let c = caption.lowercased()
        let gatedTitles = ["log in", "login", "sign up", "page not found", "not found",
                           "content isn't available", "video currently unavailable"]
        if gatedTitles.contains(where: { t == $0 || t.hasPrefix($0) }) { return true }
        let gatedPhrases = ["this account is private", "video currently unavailable",
                            "this content isn't available", "post isn't available",
                            "sorry, this page isn't available"]
        if gatedPhrases.contains(where: { c.contains($0) }) { return true }
        // No og metadata at all AND a login form → almost certainly gated.
        if title.isEmpty && caption.isEmpty && html.lowercased().contains("name=\"password\"") {
            return true
        }
        return false
    }

    /// Creators who batch posts write "Recipe 1:", "1st recipe", or repeat an "Ingredients"
    /// header per dish. Two or more such markers → probably a multi-recipe post.
    private static func detectMultipleRecipes(in caption: String) -> Bool {
        let lower = caption.lowercased()
        let ingredientHeaders = lower.components(separatedBy: "ingredients").count - 1
        if ingredientHeaders >= 2 { return true }
        guard let regex = try? NSRegularExpression(pattern: #"recipe\s*(?:no\.?\s*)?[1-9][:.)]"#) else {
            return false
        }
        let count = regex.numberOfMatches(in: lower, range: NSRange(lower.startIndex..., in: lower))
        return count >= 2
    }
}
