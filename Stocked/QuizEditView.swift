// QuizEditView.swift — Edit personality quiz answers without retaking the whole quiz
import SwiftUI

struct QuizEditView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @Environment(\.stockedMotion) private var motion

    // Local copies of all profile fields
    @State private var householdSize:    Int      = 2
    @State private var cookingGoal:      String   = ""
    @State private var dietaryStyle:     String   = ""
    @State private var allergens:        [String] = []
    @State private var cuisinePrefs:     [String] = []
    @State private var skillLevel:       String   = ""
    @State private var weeklyMeals:      Int      = 5
    @State private var mealPrepDay:      String   = ""
    @State private var cookingEquipment: [String] = []

    // Which section is expanded
    @State private var expanded: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        editRow(icon: "🏠", title: "Household", value: householdSize == 1 ? "Just me" : "\(householdSize) people", section: "household") {
                            householdGrid
                        }
                        editRow(icon: "🎯", title: "Cooking Goal", value: cookingGoal.isEmpty ? "Not set" : cookingGoal, section: "goal") {
                            goalGrid
                        }
                        editRow(icon: "🍽️", title: "Diet Style", value: dietaryStyle.isEmpty ? "Not set" : dietaryStyle, section: "diet") {
                            dietGrid
                        }
                        editRow(icon: "⚠️", title: "Allergens", value: allergens.isEmpty ? "None" : allergens.joined(separator: ", "), section: "allergens") {
                            allergenGrid
                        }
                        editRow(icon: "🌍", title: "Cuisines", value: cuisinePrefs.isEmpty ? "Not set" : cuisinePrefs.joined(separator: ", "), section: "cuisines") {
                            cuisineGrid
                        }
                        editRow(icon: "📚", title: "Skill Level", value: skillLevel.isEmpty ? "Not set" : skillLevel, section: "skill") {
                            skillList
                        }
                        editRow(icon: "📅", title: "Schedule", value: "\(weeklyMeals) meals · \(mealPrepDay.isEmpty ? "Any day" : mealPrepDay)", section: "schedule") {
                            scheduleControls
                        }
                        editRow(icon: "🍳", title: "Equipment", value: cookingEquipment.isEmpty ? "Not set" : "\(cookingEquipment.count) items", section: "equipment") {
                            equipmentGrid
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.stockedGold)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveAndDismiss() }
                        .scaledFont(15, weight: .bold)
                        .foregroundStyle(Color.stockedGold)
                }
            }
        }
        .onAppear { loadProfile() }
    }

    // MARK: - Row builder
    private func editRow<Content: View>(icon: String, title: String, value: String, section: String, @ViewBuilder content: () -> Content) -> some View {
        let isOpen = expanded == section
        return VStack(spacing: 0) {
            Button {
                motion.animate(.standard, intent: .spatial) {
                    expanded = isOpen ? nil : section
                }
            } label: {
                HStack(spacing: 12) {
                    Text(icon).scaledFont(20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .scaledFont(14, weight: .semibold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        Text(value)
                            .scaledFont(12)
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .scaledFont(12, weight: .semibold)
                        .foregroundStyle(Color.stockedGold)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(spacing: 12) {
                    content()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(session.themeCardColor)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Section content views
    private var householdGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach([1,2,3,4,5,6], id: \.self) { n in
                chip(n == 1 ? "Just me 🙋" : n == 6 ? "6+ 👨‍👩‍👧‍👦" : "\(n) people",
                     selected: householdSize == n) { householdSize = n }
            }
        }
    }

    private var goalGrid: some View {
        let goals = [("🥦","Eat Healthier"),("⏱","Cook Faster"),
                     ("🌍","Explore Cuisines"),("♻️","Reduce Waste"),
                     ("😌","Stress Less"),("🤯","Decision Fatigue")]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(goals, id: \.1) { emoji, label in
                chip("\(emoji)  \(label)", selected: cookingGoal == label) { cookingGoal = label }
            }
        }
    }

    private var dietGrid: some View {
        let styles = [("🍗","Omnivore"),("🐟","Pescatarian"),
                      ("🌱","Vegetarian"),("🌿","Vegan"),
                      ("🫙","Keto / Low-Carb"),("🤷","No Preference")]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(styles, id: \.1) { emoji, label in
                chip("\(emoji)  \(label)", selected: dietaryStyle == label) { dietaryStyle = label }
            }
        }
    }

    private var allergenGrid: some View {
        let all = ["🥜 Peanuts","🌰 Tree Nuts","🥛 Dairy","🥚 Eggs","🐟 Fish",
                   "🦐 Shellfish","🌾 Gluten","🫘 Soy","🌽 Corn","None"]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(all, id: \.self) { item in
                let clean = item.components(separatedBy: " ").dropFirst().joined(separator: " ")
                chip(item, selected: clean == "None" ? allergens.isEmpty : allergens.contains(clean)) {
                    if clean == "None" { allergens = [] }
                    else if allergens.contains(clean) { allergens.removeAll { $0 == clean } }
                    else { allergens.append(clean) }
                }
            }
        }
    }

    private var cuisineGrid: some View {
        let cuisines = RecipeTaxonomy.cuisines.map { (CuisineBrowseView.flag(for: $0), $0) }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(cuisines, id: \.1) { emoji, label in
                chip("\(emoji)\n\(label)", selected: cuisinePrefs.contains(label)) {
                    if cuisinePrefs.contains(label) { cuisinePrefs.removeAll { $0 == label } }
                    else { cuisinePrefs.append(label) }
                }
            }
        }
    }

    private var skillList: some View {
        let levels: [(String,String,String)] = [
            ("🥚","Beginner","I can scramble eggs and boil water"),
            ("🍳","Home Cook","I follow recipes confidently"),
            ("👨‍🍳","Experienced","I improvise and experiment often"),
            ("⭐️","Enthusiast","I study techniques and love to push limits"),
        ]
        return VStack(spacing: 8) {
            ForEach(levels, id: \.1) { emoji, label, desc in
                Button { skillLevel = label } label: {
                    HStack(spacing: 12) {
                        Text(emoji).scaledFont(20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label).scaledFont(13, weight: .semibold, design: .serif)
                                .foregroundStyle(session.themeTextColor)
                            Text(desc).scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.5))
                        }
                        Spacer()
                        if skillLevel == label {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.stockedGold)
                        }
                    }
                    .padding(12)
                    .background(skillLevel == label ? Color.stockedGold.opacity(0.12) : (Color.stockedWhite.opacity(0.4)))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd).stroke(skillLevel == label ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                }.buttonStyle(.plain)
            }
        }
    }

    private var scheduleControls: some View {
        let days = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun","Any"]
        return VStack(spacing: 10) {
            HStack {
                Text("Meals per week").scaledFont(13, weight: .semibold).foregroundStyle(session.themeTextColor)
                Spacer()
                Text("\(weeklyMeals)").scaledFont(14, weight: .bold).foregroundStyle(Color.stockedGold)
            }
            Slider(value: Binding(get: { Double(weeklyMeals) }, set: { weeklyMeals = Int($0) }), in: 1...21, step: 1)
                .tint(Color.stockedGold)
            Text("Grocery day").scaledFont(13, weight: .semibold).foregroundStyle(session.themeTextColor.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                ForEach(days, id: \.self) { day in
                    chip(day == "Any" ? "Any" : day, selected: mealPrepDay == day || (day == "Any" && mealPrepDay == "Any")) {
                        mealPrepDay = day
                    }
                }
            }
        }
    }

    private var equipmentGrid: some View {
        let items = [("🍳","Stovetop"),("🔥","Oven"),("🔌","Microwave"),("💨","Air Fryer"),
                     ("🫕","Slow Cooker"),("🫙","Instant Pot"),("♨️","Grill / BBQ"),
                     ("🥗","Blender"),("🍹","Food Processor"),("🎛️","Toaster Oven")]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(items, id: \.1) { emoji, label in
                chip("\(emoji)  \(label)", selected: cookingEquipment.contains(label)) {
                    if cookingEquipment.contains(label) { cookingEquipment.removeAll { $0 == label } }
                    else { cookingEquipment.append(label) }
                }
            }
        }
    }

    // MARK: - Chip
    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.stockedSystem(size: 12, weight: selected ? .bold : .medium, design: .serif))
                .foregroundStyle(selected ? Color.stockedCharcoal : session.themeTextColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd).fill(selected ? Color.stockedGold : Color.stockedWhite.opacity(0.5)))
        }.buttonStyle(.plain)
    }

    // MARK: - Load / Save
    private func loadProfile() {
        let p = session.guestStore.cookingProfile
        householdSize    = p.householdSize
        cookingGoal      = p.cookingGoal
        dietaryStyle     = p.dietaryStyle
        allergens        = p.allergens
        cuisinePrefs     = p.cuisinePrefs
        skillLevel       = p.skillLevel
        weeklyMeals      = p.weeklyMealCount
        mealPrepDay      = p.mealPrepDay
        cookingEquipment = p.cookingEquipment
    }

    private func saveAndDismiss() {
        var p = session.guestStore.cookingProfile
        p.householdSize    = householdSize
        p.cookingGoal      = cookingGoal
        p.dietaryStyle     = dietaryStyle
        p.allergens        = allergens
        p.cuisinePrefs     = cuisinePrefs
        p.skillLevel       = skillLevel
        p.weeklyMealCount  = weeklyMeals
        p.mealPrepDay      = mealPrepDay
        p.cookingEquipment = cookingEquipment
        session.guestStore.cookingProfile = p
        dismiss()
    }
}
