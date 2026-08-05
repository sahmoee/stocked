// SocialImportView.swift — RL-009: preview-before-save for social recipe links.
// ─────────────────────────────────────────────────────────────────────────────
// Presented when a pasted/imported URL turns out to be TikTok / Instagram / YouTube /
// Pinterest. Flow:
//
//   duplicate check → fetch public og: metadata → structure via the SAME Worker
//   recipeImport route as website imports (RecipeImportAI.structure) → preview.
//
// The preview shows exactly what was extracted — title, image, ingredients, quantities,
// servings, steps — and flags every uncertain/missing field with a "Needs review" chip.
// Captions rarely carry full quantities, so honesty beats confidence here: nothing is
// invented, and saving is always an explicit user action. When the post has too little
// text, the sheet explains what's missing and offers manual completion or AI-assisted
// drafting through the existing CreateRecipeView prefill path (explicitly labeled).
//
// Saved recipes keep the original link in `notes` ("Saved from TikTok: https://…") — the
// same convention website saves use — which also powers the duplicate check.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

struct SocialImportSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let urlString: String
    /// Route into the shared CreateRecipeView prefill flow (parent presents the form) —
    /// reused for "Edit before saving", manual completion, and AI-assisted drafting.
    var onOpenInForm: (AddRecipeForm, String) -> Void

    // ── Phase machine ───────────────────────────────────────────────────
    enum Phase {
        case working(String)                              // fetching / structuring status
        case duplicate(UserRecipe)                        // already imported this link
        case preview(SocialPageContent, AIRecipe)         // structured result to review
        case insufficient(SocialPageContent?, String)     // some/no content + explanation
        case failed(String)                               // clear error, no fake recipe
    }
    @State private var phase: Phase = .working("Fetching the post…")
    @State private var didStart = false
    @State private var saveOverridesDuplicate = false

    private var platform: SocialPlatform {
        SocialImportDetector.platform(for: urlString) ?? .tiktok
    }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    content.padding(20)
                }
            }
            .navigationTitle("Import from \(platform.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(session.themeTextColor.opacity(0.6))
                }
            }
            .task {
                guard !didStart else { return }
                didStart = true
                await run()
            }
        }
    }

    // MARK: - Import pipeline

    @MainActor
    private func run() async {
        // 1) Duplicate gate — same link (normalized) already saved?
        if !saveOverridesDuplicate,
           let existing = SocialImportDetector.existingImport(of: urlString,
                                                              in: session.guestStore.userRecipes) {
            phase = .duplicate(existing)
            return
        }

        // 2) Fetch public content, short timeout, honest failures.
        phase = .working("Fetching the post…")
        let content: SocialPageContent
        do {
            content = try await SocialImportFetcher.fetch(urlString, platform: platform)
        } catch let error as SocialImportError {
            if case .insufficientContent = error {
                phase = .insufficient(nil, error.userMessage)
            } else {
                phase = .failed(error.userMessage)
            }
            return
        } catch {
            phase = .failed("Couldn't read that page. Check the link and try again.")
            return
        }

        // 3) Structure the VERBATIM extracted text through the same Worker route as web
        //    imports. The model is told to flag uncertainty, never to invent amounts.
        phase = .working("Structuring the recipe…")
        if let ai = await RecipeImportAI.structure(rawText: content.combinedText,
                                                   sourceURL: content.sourceURL),
           !ai.ingredients.isEmpty || !ai.steps.isEmpty {
            phase = .preview(content, ai)
            return
        }
        // Worker unavailable/offline → the on-device parser, same as other import paths.
        let parsed = RecipeTextParser.parse(content.combinedText)
        if !parsed.ingredients.isEmpty || !parsed.steps.isEmpty {
            var fallback = AIRecipe()
            fallback.title = parsed.title.isEmpty ? content.title : parsed.title
            fallback.ingredients = parsed.ingredients.map { .init(name: $0, amount: "", needsReview: true) }
            fallback.steps = parsed.steps
            phase = .preview(content, fallback)
        } else {
            phase = .insufficient(content,
                "The post's caption doesn't spell out ingredients or steps, so there isn't enough to build a recipe from automatically.")
        }
    }

    // MARK: - Content per phase

    @ViewBuilder private var content: some View {
        switch phase {
        case .working(let status):
            VStack(spacing: 14) {
                ProgressView().tint(Color.stockedGold)
                Text(status)
                    .font(.system(size: 14))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)

        case .duplicate(let existing):
            duplicateView(existing)

        case .preview(let content, let recipe):
            previewView(content, recipe)

        case .insufficient(let content, let explanation):
            insufficientView(content, explanation)

        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.stockedError.opacity(0.8))
                Text("Couldn't import that post")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Text(message)
                    .font(.system(size: 13.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                    .multilineTextAlignment(.center)
                Button { dismiss() } label: {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.stockedWhite)
                        .padding(.horizontal, 32).padding(.vertical, 12)
                        .background(Color.stockedCharcoal).clipShape(Capsule())
                }.buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        }
    }

    // MARK: Duplicate

    private func duplicateView(_ existing: UserRecipe) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34))
                .foregroundStyle(Color.stockedSuccess)
            Text("Already imported")
                .font(.system(size: 18, weight: .semibold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            Text("This link is already saved as “\(existing.title)” in My Recipes.")
                .font(.system(size: 14))
                .foregroundStyle(session.themeTextColor.opacity(0.65))
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                Button {
                    // Take the user to their saved copy rather than making a twin.
                    dismiss()
                    NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.recipes)
                } label: {
                    Text("Open My Recipes")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(session.themeButtonColor).clipShape(Capsule())
                }.buttonStyle(.plain)

                Button {
                    saveOverridesDuplicate = true
                    Task { await run() }
                } label: {
                    Text("Import Again Anyway")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(session.themeTextColor.opacity(0.6))
                }.buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    // MARK: Preview

    private func previewView(_ content: SocialPageContent, _ recipe: AIRecipe) -> some View {
        let missingSteps      = recipe.steps.isEmpty
        let missingServings   = recipe.servings.trimmingCharacters(in: .whitespaces).isEmpty
        let uncertainCount    = recipe.ingredients.filter { $0.needsReview || $0.amount.isEmpty }.count

        return VStack(alignment: .leading, spacing: 18) {
            // Hero image straight from og:image (never a lookalike stock photo).
            if !content.imageURL.isEmpty {
                CachedAsyncImage(url: content.imageURL, imageData: nil, height: 190)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(recipe.title.isEmpty ? content.title : recipe.title)
                    .font(.system(size: 21, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Label {
                    Text(content.sourceURL)
                        .font(.system(size: 11.5))
                        .lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: platform.iconSystemName).font(.system(size: 11))
                }
                .foregroundStyle(session.themeTextColor.opacity(0.5))
            }

            if content.looksLikeMultipleRecipes {
                noteCard(icon: "square.stack",
                         text: "This post looks like it contains more than one recipe. The first was imported — check \"original text\" in the editor for the rest.")
            }
            if missingSteps || missingServings || uncertainCount > 0 {
                noteCard(icon: "exclamationmark.circle",
                         text: reviewSummary(missingSteps: missingSteps,
                                             missingServings: missingServings,
                                             uncertainIngredients: uncertainCount))
            }

            // ── Servings ──
            HStack(spacing: 8) {
                sectionHeader("Servings")
                if missingServings { needsReviewChip("Not stated") }
                else {
                    Text(recipe.servings)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(session.themeTextColor)
                }
            }

            // ── Ingredients ──
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Ingredients (\(recipe.ingredients.count))")
                if recipe.ingredients.isEmpty {
                    needsReviewChip("None found in the caption")
                } else {
                    ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, ing in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Color.stockedGold).frame(width: 5, height: 5)
                                .padding(.top, 5)
                            Text(ing.displayLine)
                                .font(.system(size: 14))
                                .foregroundStyle(session.themeTextColor)
                            if ing.needsReview || ing.amount.isEmpty {
                                needsReviewChip(ing.amount.isEmpty ? "No amount" : "Needs review")
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            // ── Steps ──
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Steps (\(recipe.steps.count))")
                if missingSteps {
                    needsReviewChip("No steps in the caption")
                } else {
                    ForEach(Array(recipe.steps.enumerated()), id: \.offset) { idx, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(idx + 1)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.stockedGold)
                            Text(step)
                                .font(.system(size: 14))
                                .foregroundStyle(session.themeTextColor.opacity(0.85))
                        }
                    }
                }
            }

            // ── Actions ──
            VStack(spacing: 10) {
                Button { save(content: content, recipe: recipe) } label: {
                    Text("Save Recipe")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(session.themeButtonColor).clipShape(Capsule())
                }.buttonStyle(.plain)

                Button { openInForm(content: content, recipe: recipe, aiAssisted: false) } label: {
                    Text("Edit Before Saving")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(session.themeTextColor.opacity(0.65))
                }.buttonStyle(.plain)
            }
            .padding(.top, 6)
        }
    }

    private func reviewSummary(missingSteps: Bool, missingServings: Bool,
                               uncertainIngredients: Int) -> String {
        var parts: [String] = []
        if uncertainIngredients > 0 {
            parts.append(uncertainIngredients == 1
                         ? "1 ingredient has no amount"
                         : "\(uncertainIngredients) ingredients have missing or uncertain amounts")
        }
        if missingSteps { parts.append("the caption didn't include steps") }
        if missingServings { parts.append("servings weren't stated") }
        return "Needs review: " + parts.joined(separator: "; ")
            + ". Only what the post actually says was imported — nothing was guessed."
    }

    // MARK: Insufficient content

    private func insufficientView(_ content: SocialPageContent?, _ explanation: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(session.themeTextColor.opacity(0.35))
            Text("Not enough to build a recipe")
                .font(.system(size: 18, weight: .semibold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            Text(explanation)
                .font(.system(size: 14))
                .foregroundStyle(session.themeTextColor.opacity(0.65))
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                Button {
                    var form = AddRecipeForm()
                    form.title = content?.title ?? ""
                    form.sourceURL = urlString
                    form.imageURL = content?.imageURL ?? ""
                    form.originalText = originalText(for: content)
                    // No dismiss() — the parent swaps its sheet item to the prefilled form
                    // (calling dismiss too races the item change; see RecipeCreateOptions).
                    onOpenInForm(form, platform.displayName)
                } label: {
                    Text("Complete It Manually")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(session.themeButtonColor).clipShape(Capsule())
                }.buttonStyle(.plain)

                if let content, RecipeImportAI.isAvailable {
                    Button {
                        // Explicitly-labeled AI drafting: the form's import banner reads
                        // "TikTok · AI-assisted draft" and the existing CreateRecipeView
                        // AI-structuring / broken-import cleanup pipeline does the rest.
                        var form = AddRecipeForm()
                        form.title = content.title
                        form.sourceURL = content.sourceURL
                        form.imageURL = content.imageURL
                        form.description = content.caption
                        form.originalText = originalText(for: content)
                        form.notes = "AI-assisted draft from a \(platform.displayName) post — verify amounts and steps before cooking."
                        onOpenInForm(form, "\(platform.displayName) · AI-assisted draft")
                    } label: {
                        Label("Draft It with AI (labeled)", systemImage: "sparkles")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.stockedGold)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Actions

    private func save(content: SocialPageContent, recipe: AIRecipe) {
        var saved = UserRecipe(
            title: (recipe.title.isEmpty ? content.title : recipe.title)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            description: recipe.description,
            cookTime: recipe.cookTime.isEmpty ? recipe.totalTime : recipe.cookTime,
            prepTime: recipe.prepTime,
            servings: Int(recipe.servings) ?? 4,
            cuisine: recipe.cuisine,
            ingredients: recipe.ingredients.map { ing in
                var qty = ing.quantity
                var unit = ing.unit
                if qty == nil, !ing.amount.isEmpty {
                    let parsed = ParsedQuantity.parse(ing.amount)
                    qty = parsed.amount > 0 ? parsed.amount : nil
                    unit = parsed.canonicalUnit.isEmpty ? nil : parsed.canonicalUnit
                }
                return RecipeIngredient(name: ing.name, amount: ing.amount,
                                        quantity: qty, unit: unit, prep: ing.prep)
            },
            instructions: recipe.steps,
            // Original source link preserved — also what the duplicate check scans for.
            notes: "Saved from \(platform.displayName): \(content.sourceURL)",
            imageURL: content.imageURL.isEmpty ? nil : content.imageURL
        )
        if saved.title.isEmpty { saved.title = "\(platform.displayName) Recipe" }
        let classification = RecipeClassifier.classify(
            title: saved.title,
            rawCuisine: recipe.cuisine,
            rawCategory: nil,
            keywords: [],
            ingredients: saved.ingredients,
            instructions: saved.instructions
        )
        saved.cuisine = classification.cuisine
        saved.tags = classification.tags
        session.guestStore.addUserRecipe(saved)
        HapticManager.success()
        dismiss()
    }

    private func openInForm(content: SocialPageContent, recipe: AIRecipe, aiAssisted: Bool) {
        var form = AddRecipeForm()
        form.title = recipe.title.isEmpty ? content.title : recipe.title
        form.description = recipe.description
        form.prepTime = recipe.prepTime
        form.cookTime = recipe.cookTime.isEmpty ? recipe.totalTime : recipe.cookTime
        form.servings = recipe.servings
        form.cuisine = recipe.cuisine
        form.ingredients = recipe.ingredients.map(\.displayLine)
        form.steps = recipe.steps
        form.imageURL = content.imageURL
        form.sourceURL = content.sourceURL
        form.originalText = originalText(for: content)
        // No dismiss() — the parent swaps its sheet item to the prefilled form.
        onOpenInForm(form, platform.displayName)
    }

    /// Verbatim extracted text + a Source line, so "Show original text" keeps the link even
    /// on paths where the form's notes field isn't carried through.
    private func originalText(for content: SocialPageContent?) -> String {
        guard let content else { return "Source: \(urlString)" }
        return content.combinedText + "\n\nSource: \(content.sourceURL)"
    }

    // MARK: - Small pieces

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold, design: .serif))
            .foregroundStyle(session.themeTextColor)
    }

    private func needsReviewChip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.stockedError.opacity(0.9))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.stockedError.opacity(0.12))
            .clipShape(Capsule())
    }

    private func noteCard(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.stockedGold)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(session.themeTextColor.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.stockedGold.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }
}
