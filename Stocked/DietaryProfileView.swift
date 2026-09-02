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
                        .scaledFont(13)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))

                    // ── Dietary style ─────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Dietary Style")
                            .scaledFont(15, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        FlowChips(items: diets, isSelected: { store.cookingProfile.dietaryStyle == $0 }) { diet in
                            var p = store.cookingProfile
                            p.dietaryStyle = (p.dietaryStyle == diet) ? "" : diet
                            store.cookingProfile = p
                        }
                    }

                    NavigationLink {
                        BrandPreferencesEditorView()
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "tag.fill")
                                .scaledFont(18, weight: .semibold)
                                .foregroundStyle(Color.stockedGold)
                                .frame(width: 34, height: 34)
                                .background(Color.stockedGold.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Brand Preferences")
                                    .scaledFont(15, weight: .bold, design: .serif)
                                    .foregroundStyle(session.themeTextColor)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Favorite or avoid brands across suggestions and substitutions")
                                    .scaledFont(11.5)
                                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right")
                                .scaledFont(12, weight: .semibold)
                                .foregroundStyle(session.themeTextColor.opacity(0.35))
                        }
                        .padding(14)
                        .background(session.themeCardColor,
                                    in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd,
                                                         style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .a11yButton("Brand Preferences", hint: "Choose favorite, neutral, or avoided brands")

                    // ── Allergens ─────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Allergens to Avoid")
                            .scaledFont(15, weight: .bold, design: .serif)
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
                                .scaledFont(14)
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
                                    .scaledFont(24).foregroundStyle(Color.stockedGold)
                            }
                            .buttonStyle(.plain)
                            .a11yButton("Add allergen")
                        }
                    }

                    Text("Recipes containing these are hidden by default in the recipe browser — the shield button there can show them again for one session.")
                        .scaledFont(11.5)
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

/// Searchable editor backed directly by `UserCookingProfile.brandPreferences`.
/// The adaptive option grid grows vertically at large Dynamic Type sizes and never truncates.
struct BrandPreferencesEditorView: View {
    @Environment(AppSession.self) private var session
    @State private var query = ""

    private var store: GuestDataStore { session.guestStore }
    private var preferences: BrandPreferences { store.cookingProfile.brandPreferences }
    private var profiles: [BrandProfile] {
        BrandDatabase.rankedProfiles(matching: query, preferences: preferences)
    }
    private var favoriteCount: Int {
        BrandDatabase.profiles.filter {
            let value = preferences.preference(for: $0.displayName)
            return value == .favorite || value == .prefer
        }.count
    }
    private var avoidedCount: Int {
        BrandDatabase.profiles.filter {
            preferences.preference(for: $0.displayName) == .avoid
        }.count
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text("Favorites rise in product suggestions and substitutions. Avoided brands stay visible, but sort after neutral choices.")
                        .scaledFont(13)
                        .foregroundStyle(session.themeTextColor.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                        TextField("Search brands or products", text: $query)
                            .textFieldStyle(.plain)
                            .scaledFont(14)
                            .foregroundStyle(session.themeTextColor)
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                            .a11yButton("Clear brand search")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(session.themeCardColor,
                                in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd,
                                                     style: .continuous))

                    Text("\(favoriteCount) favorite · \(avoidedCount) avoided · \(profiles.count) shown")
                        .scaledFont(11.5, weight: .semibold)
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)

                    if profiles.isEmpty {
                        ContentUnavailableView("No matching brands",
                                               systemImage: "tag.slash",
                                               description: Text("Try a brand or product name."))
                            .foregroundStyle(session.themeTextColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                    } else {
                        ForEach(profiles) { profile in
                            brandRow(profile)
                        }
                    }
                    Color.clear.frame(height: 28)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
        }
        .navigationTitle("Brand Preferences")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func brandRow(_ profile: BrandProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(profile.displayName)
                        .scaledFont(15, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if profile.isPrivateLabel {
                        Text("STORE BRAND")
                            .scaledFont(8.5, weight: .bold)
                            .foregroundStyle(Color.stockedGold)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !profile.knownItems.isEmpty {
                    Text(profile.knownItems.prefix(2).joined(separator: " · "))
                        .scaledFont(11)
                        .foregroundStyle(session.themeTextColor.opacity(0.48))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], spacing: 8) {
                preferenceButton("Favorite", value: .favorite, symbol: "star.fill", profile: profile)
                preferenceButton("Neutral", value: .neutral, symbol: "circle", profile: profile)
                preferenceButton("Avoid", value: .avoid, symbol: "hand.raised.fill", profile: profile)
            }
        }
        .padding(14)
        .background(session.themeCardColor,
                    in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd,
                                         style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func preferenceButton(_ title: String, value: BrandPreference, symbol: String,
                                  profile: BrandProfile) -> some View {
        let current = preferences.preference(for: profile.displayName)
        let selected = value == .favorite
            ? current == .favorite || current == .prefer
            : current == value
        let tint: Color = value == .avoid ? Color.stockedWarning
            : (value == .favorite ? Color.stockedGold : session.themeTextColor.opacity(0.55))
        return Button {
            var cookingProfile = store.cookingProfile
            cookingProfile.brandPreferences.set(value, for: profile.displayName)
            store.cookingProfile = cookingProfile
            HapticManager.select()
        } label: {
            Label(title, systemImage: symbol)
                .scaledFont(11.5, weight: .semibold)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Color.stockedWhite : tint)
                .background(selected ? tint : tint.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm,
                                                 style: .continuous))
        }
        .buttonStyle(.plain)
        .a11yButton("\(title) \(profile.displayName)", hint: selected ? "Selected" : "Not selected")
    }
}

/// Simple wrapping chip grid used by the profile editor.
private struct FlowChips: View {
    @Environment(AppSession.self) private var session
    @Environment(\.stockedMotion) private var motion
    let items: [String]
    let isSelected: (String) -> Bool
    let onTap: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button {
                    motion.animate(.selection, intent: .spatial) { onTap(item) }
                    HapticManager.light()
                } label: {
                    Text(item)
                        .scaledFont(13, weight: .semibold)
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
