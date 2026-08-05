// AIRecipeGeneratorView.swift
//
// The "describe a recipe" screen. The user types what they want, optionally lists ingredients
// they have and picks a dietary preference and a rough time limit, then taps Generate. On success
// the generated recipe is shown for review and can be saved to the recipe vault.
//
// Matches the app's editorial style: serif headers, gold accents, dark-aware fields. Calls
// RecipeGeneratorAI, which talks to the Worker's recipeIdea endpoint.

import SwiftUI

struct AIRecipeGeneratorView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @Environment(\.stockedDismiss) var stockedDismiss
    private func close() { if let stockedDismiss { stockedDismiss() } else { dismiss() } }

    // Input
    @State private var idea: String = ""
    @State private var haveText: String = ""        // comma-separated on-hand ingredients
    @State private var dietary: String = "Any"
    @State private var maxTime: String = "Any"

    // Flow
    @State private var isGenerating = false
    @State private var result: GeneratedRecipe? = nil
    @State private var errorText: String? = nil
    @State private var didSave = false

    @FocusState private var ideaFocused: Bool

    private let dietaryOptions = ["Any", "Vegetarian", "Vegan", "Gluten-free", "High-protein"]
    private let timeOptions    = ["Any", "15 min", "30 min", "1 hour"]

    private var ink: Color { session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal }
    private var fieldBg: Color { session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.45) }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let result {
                            resultCard(result)
                        } else {
                            inputForm
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
        }
        .onAppear {
            ideaFocused = true
            // #C1 — default the dietary choice from the saved profile (still changeable).
            if dietary == "Any" {
                let style = session.guestStore.cookingProfile.dietaryStyle
                if dietaryOptions.contains(where: { $0.caseInsensitiveCompare(style) == .orderedSame }) {
                    dietary = dietaryOptions.first { $0.caseInsensitiveCompare(style) == .orderedSame } ?? "Any"
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result == nil ? "Create with AI" : "Your Recipe")
                    .font(.stockedSerif(24, weight: .bold))
                    .foregroundStyle(session.themeTextColor)
                Text(result == nil ? "Describe it and we'll build the recipe." : "Review, then save it to your vault.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
            }
            Spacer()
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                    .frame(width: 30, height: 30)
                    .background((session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal).opacity(0.08))
                    .clipShape(Circle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, StockedScreen.safeTopInset + 6)
        .padding(.bottom, 12)
    }

    // MARK: - Input form

    private var inputForm: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Description
            field(label: "What do you want to make?") {
                TextField("e.g. peanut butter cookies, a cozy soup for a rainy day…",
                          text: $idea, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.system(size: 15))
                    .foregroundStyle(ink)
                    .focused($ideaFocused)
            }

            // On-hand ingredients
            field(label: "Ingredients you have (optional)") {
                TextField("comma separated — chicken, rice, garlic…", text: $haveText)
                    .font(.system(size: 15))
                    .foregroundStyle(ink)
            }

            // Dietary chips
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Dietary")
                chipRow(dietaryOptions, selection: $dietary)
            }

            // Time chips
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Time")
                chipRow(timeOptions, selection: $maxTime)
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }

            // Generate
            Button {
                Task { await generate() }
            } label: {
                HStack(spacing: 8) {
                    if isGenerating {
                        ProgressView().tint(Color.stockedWhite)
                        Text("Generating…")
                    } else {
                        Image(systemName: "sparkles")
                        Text("Generate Recipe")
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.stockedWhite)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.stockedGold.opacity(canGenerate ? 1 : 0.4))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(!canGenerate || isGenerating)
            .padding(.top, 4)

            if !RecipeGeneratorAI.isAvailable {
                Text("AI recipes need an internet connection and the recipe service set up.")
                    .font(.system(size: 12))
                    .foregroundStyle(session.themeTextColor.opacity(0.45))
            }
        }
    }

    private var canGenerate: Bool {
        idea.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && RecipeGeneratorAI.isAvailable
    }

    // MARK: - Result

    private func resultCard(_ r: GeneratedRecipe) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(r.title)
                .font(.stockedSerif(22, weight: .bold))
                .foregroundStyle(session.themeTextColor)

            HStack(spacing: 14) {
                if !r.cookTime.isEmpty { metaPill(icon: "clock", text: r.cookTime) }
                metaPill(icon: "person.2", text: "\(r.servings) servings")
                metaPill(icon: "chart.bar", text: r.difficulty)
            }

            if !r.ingredients.isEmpty {
                sectionTitle("Ingredients")
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(r.ingredients) { ing in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•").foregroundStyle(Color.stockedGold)
                            Text(ing.amount.isEmpty ? ing.name : "\(ing.amount) \(ing.name)")
                                .font(.system(size: 14))
                                .foregroundStyle(session.themeTextColor.opacity(0.85))
                        }
                    }
                }
            }

            if !r.steps.isEmpty {
                sectionTitle("Steps")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(r.steps.enumerated()), id: \.offset) { idx, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(idx + 1)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.stockedWhite)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.stockedGold))
                            Text(step)
                                .font(.system(size: 14))
                                .foregroundStyle(session.themeTextColor.opacity(0.85))
                        }
                    }
                }
            }

            if !r.tips.isEmpty {
                sectionTitle("Notes")
                Text(r.tips)
                    .font(.system(size: 13.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.7))
            }

            // Actions
            HStack(spacing: 12) {
                Button {
                    result = nil
                    didSave = false
                } label: {
                    Text("Start Over")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 14).fill(fieldBg))
                }.buttonStyle(.plain)

                Button {
                    session.guestStore.saveGeneratedRecipe(r)
                    didSave = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: didSave ? "checkmark" : "tray.and.arrow.down")
                        Text(didSave ? "Saved" : "Save Recipe")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.stockedGold))
                }
                .buttonStyle(.plain)
                .disabled(didSave)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Generate action

    private func generate() async {
        errorText = nil
        ideaFocused = false
        isGenerating = true
        defer { isGenerating = false }

        let have = haveText.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        // Pass the saved allergen profile through — the generator previously only
        // saw the free-text dietary chip, so an allergen was invisible to it.
        let mustUse = session.guestStore.inventoryItems
            .filter { $0.effectiveLevel > 0 }
            .sorted { ($0.daysUntilExpiry ?? Int.max) < ($1.daysUntilExpiry ?? Int.max) }
            .prefix(5)
            .map(\.name)
        let opts = RecipeGeneratorAI.Options(
            haveItems: have,
            dietary: dietary == "Any" ? nil : dietary,
            maxTime: maxTime == "Any" ? nil : maxTime,
            cuisinePreference: session.guestStore.cookingProfile.cuisinePrefs,
            mustUse: Array(mustUse),
            dietaryRules: DietaryGuard.Rules(allergens: session.guestStore.cookingProfile.allergens)
        )
        if let recipe = await RecipeGeneratorAI.generate(idea: idea, options: opts) {
            withAnimation(.easeOut(duration: 0.2)) { result = recipe }
            AppAnalytics.shared.log(.recipeImported)
        } else {
            errorText = "Couldn't generate a recipe just now. Check your connection and try again."
        }
    }

    // MARK: - Small building blocks

    @ViewBuilder private func field(label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(label)
            content()
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(fieldBg))
        }
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(session.themeTextColor.opacity(0.5))
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.stockedGold)
            .padding(.top, 4)
    }

    private func chipRow(_ options: [String], selection: Binding<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { opt in
                    let isOn = selection.wrappedValue == opt
                    Button { selection.wrappedValue = opt } label: {
                        Text(opt)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isOn ? Color.stockedWhite : session.themeTextColor.opacity(0.6))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(isOn ? Color.stockedGold : fieldBg))
                    }.buttonStyle(.plain)
                }
            }
            .stockedScrollTargetLayout()
        }
        .stockedHorizontalSnap()
    }

    private func metaPill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(session.themeTextColor.opacity(0.6))
    }
}
