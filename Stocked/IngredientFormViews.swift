// IngredientFormViews.swift — IngredientFormRow, IngredientPickerSheet, IngredientDetailForm.
// Split out of ReadyToCookView.swift (Build 189, code-health refactor #1). No logic changes.
import SwiftUI
import PhotosUI


// ─────────────────────────────────────────────────────────────────────────────
// OPTIONAL: AppSession.swift — one-line addition to addUserRecipe()
// ─────────────────────────────────────────────────────────────────────────────

struct IngredientFormRow: View {
    @Environment(AppSession.self) var session
    @Binding var ingredient: RecipeIngredient
    let onDelete: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TappableEditText(text: $ingredient.name, mode: .food, font: .system(size: 14, weight: .semibold))
                        if !ingredient.amount.isEmpty {
                            Text(ingredient.amount).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                        }
                    }
                    if let brand = ingredient.brand {
                        Text(brand).font(.system(size: 11)).foregroundStyle(Color.stockedGold)
                    }
                }
                Spacer()
                Button { withAnimation { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.4))
                }.buttonStyle(.plain)
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.5))
                }.buttonStyle(.plain)
            }.padding(14).contentShape(Rectangle())

            if expanded {
                VStack(spacing: 8) {
                    let brands = BrandDatabase.allBrandNames(for: ingredient.name)
                    if !brands.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Brand").font(.system(size: 11, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.4))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    Button { ingredient.brand = nil } label: {
                                        Text("None").font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(session.themeTextColor)
                                            .padding(.horizontal, 12).padding(.vertical, 10)
                                            .background(ingredient.brand == nil ? Color.stockedGold : Color.stockedWhite.opacity(0.4))
                                            .clipShape(Capsule())
                                    }.buttonStyle(.plain)
                                    ForEach(brands, id: \.self) { b in
                                        Button {
                                            ingredient.brand = b
                                            ingredient.nutrition = BrandDatabase.brands(for: ingredient.name).first { $0.brand == b }?.nutrition.toFacts()
                                        } label: {
                                            Text(b).font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(session.themeTextColor)
                                                .padding(.horizontal, 12).padding(.vertical, 10)
                                                .background(ingredient.brand == b ? Color.stockedGold : Color.stockedWhite.opacity(0.4))
                                                .clipShape(Capsule())
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    if let n = ingredient.nutrition {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Nutrition (\(n.servingSize))").font(.system(size: 11, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.4))
                            HStack(spacing: 16) {
                                nutriLabel("Cal", "\(n.calories)")
                                nutriLabel("Fat", "\(n.totalFat)g")
                                nutriLabel("Carbs", "\(n.totalCarbs)g")
                                nutriLabel("Protein", "\(n.protein)g")
                                nutriLabel("Sodium", "\(Int(n.sodium))mg")
                            }
                        }
                    }
                    Toggle("Optional ingredient", isOn: $ingredient.isOptional)
                        .font(.system(size: 13)).foregroundStyle(session.themeTextColor).tint(Color.stockedGold)
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
    }

    private func nutriLabel(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 12, weight: .bold)).foregroundStyle(session.themeTextColor)
            Text(label).font(.system(size: 9)).foregroundStyle(session.themeTextColor.opacity(0.45))
        }
    }
}

// MARK: - Ingredient Picker Sheet (from database, brand-aware)
struct IngredientPickerSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    let onAdd: (RecipeIngredient) -> Void

    @State private var searchText  = ""
    @State private var selectedCat: String? = nil
    @State private var name        = ""
    @State private var amount      = ""
    @State private var brand:      String? = nil
    @State private var notes       = ""
    @State private var isOptional  = false
    @State private var showForm    = false

    private let kb = StockedKnowledgeBase.shared

    private var entries: [KnowledgeIngredient] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty { return kb.ingredients.filter { $0.name.lowercased().contains(q) } }
        if let cat = selectedCat { return kb.ingredients.filter { $0.category == cat }.sorted { $0.name < $1.name } }
        return []
    }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(spacing: 0) {
                    // Search
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(session.themeTextColor.opacity(0.4))
                        TextField("Search ingredients…", text: $searchText)
                        .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                            .font(.system(size: 15)).dynamicTypeSize(.xSmall ... .xxxLarge).foregroundStyle(session.themeTextColor)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(session.themeTextColor.opacity(0.3))
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(11).background(Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    .padding(.horizontal, 20).padding(.vertical, 12)

                    if searchText.isEmpty && selectedCat == nil {
                        // Category grid
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                ForEach(Array(Set(kb.ingredients.map(\.category))).sorted(), id: \.self) { cat in
                                    Button { selectedCat = cat } label: {
                                        VStack(spacing: 5) {
                                            Text(catEmoji(cat)).font(.system(size: 26))
                                            Text(cat).font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(session.themeTextColor).multilineTextAlignment(.center)
                                        }
                                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                    }.buttonStyle(.plain)
                                }
                                // Custom
                                Button { showForm = true } label: {
                                    VStack(spacing: 5) {
                                        Text("✏️").font(.system(size: 26))
                                        Text("Custom").font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(session.themeTextColor)
                                    }
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                }.buttonStyle(.plain)
                            }.padding(.horizontal, 20).padding(.bottom, 20)
                        }
                    } else {
                        if selectedCat != nil && searchText.isEmpty {
                            HStack {
                                Button { selectedCat = nil } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "chevron.left").font(.system(size: 13))
                                        Text(selectedCat ?? "").font(.system(size: 14, weight: .semibold))
                                    }.foregroundStyle(Color.stockedGold)
                                }.buttonStyle(.plain)
                                Spacer()
                            }.padding(.horizontal, 20).padding(.bottom, 8)
                        }
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(entries) { entry in
                                    Button {
                                        let brandNames = BrandDatabase.allBrandNames(for: entry.name)
                                        name = entry.name
                                        brand = brandNames.first
                                        showForm = true
                                    } label: {
                                        HStack(spacing: 14) {
                                            Text(entry.emoji).font(.system(size: 22))
                                            VStack(alignment: .leading, spacing: 10) {
                                                Text(entry.name).font(.system(size: 15, weight: .semibold)).dynamicTypeSize(.xSmall ... .xxxLarge).foregroundStyle(session.themeTextColor)
                                                let brands = BrandDatabase.allBrandNames(for: entry.name)
                                                if !brands.isEmpty {
                                                    Text(brands.prefix(3).joined(separator: ", "))
                                                        .font(.system(size: 10)).foregroundStyle(Color.stockedGold)
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "plus.circle.fill").font(.system(size: 20)).foregroundStyle(Color.stockedGold)
                                        }
                                        .padding(.horizontal, 20).padding(.vertical, 12)
                                        .background(Color.clear).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Divider().padding(.leading, 68).padding(.horizontal, 20)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.stockedGold)
                }
            }
        }
        .sheet(isPresented: $showForm) {
            IngredientDetailForm(name: $name, amount: $amount, brand: $brand, notes: $notes, isOptional: $isOptional) {
                let nutrition = brand.flatMap { b in BrandDatabase.brands(for: name).first { $0.brand == b }?.nutrition.toFacts() }
                onAdd(RecipeIngredient(name: name, amount: amount, brand: brand, nutrition: nutrition, isOptional: isOptional, notes: notes.isEmpty ? nil : notes))
                name = ""; amount = ""; brand = nil; notes = ""; isOptional = false
                dismiss()
            }
        }
    }

    private func catEmoji(_ cat: String) -> String {
        switch cat {
        case "Meats":   return "🥩"; case "Poultry": return "🍗"; case "Seafood": return "🐟"
        case "Dairy":   return "🧀"; case "Produce": return "🥦"; case "Pantry":  return "🥫"
        case "Staples":  return "🧂"; case "Freezer": return "🧊"; case "Fridge":  return "🥛"
        default: return "🍽️"
        }
    }
}

// MARK: - Ingredient detail entry form (amount, brand, notes)
struct IngredientDetailForm: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @Binding var name:       String
    @Binding var amount:     String
    @Binding var brand:      String?
    @Binding var notes:      String
    @Binding var isOptional: Bool
    let onSave: () -> Void

    @State private var brandText = ""
    private var availableBrands: [String] { BrandDatabase.allBrandNames(for: name) }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.2)).frame(width: 40, height: 4).padding(.top, 12).padding(.bottom, 20)
                Text(name.isEmpty ? "Custom Ingredient" : name)
                    .font(.system(size: 20, weight: .bold, design: .serif)).foregroundStyle(session.themeTextColor).padding(.bottom, 20)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        if name.isEmpty {
                            formInput("Ingredient Name *", text: $name)
                        }
                        formInput("Amount (e.g. 2 cups, 1 lb)", text: $amount)

                        if !availableBrands.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Brand").font(.system(size: 12, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.5))
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        Button { brand = nil } label: {
                                            Text("Any").font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(session.themeTextColor)
                                                .padding(.horizontal, 14).padding(.vertical, 11)
                                                .background(brand == nil ? Color.stockedGold : Color.stockedWhite.opacity(0.4)).clipShape(Capsule())
                                        }.buttonStyle(.plain)
                                        ForEach(availableBrands, id: \.self) { b in
                                            Button { brand = b } label: {
                                                Text(b).font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(session.themeTextColor)
                                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                                    .background(brand == b ? Color.stockedGold : Color.stockedWhite.opacity(0.4)).clipShape(Capsule())
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                }
                                if let b = brand, let entry = BrandDatabase.brands(for: name).first(where: { $0.brand == b }) {
                                    HStack(spacing: 12) {
                                        nutriPill("Cal","\(entry.nutrition.calories)")
                                        nutriPill("Fat","\(entry.nutrition.totalFat)g")
                                        nutriPill("Carbs","\(entry.nutrition.totalCarbs)g")
                                        nutriPill("Protein","\(entry.nutrition.protein)g")
                                    }
                                }
                            }.padding(.horizontal, 28)
                        }

                        formInput("Notes (optional, e.g. finely chopped)", text: $notes)
                        Toggle("Optional ingredient", isOn: $isOptional)
                            .font(.system(size: 14)).foregroundStyle(session.themeTextColor)
                            .tint(Color.stockedGold).padding(.horizontal, 28)

                        Button {
                            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            onSave()
                        } label: {
                            Text("Add Ingredient")
                                .font(.system(size: 16, weight: .semibold, design: .serif)).foregroundStyle(Color.stockedWhite)
                                .frame(maxWidth: .infinity).padding(.vertical, 15)
                                .background(name.isEmpty ? Color.stockedCharcoal.opacity(0.4) : Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                        }.disabled(name.isEmpty).buttonStyle(.plain).padding(.horizontal, 28)
                    }.padding(.bottom, 40)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear { brandText = brand ?? "" }
    }

    private func formInput(_ ph: String, text: Binding<String>) -> some View {
        FoodPredictiveTextField(placeholder: ph, text: text)
            .font(.system(size: 14)).foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
            .padding(14).background(Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)).padding(.horizontal, 28)
    }
    private func nutriPill(_ label: String, _ val: String) -> some View {
        VStack(spacing: 1) {
            Text(val).font(.system(size: 12, weight: .bold)).foregroundStyle(session.themeTextColor)
            Text(label).font(.system(size: 9)).foregroundStyle(session.themeTextColor.opacity(0.45))
        }
    }
}

#Preview { RecipeVaultView().environment(AppSession()) }
