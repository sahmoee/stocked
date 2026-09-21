import SwiftUI

/// Stocked's native glass vocabulary. Reading surfaces stay matte; glass belongs
/// to navigation and controls floating above the kitchen's content.
enum StockedGlassRole: Sendable {
    case navigation
    case control
}

enum StockedGlassKit {
    static func tint(for role: StockedGlassRole, dark: Bool) -> Color {
        switch role {
        case .navigation: Color.appBg(dark).opacity(dark ? 0.62 : 0.36)
        case .control: Color.appSurface(dark).opacity(dark ? 0.48 : 0.22)
        }
    }

    static func opaqueSurface(for role: StockedGlassRole, dark: Bool) -> Color {
        switch role {
        case .navigation: Color.appBg(dark)
        case .control: Color.appSurface(dark)
        }
    }
}

private struct StockedGlassSurface: ViewModifier {
    @Environment(AppSession.self) private var session
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.stockedMotion) private var motion
    let role: StockedGlassRole
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content
                .background(StockedGlassKit.opaqueSurface(for: role, dark: session.isDarkMode), in: shape)
                .overlay {
                    shape.strokeBorder(session.themeSecondaryText.opacity(contrast == .increased ? 0.8 : 0.35),
                                       lineWidth: contrast == .increased ? 1.5 : 1)
                        .allowsHitTesting(false)
                }
        } else {
            content.glassEffect(
                .regular
                    .tint(tint ?? StockedGlassKit.tint(for: role, dark: session.isDarkMode))
                    .interactive(interactive && isEnabled && motion.permitsSpatialMotion),
                in: shape
            )
        }
    }
}

/// A single sampling container for neighboring glass controls, with no new
/// layout or animation policy. Accessibility fallbacks avoid blur entirely.
struct StockedGlassGroup<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if reduceTransparency || contrast == .increased {
            content()
        } else {
            GlassEffectContainer(spacing: spacing) { content() }
        }
    }
}

extension View {
    func stockedGlassSurface(
        _ role: StockedGlassRole = .control,
        cornerRadius: CGFloat = StockedRadius.md,
        tint: Color? = nil,
        interactive: Bool = true
    ) -> some View {
        modifier(StockedGlassSurface(role: role, cornerRadius: cornerRadius,
                                    tint: tint, interactive: interactive))
    }
}
