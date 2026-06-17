// SharedRecipeImporter.swift
// ─────────────────────────────────────────────────────────────────────────────
// Main-app side of the Share Extension flow. When the extension hands a recipe in from
// another app, it writes a payload to the shared App Group and opens stocked://shareImport.
// StockedApp sets session.pendingSharedRecipe = true on the stocked://shareImport open;
// MainTabView watches that flag, calls consumePending(), and presents the editable form.
//
// "Decipher + keep only essentials": a shared URL is run through the existing web-recipe
// importer (structured title/ingredients/steps, ignoring page chrome); shared text or a
// screenshot is run through the SAME RecipeTextParser / RecipeOCR used by Text Manually and
// Import from Screenshot — so captions, hashtags, and UI noise are dropped and only the
// recipe essentials are kept.
//
// NOTE: requires the App Group "group.com.sowens.Stocked" enabled on the MAIN APP target
// (see the extension's SETUP_GUIDE.md). Without it, UserDefaults(suiteName:) is nil and this
// safely no-ops.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import SwiftUI
import UIKit
import os

extension Notification.Name {
    static let stockedSharedRecipeArrived = Notification.Name("stockedSharedRecipeArrived")
}

/// Identifiable wrapper so a shared AddRecipeForm can drive .sheet(item:).
struct SharedRecipeFormBox: Identifiable {
    let id = UUID()
    let form: AddRecipeForm
}

enum SharedRecipeImporter {
    static let appGroupID = "group.com.sowens.Stocked"

    /// Result of consuming a shared payload: a prefilled form + a source label, or nil.
    struct Result { let form: AddRecipeForm; let source: String }

    /// Reads and clears the pending shared payload, deciphering it into a recipe form.
    /// Outcome of trying to consume a shared payload, so the UI can give specific feedback
    /// instead of failing silently (the old behavior — nothing appeared and you couldn't tell why).
    enum Outcome {
        case success(Result)
        case noPayload                  // nothing was in the App Group (handoff didn't deliver)
        case scrapeFailed(String)       // had a URL but couldn't extract a recipe from the page
        case nothingExtracted           // had text/image but found no recipe
    }

    /// URL → web import; text/image → on-device parser/OCR.
    @MainActor
    static func consumePendingDetailed() async -> Outcome {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            Log.app.error("ShareImport: UserDefaults(suiteName:) is nil — App Group '\(appGroupID, privacy: .public)' not enabled on the MAIN APP target?")
            return .noPayload
        }
        guard let payload = defaults.dictionary(forKey: "pendingSharedRecipe") else {
            Log.app.error("ShareImport: no 'pendingSharedRecipe' key in the App Group — the extension didn't write it, or the group IDs differ between app and extension.")
            return .noPayload
        }
        Log.app.log("ShareImport: payload keys = \(payload.keys.joined(separator: ","), privacy: .public)")

        // Clear immediately so we don't re-import on the next launch.
        defaults.removeObject(forKey: "pendingSharedRecipe")
        defaults.synchronize()

        // 1) A shared link → structured web import (best quality).
        if let urlStr = payload["url"] as? String, urlStr.hasPrefix("http") {
            Log.app.log("ShareImport: got URL, scraping \(urlStr, privacy: .public)")
            if let web = try? await WebRecipeManager.shared.importFromURL(urlStr) {
                var form = AddRecipeForm()
                form.title       = web.title
                form.ingredients = web.ingredients
                form.steps       = web.steps.map { $0.text }
                form.imageURL    = web.imageURL
                form.sourceURL   = urlStr
                form.servings    = web.servings
                form.description = web.description
                form.prepTime    = web.prepTime
                form.cookTime    = web.cookTime
                form.cuisine     = web.cuisine
                // #2 — keep the verbatim source text so the AI structures from real data
                // (not a re-parse) and "Show original text" works for link imports too.
                form.originalText = RecipeImportAI.composeRawText(
                    title: web.title, description: web.description,
                    ingredients: web.ingredients, steps: web.steps.map { $0.text })
                Log.app.log("ShareImport: scrape OK — title='\(form.title, privacy: .public)' ingredients=\(form.ingredients.count) steps=\(form.steps.count)")
                if !form.title.isEmpty || !form.ingredients.isEmpty {
                    return .success(Result(form: form, source: hostName(urlStr)))
                }
                Log.app.error("ShareImport: scrape returned a recipe with no title/ingredients")
            } else {
                Log.app.error("ShareImport: importFromURL threw / returned nil — no Schema.org Recipe JSON-LD. Trying visible-page-text fallback.")
            }
            // Fall through to text if present.
            if (payload["text"] as? String)?.isEmpty == false {
                Log.app.log("ShareImport: falling back to shared text")
            } else {
                // Last resort for a URL with no structured data: fetch the page and run the
                // visible text through the recipe parser. Best-effort — pages vary wildly, so
                // the user still lands in the editable form to fix anything.
                if let form = await Self.parsePageText(urlStr) {
                    Log.app.log("ShareImport: page-text fallback extracted a recipe")
                    return .success(Result(form: form, source: hostName(urlStr)))
                }
                Log.app.error("ShareImport: page-text fallback found no recipe either")
                return .scrapeFailed(hostName(urlStr))
            }
        }

        // 2) Shared text (e.g. a pasted recipe, or a caption) → heuristic parser.
        if let text = payload["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.app.log("ShareImport: parsing shared text (\(text.count) chars)")
            var form = RecipeTextParser.parse(text)
            form.originalText = text
            if !form.ingredients.isEmpty || !form.steps.isEmpty || !form.title.isEmpty {
                return .success(Result(form: form, source: "Shared Text"))
            }
            Log.app.error("ShareImport: text parser found no recipe")
        }

        // 3) Shared image (screenshot) → OCR → parser.
        if let path = payload["imagePath"] as? String,
           let data = FileManager.default.contents(atPath: path),
           let image = UIImage(data: data) {
            Log.app.log("ShareImport: running OCR on shared image")
            let text = await RecipeOCR.recognizeText(in: image)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var form = RecipeTextParser.parse(text)
                form.originalText = text
                if !form.ingredients.isEmpty || !form.steps.isEmpty || !form.title.isEmpty {
                    return .success(Result(form: form, source: "Shared Screenshot"))
                }
            }
            Log.app.error("ShareImport: OCR/parse found no recipe in image")
        }

        return .nothingExtracted
    }

    /// Back-compat wrapper for any caller that just wants the Result.
    @MainActor
    static func consumePending() async -> Result? {
        if case .success(let r) = await consumePendingDetailed() { return r }
        return nil
    }

    private static func hostName(_ s: String) -> String {
        URL(string: s)?.host?.replacingOccurrences(of: "www.", with: "") ?? "Shared"
    }

    /// Best-effort fallback for URLs with no structured recipe data: fetch the page, strip it
    /// to visible text, and run the same heuristic parser used by Text Manually. Returns a form
    /// only if it found enough to look like a recipe. The user reviews/edits before saving.
    private static func parsePageText(_ urlStr: String) async -> AddRecipeForm? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        let fetchTask = Task { try await URLSession.shared.data(for: req) }
        guard let (data, resp) = try? await fetchTask.value,
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        let text = strippedText(from: html)
        guard text.count > 80 else { return nil }   // too little to be a recipe page
        let form = RecipeTextParser.parse(text)
        guard !form.ingredients.isEmpty || form.steps.count >= 2 else { return nil }
        var f = form
        f.sourceURL = urlStr
        f.originalText = text
        if f.title.isEmpty { f.title = htmlTitle(html) ?? hostName(urlStr) }
        return f
    }

    /// Strip scripts/styles/tags to readable text, collapsing whitespace and keeping line breaks
    /// at block boundaries so the recipe parser can see ingredient/step lines.
    private static func strippedText(from html: String) -> String {
        var s = html
        // Drop script/style/noscript blocks entirely.
        for tag in ["script", "style", "noscript", "head"] {
            s = s.replacingOccurrences(of: "<\(tag)[\\s\\S]*?</\(tag)>", with: " ",
                                       options: [.regularExpression, .caseInsensitive])
        }
        // Turn block-level closers into newlines so lines survive.
        s = s.replacingOccurrences(of: "</(p|li|div|h[1-6]|br|tr)>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        // Remove all remaining tags.
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode a few common entities.
        let ents = ["&amp;":"&","&lt;":"<","&gt;":">","&quot;":"\"","&#39;":"'","&nbsp;":" ","&frac12;":"½","&frac14;":"¼","&frac34;":"¾"]
        for (k,v) in ents { s = s.replacingOccurrences(of: k, with: v) }
        // Collapse spaces per line, drop empty lines.
        let lines = s.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private static func htmlTitle(_ html: String) -> String? {
        guard let r = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let inner = String(html[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let t = inner.components(separatedBy: CharacterSet(charactersIn: "|–-")).first?.trimmingCharacters(in: .whitespaces) ?? inner.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
