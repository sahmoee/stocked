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
@preconcurrency import PhotosUI
@preconcurrency import Vision
import UIKit

// MARK: - Which create flow is active

enum RecipeCreateRoute: Identifiable, Equatable {
    case scratch
    case ai
    case url
    case browser
    case screenshot
    case manual
    case form(AddRecipeForm, String)   // prefilled form + source label
    var id: String {
        switch self {
        case .scratch: return "scratch"; case .ai: return "ai"; case .url: return "url"
        case .browser: return "browser"
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
    @State private var showRecipeFiles = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text("How do you want to add this recipe?")
                        .scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.6))
                        .padding(.top, 8).padding(.bottom, 4)

                    optionCard(icon: "square.and.pencil", tint: Color.stockedGold,
                               title: "Create Recipe",
                               subtitle: "Start from a blank form") { choose(.scratch) }

                    optionCard(icon: "sparkles", tint: Color.stockedGold,
                               title: "Create with AI",
                               subtitle: "Coming Soon") { }.disabled(true)

                    optionCard(icon: "safari", tint: Color.stockedCharcoal,
                               title: "Browse recipe websites",
                               subtitle: "View a recipe, then import it into STOCKED") { choose(.browser) }

                    optionCard(icon: "link", tint: Color.stockedInfo,
                               title: "Import from URL",
                               subtitle: "Paste a link from a recipe website") { choose(.url) }

                    optionCard(icon: "photo.on.rectangle.angled", tint: Color.stockedSuccess,
                               title: "Import from Screenshot",
                               subtitle: "Read a recipe from a saved image") { choose(.screenshot) }

                    optionCard(icon: "text.alignleft", tint: Color.stockedCharcoal,
                               title: "Text Manually",
                               subtitle: "Paste recipe text and we'll structure it") { choose(.manual) }

                    optionCard(icon: "doc.badge.arrow.up", tint: Color.stockedInfo,
                               title: "Import or export recipe files",
                               subtitle: "Cooklang, recipe JSON, HTML and text · no AI needed") { showRecipeFiles = true }
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
            .sheet(isPresented: $showRecipeFiles) { PortableRecipeFilesView().environment(session) }
        }
    }

    private func choose(_ r: RecipeCreateRoute) { dismiss(); onChoose(r) }

    private func optionCard(icon: String, tint: Color, title: String, subtitle: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd).fill(tint).frame(width: 44, height: 44)
                    Image(systemName: icon).scaledFont(19).foregroundStyle(Color.stockedWhite)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).scaledFont(16, weight: .semibold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text(subtitle).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.3))
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
    @State private var stage = ""
    @State private var importTask: Task<Void, Never>?
    @State private var importState = RecipeBrowserImportState()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Paste a link to a recipe page. We'll pull the title, ingredients, and steps for you to review.")
                        .scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("https://…", text: $urlText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).focused($focused)
                        .scaledFont(15)
                        .padding(14)
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        .foregroundStyle(session.themeTextColor)

                    RecipeBrowserLink(url: urlText, title: "View before importing")

                    PasteButton(payloadType: String.self) { values in
                        if let text = values.first, let url = RecipeImportCoordinator.normalizedURLString(from: text) { urlText = url }
                        else { error = "The clipboard doesn’t contain a supported recipe link." }
                    }.tint(session.isDarkMode ? .stockedGoldDark : .stockedGold).disabled(loading)
                        .accessibilityLabel("Paste recipe link")

                    if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(Color.stockedGold)
                            Text(stage).scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.6))
                        }
                    }

                    if let error {
                        Text(error).scaledFont(13).foregroundStyle(Color.stockedError)
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
                Button {
                    if loading { cancelImport() }
                    else { importTask = Task { await fetch() } }
                } label: {
                    HStack {
                        if loading { ProgressView().tint(.white) }
                        Text(loading ? "Cancel Import" : "Import")
                            .scaledFont(16, weight: .semibold)
                    }
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(loading ? Color.stockedError : (isValidURL ? session.themeButtonColor : Color.gray.opacity(0.5)))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain).disabled(!loading && !isValidURL)
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            .onDisappear { cancelImport() }
        }
    }

    private var isValidURL: Bool {
        RecipeImportCoordinator.normalizedURLString(from: urlText) != nil
    }

    private func fetch() async {
        guard !loading else { return }
        error = nil; focused = false
        guard let trimmed = RecipeImportCoordinator.normalizedURLString(from: urlText) else {
            error = "Enter a valid recipe link."
            return
        }
        guard ConnectivityMonitor.isOnlineFlag else { error = "You're offline — connect and try again."; return }
        loading = true
        let token = importState.begin()
        defer { if importState.accepts(token) { importState.finish(token); loading = false } }
        do {
            let result = try await RecipeImportCoordinator.importURL(trimmed) { next in
                if importState.accepts(token) { stage = next }
            }
            try Task.checkCancellation()
            guard importState.accepts(token) else { return }
            var form = result.form
            form.notes = [form.notes, RecipeImportQuality.summary(form)].filter { !$0.isEmpty }.joined(separator: "\n")
            if let existing = RecipeImportQuality.duplicate(form, in: session.guestStore.userRecipes) {
                form.notes = "Possible duplicate of \"\(existing.title)\". Review before saving.\n" + form.notes
            }
            // Don't call dismiss() here: the parent presents this sheet via
            // .sheet(item: createRoute) and its onParsed closure tears it down by
            // setting createRoute = nil before presenting the prefilled form. Calling
            // the environment dismiss() as well raced that binding and made the form
            // present/dismiss endlessly.
            onParsed(form, result.source)
        } catch is CancellationError {
            if importState.accepts(token) { stage = "Import cancelled" }
        } catch {
            if importState.accepts(token) { self.error = (error as? RecipePageLoadError)?.message ?? "Couldn't read that page. Retry, paste its text, or import screenshots instead." }
        }
    }

    private func cancelImport() {
        importState.cancel(); importTask?.cancel(); importTask = nil; loading = false; stage = "Import cancelled"
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

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let pickerLabel = working ? "Reading…" : "Choose Screenshots"
        let pickerText = session.themeTextColor
        let pickerSurface = session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5)
        let pickerRadius = StockedUI.cornerRadiusLg
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("Pick a screenshot of a recipe. We'll read the text on your device and structure it for you to review.")
                        .scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)

                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 12, matching: .images) {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.badge.plus").scaledFont(40).foregroundStyle(Color.stockedGold)
                            Text(pickerLabel)
                                .scaledFont(16, weight: .semibold, design: .serif)
                                .foregroundStyle(pickerText)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                        .background(pickerSurface)
                        .clipShape(RoundedRectangle(cornerRadius: pickerRadius))
                    }
                    .disabled(working)

                    if working { ProgressView().tint(Color.stockedGold) }
                    if let error {
                        Text(error).scaledFont(13).foregroundStyle(Color.stockedError)
                            .multilineTextAlignment(.center)
                    }
                    Text("Tip: the clearer the screenshot, the better the result. You can fix anything on the next screen.")
                        .scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.4))
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
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await handle(items) }
            }
        }
    }

    private func handle(_ items: [PhotosPickerItem]) async {
        error = nil; working = true
        defer { working = false }
        var pages: [String] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            let page = await RecipeOCR.recognizeText(in: image)
            if !page.isEmpty { pages.append(page) }
        }
        let text = RecipeTextParser.mergeOCRPages(pages)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "No readable text found in those screenshots."; return
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
                        .scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Paste recipe here…")
                                .stockedTextEditorPlaceholder()
                        }
                        TextEditor(text: $text)
                            .stockedTextEditorContent(minimumHeight: 220)
                            .focused($focused)
                    }
                    .stockedInputSurface()

                    if let error {
                        Text(error).scaledFont(13).foregroundStyle(Color.stockedError)
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
                    Text("Structure Recipe").scaledFont(16, weight: .semibold)
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
nonisolated enum RecipeTextParser {
    static func mergeOCRPages(_ pages: [String]) -> String {
        var seen = Set<String>()
        return pages.flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let key = line.lowercased().filter { $0.isLetter || $0.isNumber }
                guard key.count > 2, seen.insert(key).inserted else { return false }
                return true
            }.joined(separator: "\n")
    }
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
    private static let units = ["cup","cups","tbsp","tablespoon","tablespoons","tsp","teaspoon","teaspoons","oz","ounce","ounces","lb","lbs","pound","pounds",
                                "g","gram","kg","ml","l","clove","cloves","pinch","slice","slices","can","cans",
                                "package","packages","pkg","stick","sticks","dash","quart","quarts","pint","pints","gallon","gallons",
                                "liter","liters","litre","litres","centimeter","cm","handful","bunch","sprig","sprigs"]

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
        lower == "ingredients" || lower.hasPrefix("ingredients") && lower.count < 28 ||
        lower.hasPrefix("for the ") || lower.hasPrefix("for ") && lower.count < 32
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

// MARK: - Shared URL import pipeline

enum RecipeImportCoordinator {
    nonisolated struct Result: Sendable { let form: AddRecipeForm; let source: String }

    static func normalizedURLString(from input: String) -> String? {
        // A bare URL is checked before link detection, so invalid schemes or
        // embedded credentials cannot be rescued into a different link silently.
        if let direct = RecipeBrowserPolicy.importURL(input) { return direct.absoluteString }
        guard input.count <= 16_384, !input.trimmingCharacters(in: .whitespacesAndNewlines).contains("://") || input.contains(where: \.isWhitespace) else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(input.startIndex..., in: input)
        guard let candidate = detector?.firstMatch(in: input, range: range)?.url?.absoluteString else { return nil }
        return RecipeBrowserPolicy.importURL(candidate)?.absoluteString
    }

    @MainActor
    static func importURL(_ input: String, progress: @escaping (String) -> Void) async throws -> Result {
        guard let url = normalizedURLString(from: input) else { throw StockedError.invalidURL(input) }
        progress("Opening recipe page…")
        try Task.checkCancellation()
        if let platform = SocialImportDetector.platform(for: url) {
            progress("Reading \(platform.displayName) post…")
            let content = try await SocialImportFetcher.fetch(url, platform: platform)
            var form = RecipeTextParser.parse(content.combinedText)
            form.title = form.title.isEmpty ? content.title : form.title
            form.description = content.caption
            form.imageURL = content.imageURL
            form.sourceURL = content.sourceURL
            form.originalText = content.combinedText
            return Result(form: form, source: platform.displayName)
        }
        let page = try await WebRecipeFetcher.shared.importPageHTML(url)
        try Task.checkCancellation()
        progress("Reading ingredients and instructions…")
        guard let result = await parsePage(html: page.html, url: page.url) else {
            try Task.checkCancellation(); throw StockedError.noResults(url)
        }
        try Task.checkCancellation()
        progress("Recipe ready to review")
        return result
    }

    /// Parse the same downloaded/rendered page once, away from the UI actor. The
    /// visible-text fallback reuses these bytes instead of making a second request.
    nonisolated static func parsePage(html: String, url: URL, allowTextFallback: Bool = true) async -> Result? {
        guard html.utf8.count <= RecipePageResponsePolicy.maximumHTMLBytes,
              RecipeBrowserPolicy.url(url.absoluteString) != nil, !Task.isCancelled else { return nil }
        let work = Task.detached(priority: .utility) { () -> Result? in
            guard !Task.isCancelled else { return nil }
            if let web = JSONLDRecipeParser.parse(html: html, pageURL: url.absoluteString),
               !web.ingredients.isEmpty, !web.steps.isEmpty {
                return Result(form: form(from: web), source: web.sourceName)
            }
            guard allowTextFallback, !Task.isCancelled,
                  let form = SharedRecipeImporter.visiblePageForm(html: html, urlStr: url.absoluteString) else { return nil }
            return Result(form: form, source: RecipeBrowserPolicy.hostLabel(url))
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        return Task.isCancelled ? nil : result
    }

    private nonisolated static func form(from web: WebRecipe) -> AddRecipeForm {
        var form = AddRecipeForm()
        form.title = web.title; form.ingredients = web.ingredients; form.steps = web.steps.map(\.text)
        form.imageURL = web.imageURL; form.sourceURL = web.sourceURL; form.servings = web.servings
        form.description = web.description; form.prepTime = web.prepTime; form.cookTime = web.cookTime
        form.cuisine = web.cuisine; form.totalTime = web.totalTime
        form.tags = web.tags; form.category = web.category; form.sourceURL = web.sourceURL
        form.originalText = [web.title, web.description, "Ingredients", web.ingredients.joined(separator: "\n"),
                             "Instructions", web.steps.map(\.text).joined(separator: "\n")].joined(separator: "\n\n")
        return form
    }
}

enum RecipeImportQuality {
    static func exactDuplicate(_ form: AddRecipeForm, in recipes: [UserRecipe]) -> UserRecipe? {
        guard let source = RecipeBrowserPolicy.importURL(form.sourceURL) else { return nil }
        let identity = FinderWebPolicy.identity(source.absoluteString)
        return recipes.first { recipe in
            guard let saved = RecipeBrowserPolicy.importURL(recipe.attributedSourceURL ?? "") else { return false }
            return identity == FinderWebPolicy.identity(saved.absoluteString)
        }
    }
    static func summary(_ form: AddRecipeForm) -> String {
        var found = ["\(form.ingredients.count) ingredients", "\(form.steps.count) steps"]
        if !form.cookTime.isEmpty { found.append("cook time") }
        if !form.imageURL.isEmpty { found.append("image") }
        let missing = [(form.title.isEmpty, "title"), (form.ingredients.isEmpty, "ingredients"), (form.steps.isEmpty, "instructions"),
                       (form.imageURL.isEmpty, "image"), (RecipePageMarkup.servings(form.servings) == nil, "serving count")]
            .compactMap { $0.0 ? $0.1 : nil }
        return "Import quality: Found " + found.joined(separator: ", ") +
            (missing.isEmpty ? "." : ". Needs review: " + missing.joined(separator: ", ") + ".")
    }

    static func duplicate(_ form: AddRecipeForm, in recipes: [UserRecipe]) -> UserRecipe? {
        let title = OnlineRecipeFacts.normalizedTitle(form.title)
        let source = RecipeImportCoordinator.normalizedURLString(from: form.sourceURL)
        return recipes.first {
            OnlineRecipeFacts.normalizedTitle($0.title) == title ||
            (source != nil && RecipeImportCoordinator.normalizedURLString(from: $0.attributedSourceURL ?? "") == source) ||
            (source != nil && $0.notes.localizedCaseInsensitiveContains(source!))
        }
    }
}
