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

    // Bump when the product tour gains material features or gesture changes so
    // returning installations receive the same current guidance as new users.
    var seenKey: String { "coachmark.seen.\(rawValue).v2" }
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
    var pad: CGFloat = 14

    static func spotlight(_ anchorID: String, title: String, body: String, pad: CGFloat = 14) -> CoachmarkStep {
        CoachmarkStep(kind: .spotlight(anchorID: anchorID), title: title, body: body, pad: pad)
    }
    static func card(title: String, body: String) -> CoachmarkStep {
        CoachmarkStep(kind: .card, title: title, body: body)
    }
}

// MARK: - Anchor collection

struct CoachmarkAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Tag a view so a coachmark spotlight step can glow around it.
    ///
    /// Also registers the same id with `.id(_:)` so the coachmark engine can scroll the element
    /// into view before spotlighting it. Without this, a spotlight step whose target is below the
    /// fold fell back to a floating centered card that referenced something the user couldn't see —
    /// the "Not sure what area this prompt is referencing to" bug. The scroll container
    /// (`StockedShell`) listens for `.coachmarkScrollTo` and scrolls to this id.
    ///
    /// Safe on every current call site: all anchors are static sections, grid cells, or ForEach
    /// rows with stable identity — none is inside a `List`, and the id strings are unique.
    func coachmarkAnchor(_ id: String) -> some View {
        anchorPreference(key: CoachmarkAnchorKey.self, value: .bounds) { [id: $0] }
            .id(id)
    }
}

// MARK: - Scroll coordination

extension Notification.Name {
    /// Posted by the coachmark engine with the anchor id (as `object`) when a spotlight step
    /// becomes active. `StockedShell` scrolls that id to center.
    static let coachmarkScrollTo = Notification.Name("coachmarkScrollTo")
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
    @Environment(\.stockedMotion) private var motion
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
                    let delay = motion.permitsSpatialMotion ? 0.45 : 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        motion.animate(.standard, intent: .opacity) { active = true }
                        scrollToCurrent()
                    }
                }
            }
    }

    /// Bring the current step's target on-screen if it's a spotlight step. No-op for card steps.
    /// The anchor's reported rect updates automatically once the scroll settles, so the glow and
    /// callout re-resolve to the new position.
    private func scrollToCurrent() {
        guard index < steps.count, case let .spotlight(anchorID) = steps[index].kind else { return }
        NotificationCenter.default.post(name: .coachmarkScrollTo, object: anchorID)
    }

    private func advance() {
        if index + 1 < steps.count {
            motion.animate(.selection, intent: .opacity) { index += 1 }
            scrollToCurrent()
        } else {
            finish()
        }
    }

    private func finish() {
        CoachmarkStore.markSeen(page)
        motion.animate(.standard, intent: .opacity) { active = false }
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
        ZStack(alignment: .topLeading) {
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

    // Dimmed background with a rounded hole punched around the spotlight, with a soft gold
    // inner tint at the hole edge so the cutout itself reads as lit.
    private var dimWithHole: some View {
        let dim = Color.black.opacity(isDark ? 0.78 : 0.66)
        return Group {
            if let rect = spotlightRect {
                Rectangle()
                    .fill(dim)
                    .reverseMask {
                        RoundedRectangle(cornerRadius: spotCorner)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
            } else {
                Rectangle().fill(dim)
            }
        }
    }

    private let spotCorner: CGFloat = 18

    // Multi-layer luminous gold halo radiating out from the element's edge. Several blurred
    // strokes of increasing width and decreasing opacity build a soft glow rather than a hard
    // outline, and the whole thing breathes.
    private func glowRing(around rect: CGRect) -> some View {
        PulsingGlow(width: rect.width, height: rect.height, corner: spotCorner)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    // Card placed clear of the spotlit element: below it if there is room beneath, otherwise
    // above it. The card's edge is offset from the element by a real gap, and the whole card is
    // clamped to stay on screen.
    private func calloutCard(near rect: CGRect) -> some View {
        let gap: CGFloat = 22
        let estCardHeight: CGFloat = 190     // generous estimate for clamping
        let spaceBelow = proxy.size.height - rect.maxY
        let placeBelow = spaceBelow > estCardHeight + gap + 40

        // Top Y of the card.
        let rawTop = placeBelow ? rect.maxY + gap : rect.minY - gap - estCardHeight
        let topY = min(max(rawTop, 70), proxy.size.height - estCardHeight - 40)

        return cardBody
            .frame(maxWidth: 330)
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(y: topY)
    }

    private var centeredCard: some View {
        cardBody
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(step.title)
                    .scaledFont(17, weight: .bold, design: .serif)
                    .foregroundStyle(isDark ? Color.stockedWhite : Color.stockedCharcoal)
                Spacer()
                Text("\(stepNumber) of \(stepCount)")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle((isDark ? Color.stockedWhite : Color.stockedCharcoal).opacity(0.45))
            }
            Text(step.body)
                .scaledFont(14)
                .foregroundStyle((isDark ? Color.stockedWhite : Color.stockedCharcoal).opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip") { onSkip() }
                    .scaledFont(13, weight: .medium)
                    .foregroundStyle((isDark ? Color.stockedWhite : Color.stockedCharcoal).opacity(0.5))
                Spacer()
                Button(stepNumber == stepCount ? "Got it" : "Next") { onNext() }
                    .scaledFont(14, weight: .bold)
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

// MARK: - Pulsing glow halo

private struct PulsingGlow: View {
    @Environment(\.stockedMotion) private var motion
    let width: CGFloat
    let height: CGFloat
    let corner: CGFloat
    @State private var pulse = false

    var body: some View {
        ZStack {
            // Outer soft bloom — wide, very blurred, low opacity. This is the "light spilling out".
            RoundedRectangle(cornerRadius: corner)
                .stroke(Color.stockedGold, lineWidth: 14)
                .blur(radius: 22)
                .opacity(pulse ? 0.75 : 0.4)

            // Mid halo — medium width and blur.
            RoundedRectangle(cornerRadius: corner)
                .stroke(Color.stockedGold, lineWidth: 7)
                .blur(radius: 9)
                .opacity(pulse ? 0.95 : 0.6)

            // Crisp inner edge — defines the lit boundary of the element.
            RoundedRectangle(cornerRadius: corner)
                .stroke(Color.stockedGold, lineWidth: 2)
                .opacity(0.95)
        }
        // The bloom needs to extend beyond the element frame, so draw into an oversized canvas.
        .frame(width: width, height: height)
        .scaleEffect(pulse ? 1.03 : 1.0)
        .shadow(color: Color.stockedGold.opacity(pulse ? 0.7 : 0.35), radius: pulse ? 24 : 14)
        .onAppear {
            guard motion.permitsContinuousMotion else { return }
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
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
