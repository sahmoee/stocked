// ForYouView.swift — "For You ✦" tab. Extracted from RecipeVaultViews.swift
import SwiftUI

struct ForYouPremiumView: View {
    @Environment(AppSession.self) var session
    @State private var showTeaser = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                ForYouHeroCard(showTeaser: $showTeaser)
                ForYouWhatsComingSection()
                ForYouPreviewSection(showTeaser: $showTeaser)
            }
        }
        .sheet(isPresented: $showTeaser) {
            ForYouTeaserSheet().environment(session)
        }
    }
}

private struct ForYouHeroCard: View {
    @Environment(AppSession.self) var session
    @Binding var showTeaser: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.stockedCharcoal, Color.stockedCharcoal.opacity(0.7)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))

            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.stockedGold.opacity(0.18)).frame(width: 80, height: 80)
                    Image(systemName: "sparkles").font(.system(size: 36)).foregroundStyle(Color.stockedGold)
                }
                .padding(.top, 32)

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("For You")
                            .font(.system(size: 28, weight: .bold, design: .serif))
                            .foregroundStyle(Color.stockedWhite)
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").font(.system(size: 9))
                            Text("PREMIUM").font(.system(size: 9, weight: .bold)).tracking(1)
                        }
                        .foregroundStyle(Color.stockedGold)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.stockedGold.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                    }
                    Text("Personalized AI recipes built from your cooking personality")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.stockedWhite.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Button { showTeaser = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill").font(.system(size: 13))
                        Text("Coming Soon — Learn More").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(Color.stockedGold)
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 32)
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
    }
}

private struct ForYouWhatsComingSection: View {
    @Environment(AppSession.self) var session

    private let highlights: [(icon: String, title: String, detail: String)] = [
        ("sparkles",                   "Taste Profile",   "Claude analyses your past meals, cuisine preferences, and dietary style to understand what makes you tick."),
        ("brain.head.profile",         "Pantry-First",    "Every suggestion starts with what you already have. No unnecessary shopping — just creative cooking."),
        ("chart.line.uptrend.xyaxis",  "Gets Smarter",    "The more you cook and rate, the more precisely your feed is tuned to your evolving palate."),
        ("star.fill",                  "Exclusive Access","For You is part of Stocked. Premium — launching soon with personalised meal planning and more."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text("WHAT'S COMING")
                .font(.system(size: 10, weight: .bold)).tracking(1.2)
                .foregroundStyle(session.themeTextColor.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 12)

            VStack(spacing: 10) {
                ForEach(highlights, id: \.title) { h in
                    ForYouHighlightRow(icon: h.icon, title: h.title, detail: h.detail)
                }
            }
            .padding(.bottom, 32)
        }
    }
}

private struct ForYouPreviewSection: View {
    @Environment(AppSession.self) var session
    @Binding var showTeaser: Bool

    private let mockRecipes: [(title: String, reason: String)] = [
        ("Spiced Lamb Flatbreads with Herb Yogurt", "Based on your Middle Eastern preference"),
        ("Miso-Glazed Salmon with Sesame Slaw",     "Matches your weeknight cook style"),
        ("Slow-Roasted Tomato Pasta",               "Uses 6 items already in your pantry"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text("PREVIEW")
                .font(.system(size: 10, weight: .bold)).tracking(1.2)
                .foregroundStyle(session.themeTextColor.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 12)

            VStack(spacing: 10) {
                ForEach(mockRecipes, id: \.title) { r in
                    ForYouMockCard(title: r.title, reason: r.reason, onTap: { showTeaser = true })
                }
            }
            .padding(.bottom, 60)
        }
    }
}

// MARK: - ForYou subviews (extracted to fix compiler type-check timeout)
private struct ForYouHighlightRow: View {
    @Environment(AppSession.self) var session
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                    .fill(Color.stockedGold.opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.stockedGold)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .lineSpacing(2)
            }
            Spacer()
        }
        .padding(14)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .padding(.horizontal, 20)
    }
}

private struct ForYouMockCard: View {
    @Environment(AppSession.self) var session
    let title: String
    let reason: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                        .fill(Color.stockedCharcoal.opacity(0.7))
                        .frame(width: 52, height: 52)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.stockedGold)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                        .blur(radius: 3)
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.stockedGold)
                }
                Spacer()
                Text("PREMIUM")
                    .font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .foregroundStyle(Color.stockedGold)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.stockedGold.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
            }
            .padding(14)
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }
}

// MARK: - For You Teaser Sheet
struct ForYouTeaserSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.stockedGold)
                            .padding(.top, 40)

                        VStack(spacing: 10) {
                            Text("For You — Premium")
                                .font(.system(size: 24, weight: .bold, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                            Text("Personalized AI recipes are coming to Stocked. as part of the Premium tier. We're building a system that reads your taste profile, pantry, and cooking history to suggest recipes you'll actually love — before you even know you want them.")
                                .font(.system(size: 14))
                                .foregroundStyle(session.themeTextColor.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                                .padding(.horizontal, 24)
                        }

                        VStack(spacing: 12) {
                            featureRow("✦", "Recipes tuned to your cuisine preferences")
                            featureRow("✦", "Suggestions built around pantry items you already have")
                            featureRow("✦", "Learns from every meal you cook and rate")
                            featureRow("✦", "Exclusive to Stocked. Premium — launching soon")
                        }
                        .padding(.horizontal, 24)

                        Button { dismiss() } label: {
                            Text("Got It")
                                .font(.system(size: 16, weight: .semibold, design: .serif))
                                .foregroundStyle(Color.stockedWhite)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color.stockedCharcoal)
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("For You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }.foregroundStyle(Color.stockedGold)
                }
            }
        }
    }

    private func featureRow(_ bullet: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(bullet)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.stockedGold)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(session.themeTextColor.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

// MARK: - Ready to Cook Now
