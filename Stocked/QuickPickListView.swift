// QuickPickListView.swift
// #FB — extra browse categories on the Recipes tab: Under 15 mins, One Pot,
// Feeling Lazy, Comfort Food. Filters the live Discover pool with simple
// heuristics over titles, categories, ingredient counts, and instructions.

import SwiftUI

struct QuickPickListView: View {
    @Environment(AppSession.self) private var session
    let pick: String
    let pool: [OnlineRecipe]
    let onOpenRecipe: (OnlineRecipe) -> Void

    private var filtered: [OnlineRecipe] {
        switch pick {
        case "Under 15 mins":
            // Few ingredients + short instructions reads as quick.
            return pool.filter { $0.ingredients.count <= 7 && $0.instructions.count < 900 }
        case "One Pot":
            let words = ["one pot", "one-pot", "skillet", "sheet pan", "tray", "casserole",
                         "stew", "soup", "curry", "chili", "risotto", "paella", "bake"]
            return pool.filter { r in
                let t = (r.title + " " + r.category + " " + r.instructions.prefix(300)).lowercased()
                return words.contains { t.contains($0) }
            }
        case "Feeling Lazy":
            return pool.filter { $0.ingredients.count <= 6 }
        case "Comfort Food":
            let words = ["mac", "cheese", "pie", "roast", "stew", "casserole", "gravy",
                         "mashed", "fried", "pasta", "burger", "pizza", "soup", "dumpling"]
            return pool.filter { r in
                let t = (r.title + " " + r.category).lowercased()
                return words.contains { t.contains($0) }
            }
        default:
            return pool
        }
    }

    private var subtitle: String {
        switch pick {
        case "Under 15 mins": return "Fast dishes with short ingredient lists."
        case "One Pot":       return "Minimal cleanup — everything in one vessel."
        case "Feeling Lazy":  return "Six ingredients or fewer. You've got this."
        case "Comfort Food":  return "The warm, familiar stuff."
        default:               return ""
        }
    }

    let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        StockedShell(showBack: true, titleText: pick) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pick)
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                .padding(.horizontal, 22).padding(.top, 4)

                if filtered.isEmpty {
                    StockedEmptyState(icon: "fork.knife",
                                      title: "Nothing here yet",
                                      subtitle: "Pull fresh recipes on the Recipes tab and check back.")
                        .padding(.top, 40)
                        .padding(.horizontal, 22)
                } else {
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(filtered) { recipe in
                            Button { onOpenRecipe(recipe) } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    CachedAsyncImage(url: recipe.imageURL, imageData: nil,
                                                     height: 110, resolveName: recipe.title)
                                        .frame(height: 110)
                                        .frame(maxWidth: .infinity)
                                        .clipped()
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(recipe.title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(session.themeTextColor)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                            .frame(height: 32, alignment: .top)
                                        Text([recipe.area.isEmpty ? recipe.category : recipe.area, recipe.source]
                                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                                            .lineLimit(1)
                                    }
                                    .padding(9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.45))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 24)
                }
            }
        }
    }
}
