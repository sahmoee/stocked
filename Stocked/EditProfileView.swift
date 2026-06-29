// EditProfileView.swift — Edit Profile screen (Build 296).
//
// Opened from the drawer chef row. Shows the editable chef avatar centered at the top
// (tap to change skin tone or add a photo) and all nine onboarding answers inline, so the
// user can recalibrate the app without re-running the full quiz. Every control writes straight
// to session.guestStore.cookingProfile, which the recommendation engines read live, so changes
// take effect immediately.

import SwiftUI

struct EditProfileView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var nameInput = ""
    @State private var editingName = false

    // Option lists mirror the onboarding quiz exactly.
    private let goals = ["Eat Healthier","Cook Faster","Explore Cuisines","Reduce Waste","Stress Less","Decision Fatigue"]
    private let diets = ["Omnivore","Vegetarian","Vegan","Pescatarian","Keto","Paleo","Gluten-Free"]
    private let allergenOptions = ["Peanuts","Tree Nuts","Dairy","Eggs","Fish","Shellfish","Gluten","Soy","Corn"]
    private let cuisineOptions = ["Italian","Mexican","Asian","Mediterranean","American","Indian","Caribbean","Middle Eastern","French"]
    private let skills = ["Beginner","Home Cook","Experienced","Enthusiast"]
    private let prepDays = ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"]
    private let equipmentOptions = ["Stovetop","Oven","Microwave","Air Fryer","Slow Cooker","Instant Pot","Grill / BBQ","Blender","Food Processor","Toaster Oven"]

    // Binding into the persisted profile.
    private var profile: Binding<UserCookingProfile> {
        Binding(get: { session.guestStore.cookingProfile },
                set: { session.guestStore.cookingProfile = $0 })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Centered editable avatar.
                    EditableProfileAvatar(size: 96)
                        .padding(.top, 12)

                    // Name (inline editor).
                    nameField

                    Divider().padding(.horizontal, 24)

                    // The nine inline quiz fields.
                    stepperField(title: "Household Size", systemImage: "person.3.fill",
                                 value: profile.householdSize, range: 1...12)

                    singleSelectField(title: "Cooking Goal", systemImage: "target",
                                      options: goals, selection: profile.cookingGoal)

                    singleSelectField(title: "Dietary Style", systemImage: "leaf.fill",
                                      options: diets, selection: profile.dietaryStyle)

                    multiSelectField(title: "Allergies & Avoidances", systemImage: "exclamationmark.triangle.fill",
                                     options: allergenOptions, selection: profile.allergens, allowNone: true)

                    multiSelectField(title: "Favorite Cuisines", systemImage: "globe",
                                     options: cuisineOptions, selection: profile.cuisinePrefs)

                    singleSelectField(title: "Skill Level", systemImage: "star.fill",
                                      options: skills, selection: profile.skillLevel)

                    stepperField(title: "Meals per Week", systemImage: "calendar",
                                 value: profile.weeklyMealCount, range: 1...21)

                    singleSelectField(title: "Meal Prep Day", systemImage: "calendar.badge.clock",
                                      options: prepDays, selection: profile.mealPrepDay)

                    multiSelectField(title: "Cooking Equipment", systemImage: "frying.pan.fill",
                                     options: equipmentOptions, selection: profile.cookingEquipment)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 60)
            }
            .scrollContentBackground(.hidden)
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.stockedGold)
                }
            }
        }
        .environment(session)
    }

    // MARK: - Name

    private var nameField: some View {
        VStack(spacing: 8) {
            if editingName {
                HStack {
                    TextField("Your name", text: $nameInput)
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                        .multilineTextAlignment(.center)
                    Button("Save") {
                        session.displayName = nameInput.trimmingCharacters(in: .whitespaces)
                        editingName = false
                    }.foregroundStyle(Color.stockedGold).font(.system(size: 14, weight: .bold))
                }
                .padding(.horizontal, 24)
            } else {
                Button {
                    nameInput = session.displayName; editingName = true
                } label: {
                    HStack(spacing: 6) {
                        Text(session.userName)
                            .font(.system(size: 20, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Image(systemName: "pencil")
                            .font(.system(size: 13))
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                    }
                }.buttonStyle(.plain)
            }
        }
    }

    // MARK: - Field builders

    private func fieldHeader(_ title: String, _ systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(session.themeTextColor.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepperField(title: String, systemImage: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldHeader(title, systemImage)
            HStack {
                Text("\(value.wrappedValue)")
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                Stepper("", value: value, in: range).labelsHidden().tint(Color.stockedGold)
            }
        }
    }

    private func singleSelectField(title: String, systemImage: String, options: [String], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldHeader(title, systemImage)
            FlowChips(options: options,
                      isSelected: { $0 == selection.wrappedValue },
                      onTap: { selection.wrappedValue = $0 })
        }
    }

    private func multiSelectField(title: String, systemImage: String, options: [String], selection: Binding<[String]>, allowNone: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldHeader(title, systemImage)
            FlowChips(options: allowNone ? options + ["None"] : options,
                      isSelected: { opt in
                          opt == "None" ? selection.wrappedValue.isEmpty : selection.wrappedValue.contains(opt)
                      },
                      onTap: { opt in
                          if opt == "None" {
                              selection.wrappedValue = []
                          } else if let idx = selection.wrappedValue.firstIndex(of: opt) {
                              selection.wrappedValue.remove(at: idx)
                          } else {
                              selection.wrappedValue.append(opt)
                          }
                      })
        }
    }
}

// MARK: - Wrapping chip row

private struct FlowChips: View {
    let options: [String]
    let isSelected: (String) -> Bool
    let onTap: (String) -> Void
    @Environment(AppSession.self) private var session

    var body: some View {
        FlexibleWrap(options) { opt in
            Button { onTap(opt) } label: {
                Text(opt)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected(opt) ? Color.stockedCharcoal : session.themeTextColor.opacity(0.7))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(isSelected(opt) ? Color.stockedGold : (session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5)))
                    .clipShape(Capsule())
            }.buttonStyle(.plain)
        }
    }
}

// MARK: - Simple wrapping layout (no external dependency)

private struct FlexibleWrap<Item: Hashable>: View {
    let items: [Item]
    let content: (Item) -> AnyView

    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> some View) {
        self.items = items
        self.content = { AnyView(content($0)) }
    }

    var body: some View {
        Wrap(items: items, content: content)
    }
}

private struct Wrap<Item: Hashable>: View {
    let items: [Item]
    let content: (Item) -> AnyView
    @State private var totalHeight: CGFloat = .zero

    var body: some View {
        GeometryReader { geo in
            self.generate(in: geo)
        }
        .frame(height: totalHeight)
    }

    private func generate(in g: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero
        return ZStack(alignment: .topLeading) {
            ForEach(items, id: \.self) { item in
                content(item)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .alignmentGuide(.leading) { d in
                        if abs(width - d.width) > g.size.width {
                            width = 0
                            height -= d.height
                        }
                        let result = width
                        if item == items.last { width = 0 } else { width -= d.width }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        if item == items.last { height = 0 }
                        return result
                    }
            }
        }
        .background(heightReader)
    }

    private var heightReader: some View {
        GeometryReader { geo -> Color in
            DispatchQueue.main.async { self.totalHeight = geo.size.height }
            return Color.clear
        }
    }
}
