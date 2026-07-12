// CreateRecipeView.swift — the New Recipe form (create + AI-assisted import).
// Split out of ReadyToCookView.swift (Build 189, code-health refactor #1). No logic changes.
import SwiftUI
import PhotosUI

// MARK: - Create Recipe View (full form)

struct CreateRecipeView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    // Optional prefill from an import path (URL / screenshot OCR / pasted text). When set,
    // it's applied once on appear via the existing applyAutofill path.
    var prefill: AddRecipeForm? = nil
    var prefillSource: String = "Imported"

    // ── Form state ──────────────────────────────────────────────────────
    @State private var title       = ""
    @State private var description = ""
    @State private var cookTime    = ""
    @State private var prepTime    = ""
    @State private var servings    = 4
    @State private var difficulty  = "Medium"
    @State private var cuisine     = ""
    @State private var ingredients: [RecipeIngredient] = []
    @State private var instructions: [String] = [""]
    @State private var notes       = ""
    @State private var imageData:  Data?
    @State private var imageURL    = ""

    // ── NEW: autofill state ─────────────────────────────────────────────
    /// The form that RecipePredictiveTextField fills on tap.
    @State private var autofillForm = AddRecipeForm()
    /// Shown after autofill, dismissed by ×.
    @State private var autofillSource: String? = nil
    /// AI import structuring (Haiku via the Worker).
    @State private var isStructuring = false
    @State private var didStructure  = false
    @State private var originalText  = ""
    @State private var showOriginal  = false
    @State private var groceryPushMsg: String? = nil
    /// Ingredient IDs the AI flagged as uncertain (#6) — shown with a review hint.
    @State private var flaggedIngredientIDs: Set<UUID> = []

    @State private var selectedPhoto: PhotosPickerItem?

    let difficulties = ["Easy","Medium","Hard","Expert"]

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {

                        // Photo — shows the pulled / auto-resolved image; tap to set your own
                        photoSection.padding(.bottom, 24)

                        // ── Recipe Details ─────────────────────────────────
                        formSection("Recipe Details") {

                            VStack(alignment: .leading, spacing: 0) {
                                RecipePredictiveTextField(
                                    placeholder: "Title *",
                                    text: $title,
                                    form: $autofillForm,
                                    onRecipeFill: { entry in
                                        applyAutofill(from: autofillForm, sourceName: entry.sourceName)
                                    }
                                )
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(session.themeTextColor)
                                .padding(16)

                                // Autofill confirmation banner
                                if let source = autofillSource {
                                    RecipeFormAutofillBanner(sourceName: source) {
                                        withAnimation { autofillSource = nil }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 12)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                }

                                if isStructuring {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text("Tidying up the import…")
                                            .font(.system(size: 12))
                                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                                    }
                                    .padding(.horizontal, 16).padding(.bottom, 10)
                                }

                                if !originalText.isEmpty {
                                    Button { showOriginal = true } label: {
                                        Label("Show original text", systemImage: "doc.plaintext")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 16).padding(.bottom, 10)
                                }
                            }

                            formDivider
                            fieldLabel("Description")
                            bigEditor(placeholder: "A short description…", text: $description, minHeight: 88)
                            formDivider
                            fieldLabel("Cuisine")
                            bigField("Italian, Mexican, American…", text: $cuisine)
                        }

                        // ── Timing & Servings ──────────────────────────────
                        formSection("Timing & Servings") {
                            HStack(spacing: 0) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Prep Time")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                                    TextField("15 min", text: $prepTime)
                                        .font(.system(size: 17))
                                        .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                                }
                                .padding(16)
                                Divider().frame(height: 48)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Cook Time")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                                    TextField("30 min", text: $cookTime)
                                        .font(.system(size: 17))
                                        .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                                }
                                .padding(16)
                            }

                            formDivider
                            HStack {
                                Text("Servings")
                                    .font(.system(size: 16))
                                    .foregroundStyle(session.themeTextColor)
                                Spacer()
                                Stepper("", value: $servings, in: 1...50).labelsHidden()
                                Text("\(servings)")
                                    .font(.system(size: 17, weight: .semibold, design: .serif))
                                    .foregroundStyle(session.themeTextColor)
                                    .frame(minWidth: 30)
                            }
                            .padding(16)

                            formDivider
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Difficulty")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(session.themeTextColor.opacity(0.45))
                                HStack(spacing: 8) {
                                    ForEach(difficulties, id: \.self) { d in
                                        Button { difficulty = d } label: {
                                            Text(d)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(difficulty == d ? Color.stockedWhite : session.themeTextColor.opacity(0.6))
                                                .padding(.horizontal, 14).padding(.vertical, 9)
                                                .background(difficulty == d ? Color.stockedGold : Color.stockedWhite.opacity(0.35))
                                                .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                        }

                        // ── Ingredients ────────────────────────────────────
                        formSection("Ingredients") {
                            if ingredients.isEmpty {
                                Text("No ingredients yet — tap below to add some.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                            } else {
                                ForEach($ingredients) { $ing in
                                    IngredientFormRow(ingredient: $ing) {
                                        withAnimation { ingredients.removeAll { $0.id == ing.id } }
                                    }
                                    if flaggedIngredientIDs.contains(ing.id) {
                                        HStack(spacing: 5) {
                                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                                            Text("Double-check this one").font(.system(size: 11, weight: .semibold))
                                        }
                                        .foregroundStyle(Color.stockedGold)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 16).padding(.bottom, 8)
                                    }
                                    formDivider
                                }
                            }
                            Button {
                                withAnimation { ingredients.append(RecipeIngredient(name: "", amount: "")) }
                            } label: {
                                Label("Add Ingredient", systemImage: "plus.circle.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.stockedGold)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                            }
                            .buttonStyle(.plain)

                            if !ingredients.isEmpty {
                                formDivider
                                Button {
                                    let n = session.guestStore.addRecipeIngredientsToGrocery(
                                        ingredients, recipeName: title.isEmpty ? "Recipe" : title)
                                    withAnimation {
                                        groceryPushMsg = n > 0
                                            ? "Added \(n) item\(n == 1 ? "" : "s") to your grocery list"
                                            : "Those are already on your list or in stock"
                                    }
                                } label: {
                                    Label("Add missing to grocery list", systemImage: "cart.badge.plus")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Color.stockedGreen)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(16)
                                }
                                .buttonStyle(.plain)
                                if let msg = groceryPushMsg {
                                    Text(msg)
                                        .font(.system(size: 12))
                                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                                        .padding(.horizontal, 16).padding(.bottom, 12)
                                }
                            }
                        }

                        // ── Steps ──────────────────────────────────────────
                        formSection("Steps") {
                            ForEach(instructions.indices, id: \.self) { idx in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 14, weight: .bold, design: .serif))
                                        .foregroundStyle(Color.stockedWhite)
                                        .frame(width: 26, height: 26)
                                        .background(Circle().fill(Color.stockedGold))
                                        .padding(.top, 10)
                                    VStack(alignment: .leading, spacing: 2) {
                                        bigEditor(placeholder: "Describe step \(idx + 1)…", text: $instructions[idx], minHeight: 60)
                                        if let secs = StepTimerEngine.detectSeconds(in: instructions[idx]), secs > 0 {
                                            HStack(spacing: 5) {
                                                Image(systemName: "timer").font(.system(size: 10))
                                                Text("\(timerLabel(secs)) timer").font(.system(size: 11, weight: .semibold))
                                            }
                                            .foregroundStyle(Color.stockedGold)
                                            .padding(.horizontal, 14).padding(.bottom, 8)
                                        }
                                    }
                                    Button {
                                        withAnimation {
                                            instructions.remove(at: idx)
                                            if instructions.isEmpty { instructions = [""] }
                                        }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.5))
                                    }
                                    .buttonStyle(.plain).padding(.top, 12)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 4)
                                formDivider
                            }
                            Button {
                                withAnimation { instructions.append("") }
                            } label: {
                                Label("Add Step", systemImage: "plus.circle.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.stockedGold)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                            }
                            .buttonStyle(.plain)
                        }

                        // ── Notes ──────────────────────────────────────────
                        formSection("Notes") {
                            bigEditor(placeholder: "Anything else worth remembering…", text: $notes, minHeight: 88)
                        }

                        Color.clear.frame(height: StockedUI.scrollBottomPad)

                    } // VStack
                } // ScrollView
            } // ZStack
            .navigationTitle("New Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showOriginal) {
                NavigationStack {
                    ScrollView {
                        Text(originalText)
                            .font(.system(size: 14))
                            .foregroundStyle(session.themeTextColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                    .background(session.themeBgColor.ignoresSafeArea())
                    .navigationTitle("Original Text")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showOriginal = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .onAppear {
                guard let prefill, !didStructure else { return }
                didStructure = true
                if imageURL.isEmpty { imageURL = prefill.imageURL }
                originalText = prefill.originalText
                if title.isEmpty, !prefill.title.isEmpty { title = prefill.title }

                // Prefer the true source text; otherwise compose from the parsed fields so
                // the model can still clean up names/amounts.
                let rawText = prefill.originalText.isEmpty
                    ? RecipeImportAI.composeRawText(title: prefill.title, description: prefill.description,
                                                    ingredients: prefill.ingredients, steps: prefill.steps)
                    : prefill.originalText

                if RecipeImportAI.isAvailable,
                   rawText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 {
                    isStructuring = true
                    // #8 — resolve the hero image in parallel with the AI call so it's
                    // warm in the cache by the time structuring returns, instead of only
                    // starting once the form is on screen.
                    if imageURL.isEmpty, !title.isEmpty {
                        let name = title
                        Task.detached(priority: .utility) {
                            _ = await RecipeImageResolver.shared.imageURL(for: name)
                        }
                    }
                    Task { @MainActor in
                        if let ai = await RecipeImportAI.structure(rawText: rawText, sourceURL: prefill.sourceURL) {
                            applyAIRecipe(ai, source: prefillSource)
                        } else {
                            applyAutofill(from: prefill, sourceName: prefillSource)
                        }
                        if originalText.isEmpty { originalText = rawText }
                        isStructuring = false
                    }
                } else {
                    applyAutofill(from: prefill, sourceName: prefillSource)
                    if originalText.isEmpty { originalText = rawText }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveRecipe() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Apply an AI-structured recipe (authoritative on import)
    private func applyAIRecipe(_ ai: AIRecipe, source: String) {
        withAnimation {
            if !ai.title.isEmpty       { title       = ai.title }
            if !ai.description.isEmpty { description = ai.description }
            if !ai.cuisine.isEmpty     { cuisine     = ai.cuisine }
            if !ai.prepTime.isEmpty    { prepTime    = ai.prepTime }
            let cook = ai.cookTime.isEmpty ? ai.totalTime : ai.cookTime
            if !cook.isEmpty           { cookTime    = cook }
            if let s = Int(ai.servings) { servings = s }
            if !ai.ingredients.isEmpty {
                var seen = Set<String>()
                var rows: [RecipeIngredient] = []
                var flagged = Set<UUID>()
                for ing in ai.ingredients {
                    // #8 — merge/de-dupe by canonical name.
                    let canon = IngredientMatcher.canonical(ing.name)
                    if !canon.isEmpty {
                        if seen.contains(canon) { continue }
                        seen.insert(canon)
                    }
                    // #1 — prefer the model's structured fields; only parse the amount if
                    // the model didn't supply quantity/unit.
                    var qty = ing.quantity
                    var unit = ing.unit
                    if qty == nil, !ing.amount.isEmpty {
                        let pa = ParsedQuantity.parse(ing.amount)
                        qty = pa.amount > 0 ? pa.amount : nil
                        unit = pa.canonicalUnit.isEmpty ? nil : pa.canonicalUnit
                    }
                    let row = RecipeIngredient(name: ing.name, amount: ing.amount,
                                               quantity: qty, unit: unit, prep: ing.prep)
                    if ing.needsReview { flagged.insert(row.id) }
                    rows.append(row)
                }
                ingredients = rows
                flaggedIngredientIDs = flagged
            }
            if !ai.steps.isEmpty { instructions = ai.steps }
            if instructions.isEmpty { instructions = [""] }
            autofillSource = source.isEmpty ? "Recipe Database" : source
        }
    }

    // MARK: - Apply autofill from AddRecipeForm → local @State
    private func applyAutofill(from form: AddRecipeForm, sourceName: String) {
        withAnimation {
            // Only overwrite fields that are still empty
            if description.isEmpty { description = form.description }
            if cuisine.isEmpty     { cuisine     = form.cuisine }
            if prepTime.isEmpty    { prepTime    = StockedFormatters.prettyDuration(form.prepTime) }
            if cookTime.isEmpty {
                let cook = StockedFormatters.prettyDuration(form.cookTime)
                cookTime = cook.isEmpty ? StockedFormatters.prettyDuration(form.totalTime) : cook
            }
            if servings == 4, let s = Int(form.servings) { servings = s }

            // Ingredients: split each line with ParsedQuantity (handles "1/4 cup …",
            // "2 4-ounce …", "12 strawberries, sliced", "salt and pepper to taste") and
            // present the name in sentence case rather than all-lowercase.
            if ingredients.isEmpty && !form.ingredients.isEmpty {
                ingredients = form.ingredients.compactMap { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    let parsed = ParsedQuantity.parse(trimmed)
                    let name   = parsed.baseName.isEmpty ? trimmed : parsed.baseName
                    let amount = parsed.amount > 0 ? parsed.display : ""
                    return RecipeIngredient(
                        name: Self.sentenceCased(name),
                        amount: amount,
                        quantity: parsed.amount > 0 ? parsed.amount : nil,
                        unit: parsed.canonicalUnit.isEmpty ? nil : parsed.canonicalUnit
                    )
                }
                ingredients = Self.dedupeByCanonical(ingredients)   // #8
            }

            // Steps — keep the source wording but ensure they don't arrive all-lowercase.
            if instructions == [""] || instructions.isEmpty, !form.steps.isEmpty {
                instructions = form.steps
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { Self.sentenceCased($0) }
                if instructions.isEmpty { instructions = [""] }
            }

            // Image URL
            if imageURL.isEmpty && !form.imageURL.isEmpty { imageURL = form.imageURL }

            // Show banner
            autofillSource = sourceName.isEmpty ? "Recipe Database" : sourceName
        }
    }

    // MARK: - Save (with DB write-back)
    private func saveRecipe() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let steps = instructions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var recipe = UserRecipe(
            title:        title.trimmingCharacters(in: .whitespacesAndNewlines),
            description:  description,
            cookTime:     cookTime,
            prepTime:     prepTime,
            servings:     servings,
            difficulty:   difficulty,
            cuisine:      cuisine,
            ingredients:  ingredients,
            instructions: steps,
            notes:        notes,
            imageURL:     imageURL.isEmpty ? nil : imageURL
        )
        if let data = imageData { recipe.imageData = data }

        // ── Save to AppSession (existing) ──
        session.guestStore.addUserRecipe(recipe)

        // ── NEW: Also write into RecipeDatabase for future predictive search ──
        Task(priority: .background) {
            await RecipeDatabaseManager.shared.save(userRecipe: recipe)
        }

        dismiss()
    }

    // MARK: - Helpers
    /// Capitalize only the first character, preserving the rest ("extra-virgin olive
    /// oil" → "Extra-virgin olive oil"). Avoids over-capitalizing every word.
    private static func sentenceCased(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return t }
        return first.uppercased() + t.dropFirst()
    }

    /// #8 — collapse duplicate ingredient lines by canonical name, keeping the first.
    private static func dedupeByCanonical(_ items: [RecipeIngredient]) -> [RecipeIngredient] {
        var seen = Set<String>(); var out: [RecipeIngredient] = []
        for it in items {
            let c = IngredientMatcher.canonical(it.name)
            if c.isEmpty { out.append(it); continue }
            if seen.insert(c).inserted { out.append(it) }
        }
        return out
    }

    /// Friendly label for a detected step-timer duration (in seconds).
    private func timerLabel(_ seconds: Int) -> String {
        let mins = seconds / 60
        if mins >= 60 {
            let h = mins / 60, m = mins % 60
            return m > 0 ? "\(h) hr \(m) min" : "\(h) hr"
        }
        return mins > 0 ? "\(mins) min" : "\(seconds) sec"
    }

    /// A small section/field label.
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(session.themeTextColor.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 2)
    }

    /// A larger single-line text field — roomier tap target and bigger type.
    private func bigField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 16))
            .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
            .padding(.horizontal, 18).padding(.vertical, 16)
    }

    /// A multi-line editor with a placeholder and a comfortable minimum height,
    /// so descriptions, steps, and notes have real room to type.
    private func bigEditor(placeholder: String, text: Binding<String>, minHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 16))
                    .foregroundStyle(session.themeTextColor.opacity(0.3))
                    .padding(.horizontal, 18).padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .font(.system(size: 16))
                .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private var formDivider: some View {
        Rectangle()
            .fill(Color.stockedCharcoal.opacity(0.1))
            .frame(height: 1)
            .padding(.leading, 14)
    }

    @ViewBuilder
    private func formSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(session.themeTextColor.opacity(0.5))
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 16)
        VStack(spacing: 0) { content() }
            .background(Color.stockedWhite.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .padding(.horizontal, 20)
    }

    // MARK: - Photo section
    // Shows the pulled image (from the autofilled imageURL) or one resolved by title,
    // and lets the user pick their own from the photo library.
    @ViewBuilder
    private var photoSection: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                    .fill(Color.stockedWhite.opacity(0.25))
                if imageData != nil || !imageURL.isEmpty || !title.isEmpty {
                    RecipeHeroImage(
                        imageData: imageData,
                        imageURL: imageURL.isEmpty ? nil : imageURL,
                        recipeName: title,
                        height: 200
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 34))
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                        Text("Add a photo")
                            .font(.system(size: 13))
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                    }
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))

            HStack(spacing: 18) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label(imageData == nil ? "Choose Photo" : "Change Photo", systemImage: "photo.on.rectangle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                }
                if imageData != nil {
                    Button(role: .destructive) {
                        withAnimation { imageData = nil; selectedPhoto = nil }
                    } label: {
                        Label("Remove", systemImage: "trash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
        }
        .padding(.horizontal, 20)
        .onChange(of: selectedPhoto) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) {
                    await MainActor.run { withAnimation { imageData = data } }
                }
            }
        }
    }
}
