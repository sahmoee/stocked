// CookRightNowView.swift — #14 first-class "what can I cook right now" destination.
// Shows ONLY meals you can make with what's on hand, ranked so the ones using the most
// soon-to-expire ingredients come first (cook these to avoid waste). Expiring items are
// surfaced at the top so the intent is obvious.
import SwiftUI

struct CookRightNowView: View {
    @Environment(AppSession.self) var session
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var openRecipe: UserRecipe? = nil
    @State private var goRecipe = false

    private var ranked: [(recipe: UserRecipe, expiringUsed: [String])] {
        store.cookableRankedByExpiry()
    }
    private var expiring: [LocalInventoryItem] { store.expiringSoonItems }

    var body: some View {
        StockedShell(showBack: true, scrollDisabled: false) {
            VStack(alignment: .leading, spacing: 18) {

                // Title
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cook Right Now")
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text(ranked.isEmpty
                         ? "Nothing's fully stocked yet — add a few items and these will fill in."
                         : "Meals you can make with what's on hand. Top picks use what's expiring first.")
                        .font(.system(size: 14))
                        .foregroundStyle(session.themeTextColor.opacity(0.6))
                }
                .padding(.horizontal, 24).padding(.top, 4)

                // Expiring strip — what we're trying to use up.
                if !expiring.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use these soon")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                            .padding(.horizontal, 24)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(expiring, id: \.id) { item in
                                    HStack(spacing: 5) {
                                        Image(systemName: "clock.badge.exclamationmark")
                                            .font(.system(size: 10, weight: .bold))
                                        Text(item.name.displayNormalized)
                                            .font(.system(size: 12, weight: .semibold))
                                        if let d = item.daysUntilExpiry {
                                            Text(d <= 0 ? "today" : "\(d)d")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(Color.stockedError)
                                        }
                                    }
                                    .foregroundStyle(session.themeTextColor.opacity(0.8))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Color.stockedError.opacity(0.10))
                                    .clipShape(Capsule())
                                }
                            }
                            .stockedScrollTargetLayout()
                            .padding(.horizontal, 24)
                        }
                        .stockedHorizontalSnap()
                    }
                }

                // Ranked makeable meals
                if ranked.isEmpty {
                    StockedEmptyState(icon: "frying.pan",
                                      title: "No ready meals yet",
                                      subtitle: "When your recipes are fully stocked, they'll appear here — ready to cook with zero shopping.")
                        .padding(.horizontal, 24).padding(.top, 12)
                } else {
                    VStack(spacing: 12) {
                        ForEach(ranked, id: \.recipe.id) { entry in
                            cookNowCell(entry.recipe, expiringUsed: entry.expiringUsed)
                        }
                    }
                    .padding(.horizontal, 24)
                }

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationDestination(isPresented: $goRecipe) {
                if let r = openRecipe { UserRecipeDetailView(recipe: r) }
            }
            .onAppear { UsageMetrics.shared.record(.cookRightNowOpened) }
        }
    }

    private func cookNowCell(_ recipe: UserRecipe, expiringUsed: [String]) -> some View {
        Button { openRecipe = recipe; goRecipe = true } label: {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: recipe.imageURL, imageData: recipe.imageData,
                                 height: 120, resolveName: recipe.title)
                    .frame(maxWidth: .infinity).frame(height: 120).clipped()
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.78)],
                               startPoint: .top, endPoint: .bottom)

                // Top-right: Ready badge.
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 9, weight: .bold))
                            Text("Ready").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.stockedGreen).clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(10)

                // Bottom: title + "uses expiring" + cook button.
                VStack(alignment: .leading, spacing: 6) {
                    Text(recipe.title)
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(.white).lineLimit(2)
                    if !expiringUsed.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "leaf.fill").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.stockedGreen)
                            Text("Uses \(expiringUsed.prefix(3).joined(separator: ", "))")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                        }
                    }
                    HStack(spacing: 8) {
                        if !recipe.cookTime.isEmpty {
                            Label(recipe.cookTime, systemImage: "clock")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Spacer()
                        Text("Cook")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Color.stockedCharcoal)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Color.stockedGold).clipShape(Capsule())
                            .onTapGesture { openRecipe = recipe; goRecipe = true }
                    }
                }
                .padding(14)
            }
            .frame(minHeight: 120)
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        }
        .buttonStyle(.plain)
    }
}
