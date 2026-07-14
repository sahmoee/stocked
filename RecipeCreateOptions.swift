// RecipeCreateOptions.swift
// ─────────────────────────────────────────────────────────────────────────────
// The "+" / Create Recipe entry now opens a 4-option menu:
//   1. Create recipe      → blank CreateRecipeView (from scratch)
//   2. Import from URL     → paste a link → fetch + parse → prefilled CreateRecipeView
//   3. Import from screenshot → pick a photo → Vision OCR → parse → prefilled form
//   4. Text manually       → paste a block of recipe text → parse → prefilled form
//
// Options 2–4 all funnel into the SAME CreateRecipeView (via its `prefill:`), so the user
// always lands in the familiar editable form to review before saving — nothing is saved
// silently. Screenshot + manual share one RecipeTextParser; URL reuses the existing
// WebRecipeDatabase.importFromURL.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import PhotosUI
@preconcurrency import Vision
import UIKit

// MARK: - Which create flow is active

enum RecipeCreateRoute: Identifiable, Equatable {
    case scratch
    case ai
    case url
    case screenshot
    case manual
    case form(AddRecipeForm, String)   // prefilled form + source label
    var id: String {
        switch self {
        case .scratch: return "scratch"; case .ai: return "ai"; case .url: return "url"
        case .screenshot: return "screenshot"; case .manual: return "manual"
        case .form: return "form"
        }
    }
    static func == (l: RecipeCreateRoute, r: RecipeCreateRoute) -> Bool { l.id == r.id }
}

// MARK: - The 4-option chooser

struct RecipeCreateOptionsSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    /// Called with the chosen route; the parent presents the matching destination.
    var onChoose: (RecipeCreateRoute) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text("How do you want to add this recipe?")
                        .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.6))
                        .padding(.top, 8).padding(.bottom, 4)

                    optionCard(icon: "square.and.pencil", tint: Color.stockedGold,
                               title: "Create Recipe",
                               subtitle: "Start from a blank form") { choose(.scratch) }

                    optionCard(icon: "sparkles", tint: Color.stockedGold,
                               title: "Create with AI",
                               subtitle: "Describe it and we'll build the recipe") { choose(.ai) }

                    optionCard(icon: "link", tint: Color.stockedInfo,
                               title: "Import from URL",
                               subtitle: "Paste a link from a recipe website") { choose(.url) }

                    optionCard(icon: "photo.on.rectangle.angled", tint: Color.stockedSuccess,
                               title: "Import from Screenshot",
                               subtitle: "Read a recipe from a saved image") { choose(.screenshot) }

                    optionCard(icon: "text.alignleft", tint: Color.stockedCharcoal,
                               title: "Text Manually",
                               subtitle: "Paste recipe text and we'll structure it") { choose(.manual) }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Add a Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(session.themeTextColor.opacity(0.6))
                }
            }
        }
    }

    private func choose(_ r: RecipeCreateRoute) { dismiss(); onChoose(r) }

    private func optionCard(icon: String, tint: Color, title: String, subtitle: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd).fill(tint).frame(width: 44, height: 44)
                    Image(systemName: icon).font(.system(size: 19)).foregroundStyle(Color.stockedWhite)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(14)
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Import from URL

struct RecipeURLImportSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    /// Hands back a parsed form (+source) for the parent to open in CreateRecipeView.
    var onParsed: (AddRecipeForm, String) -> Void

    @State private var urlText = ""
    @State private var loading = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Paste a link to a recipe page. We'll pull the title, ingredients, and steps for you to review.")
                        .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("https://…", text: $urlText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).focused($focused)
                        .font(.system(size: 15))
                        .padding(14)
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        .foregroundStyle(session.themeTextColor)

                    if let error {
                        Text(error).font(.system(size: 13)).foregroundStyle(Color.stockedError)
                    }
                }
                .padding(20)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Import from URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(session.themeTextColor.opacity(0.6))
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { Task { await fetch() } } label: {
                    HStack {
                        if loading { ProgressView().tint(.white) }
                        Text(loading ? "Fetching…" : "Import")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(isValidURL ? session.themeButtonColor : Color.gray.opacity(0.5))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain).disabled(loading || !isValidURL)
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            .onAppear { focused = true }
        }
    }

    private var isValidURL: Bool {
        let t = urlText.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("http://") || t.hasPrefix("https://")
    }

    private func fetch() async {
        error = nil; focused = false
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard ConnectivityMonitor.isOnlineFlag else { error = "You're offline — connect and try again."; return }
        loading = true
        defer { loading = false }
        do {
            let web = try await WebRecipeManager.shared.importFromURL(trimmed)
            var form = AddRecipeForm()
            form.title       = web.title
            form.ingredients = web.ingredients
            form.steps       = web.steps.map { $0.text }
            form.imageURL    = web.imageURL
            form.sourceURL   = trimmed
            form.servings    = web.servings
            form.description = web.description
            form.prepTime    = web.prepTime
            form.cookTime    = web.cookTime
            form.cuisine     = web.cuisine
            guard !form.title.isEmpty || !form.ingredients.isEmpty else {
                error = "Couldn't find a recipe on that page. Try a different link, or use Text Manually."
                return
            }
            // Don't call dismiss() here: the parent presents this sheet via
            // .sheet(item: createRoute) and its onParsed closure tears it down by
            // setting createRoute = nil before presenting the prefilled form. Calling
            // the environment dismiss() as well raced that binding and made the form
            // present/dismiss endlessly.
            onParsed(form, hostName(trimmed))
        } catch {
            self.error = "Couldn't read that page. Check the link, or paste the text instead."
        }
    }

    private func hostName(_ s: String) -> String {
        URL(string: s)?.host?.replacingOccurrences(of: "www.", with: "") ?? "Imported"
    }
}

// MARK: - Import from Screenshot (Vision OCR → parser)

struct RecipeScreenshotImportSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    var onParsed: (AddRecipeForm, String) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("Pick a screenshot of a recipe. We'll read the text on your device and structure it for you to review.")
                        .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 40)).foregroundStyle(Color.stockedGold)
                            Text(working ? "Reading…" : "Choose Screenshot")
                                .font(.system(size: 16, weight: .semibold, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                    }
                    .disabled(working)

                    if working { ProgressView().tint(Color.stockedGold) }
                    if let error {
                        Text(error).font(.system(size: 13)).foregroundStyle(Color.stockedError)
                            .multilineTextAlignment(.center)
                    }
                    Text("Tip: the clearer the screenshot, the better the result. You can fix anything on the next screen.")
                        .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.4))
                        .multilineTextAlignment(.center).padding(.top, 4)
                }
                .padding(20)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Import from Screenshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(session.themeTextColor.opacity(0.6))
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { await handle(item) }
            }
        }
    }

    private func handle(_ item: PhotosPickerItem) async {
        error = nil; working = true
        defer { working = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            error = "Couldn't load that image."; return
        }
        let text = await RecipeOCR.recognizeText(in: image)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "No readable text found in that screenshot."; return
        }
        let form = RecipeTextParser.parse(text)
        guard !form.ingredients.isEmpty || !form.steps.isEmpty || !form.title.isEmpty else {
            error = "Read the text, but couldn't spot a recipe. Try Text Manually to paste and edit it."; return
        }
        // No dismiss() — parent's onParsed tears down via createRoute (see URL import note).
        onParsed(form, "Screenshot")
    }
}

// MARK: - Text Manually (paste → parser)

struct RecipeManualTextSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    var onParsed: (AddRecipeForm, String) -> Void

    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Paste the recipe text — title, ingredients, and steps. We'll structure it; you can fix anything before saving.")
                        .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Paste recipe here…")
                                .font(.system(size: 15)).foregroundStyle(session.themeTextColor.opacity(0.35))
                                .padding(.horizontal, 14).padding(.vertical, 14)
                        }
                        TextEditor(text: $text)
                            .font(.system(size: 15)).foregroundStyle(session.themeTextColor)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .focused($focused)
                    }
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))

                    if let error {
                        Text(error).font(.system(size: 13)).foregroundStyle(Color.stockedError)
                    }
                }
                .padding(20)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Text Manually")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(session.themeTextColor.opacity(0.6))
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { structure() } label: {
                    Text("Structure Recipe").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(text.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray.opacity(0.5) : session.themeButtonColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
    }

    private func structure() {
        error = nil
        let form = RecipeTextParser.parse(text)
        guard !form.ingredients.isEmpty || !form.steps.isEmpty || !form.title.isEmpty else {
            error = "Couldn't spot a recipe in that text. Make sure it includes a title, ingredients, and steps."
            return
        }
        // No dismiss() — parent's onParsed tears down via createRoute (see URL import note).
        onParsed(form, "Pasted Text")
    }
}

// MARK: - On-device OCR (Vision)

enum RecipeOCR {
    static func recognizeText(in image: UIImage) async -> String {
        guard let cg = image.cgImage else { return "" }
        return await withCheckedContinuation { cont in
            let request = VNRecognizeTextRequest { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) }
                catch { cont.resume(returning: "") }
            }
        }
    }
}

// MARK: - Shared recipe-text parser (screenshot OCR + manual paste)
// Heuristic, on-device. Splits a free-text recipe into title / ingredients / steps.
// Deliberately conservative: when unsure it leaves text for the user to fix in the form.
enum RecipeTextParser {
    static func parse(_ raw: String) -> AddRecipeForm {
        var form = AddRecipeForm()
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return form }

        // Title = first non-trivial line that isn't a section header or a quantity line.
        if let titleLine = lines.first(where: { !isSectionHeader($0) && !looksLikeIngredient($0) && $0.count >= 3 }) {
            form.title = titleLine.count > 80 ? String(titleLine.prefix(80)) : titleLine
        }

        // Section-aware pass: switch buckets on "Ingredients" / "Instructions"/"Steps"/"Directions".
        enum Bucket { case none, ingredients, steps }
        var bucket: Bucket = .none
        var ingredients: [String] = []
        var steps: [String] = []

        for line in lines {
            let lower = line.lowercased()
            if line == form.title { continue }
            if isIngredientsHeader(lower) { bucket = .ingredients; continue }
            if isStepsHeader(lower)       { bucket = .steps; continue }

            switch bucket {
            case .ingredients:
                if !isSectionHeader(line) { ingredients.append(stripBullet(line)) }
            case .steps:
                if !isSectionHeader(line) { steps.append(stripStepNumber(line)) }
            case .none:
                // No headers seen yet — guess by shape.
                if looksLikeIngredient(line) { ingredients.append(stripBullet(line)) }
                else if looksLikeStep(line)  { steps.append(stripStepNumber(line)) }
            }
        }

        // If we never saw headers and split nothing into steps, treat longer sentences as steps.
        if steps.isEmpty && bucket == .none {
            steps = lines.filter { looksLikeStep($0) && !looksLikeIngredient($0) }.map(stripStepNumber)
        }

        form.ingredients = ingredients.filter { !$0.isEmpty }
        form.steps = steps.filter { !$0.isEmpty }
        return form
    }

    // ── Heuristics ──────────────────────────────────────────────────────
    private static let units = ["cup","cups","tbsp","tablespoon","tsp","teaspoon","oz","ounce","lb","pound",
                                "g","gram","kg","ml","l","clove","cloves","pinch","slice","slices","can","cans",
                                "package","pkg","stick","sticks","dash","quart","pint","gallon"]

    private static func looksLikeIngredient(_ line: String) -> Bool {
        let lower = line.lowercased()
        // Starts with a number/fraction, or contains a measurement unit, and is short-ish.
        let startsNumeric = line.first.map { $0.isNumber || "½⅓¼¾⅔⅛".contains($0) } ?? false
        let hasUnit = units.contains { lower.contains(" \($0) ") || lower.hasPrefix("\($0) ") || lower.contains(" \($0)s ") }
        let bulleted = line.hasPrefix("•") || line.hasPrefix("-") || line.hasPrefix("*")
        return (startsNumeric || hasUnit || bulleted) && line.count < 80
    }

    private static func looksLikeStep(_ line: String) -> Bool {
        // Numbered ("1.", "2)") or a reasonably long sentence.
        let numbered = line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
        return numbered || line.count >= 40
    }

    private static func isSectionHeader(_ line: String) -> Bool {
        isIngredientsHeader(line.lowercased()) || isStepsHeader(line.lowercased())
    }
    private static func isIngredientsHeader(_ lower: String) -> Bool {
        lower == "ingredients" || lower.hasPrefix("ingredients") && lower.count < 16
    }
    private static func isStepsHeader(_ lower: String) -> Bool {
        ["instructions","steps","directions","method","preparation"].contains { lower == $0 || (lower.hasPrefix($0) && lower.count < 16) }
    }
    private static func stripBullet(_ line: String) -> String {
        var s = line
        for p in ["•","-","*","–"] where s.hasPrefix(p) { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return s
    }
    private nonisolated static func stripStepNumber(_ line: String) -> String {
        line.replacingOccurrences(of: #"^\d+[.)]\s*"#, with: "", options: .regularExpression)
    }
}
