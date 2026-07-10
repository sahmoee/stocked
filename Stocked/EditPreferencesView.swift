// EditPreferencesView.swift — Edit individual personality quiz preferences
// without retaking the whole quiz (Ticket 20)
import SwiftUI

struct EditPreferencesView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    @State private var dietaryStyle  = ""
    @State private var allergens:    [String] = []
    @State private var cuisinePrefs: [String] = []
    @State private var skillLevel    = ""
    @State private var budgetLevel   = ""
    @State private var weeklyMeals   = 5
    @AppStorage(CookHubStyle.storageKey) private var cookHubStyleRaw = CookHubStyle.circles.rawValue

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
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                        .listRowBackground(Color.clear)

                } header: {
                    Text("COOKING PROFILE").font(.system(size: 10, weight: .bold)).tracking(1)
                }

                Section {
                    let cuisines = ["Italian","Mexican","Japanese","Chinese","Indian",
                                    "Mediterranean","American","French","Thai","Korean"]
                    ForEach(cuisines, id: \.self) { cuisine in
                        HStack {
                            Text(cuisine).font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
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
                    Text("FAVOURITE CUISINES").font(.system(size: 10, weight: .bold)).tracking(1)
                }

                // #FB2 — Cook hub layout preference: Circles (default), Photo Cards,
                // or Compact Rows. Applies immediately; no save needed.
                Section {
                    Picker("Cook Hub Style", selection: $cookHubStyleRaw) {
                        ForEach(CookHubStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    }
                    .listRowBackground(Color.clear)
                } header: {
                    Text("APPEARANCE").font(.system(size: 10, weight: .bold)).tracking(1)
                } footer: {
                    Text("Choose how the Cook tab shows its two options.")
                        .font(.system(size: 11))
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
