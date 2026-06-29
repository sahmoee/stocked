// Coachmark.swift — first-visit coachmark engine (Build 298).
//
// A reusable, per-page guided introduction. Each page declares an ordered list of steps; the
// engine shows them the first time that page is visited and never again (tracked in
// UserDefaults). Two kinds of step:
//
//   • .spotlight(id:): dims the screen and cuts a GLOWING hole around a real on-screen element,
//     identified by a matching .coachmarkAnchor(id) tag on that element. Use for major features
//     the user should see in place.
//   • .card: a centered card with no anchor. Use for lower-tier or easily-missed things that do
//     not warrant a spotlight (per the design: things that might go missed).
//
// Usage on a page:
//   SomeButton().coachmarkAnchor("home.add")
//   ...
//   .coachmarks(page: .home, steps: HomeCoachmarks.steps)
//
// The engine is additive: pages without .coachmarks(...) are unaffected.

import SwiftUI

// MARK: - Page identity (one first-visit flag per page)

enum CoachmarkPage: String, CaseIterable {
    case home, cook, inventory, recipes, grocery

    var seenKey: String { "coachmark.seen.\(rawValue).v1" }
}

// MARK: - Step model

struct CoachmarkStep: Identifiable {
    enum Kind {
        case spotlight(anchorID: String)   // glow around the tagged element
        case card                          // centered card, no anchor
    }
    let id = UUID()
    let kind: Kind
    let title: String
    let body: String
    /// Extra padding around the spotlit element's frame (visual breathing room for the glow).
    var pad: CGFloat = 10

    static func spotlight(_ anchorID: String, title: String, body: String, pad: CGFloat = 10) -> CoachmarkStep {
        CoachmarkStep(kind: .spotlight(anchorID: anchorID), title: title, body: body, pad: pad)
    }
    static func card(title: String, body: String) -> CoachmarkStep {
        CoachmarkStep(kind: .card, title: title, body: body)
    }
}

// MARK: - Anchor collection

struct CoachmarkAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Tag a view so a coachmark spotlight step can glow around it.
    func coachmarkAnchor(_ id: String) -> some View {
        anchorPreference(key: CoachmarkAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

// MARK: - Seen tracking

enum CoachmarkStore {
    static func hasSeen(_ page: CoachmarkPage) -> Bool {
        UserDefaults.standard.bool(forKey: page.seenKey)
    }
    static func markSeen(_ page: CoachmarkPage) {
        UserDefaults.standard.set(true, forKey: page.seenKey)
    }
    /// Reset all page flags (used by a future replay-from-settings action).
    static func resetAll() {
        for p in CoachmarkPage.allCases { UserDefaults.standard.removeObject(forKey: p.seenKey) }
    }
}

// MARK: - Page attachment modifier

extension View {
    /// Attach a coachmark flow to a page. Shows once on first visit.
    func coachmarks(page: CoachmarkPage, steps: [CoachmarkStep]) -> some View {
        modifier(CoachmarkHost(page: page, steps: steps))
    }
}

private struct CoachmarkHost: ViewModifier {
    let page: CoachmarkPage
    let steps: [CoachmarkStep]

    @Environment(AppSession.self) private var session
    @State private var active = false
    @State private var index = 0
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(CoachmarkAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if active, index < steps.count {
                        CoachmarkOverlay(
                            step: steps[index],
                            anchors: anchors,
                            proxy: proxy,
                            isDark: session.isDarkMode,
                            stepNumber: index + 1,
                            stepCount: steps.count,
                            onNext: advance,
                            onSkip: finish
                        )
                        .transition(.opacity)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(active)
            }
            .onAppear {
                // Slight delay so the page has laid out and anchors are reported before we draw.
                guard !appeared else { return }
                appeared = true
                if !CoachmarkStore.hasSeen(page) && !steps.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        withAnimation(.easeInOut(duration: 0.3)) { active = true }
                    }
                }
            }
    }

    private func advance() {
        if index + 1 < steps.count {
            withAnimation(.easeInOut(duration: 0.25)) { index += 1 }
        } else {
            finish()
        }
    }

    private func finish() {
        CoachmarkStore.markSeen(page)
        withAnimation(.easeInOut(duration: 0.3)) { active = false }
    }
}

// MARK: - Overlay (dim + glowing spotlight or centered card)

private struct CoachmarkOverlay: View {
    let step: CoachmarkStep
    let anchors: [String: Anchor<CGRect>]
    let proxy: GeometryProxy
    let isDark: Bool
    let stepNumber: Int
    let stepCount: Int
    let onNext: () -> Void
    let onSkip: () -> Void

    // Resolve the spotlight rect (if this is a spotlight step with a found anchor).
    private var spotlightRect: CGRect? {
        if case let .spotlight(anchorID) = step.kind, let anchor = anchors[anchorID] {
            let r = proxy[anchor]
            return r.insetBy(dx: -step.pad, dy: -step.pad)
        }
        return nil
    }

    var body: some View {
        ZStack {
            dimWithHole
            if let rect = spotlightRect {
                glowRing(around: rect)
                calloutCard(near: rect)
            } else {
                // Card step (or anchor not found → graceful centered fallback).
                centeredCard
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onNext() }   // tap anywhere to advance
    }

    // Dimmed background with a rounded rectangular hole punched around the spotlight.
    private var dimWithHole: some View {
        let dim = Color.black.opacity(isDark ? 0.72 : 0.6)
        return Group {
            if let rect = spotlightRect {
                Rectangle()
                    .fill(dim)
                    .reverseMask {
                        RoundedRectangle(cornerRadius: 16)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
            } else {
                Rectangle().fill(dim)
            }
        }
    }

    // Pulsing gold glow ring around the spotlit element.
    private func glowRing(around rect: CGRect) -> some View {
        PulsingGlow()
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    // Callout positioned just below (or above) the spotlight.
    private func calloutCard(near rect: CGRect) -> some View {
        let placeBelow = rect.maxY < proxy.size.height * 0.6
        let y = placeBelow ? rect.maxY + 16 : rect.minY - 16
        return cardBody
            .frame(maxWidth: 320)
            .position(x: proxy.size.width / 2, y: 0)
            .offset(y: placeBelow ? y : max(y - 140, 80))
    }

    private var centeredCard: some View {
        cardBody
            .frame(maxWidth: 340)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(step.title)
                    .font(.system(size: 17, weight: .bold, design: .serif))
                    .foregroundStyle(isDark ? Color.stockedWhite : Color.stockedCharcoal)
                Spacer()
                Text("\(stepNumber) of \(stepCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle((isDark ? Color.stockedWhite : Color.stockedCharcoal).opacity(0.45))
            }
            Text(step.body)
                .font(.system(size: 14))
                .foregroundStyle((isDark ? Color.stockedWhite : Color.stockedCharcoal).opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip") { onSkip() }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle((isDark ? Color.stockedWhite : Color.stockedCharcoal).opacity(0.5))
                Spacer()
                Button(stepNumber == stepCount ? "Got it" : "Next") { onNext() }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.stockedCharcoal)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Color.stockedGold)
                    .clipShape(Capsule())
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(isDark ? Color.darkSurface : Color.stockedWhite)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .padding(.horizontal, 24)
    }
}

// MARK: - Pulsing glow ring

private struct PulsingGlow: View {
    @State private var pulse = false
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(Color.stockedGold, lineWidth: 2.5)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.stockedGold, lineWidth: 6)
                    .blur(radius: 8)
                    .opacity(pulse ? 0.9 : 0.4)
            )
            .shadow(color: Color.stockedGold.opacity(pulse ? 0.8 : 0.3), radius: pulse ? 16 : 8)
            .scaleEffect(pulse ? 1.02 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - Reverse mask helper (punch a hole in a fill)

private extension View {
    @ViewBuilder
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .center) {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}
