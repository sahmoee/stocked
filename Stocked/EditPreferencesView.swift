// EditPreferencesView.swift — Edit individual personality quiz preferences
// without retaking the whole quiz (Ticket 20)
import SwiftUI

struct EditPreferencesView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    @State private var showKitchenGoals = false   // #16 Kitchen Goals sheet
    @State private var dietaryStyle  = ""
    @State private var allergens:    [String] = []
    @State private var cuisinePrefs: [String] = []
    @State private var skillLevel    = ""
    @State private var budgetLevel   = ""
    @State private var weeklyMeals   = 5

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            List {
                Section {
                    Picker("Dietary Style", selection: $dietaryStyle) {
                        ForEach(["Omnivore","Vegetarian","Vegan","Keto","Paleo","Gluten-Free","No Preference"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .listRowBackground(Color.clear)

                    Picker("Skill Level", selection: $skillLevel) {
                        ForEach(["Beginner","Home Cook","Experienced","Enthusiast"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .listRowBackground(Color.clear)

                    Picker("Budget", selection: $budgetLevel) {
                        ForEach(["Budget-Friendly","Moderate","Premium"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .listRowBackground(Color.clear)

                    Stepper("Meals/week: \(weeklyMeals)", value: $weeklyMeals, in: 1...21)
                        .scaledFont(14, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                        .listRowBackground(Color.clear)

                } header: {
                    Text("COOKING PROFILE").scaledFont(10, weight: .bold).tracking(1)
                }

                // #16 — Kitchen Goals editable here too, not only via the Kitchen Health ring.
                Section {
                    Button { showKitchenGoals = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "checklist").scaledFont(14).foregroundStyle(Color.stockedGreen)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Kitchen Goals")
                                    .scaledFont(14, design: .serif).foregroundStyle(session.themeTextColor)
                                Text(session.guestStore.stockGoalsConfigured
                                     ? "\(session.guestStore.stockStaples.count) staples anchor your Kitchen Health score"
                                     : "Define what stocked means to you")
                                    .scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.45))
                            }
                            Spacer()
                            Image(systemName: "chevron.right").scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.3))
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .sheet(isPresented: $showKitchenGoals) {
                        StockGoalsSetupView(existing: session.guestStore.stockStaples,
                                            configured: session.guestStore.stockGoalsConfigured)
                            .environment(session)
                    }
                } header: {
                    Text("KITCHEN GOALS").scaledFont(10, weight: .bold).tracking(1)
                }

                Section {
                    let cuisines = RecipeTaxonomy.cuisines
                    ForEach(cuisines, id: \.self) { cuisine in
                        HStack {
                            Text(cuisine).scaledFont(14, design: .serif).foregroundStyle(session.themeTextColor)
                            Spacer()
                            if cuisinePrefs.contains(cuisine) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.stockedGold)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if cuisinePrefs.contains(cuisine) { cuisinePrefs.removeAll { $0 == cuisine } }
                            else { cuisinePrefs.append(cuisine) }
                        }
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("FAVOURITE CUISINES").scaledFont(10, weight: .bold).tracking(1)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Edit Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") {
                    var p = session.guestStore.cookingProfile
                    p.dietaryStyle  = dietaryStyle
                    p.skillLevel    = skillLevel
                    p.budgetLevel   = budgetLevel
                    p.weeklyMealCount = weeklyMeals
                    p.cuisinePrefs  = cuisinePrefs
                    session.guestStore.cookingProfile = p
                    dismiss()
                }
                .foregroundStyle(Color.stockedGold).fontWeight(.bold)
            }
        }
        .onAppear {
            let p = session.guestStore.cookingProfile
            dietaryStyle  = p.dietaryStyle
            skillLevel    = p.skillLevel
            budgetLevel   = p.budgetLevel
            weeklyMeals   = p.weeklyMealCount
            cuisinePrefs  = p.cuisinePrefs
        }
    }
}

#Preview { EditPreferencesView().environment(AppSession()) }
