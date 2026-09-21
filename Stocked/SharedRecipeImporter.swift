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
            // RL-009: social links (TikTok / Instagram / YouTube / Pinterest) never carry
            // Schema.org Recipe JSON-LD, so the web scrape below is doomed for them. Branch
            // to the social fetcher: public og:title/og:description (the caption, where
            // creators put the recipe) + og:image, then the SAME editable-form flow — the
            // form runs the Worker recipeImport structuring exactly like web imports, and
            // flags uncertain amounts "Needs review". Nothing is fabricated: a private or
            // deleted post is a clear error, not a fake recipe.
            if let platform = SocialImportDetector.platform(for: urlStr) {
                Log.app.log("ShareImport: social URL (\(platform.rawValue, privacy: .public)) — using og: metadata")
                do {
                    let content = try await SocialImportFetcher.fetch(urlStr, platform: platform)
                    var form = AddRecipeForm()
                    form.title = content.title
                    form.imageURL = content.imageURL
                    form.sourceURL = content.sourceURL
                    form.description = content.caption
                    // Verbatim caption + a Source line, so "Show original text" preserves
                    // the link even though the create form doesn't carry notes through.
                    form.originalText = content.combinedText + "\n\nSource: \(content.sourceURL)"
                    return .success(Result(form: form, source: platform.displayName))
                } catch let error as SocialImportError {
                    switch error {
                    case .privateOrDeleted:
                        return .scrapeFailed("\(platform.displayName) — the post looks private or deleted, so no public recipe text exists")
                    case .offline:
                        return .scrapeFailed("\(platform.displayName) while offline")
                    case .insufficientContent, .transport:
                        // Fall through to shared text (a share often includes the caption)
                        // or the generic failure below.
                        if (payload["text"] as? String)?.isEmpty == false {
                            Log.app.log("ShareImport: social fetch thin — falling back to shared text")
                        } else {
                            return .scrapeFailed(platform.displayName)
                        }
                    }
                } catch {
                    return .scrapeFailed(platform.displayName)
                }
            } else {
            Log.app.log("ShareImport: got URL, scraping \(urlStr, privacy: .public)")
            if let result = try? await RecipeImportCoordinator.importURL(urlStr, progress: { _ in }), !Task.isCancelled {
                return .success(Result(form: result.form, source: result.source))
            }
            // Fall through to text if present.
            if (payload["text"] as? String)?.isEmpty == false {
                Log.app.log("ShareImport: falling back to shared text")
            } else {
                // The shared pipeline already attempted both formats from one response.
                return .scrapeFailed(hostName(urlStr))
            }
            }   // end non-social web-scrape branch (RL-009)
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

    private nonisolated static func hostName(_ s: String) -> String {
        URL(string: s)?.host?.replacingOccurrences(of: "www.", with: "") ?? "Shared"
    }

    /// Best-effort fallback for URLs with no structured recipe data: fetch the page, strip it
    /// to visible text, and run the same heuristic parser used by Text Manually. Returns a form
    /// only if it found enough to look like a recipe. The user reviews/edits before saving.
    static func parsePageText(_ urlStr: String) async -> AddRecipeForm? {
        guard let page = await WebRecipeFetcher.shared.pageHTML(urlStr), !Task.isCancelled else { return nil }
        let work = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil as AddRecipeForm? }
            let form = visiblePageForm(html: page.html, urlStr: page.url.absoluteString)
            return Task.isCancelled ? nil : form
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    nonisolated static func visiblePageForm(html: String, urlStr: String) -> AddRecipeForm? {
        guard html.utf8.count <= RecipePageResponsePolicy.maximumHTMLBytes, !Task.isCancelled else { return nil }
        let main = html.range(of: #"<main\b[^>]*>[\s\S]*?</main>"#, options: [.regularExpression, .caseInsensitive])
        let text = strippedText(from: main.map { String(html[$0]) } ?? html)
        guard text.count > 80 else { return nil }   // too little to be a recipe page
        let form = RecipeTextParser.parse(text)
        guard !form.ingredients.isEmpty, !form.steps.isEmpty,
              form.ingredients.count <= 500, form.steps.count <= 500 else { return nil }
        var f = form
        f.sourceURL = urlStr
        f.originalText = text
        if let title = htmlTitle(html) { f.title = title }
        return f
    }

    /// Strip scripts/styles/tags to readable text, collapsing whitespace and keeping line breaks
    /// at block boundaries so the recipe parser can see ingredient/step lines.
    private nonisolated static func strippedText(from html: String) -> String {
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
        s = RecipePageMarkup.text(s)
        // Collapse spaces per line, drop empty lines.
        let lines = s.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func htmlTitle(_ html: String) -> String? {
        guard let r = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let inner = RecipePageMarkup.text(String(html[r]))
        let separator = inner.range(of: #"\s+[|–—]\s+"#, options: .regularExpression)
        let t = separator.map { String(inner[..<$0.lowerBound]) } ?? inner
        return t.isEmpty ? nil : t
    }
}
