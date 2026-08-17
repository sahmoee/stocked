// RecipeSubstitutionPickerSheet.swift
// Explicit substitution selection for saved recipes and Cook Now.

import SwiftUI

struct RecipeSubstitutionPickerSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let ingredient: RecipeIngredient
    let allowsCookOnly: Bool
    let onReplaceRecipe: (Substitution) -> Void
    let onUseForCook: (Substitution) -> Void

    @State private var options: [Substitution] = []
    @State private var selectedID: String?
    @State private var showCustom = false
    @State private var customName = ""
    @State private var customNotes = ""

    private var selected: Substitution? {
        options.first { $0.id == selectedID }
    }

    private var availableInventoryNames: Set<String> {
        KitchenAvailability.availableNames(in: session.guestStore.inventoryItems)
    }

    private func isInKitchen(_ substitution: Substitution) -> Bool {
        let candidate = GroceryKnowledgeBase.normalize(substitution.substitute)
        return availableInventoryNames.contains {
            let stocked = GroceryKnowledgeBase.normalize($0)
            return stocked == candidate || stocked.contains(candidate) || candidate.contains(stocked)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Replace (ingredient.name.displayNormalized)")
                                .font(.stockedSerif(22, weight: .bold))
                                .foregroundStyle(session.themeTextColor)
                            Text("Choose the exact substitution Stocked should use. Nothing changes until you confirm.")
                                .font(.system(size: 13))
                                .foregroundStyle(session.themeSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if options.isEmpty {
                            ContentUnavailableView(
                                "No safe substitutions yet",
                                systemImage: "arrow.left.arrow.right",
                                description: Text("Add your own option below and it will be available anywhere this ingredient appears.")
                            )
                            .foregroundStyle(session.themeTextColor)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(options) { option in
                                    Button { selectedID = option.id } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: selectedID == option.id ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 20))
                                                .foregroundStyle(selectedID == option.id ? session.accentColor : session.themeSecondaryText)
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(spacing: 7) {
                                                    Text(option.substitute.displayNormalized)
                                                        .font(.system(size: 15, weight: .semibold))
                                                        .foregroundStyle(session.themeTextColor)
                                                    if isInKitchen(option) {
                                                        Text("In kitchen")
                                                            .font(.system(size: 9.5, weight: .bold))
                                                            .foregroundStyle(Color.stockedGreen)
                                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                                            .background(Color.stockedGreen.opacity(0.13))
                                                            .clipShape(Capsule())
                                                    }
                                                    Spacer(minLength: 0)
                                                }
                                                if !option.detail.isEmpty {
                                                    Text(option.detail)
                                                        .font(.system(size: 11.5))
                                                        .foregroundStyle(session.themeSecondaryText)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }
                                                Text(option.source.label)
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(session.accentColor.opacity(0.8))
                                            }
                                        }
                                        .padding(13)
                                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.48))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                                                .stroke(selectedID == option.id ? session.accentColor : session.themeContrastAccent.opacity(0.22),
                                                        lineWidth: selectedID == option.id ? 2 : 1)
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(option.substitute), \(isInKitchen(option) ? "in kitchen" : "not currently in kitchen")")
                                    .accessibilityAddTraits(selectedID == option.id ? .isSelected : [])
                                }
                            }
                        }

                        DisclosureGroup(isExpanded: $showCustom) {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("Substitution name", text: $customName)
                                    .textInputAutocapitalization(.words)
                                    .padding(12)
                                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.48))
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                                TextField("Ratio or notes (optional)", text: $customNotes, axis: .vertical)
                                    .lineLimit(2...4)
                                    .padding(12)
                                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.48))
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                                Button("Add and Select") { addCustom() }
                                    .buttonStyle(.borderedProminent)
                                    .tint(session.accentColor)
                                    .disabled(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            .padding(.top, 10)
                        } label: {
                            Label("Add a Custom Substitution", systemImage: "plus.circle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(session.themeTextColor)
                        }

                        if let selected {
                            VStack(spacing: 10) {
                                if allowsCookOnly {
                                    Button {
                                        onUseForCook(selected)
                                        dismiss()
                                    } label: {
                                        Label("Use for This Cook", systemImage: "fork.knife")
                                            .font(.system(size: 15, weight: .bold))
                                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(session.accentColor)
                                }

                                Button {
                                    onReplaceRecipe(selected)
                                    dismiss()
                                } label: {
                                    Label("Replace in Recipe", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 15, weight: .bold))
                                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(session.accentColor)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Choose Substitution")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task(id: ingredient.name) { reloadOptions() }
    }

    private func reloadOptions(selecting preferred: String? = nil) {
        let rules = DietaryGuard.Rules(allergens: session.guestStore.cookingProfile.allergens)
        options = SubstitutionEngine
            .local(for: ingredient.name, userEntries: session.guestStore.userSubstitutions)
            .filter {
                DietaryGuard.allergenHits(ingredientLines: [$0.substitute], title: "", rules: rules).isEmpty
            }
        if let preferred,
           let match = options.first(where: { $0.substitute.caseInsensitiveCompare(preferred) == .orderedSame }) {
            selectedID = match.id
        } else if options.count == 1 {
            selectedID = options.first?.id
        } else if !options.contains(where: { $0.id == selectedID }) {
            selectedID = nil
        }
    }

    private func addCustom() {
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let rules = DietaryGuard.Rules(allergens: session.guestStore.cookingProfile.allergens)
        guard DietaryGuard.allergenHits(ingredientLines: [name], title: "", rules: rules).isEmpty else {
            ToastCenter.shared.warning("That substitution conflicts with a saved allergen")
            return
        }
        let notes = customNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicate = session.guestStore.userSubstitutions.contains {
            GroceryKnowledgeBase.normalize($0.ingredient) == GroceryKnowledgeBase.normalize(ingredient.name)
                && GroceryKnowledgeBase.normalize($0.substitute) == GroceryKnowledgeBase.normalize(name)
        }
        if !duplicate {
            session.guestStore.userSubstitutions.append(
                UserSubstitutionEntry(ingredient: ingredient.name, substitute: name, notes: notes)
            )
        }
        reloadOptions(selecting: name)
        customName = ""
        customNotes = ""
        showCustom = false
        HapticManager.success()
    }
}
