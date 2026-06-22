// ScalableFont.swift — #5 Dynamic Type foundation.
//
// The app uses ~1,600 fixed `.font(.system(size: N))` calls, which do NOT scale when a user
// raises their system text size (a major accessibility gap). Converting all of them blindly
// would break fixed-size layouts (badges, icon frames, pills), so this introduces a SAFE,
// incremental path:
//
//   • `.scaledFont(_:weight:design:)` — a drop-in replacement for
//     `.font(.system(size:weight:design:))` that scales with Dynamic Type by anchoring the point
//     size to the nearest text style via @ScaledMetric.
//   • Adopt it screen-by-screen on TEXT (titles, body, captions). Leave fixed sizing on things
//     that must not reflow (badge circles, icon frames).
//
// Migration example:
//   Text("Grocery List").font(.system(size: 20, weight: .bold))
//     →  Text("Grocery List").scaledFont(20, weight: .bold)
//
// Nothing here changes existing views; it only adds the modifier.

import SwiftUI

extension View {
    /// Dynamic-Type-aware replacement for `.font(.system(size:weight:design:))`.
    func scaledFont(_ size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design))
    }
}

/// Maps a raw point size to the nearest built-in text style for relative scaling.
private func textStyle(forApprox size: CGFloat) -> Font.TextStyle {
    switch size {
    case ..<11.5:  return .caption2
    case ..<12.5:  return .caption
    case ..<14.5:  return .footnote
    case ..<16.5:  return .subheadline
    case ..<18:    return .body
    case ..<20:    return .callout
    case ..<23:    return .title3
    case ..<28:    return .title2
    case ..<34:    return .title
    default:       return .largeTitle
    }
}

/// Scales the given point size with the user's Dynamic Type setting, anchored to a text style.
private struct ScaledFontModifier: ViewModifier {
    @ScaledMetric var scaled: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: textStyle(forApprox: size))
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: scaled, weight: weight, design: design))
    }
}
