// CoachWalkthrough.swift
// ─────────────────────────────────────────────────────────────────────────────
// First-run guided walkthrough (Change 3). Dims the screen and shows an arrow +
// instruction card pointing at the relevant area, stepping through the drawer and
// each tab in order: Drawer → Home → Inventory → Recipes → Grocery List.
//
// Triggered once (gated by UserDefaults) shortly after the main UI appears. Tapping
// "Next" advances; "Skip" ends it. Because exact on-device control positions vary by
// device, each step anchors its arrow to a screen region (top bar, a tab in the
// bottom bar, the left pull-tab) rather than a hardcoded pixel — the arrow points to
// the right area on any iPhone size.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

struct CoachWalkthrough: View {
    @Environment(AppSession.self) var session
    let onFinish: () -> Void

    @State private var stepIndex = 0

    // Where on screen the arrow/card should anchor for each step.
    private enum Anchor { case topBar, leftEdge, bottomBar(slot: Int, of: Int), center }

    private struct Step {
        let title: String
        let body:  String
        let anchor: Anchor
    }

    // The ordered tour. Bottom-bar steps point at one of the four tabs (slot 0–3).
    private var steps: [Step] {
        [
            Step(title: "Welcome to Stocked.",
                 body: "A quick tour of where everything lives. You can skip anytime.",
                 anchor: .center),
            Step(title: "The Menu",
                 body: "Pull this tab from the left to open the menu — scan receipts, add items, search, settings, and more.",
                 anchor: .leftEdge),
            Step(title: "Your Daily Brief",
                 body: "Tap “Stocked.” at the top to open your Daily Brief: what's expiring, what to buy, and quick actions.",
                 anchor: .topBar),
            Step(title: "Home",
                 body: "Your kitchen at a glance — stock level, quick actions, and what to use soon. Press and hold to rearrange your widgets.",
                 anchor: .bottomBar(slot: 0, of: 5)),
            Step(title: "Cook",
                 body: "“Cook Now” finds something to make right now; “Cook Later” plans ahead.",
                 anchor: .bottomBar(slot: 1, of: 5)),
            Step(title: "Inventory",
                 body: "Everything in your kitchen, by zone. Add items, track how much is left, and set expiry dates.",
                 anchor: .bottomBar(slot: 2, of: 5)),
            Step(title: "Recipes",
                 body: "Discover recipes you can make with what you have, save favorites, and browse online.",
                 anchor: .bottomBar(slot: 3, of: 5)),
            Step(title: "Grocery List",
                 body: "Your shopping list — auto-sorted by aisle, with low-stock items suggested for you.",
                 anchor: .bottomBar(slot: 4, of: 5)),
            Step(title: "You're all set!",
                 body: "That's the tour. Tap below to start stocking your kitchen.",
                 anchor: .center)
        ]
    }

    private var safeTop: CGFloat { StockedScreen.safeTopInset }
    private var safeBottom: CGFloat { StockedScreen.safeBottomInset }

    private var step: Step { steps[min(stepIndex, steps.count - 1)] }
    private var isLast: Bool { stepIndex >= steps.count - 1 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25).ignoresSafeArea()

                arrow(in: geo.size)
                card(in: geo.size)
            }
        }
        .transition(.opacity)
    }

    // MARK: - Arrow pointing at the relevant area
    @ViewBuilder
    private func arrow(in size: CGSize) -> some View {
        switch step.anchor {
        case .topBar:
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 16)).foregroundStyle(Color.stockedGold)
                .position(x: size.width / 2, y: safeTop + 30)
        case .leftEdge:
            Image(systemName: "arrowtriangle.left.fill")
                .font(.system(size: 16)).foregroundStyle(Color.stockedGold)
                .position(x: 22, y: size.height * 0.5)
        case .bottomBar(let slot, let count):
            // Tabs are evenly spaced across the bottom pill.
            let slotWidth = size.width / CGFloat(count)
            let x = slotWidth * (CGFloat(slot) + 0.5)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 16)).foregroundStyle(Color.stockedGold)
                .position(x: x, y: size.height - safeBottom - 64)
        case .center:
            EmptyView()
        }
    }

    // MARK: - Instruction card
    @ViewBuilder
    private func card(in size: CGSize) -> some View {
        let cardView = VStack(spacing: 12) {
            Text(step.title)
                .font(.system(size: 19, weight: .bold, design: .serif))
                .foregroundStyle(Color.stockedWhite)
                .multilineTextAlignment(.center)
            Text(step.body)
                .font(.system(size: 14))
                .foregroundStyle(Color.stockedWhite.opacity(0.85))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Progress dots
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Circle()
                        .fill(i == stepIndex ? Color.stockedGold : Color.stockedWhite.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 2)

            HStack(spacing: 12) {
                if !isLast {
                    Button {
                        finish()
                    } label: {
                        Text("Skip")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.stockedWhite.opacity(0.6))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.plain)
                }
                Button {
                    advance()
                } label: {
                    Text(isLast ? "Get Started" : "Next")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.stockedCharcoal)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.stockedGold)
                        .clipShape(Capsule())
                }.buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: 340)
        .background(Color.stockedCharcoal)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.stockedGold.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)

        // Position the card away from the highlighted area so the arrow target stays visible.
        switch step.anchor {
        case .topBar, .leftEdge, .center:
            cardView.position(x: size.width / 2, y: size.height * 0.58)
        case .bottomBar:
            // Keep the card in the upper-middle so it doesn't cover the bottom bar it points to.
            cardView.position(x: size.width / 2, y: size.height * 0.4)
        }
    }

    private func advance() {
        if isLast { finish(); return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { stepIndex += 1 }
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.2)) { onFinish() }
    }
}
