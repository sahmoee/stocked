// CuisineBrowseView.swift
// ─────────────────────────────────────────────────────────────────────────────
// "See All" on the Recipes tab → this screen. It lists cuisine types
// (Italian, Mexican, American, …) and lets the user browse online recipes from
// each one specifically. Cuisines come from TheMealDB's area list (with a
// curated fallback so the screen is never empty offline); tapping a cuisine
// fetches that area's recipes WITH full step-by-step instructions, so they pass
// the app-wide no-steps filter and open as complete recipes.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

struct CuisineBrowseView: View {
    @Environment(AppSession.self) var session

    @State private var cuisines: [String] = CuisineBrowseView.fallbackCuisines
    @State private var loaded = false

    var body: some View {
        StockedShell(showBack: true, scrollDisabled: false, titleText: "Cuisines") {
            VStack(alignment: .leading, spacing: 0) {
                Text("Browse recipes by cuisine")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                    .padding(.horizontal, 24).padding(.bottom, 12)

                LazyVStack(spacing: 10) {
                    ForEach(cuisines, id: \.self) { cuisine in
                        NavigationLink {
                            CuisineRecipesView(area: cuisine).environment(session)
                        } label: {
                            cuisineRow(cuisine)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .task {
                guard !loaded else { return }
                loaded = true
                let areas = await RecipeSourcesPlus.mealDBAreas()
                if !areas.isEmpty {
                    // Keep only cuisines we have a flag for — this also drops non-cuisine
                    // areas like "Unknown" that have nothing real to browse. Then sort
                    // the most familiar ones first, the rest A–Z.
                    let known = areas.filter { CuisineBrowseView.flagIfKnown(for: $0) != nil }
                    let preferred = CuisineBrowseView.fallbackCuisines
                    let ranked = known.sorted { a, b in
                        let ia = preferred.firstIndex(of: a) ?? Int.max
                        let ib = preferred.firstIndex(of: b) ?? Int.max
                        if ia != ib { return ia < ib }
                        return a < b
                    }
                    if !ranked.isEmpty { cuisines = ranked }
                }
            }
        }
    }

    private func cuisineRow(_ cuisine: String) -> some View {
        HStack(spacing: 14) {
            Text(CuisineBrowseView.flag(for: cuisine))
                .font(.system(size: 26))
                .frame(width: 38, height: 38)
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                .clipShape(Circle())
            Text(cuisine)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(session.themeTextColor)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(session.themeTextColor.opacity(0.35))
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .contentShape(Rectangle())
    }

    // Curated default list — used as a fallback and to rank the live area list.
    static let fallbackCuisines = [
        "American", "Italian", "Mexican", "Chinese", "Indian", "Japanese",
        "Thai", "French", "Greek", "Spanish", "British", "Turkish",
        "Vietnamese", "Moroccan", "Jamaican"
    ]

    /// The flag emoji for a known cuisine, or nil if we don't have one. Cuisines
    /// without a flag are dropped from the list (along with non-cuisine areas like
    /// "Unknown", which also have no real recipes to browse).
    static func flagIfKnown(for cuisine: String) -> String? {
        switch cuisine.lowercased() {
        case "american":              return "🇺🇸"
        case "italian":               return "🇮🇹"
        case "mexican":               return "🇲🇽"
        case "chinese":               return "🇨🇳"
        case "indian":                return "🇮🇳"
        case "japanese":              return "🇯🇵"
        case "thai":                  return "🇹🇭"
        case "french":                return "🇫🇷"
        case "greek":                 return "🇬🇷"
        case "spanish":               return "🇪🇸"
        case "british":               return "🇬🇧"
        case "turkish":               return "🇹🇷"
        case "vietnamese":            return "🇻🇳"
        case "moroccan":              return "🇲🇦"
        case "jamaican":              return "🇯🇲"
        case "canadian":              return "🇨🇦"
        case "dutch":                 return "🇳🇱"
        case "egyptian":              return "🇪🇬"
        case "filipino":              return "🇵🇭"
        case "irish":                 return "🇮🇪"
        case "kenyan":                return "🇰🇪"
        case "malaysian":             return "🇲🇾"
        case "polish":                return "🇵🇱"
        case "portuguese":            return "🇵🇹"
        case "russian":               return "🇷🇺"
        case "tunisian":              return "🇹🇳"
        case "ukrainian":             return "🇺🇦"
        case "croatian":              return "🇭🇷"
        case "norwegian":             return "🇳🇴"
        default:                      return nil
        }
    }

    /// Non-optional flag for display (only called on cuisines we've already filtered
    /// to known ones, so the fallback should never actually show).
    static func flag(for cuisine: String) -> String {
        flagIfKnown(for: cuisine) ?? "🍽️"
    }
}

// MARK: - Recipes for one cuisine
private struct CuisineRecipesView: View {
    @Environment(AppSession.self) var session
    let area: String

    @State private var recipes: [OnlineRecipe] = []
    @State private var loading = true
    @State private var selected: OnlineRecipe? = nil

    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        StockedShell(showBack: true, scrollDisabled: false, titleText: area) {
            Group {
                if loading {
                    VStack(spacing: 14) {
                        ProgressView().tint(Color.stockedGold)
                        Text("Finding \(area) recipes…")
                            .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                } else if recipes.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 26)).foregroundStyle(session.themeTextColor.opacity(0.4))
                        Text("Couldn't load \(area) recipes right now.")
                            .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 32)
                } else {
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(recipes) { recipe in
                            Button { selected = recipe } label: {
                                OnlineRecipeCard(recipe: recipe)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 24)
                }
            }
            .navigationDestination(item: $selected) { recipe in
                OnlineRecipeDetailView(recipe: recipe).environment(session)
            }
            .task {
                guard recipes.isEmpty else { return }
                // mealDBByArea returns full recipes WITH steps, so they pass the
                // app-wide no-steps filter. Belt-and-suspenders: filter here too.
                let fetched = await RecipeSourcesPlus.mealDBByArea(area, limit: 20)
                recipes = fetched.filter { OnlineRecipeFacts.hasRealInstructions($0.instructions) }
                loading = false
            }
        }
    }
}
