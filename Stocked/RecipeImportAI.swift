// RecipeImportAI.swift — Claude-assisted recipe import.
// ─────────────────────────────────────────────────────────────────────────────
// Sends raw imported recipe text to the Stocked. Worker's recipe branch (Haiku),
// which returns a clean structured recipe: properly-cased name, split
// name/amount ingredients, ordered steps, and friendly times.
//
// This is an ENHANCEMENT layer, never a hard dependency: every caller falls back
// to the existing on-device parser (JSON-LD scrape / RecipeTextParser / OCR) when
// the Worker isn't configured, the device is offline, or the response is unusable.
// The key lives only in the Worker (same one the receipt scanner uses) — never here.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import CryptoKit
import os

/// A structured recipe returned by the Worker's Haiku recipe branch.
struct AIRecipe: Codable {
    struct Ingredient: Codable {
        let name: String
        let amount: String
        var quantity: Double? = nil
        var unit: String? = nil
        var prep: String? = nil
        var needsReview: Bool = false
    }
    var title:       String = ""
    var description: String = ""
    var cuisine:     String = ""
    var prepTime:    String = ""
    var cookTime:    String = ""
    var totalTime:   String = ""
    var servings:    String = ""
    var ingredients: [Ingredient] = []
    var steps:       [String] = []

    /// Did we get anything worth showing? Guards against an empty/garbage response.
    var isUsable: Bool { !title.isEmpty || !ingredients.isEmpty || steps.count >= 1 }
}

enum RecipeImportAI {

    /// Whether the Worker is configured (shares the receipt Worker endpoint).
    static var isAvailable: Bool { StockedWorkerClient.isConfigured }

    /// Compose a raw-text blob from already-parsed form fields, for when we don't have
    /// the original page text but still want the model to clean up / re-split.
    static func composeRawText(title: String, description: String,
                               ingredients: [String], steps: [String]) -> String {
        var lines: [String] = []
        if !title.isEmpty { lines.append(title) }
        if !description.isEmpty { lines.append(description) }
        if !ingredients.isEmpty {
            lines.append("Ingredients:")
            lines.append(contentsOf: ingredients)
        }
        if !steps.isEmpty {
            lines.append("Instructions:")
            lines.append(contentsOf: steps.enumerated().map { "\($0.offset + 1). \($0.element)" })
        }
        return lines.joined(separator: "\n")
    }

    /// Send recipe text to the Worker and decode a structured recipe. Returns nil on any
    /// failure so the caller can fall back to its on-device parse.
    static func structure(rawText: String, sourceURL: String? = nil) async -> AIRecipe? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return nil }

        // #7/#9 — cached structuring is free, instant, and works offline. Try the
        // source-URL key first (survives small text shifts like ads/timestamps), then a
        // hash of the exact text.
        let textKey = cacheKey(for: trimmed)
        let urlKey  = sourceURL.flatMap(urlCacheKey)
        if let urlKey, let hit = loadCached(urlKey) { return hit }
        if let hit = loadCached(textKey) { return hit }

        guard StockedWorkerClient.isConfigured else { return nil }

        // One retry (#4): a small model occasionally emits not-quite-JSON; a second pass
        // usually lands it before we fall back to the on-device parser.
        for attempt in 0..<2 {
            if let recipe = await callWorker(text: trimmed) {
                saveCached(textKey, recipe)
                if let urlKey { saveCached(urlKey, recipe) }
                return recipe
            }
            if attempt == 1 { return nil }
        }
        return nil
    }

    private static func callWorker(text: String) async -> AIRecipe? {
        guard let responseText = await StockedWorkerClient.completionText(payload: ["recipeText": text]) else {
            return nil
        }
        guard let parsed = recipe(fromText: responseText) else {
            Log.app.error("RecipeImportAI: worker returned text but it didn't parse as a recipe.")
            return nil
        }
        return parsed
    }

    // MARK: - Result cache (text-hash + source-URL keys, with TTL) — #7/#9
    private static let cacheIndexKey = DefaultsKey.recipeImportCacheIndex
    private static let cacheCap = 80
    private static let cacheTTL: TimeInterval = 60 * 60 * 24 * 30   // 30 days

    private struct Cached: Codable { let recipe: AIRecipe; let savedAt: Date }

    private static func cacheKey(for rawText: String) -> String { DefaultsKey.recipeImportCacheTextPrefix + sha(rawText) }
    private static func urlCacheKey(_ url: String) -> String? {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return u.isEmpty ? nil : DefaultsKey.recipeImportCacheURLPrefix + sha(u)
    }
    private static func sha(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(40))
    }

    private static func loadCached(_ key: String) -> AIRecipe? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entry = try? JSONDecoder().decode(Cached.self, from: data) else { return nil }
        guard Date().timeIntervalSince(entry.savedAt) < cacheTTL else {
            UserDefaults.standard.removeObject(forKey: key); return nil
        }
        return entry.recipe
    }

    private static func saveCached(_ key: String, _ recipe: AIRecipe) {
        let ud = UserDefaults.standard
        guard let data = try? JSONEncoder().encode(Cached(recipe: recipe, savedAt: Date())) else { return }
        ud.set(data, forKey: key)
        var index = ud.stringArray(forKey: cacheIndexKey) ?? []
        index.removeAll { $0 == key }
        index.insert(key, at: 0)
        while index.count > cacheCap { if let evict = index.popLast() { ud.removeObject(forKey: evict) } }
        ud.set(index, forKey: cacheIndexKey)
    }

    /// Worker text → AIRecipe. Parses leniently and reads the structured ingredient
    /// fields (#1/#6). The Anthropic envelope was already unwrapped by the client.
    private static func recipe(fromText text: String) -> AIRecipe? {
        guard let obj = parseLenient(text) else { return nil }

        func str(_ key: String) -> String {
            if let s = obj[key] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let n = obj[key] as? Int { return String(n) }
            if let d = obj[key] as? Double { return String(d) }
            return ""
        }

        var recipe = AIRecipe()
        recipe.title       = str("title")
        recipe.description = str("description")
        recipe.cuisine     = str("cuisine")
        recipe.prepTime    = str("prepTime")
        recipe.cookTime    = str("cookTime")
        recipe.totalTime   = str("totalTime")
        recipe.servings    = str("servings")

        if let ing = obj["ingredients"] as? [[String: Any]] {
            recipe.ingredients = ing.compactMap { o in
                let name = (o["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let amount = (o["amount"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let qty: Double? = (o["quantity"] as? Double) ?? (o["quantity"] as? Int).map(Double.init)
                let unitRaw = (o["unit"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let unit = (unitRaw == nil || unitRaw!.isEmpty || unitRaw == "null") ? nil : unitRaw
                let prepRaw = (o["prep"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let prep = (prepRaw?.isEmpty == false && prepRaw?.lowercased() != "null") ? prepRaw : nil
                let needs = (o["needsReview"] as? Bool) ?? false
                return AIRecipe.Ingredient(name: name, amount: amount, quantity: qty,
                                           unit: unit, prep: prep, needsReview: needs)
            }
        } else if let ingStrings = obj["ingredients"] as? [String] {
            recipe.ingredients = ingStrings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { AIRecipe.Ingredient(name: $0, amount: "") }
        }

        if let steps = obj["steps"] as? [String] {
            recipe.steps = steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return recipe.isUsable ? recipe : nil
    }

    /// Tolerant JSON parse (#4): strip code fences, then if needed isolate the outermost
    /// {…} object and drop trailing commas before a repair attempt.
    private static func parseLenient(_ text: String) -> [String: Any]? {
        let stripped = text.replacingOccurrences(of: "```json", with: "")
                           .replacingOccurrences(of: "```", with: "")
                           .trimmingCharacters(in: .whitespacesAndNewlines)
        if let o = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any] { return o }
        guard let first = stripped.firstIndex(of: "{"),
              let last  = stripped.lastIndex(of: "}"), first < last else { return nil }
        var candidate = String(stripped[first...last])
        candidate = candidate.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1",
                                                   options: .regularExpression)
        return try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any]
    }
}
