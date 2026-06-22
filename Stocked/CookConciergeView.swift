// CookConciergeView.swift — the redesigned Cook tab ("Recipe Concierge").
//
// Replaces the old "What would you like to do?" Cook home with the mockup's concierge layout:
// three large cards (Build Around Food / Match My Mood / Surprise Me) plus a Recently Cooked
// list. Build Around Food routes to the existing food-category flow; Match My Mood routes to a
// new 3-question flow that feeds the existing mood recipe finder; Surprise Me opens the surprise
// generator. The underlying recipe-matching and inventory systems are reused, not duplicated.

import SwiftUI

struct CookConciergeView: View {
    @Environment(AppSession.self) private var session
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var openRecipe: UserRecipe? = nil
    @State private var goRecipe = false
    @State private var goBuildFood = false
    @State private var goMood = false
    @State private var goSurprise = false

    // Recently cooked: user recipes that have been cooked, newest first.
    private var recentlyCooked: [UserRecipe] {
        store.userRecipes
            .filter { $0.lastCooked != nil }
            .sorted { ($0.lastCooked ?? .distantPast) > ($1.lastCooked ?? .distantPast) }
    }

    var body: some View {
        StockedShell(titleText: "Cook Now", leadingTitle: true) {
            VStack(alignment: .leading, spacing: 16) {

                VStack(alignment: .leading, spacing: 4) {
                    Text("What's on the menu tonight?")
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Let's build something delicious.")
                        .font(.system(size: 14))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                .padding(.horizontal, 24).padding(.top, 4)

                // ── Three concierge cards ──────────────────────────────
                VStack(spacing: 14) {
                    conciergeCard(
                        title: "Build Around Food",
                        subtitle: "Use what you have or what you love.",
                        icon: "fork.knife",
                        tint: Color.stockedCharcoal,
                        textOnDark: true
                    ) { goBuildFood = true }

                    conciergeCard(
                        title: "Match My Mood",
                        subtitle: "Find recipes that fit how you feel.",
                        icon: "face.smiling",
                        tint: Color.stockedGold,
                        textOnDark: true
                    ) { goMood = true }

                    HStack {
                        Rectangle().fill(session.themeTextColor.opacity(0.12)).frame(height: 1)
                        Text("OR").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                        Rectangle().fill(session.themeTextColor.opacity(0.12)).frame(height: 1)
                    }
                    .padding(.vertical, 2)

                    conciergeCard(
                        title: "Surprise Me",
                        subtitle: "Let us pick the perfect recipe.",
                        icon: "gift",
                        tint: dark ? Color.darkSurface : Color.stockedWhite.opacity(0.7),
                        textOnDark: false
                    ) { goSurprise = true }
                }
                .padding(.horizontal, 24)

                // ── Recently Cooked ────────────────────────────────────
                if !recentlyCooked.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recently Cooked")
                            .font(.system(size: 17, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                            .padding(.horizontal, 24)
                        VStack(spacing: 0) {
                            ForEach(recentlyCooked.prefix(4)) { recipe in
                                Button { openRecipe = recipe; goRecipe = true } label: {
                                    recentRow(recipe)
                                }.buttonStyle(.plain)
                                if recipe.id != recentlyCooked.prefix(4).last?.id {
                                    Divider().padding(.leading, 76)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                        .padding(.horizontal, 24)
                    }
                }

                Spacer(minLength: 20)
            }
        }
        .navigationDestination(isPresented: $goBuildFood) { FoodsCategoryView(servings: 4) }
        .navigationDestination(isPresented: $goMood) { MatchMyMoodView() }
        .navigationDestination(isPresented: $goSurprise) { ServingSizeView(isCookNow: true) }
        .navigationDestination(isPresented: $goRecipe) {
            if let recipe = openRecipe { UserRecipeDetailView(recipe: recipe) }
        }
    }

    // MARK: - Card builders

    private func conciergeCard(title: String, subtitle: String, icon: String,
                               tint: Color, textOnDark: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(textOnDark ? Color.white.opacity(0.18) : Color.stockedGold.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(textOnDark ? Color.white : Color.stockedGold)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 19, weight: .bold, design: .serif))
                        .foregroundStyle(textOnDark ? Color.stockedWhite : session.themeTextColor)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(textOnDark ? Color.stockedWhite.opacity(0.75) : session.themeTextColor.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(textOnDark ? Color.stockedWhite.opacity(0.6) : session.themeTextColor.opacity(0.3))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        }
        .buttonStyle(.plain)
    }

    private func recentRow(_ recipe: UserRecipe) -> some View {
        HStack(spacing: 12) {
            recipeThumb(recipe)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                    .lineLimit(1)
                Text([recipe.cookTime, recipe.difficulty].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            Spacer()
            Image(systemName: recipe.isFavorited ? "heart.fill" : "heart")
                .font(.system(size: 15))
                .foregroundStyle(recipe.isFavorited ? Color.stockedError : session.themeTextColor.opacity(0.3))
        }
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private func recipeThumb(_ recipe: UserRecipe) -> some View {
        if let data = recipe.imageData, let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.stockedGold.opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: "fork.knife").font(.system(size: 18)).foregroundStyle(Color.stockedGold)
            }
        }
    }
}

// MARK: - Match My Mood (3-question flow → existing mood recipe finder)

struct MatchMyMoodView: View {
    @Environment(AppSession.self) private var session

    @State private var energy: String? = nil      // Low / Medium / High
    @State private var moodPick: String? = nil     // Comforting / Bold & Spicy / ...
    @State private var time: String? = nil         // 15 / 30 / 60+
    @State private var goResults = false

    private var canShow: Bool { moodPick != nil }

    // Map the mockup's mood choices onto subcategory keys the existing finder understands.
    private func subcategory(for mood: String) -> (category: String, sub: String, emoji: String) {
        switch mood {
        case "Comforting":   return ("Current Mood", "Craving Comfort", "🥰")
        case "Bold & Spicy": return ("Passport Plates", "Indian", "🔥")
        case "Light & Fresh":return ("Current Mood", "Keep it Light", "🥗")
        case "Adventurous":  return ("Passport Plates", "Thai", "🌎")
        case "Indulgent":    return ("Current Mood", "Treat Yourself", "🍰")
        case "Challenge Me": return ("Today's Energy", "Feeling Chef-y", "🧑‍🍳")
        default:             return ("Current Mood", "Craving Comfort", "🥰")
        }
    }

    var body: some View {
        StockedShell(titleText: "Match My Mood", showBack: true) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Let's get a feel for tonight.")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Your answers help us find the perfect recipes for you.")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                .padding(.top, 4)

                question("1. How much energy do you have?") {
                    optionRow([
                        ("😴", "Low", "Take it easy"),
                        ("😀", "Medium", "I can cook"),
                        ("⚡", "High", "I'm pumped"),
                    ], selected: energy) { energy = $0 }
                }

                question("2. What sounds best right now?") {
                    VStack(spacing: 10) {
                        optionRow([
                            ("❤️", "Comforting", ""),
                            ("🌶️", "Bold & Spicy", ""),
                            ("🌿", "Light & Fresh", ""),
                        ], selected: moodPick) { moodPick = $0 }
                        optionRow([
                            ("🌎", "Adventurous", ""),
                            ("🍰", "Indulgent", ""),
                            ("🧑‍🍳", "Challenge Me", ""),
                        ], selected: moodPick) { moodPick = $0 }
                    }
                }

                question("3. How much time do you have?") {
                    optionRow([
                        ("", "15 min", "Quick & easy"),
                        ("", "30 min", "Sweet spot"),
                        ("", "60+ min", "I've got time"),
                    ], selected: time) { time = $0 }
                }

                Button {
                    goResults = true
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("Show My Recipes").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(canShow ? Color.stockedCharcoal : Color.stockedCharcoal.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(!canShow)
                .padding(.top, 4).padding(.bottom, 24)
            }
            .padding(.horizontal, 22)
        }
        .navigationDestination(isPresented: $goResults) {
            let mapping = subcategory(for: moodPick ?? "Comforting")
            MoodRecipeFinderView(category: mapping.category, subcategory: mapping.sub,
                                 emoji: mapping.emoji, servings: 4)
        }
    }

    @ViewBuilder
    private func question<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(session.themeTextColor)
            content()
        }
    }

    private func optionRow(_ options: [(String, String, String)], selected: String?,
                           onPick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.1) { opt in
                let isSel = selected == opt.1
                Button { onPick(opt.1) } label: {
                    VStack(spacing: 4) {
                        if !opt.0.isEmpty { Text(opt.0).font(.system(size: 22)) }
                        Text(opt.1).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                        if !opt.2.isEmpty {
                            Text(opt.2).font(.system(size: 10))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.6),
                                in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSel ? Color.stockedGold : Color.clear, lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
