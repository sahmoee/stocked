// RecipePredictiveTextField.swift
// Predictive text field for recipe and ingredient search.
//
// Three modes:
//   • recipesOnly: true  → shows only recipe chips (no food items). Used in RecipePickerSheet.
//   • form: non-nil      → shows recipe chips + autofills form on tap.
//   • default            → shows food ingredient chips. Used in IngredientPickerSheet / grocery.

import SwiftUI

// MARK: - RecipePredictiveTextField
struct RecipePredictiveTextField: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedMotion) private var motion
    let placeholder: String
    @Binding var text: String

    /// When true, only recipe suggestions are shown (no ingredient chips).
    var recipesOnly: Bool = false

    /// When non-nil, selecting a recipe suggestion autofills the entire form.
    var form: Binding<AddRecipeForm>?

    var onCommit:     () -> Void    = {}
    var onSelect:     (String) -> Void = { _ in }
    var onRecipeFill: (RecipeDatabaseEntry) -> Void = { _ in }

    @FocusState private var isFocused: Bool
    @State private var recipeSuggestions: [RecipeDatabaseEntry] = []
    @State private var snapshot: [RecipeDatabaseEntry] = []
    @State private var recipeSuggestionPosition: UUID? = nil
    @State private var ingredientSuggestionPosition: UUID? = nil

    private var showRecipes: Bool { recipesOnly || form != nil }

    private var ingredientSuggestions: [KnowledgeIngredient] {
        guard !showRecipes else { return [] }
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 1 else { return [] }
        return StockedKnowledgeBase.shared.suggestIngredients(prefix: q, limit: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Text field ────────────────────────────────────────────
            TextField(placeholder, text: $text)
                .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                .focused($isFocused)
                .onSubmit { onCommit() }
                .autocorrectionDisabled()
                .onChange(of: text) { _, newValue in updateRecipeSuggestions(for: newValue) }
                .task { snapshot = await RecipeDatabaseManager.shared.loadSnapshot() }

            // ── Recipe suggestion chips ───────────────────────────────
            if !recipeSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "book.closed.fill")
                            .scaledFont(10)
                            .foregroundStyle(Color.stockedGold.opacity(0.7))
                        Text("Recipes")
                            .scaledFont(10, weight: .semibold, design: .serif)
                            .foregroundStyle(Color.stockedGold.opacity(0.7))
                    }
                    .padding(.top, 8)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(recipeSuggestions) { entry in
                                Button {
                                    motion.animate(.selection, intent: .spatial) {
                                        recipeSuggestionPosition = entry.id
                                    }
                                    selectRecipe(entry)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "fork.knife")
                                            .scaledFont(11)
                                            .foregroundStyle(Color.stockedGold)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.title)
                                                .scaledFont(13, weight: .semibold, design: .serif)
                                                .foregroundStyle(session.themeTextColor)
                                                .fixedSize(horizontal: false, vertical: true)
                                            if !entry.totalTime.isEmpty || !entry.sourceName.isEmpty {
                                                HStack(spacing: 4) {
                                                    if !entry.totalTime.isEmpty {
                                                        Text(entry.totalTime)
                                                            .scaledFont(10)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    if !entry.sourceName.isEmpty && entry.sourceName != "My Recipes" {
                                                        Text("· \(entry.sourceName)")
                                                            .scaledFont(10)
                                                            .foregroundStyle(.secondary)
                                                            .fixedSize(horizontal: false, vertical: true)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 7)
                                    .background(Color.stockedGold.opacity(0.12))
                                    .overlay(Capsule().stroke(Color.stockedGold.opacity(0.45), lineWidth: 1))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .id(entry.id)
                            }
                        }
                        .stockedScrollTargetLayout()
                        .padding(.vertical, 2)
                    }
                    .stockedHorizontalSnap()
                    .scrollPosition(id: $recipeSuggestionPosition, anchor: .center)
                    .contentMargins(.horizontal, 2, for: .scrollContent)
                    .onChange(of: recipeSuggestions.map(\.id)) { _, ids in
                        if let current = recipeSuggestionPosition, !ids.contains(current) {
                            recipeSuggestionPosition = ids.first
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // ── Ingredient suggestion chips (ingredient mode only) ────
            if !ingredientSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(ingredientSuggestions) { entry in
                            Button {
                                motion.animate(.selection, intent: .spatial) {
                                    ingredientSuggestionPosition = entry.id
                                }
                                text = entry.name
                                isFocused = false
                                onSelect(entry.name)
                            } label: {
                                HStack(spacing: 5) {
                                    Text(entry.emoji).scaledFont(14)
                                    Text(entry.name)
                                        .scaledFont(13, weight: .medium, design: .serif)
                                        .foregroundStyle(session.themeTextColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(Color.stockedGold.opacity(0.18))
                                .overlay(Capsule().stroke(Color.stockedGold.opacity(0.5), lineWidth: 1))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .id(entry.id)
                        }
                    }
                    .stockedScrollTargetLayout()
                    .padding(.vertical, 2)
                }
                .stockedHorizontalSnap()
                .scrollPosition(id: $ingredientSuggestionPosition, anchor: .center)
                .contentMargins(.horizontal, 2, for: .scrollContent)
                .onChange(of: ingredientSuggestions.map(\.id)) { _, ids in
                    if let current = ingredientSuggestionPosition, !ids.contains(current) {
                        ingredientSuggestionPosition = ids.first
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .stockedAnimation(.selection, intent: .spatial, value: recipeSuggestions.map(\.id))
        .stockedAnimation(.selection, intent: .spatial, value: ingredientSuggestions.map(\.id))
    }

    // MARK: - Private helpers
    private func updateRecipeSuggestions(for query: String) {
        guard showRecipes else { recipeSuggestions = []; return }
        let mgr = RecipeDatabaseManager.shared
        let results = mgr.suggestions(for: query, in: snapshot, limit: 12)
        // #17: collapse near-duplicate titles so suggestions are clean, then cap at 6.
        let deduped = RecipeDedup.dedupe(results,
                                         title: { $0.title },
                                         ingredients: { $0.ingredients })
        recipeSuggestions = Array(deduped.prefix(6))
    }

    private func selectRecipe(_ entry: RecipeDatabaseEntry) {
        text = entry.title
        isFocused = false
        if let formBinding = form {
            RecipeDatabaseManager.shared.autofill(from: entry, into: &formBinding.wrappedValue)
        }
        onSelect(entry.title)
        onRecipeFill(entry)
        recipeSuggestions = []
    }
}

// MARK: - Convenience inits
extension RecipePredictiveTextField {
    /// Ingredient-only mode (no recipe chips) — backwards-compatible default
    init(
        placeholder: String,
        text: Binding<String>,
        onCommit: @escaping () -> Void = {},
        onSelect: @escaping (String) -> Void = { _ in }
    ) {
        self.placeholder  = placeholder
        self._text        = text
        self.recipesOnly  = false
        self.form         = nil
        self.onCommit     = onCommit
        self.onSelect     = onSelect
    }

    /// Recipe-only mode — shows recipe chips, no ingredient chips. No form autofill.
    init(
        placeholder: String,
        text: Binding<String>,
        recipesOnly: Bool,
        onSelect: @escaping (String) -> Void = { _ in }
    ) {
        self.placeholder  = placeholder
        self._text        = text
        self.recipesOnly  = recipesOnly
        self.form         = nil
        self.onSelect     = onSelect
    }
}

// MARK: - RecipeFormAutofillBanner
struct RecipeFormAutofillBanner: View {
    @Environment(AppSession.self) var session
    let sourceName: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.stockedGold)
                .scaledFont(13)
            Text("Autofilled from \(sourceName.isEmpty ? "recipe database" : sourceName)")
                .scaledFont(12, weight: .medium, design: .serif)
                .foregroundStyle(session.themeTextColor)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.stockedGold.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                .stroke(Color.stockedGold.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
