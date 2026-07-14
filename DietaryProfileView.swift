// DietaryProfileView.swift — persistent dietary & allergen profile editor (#C1).
//
// The profile itself already lives in UserCookingProfile (dietaryStyle + allergens,
// set once during onboarding); this gives it a permanent home in the Kitchen Toolbox
// so it can be changed any time. The saved profile now also seeds the recipe browser
// filters (allergen hide + diet chip) and the AI recipe generator automatically.
import SwiftUI

struct DietaryProfileView: View {
    @Environment(AppSession.self) private var session

    private var store: GuestDataStore { session.guestStore }

    private let diets = ["Omnivore", "Vegetarian", "Vegan", "Pescatarian", "Gluten-free", "Keto", "Paleo"]
    private let commonAllergens = ["Peanuts", "Tree nuts", "Dairy", "Eggs", "Gluten", "Soy", "Shellfish", "Fish", "Sesame"]

    @State private var customAllergen = ""

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {

                    Text("Your saved diet and allergens filter recipe results automatically and steer AI recipe ideas.")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))

                    // ── Dietary style ─────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Dietary Style")
                            .font(.system(size: 15, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        FlowChips(items: diets, isSelected: { store.cookingProfile.dietaryStyle == $0 }) { diet in
                            var p = store.cookingProfile
                            p.dietaryStyle = (p.dietaryStyle == diet) ? "" : diet
                            store.cookingProfile = p
                        }
                    }

                    // ── Allergens ─────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Allergens to Avoid")
                            .font(.system(size: 15, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        FlowChips(items: commonAllergens,
                                  isSelected: { name in store.cookingProfile.allergens.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) }) { name in
                            var p = store.cookingProfile
                            if let i = p.allergens.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                                p.allergens.remove(at: i)
                            } else {
                                p.allergens.append(name)
                            }
                            store.cookingProfile = p
                        }
                        // Custom entries beyond the common list.
                        let custom = store.cookingProfile.allergens.filter { a in
                            !commonAllergens.contains(where: { $0.caseInsensitiveCompare(a) == .orderedSame })
                        }
                        if !custom.isEmpty {
                            FlowChips(items: custom, isSelected: { _ in true }) { name in
                                var p = store.cookingProfile
                                p.allergens.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
                                store.cookingProfile = p
                            }
                        }
                        HStack(spacing: 8) {
                            TextField("Add another (e.g. cilantro)", text: $customAllergen)
                                .font(.system(size: 14))
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
                                .clipShape(Capsule())
                            Button {
                                let t = customAllergen.trimmingCharacters(in: .whitespaces)
                                guard !t.isEmpty else { return }
                                var p = store.cookingProfile
                                if !p.allergens.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
                                    p.allergens.append(t)
                                    store.cookingProfile = p
                                }
                                customAllergen = ""
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 24)).foregroundStyle(Color.stockedGold)
                            }
                            .buttonStyle(.plain)
                            .a11yButton("Add allergen")
                        }
                    }

                    Text("Recipes containing these are hidden by default in the recipe browser — the shield button there can show them again for one session.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.4))

                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 22).padding(.top, 12)
            }
        }
        .navigationTitle("Dietary Profile")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Simple wrapping chip grid used by the profile editor.
private struct FlowChips: View {
    @Environment(AppSession.self) private var session
    let items: [String]
    let isSelected: (String) -> Bool
    let onTap: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button {
                    withAnimation(.spring(response: 0.22)) { onTap(item) }
                    HapticManager.light()
                } label: {
                    Text(item)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected(item) ? Color.stockedWhite : session.themeTextColor.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(isSelected(item) ? Color.stockedGold : session.themeTextColor.opacity(0.07))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .a11yButton(item, hint: isSelected(item) ? "Selected" : "Not selected")
            }
        }
    }
}
