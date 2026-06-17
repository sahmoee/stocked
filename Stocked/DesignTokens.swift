// DesignTokens.swift — Single source of truth for the Stocked. design system.
// ColorTheme.swift is DELETED. All views use these hex-defined tokens only.
import SwiftUI

// MARK: - Brand Colors
extension Color {
    // Core backgrounds
    static let stockedBg        = Color(red: 0.780, green: 0.671, blue: 0.506) // #C7AB81 warm tan
    static let stockedDarkBg    = Color(red: 0.086, green: 0.078, blue: 0.063) // #161410 OLED dark

    // Charcoal — buttons, tab bar, cards on tan
    static let stockedCharcoal  = Color(red: 0.176, green: 0.173, blue: 0.165) // #2D2C2A

    // Gold — accent, active states, Find in Store, bolt
    static let stockedGold      = Color(red: 0.635, green: 0.447, blue: 0.102) // #A27219
    static let stockedGoldDark  = Color(red: 0.800, green: 0.592, blue: 0.188) // #CC9730 on dark bg

    // Success
    static let stockedGreen     = Color(red: 0.118, green: 0.502, blue: 0.196) // #1E8032

    // Text
    static let stockedBlack     = Color(red: 0.102, green: 0.090, blue: 0.071) // #1A1712
    static let stockedWhite     = Color(red: 0.961, green: 0.949, blue: 0.922) // #F5F2EB off-white

    // Dark mode surface
    static let darkSurface      = Color(red: 0.129, green: 0.118, blue: 0.102) // #211E1A
    static let darkLabel        = Color(red: 0.949, green: 0.929, blue: 0.898) // #F2EDE5

    // Semantic status colors — canonical accents for info / success / warning / error.
    // These replace ad-hoc one-off blues/greens/ambers/reds across functional UI so status
    // styling is consistent. (Brand stockedGold/stockedGreen are separate and unchanged.
    // The decorative per-entry icon colors in AppChangelog are intentionally NOT these.)
    static let stockedInfo      = Color(red: 0.231, green: 0.510, blue: 0.769) // #3B82C4 iCloud/info blue
    static let stockedSuccess   = Color(red: 0.180, green: 0.620, blue: 0.349) // #2E9E59 confirm/success green
    static let stockedWarning   = Color(red: 0.851, green: 0.557, blue: 0.169) // #D98E2B caution amber
    static let stockedError     = Color(red: 0.753, green: 0.224, blue: 0.169) // #C0392B error/offline red

    // Adaptive helpers
    static func appBg(_ dark: Bool)      -> Color { dark ? stockedDarkBg  : stockedBg      }
    static func appText(_ dark: Bool)    -> Color { dark ? darkLabel      : stockedBlack   }
    static func appSubtext(_ dark: Bool) -> Color { dark ? darkLabel.opacity(0.55) : stockedBlack.opacity(0.55) }
    static func appButton(_ dark: Bool)  -> Color { dark ? Color(white: 0.22) : stockedCharcoal }
    static func appSurface(_ dark: Bool) -> Color { dark ? darkSurface    : stockedWhite.opacity(0.30) }
}

// MARK: - Corner Radii
enum StockedRadius {
    static let sm:  CGFloat = 10
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 24
    static let xl:  CGFloat = 30
    static let pill: CGFloat = 100  // full capsule
}

// MARK: - Spacing
enum StockedSpacing {
    static let xs:  CGFloat = 6
    static let sm:  CGFloat = 12
    static let md:  CGFloat = 20
    static let lg:  CGFloat = 28
    static let xl:  CGFloat = 40
}

// MARK: - Typography helpers
extension Font {
    static func stockedSerif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func stockedSans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

// MARK: - Page background helper
extension Color {
    static func pageBg(_ dark: Bool) -> Color {
        dark ? Color.stockedDarkBg : Color.stockedBg
    }
}

// MARK: - Preview
#Preview("Color Palette") {
    VStack(spacing: 0) {
        ForEach([
            ("stockedBg",       Color.stockedBg),
            ("stockedDarkBg",   Color.stockedDarkBg),
            ("stockedCharcoal", Color.stockedCharcoal),
            ("stockedGold",     Color.stockedGold),
            ("stockedGreen",    Color.stockedGreen),
            ("stockedBlack",    Color.stockedCharcoal),
            ("stockedWhite",    Color.stockedWhite),
        ], id: \.0) { name, color in
            HStack {
                color.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                Text(name).font(.system(size: 14, design: .monospaced)).foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 6)
        }
    }
    .padding(.vertical, 20)
}
