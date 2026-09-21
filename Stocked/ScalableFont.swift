// ScalableFont.swift — #5 Dynamic Type foundation.
//
// Single linked typography path for custom point sizes. Both system Dynamic Type and
// Stocked's in-app text preference are applied by StockedType, so pages, sheets, controls,
// button labels, and flows update together.

import SwiftUI

extension View {
    /// App- and Dynamic-Type-aware replacement for a raw point-size font.
    nonisolated func scaledFont(_ size: CGFloat,
                               weight: Font.Weight = .regular,
                               design: Font.Design = .default) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design))
    }

    /// Root policy for controls and containers throughout the app. It intentionally does not
    /// cap Dynamic Type: standard buttons, fields, pickers, lists, alerts, and sheets inherit
    /// larger control geometry while custom text uses `scaledFont` above.
    func stockedAdaptiveInterface() -> some View {
        modifier(StockedAdaptiveInterfaceModifier())
    }
}

private struct StockedAdaptiveInterfaceModifier: ViewModifier {
    @Environment(\.stockedLayout) private var layoutMetrics
    @ScaledMetric(relativeTo: .body) private var minimumControlHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .headline) private var minimumHeaderHeight: CGFloat = 28

    private var adaptiveControlSize: ControlSize {
        if layoutMetrics.textScale >= 1.65 { return .extraLarge }
        if layoutMetrics.textScale >= 1.12 { return .large }
        return .regular
    }

    func body(content: Content) -> some View {
        content
            .controlSize(adaptiveControlSize)
            .buttonBorderShape(.roundedRectangle(radius: layoutMetrics.controlCornerRadius))
            .environment(\.defaultMinListRowHeight,
                         max(layoutMetrics.minimumControlHeight, minimumControlHeight))
            .environment(\.defaultMinListHeaderHeight,
                         max(24 * min(layoutMetrics.textScale, 1.6), minimumHeaderHeight))
    }
}

/// Maps a raw point size to the nearest built-in text style for relative scaling.
nonisolated private func textStyle(forApprox size: CGFloat) -> Font.TextStyle {
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
    @AppStorage(StockedType.appTextSizePreferenceKey) private var appTextSizeRaw = AppTextSize.standard.rawValue
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    nonisolated init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _appTextSizeRaw = AppStorage(wrappedValue: "Standard", "stocked.appTextSize")
        self.size = size
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        _ = appTextSizeRaw // Observe the shared preference and invalidate every label together.
        return content.font(StockedType.font(
            size: size,
            weight: weight,
            design: design,
            relativeTo: textStyle(forApprox: size)
        ))
    }
}
