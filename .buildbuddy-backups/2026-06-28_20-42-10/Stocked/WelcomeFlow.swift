// WelcomeFlow.swift — first-run welcome experience.
//
// Replaces the old CoachWalkthrough arrow tour. A full-screen, swipeable set of intro pages
// that introduces the app and its main areas, with one page that prominently calls out the
// hidden left pull-tab menu (where scan, add, search, and settings live — easy to miss).
// Ends on a "Get Started" button. Shown once, gated by a UserDefaults flag in MainTabView.

import SwiftUI

struct WelcomeFlow: View {
    @Environment(AppSession.self) private var session
    let onFinish: () -> Void

    @State private var page = 0

    private var dark: Bool { session.isDarkMode }
    private var pages: [WelcomePage] { WelcomePage.all }

    var body: some View {
        ZStack {
            // Full-screen themed background.
            session.themeBgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip, top-right.
                HStack {
                    Spacer()
                    Button("Skip") { finish() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                        .padding(.trailing, 22).padding(.top, 8)
                }

                // Swipeable pages.
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, p in
                        WelcomePageView(page: p, isMenuPage: p.isMenuCallout)
                            .environment(session)
                            .tag(idx)
                            .padding(.horizontal, 28)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: page)

                // Page dots.
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? Color.stockedGold : session.themeTextColor.opacity(0.2))
                            .frame(width: i == page ? 22 : 7, height: 7)
                            .animation(.spring(response: 0.3), value: page)
                    }
                }
                .padding(.bottom, 18)

                // Primary action: Next, or Get Started on the last page.
                Button {
                    if page >= pages.count - 1 { finish() }
                    else { withAnimation(.easeInOut) { page += 1 } }
                } label: {
                    Text(page >= pages.count - 1 ? "Get Started" : "Next")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Color.stockedCharcoal, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 28).padding(.bottom, 28)
            }
        }
    }

    private func finish() {
        onFinish()
    }
}

// MARK: - Page model

private struct WelcomePage {
    let emoji: String
    let title: String
    let body: String
    var isMenuCallout: Bool = false

    static let all: [WelcomePage] = [
        WelcomePage(
            emoji: "👋",
            title: "Welcome to Stocked",
            body: "Your kitchen, organized. Track what you have, find recipes you can make right now, and never forget an item on the grocery run."),
        WelcomePage(
            emoji: "📦",
            title: "Know what's in your kitchen",
            body: "Add items by scanning a receipt or barcode, or by hand. Stocked tracks freshness and flags what's expiring soon so nothing goes to waste."),
        WelcomePage(
            emoji: "🍳",
            title: "Cook with what you have",
            body: "The Cook tab builds meals around your inventory, matches recipes to your mood, or plans the whole week ahead."),
        WelcomePage(
            emoji: "👈",
            title: "Don't miss the menu",
            body: "Pull the tab from the LEFT edge of the screen to open the menu. That's where you scan receipts, add items, search everything, and reach settings. It's easy to miss, so swipe right from the left edge any time.",
            isMenuCallout: true),
        WelcomePage(
            emoji: "✨",
            title: "You're all set",
            body: "Everything saves automatically. Explore the tabs along the bottom, and pull the left menu whenever you need to add or find something."),
    ]
}

// MARK: - Single page

private struct WelcomePageView: View {
    @Environment(AppSession.self) private var session
    let page: WelcomePage
    let isMenuPage: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Emoji badge.
            ZStack {
                Circle().fill(Color.stockedGold.opacity(session.isDarkMode ? 0.22 : 0.14))
                    .frame(width: 118, height: 118)
                Text(page.emoji).font(.system(size: 56))
            }
            .padding(.bottom, 30)

            Text(page.title)
                .font(.system(size: 28, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
                .multilineTextAlignment(.center)
                .padding(.bottom, 14)

            Text(page.body)
                .font(.system(size: 16))
                .foregroundStyle(session.themeTextColor.opacity(0.62))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            // On the hidden-menu page, show a small visual hint of the left-edge swipe.
            if isMenuPage {
                MenuSwipeHint()
                    .padding(.top, 30)
            }

            Spacer()
            Spacer()
        }
    }
}

// MARK: - Left-edge swipe hint

private struct MenuSwipeHint: View {
    @Environment(AppSession.self) private var session
    @State private var nudge = false

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 14)
                .fill(session.themeCardColor)
                .frame(height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.stockedGold.opacity(0.35), lineWidth: 1)
                )

            // The pull-tab on the left edge.
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.stockedGold)
                    .frame(width: 5, height: 34)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.stockedGold)
                    .offset(x: nudge ? 6 : 0)
                Text("Swipe from the left edge")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(session.themeTextColor.opacity(0.7))
                Spacer()
            }
            .padding(.leading, 14)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                nudge = true
            }
        }
    }
}
