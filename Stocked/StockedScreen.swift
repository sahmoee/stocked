// StockedScreen.swift — Improvements #8 and #16: one themed container, one type scale.
//
// #8 — The theme bug class. Roughly forty screens each repeat the same four lines:
//
//     .background(session.themeBgColor.ignoresSafeArea())
//     .foregroundStyle(session.themeTextColor)
//     .tint(session.accentColor)
//     .preferredColorScheme(session.isDarkMode ? .dark : .light)
//
// A screen that forgets one of them renders wrong, and that is exactly what happened in the QA
// Workbook: the root screen looked right, but pushed screens showed dark text on a dark background
// because the push destination never applied the theme. Fixing that one screen didn't fix the bug
// — it fixed one instance of it. `.stockedScreen()` fixes the class.
//
// #16 — Dynamic Type. Most of the app hardcodes `.font(.system(size: 11…16))`, which does not
// respond to the user's text-size setting at all. At the accessibility sizes, fixed 11pt stat rows
// and tool tiles either clip or stay unreadably small. Food and kitchen apps skew older; this is a
// real exclusion, not a nicety. `StockedType` gives relative sizes that scale, capped so layouts
// don't explode, and can be adopted screen by screen.

import SwiftUI

// MARK: - Screen container (#8)

struct StockedScreenModifier: ViewModifier {
    @Environment(AppSession.self) private var session

    /// Some screens (media, full-bleed hero headers) want the theme's colours but not its
    /// background fill.
    var fillBackground: Bool = true
    /// List/Form-based screens need the system's own grouped background suppressed.
    var clearScrollBackground: Bool = true

    func body(content: Content) -> some View {
        content
            .modifier(ConditionalScrollBackground(active: clearScrollBackground))
            .background {
                if fillBackground { session.themeBgColor.ignoresSafeArea() }
            }
            .foregroundStyle(session.themeTextColor)
            .tint(session.accentColor)
            .preferredColorScheme(session.isDarkMode ? .dark : .light)
    }
}

private struct ConditionalScrollBackground: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.scrollContentBackground(.hidden) } else { content }
    }
}

extension View {
    /// Apply the app's theme to a whole screen. Use this instead of hand-applying background,
    /// foreground, tint and colour scheme — a screen that uses this cannot forget one of them.
    ///
    /// Put it on the OUTERMOST view of a screen, after `.navigationTitle`.
    func stockedScreen(fillBackground: Bool = true, clearScrollBackground: Bool = true) -> some View {
        modifier(StockedScreenModifier(fillBackground: fillBackground,
                                       clearScrollBackground: clearScrollBackground))
    }
}

// MARK: - Type scale (#16)

/// Semantic roles for text, so screens stop hardcoding point sizes.
///
/// The app ALREADY has Dynamic Type scaling — `StockedType.scaled(_:)` in DesignTokens.swift, used
/// by the `stockedSerif`/`stockedSans` font helpers. The problem was never a missing mechanism, it
/// was that most screens (including all fifteen new features) call `.font(.system(size: 13))`
/// directly and bypass it entirely.
///
/// So this deliberately does NOT introduce a second scaling implementation. It names the seven
/// sizes the app actually uses and routes them through the existing `StockedType.scaled`, giving
/// one obvious thing to reach for: `.stockedFont(.rowTitle)` instead of a magic number.
nonisolated enum StockedTextRole: Sendable {
    case screenTitle    // large headers inside content
    case sectionTitle   // "Insights", "Take out"
    case rowTitle       // the main line of a list row
    case rowDetail      // the supporting line under it
    case caption        // timestamps, source labels, units
    case statValue      // big numbers in stat rows
    case statLabel      // the word under a big number

    var size: CGFloat {
        switch self {
        case .screenTitle:  return 20
        case .sectionTitle: return 16
        case .rowTitle:     return 15
        case .rowDetail:    return 13
        case .caption:      return 11
        case .statValue:    return 17
        case .statLabel:    return 10
        }
    }
    var weight: Font.Weight {
        switch self {
        case .screenTitle, .statValue: return .bold
        case .sectionTitle, .rowTitle: return .semibold
        default:                       return .regular
        }
    }
    /// Where growth stops. Stat rows sit three-across and genuinely cannot take AX5; body text can.
    var maxCategory: DynamicTypeSize {
        switch self {
        case .statValue, .statLabel, .caption: return .accessibility1
        default:                               return .accessibility3
        }
    }
}

extension View {
    /// Dynamic-Type-aware replacement for `.font(.system(size:weight:))`.
    /// Uses the app's existing `StockedType.scaled` so there is exactly one scaling rule.
    func stockedFont(_ role: StockedTextRole) -> some View {
        self
            .font(.stockedSans(role.size, weight: role.weight))
            .dynamicTypeSize(...role.maxCategory)
    }
}

// MARK: - Accessible row helpers (#16)

extension View {
    /// Collapse a compound row into one VoiceOver element with a spoken label.
    /// Compound rows (title + detail + trailing badge) otherwise read as three separate
    /// unlabelled stops, which is the most common VoiceOver defect in list-heavy apps.
    func stockedRowAccessibility(_ label: String, hint: String? = nil) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
    }

    /// Guarantee the 44×44pt minimum touch target Apple requires, without changing visual size.
    /// Several of the app's inline pill buttons render at ~28pt tall.
    func stockedTouchTarget() -> some View {
        frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}
