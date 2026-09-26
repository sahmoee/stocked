// DesignTokens.swift — Single source of truth for the Stocked. design system.
// ColorTheme.swift is DELETED. All views use these hex-defined tokens only.
import SwiftUI
import UIKit

/// Shared sizing for recipe tiles. Rows and detail heroes retain their own layouts.
nonisolated enum RecipeCardStyle {
    static let imageHeight: CGFloat = 120
    static let titleSize: CGFloat = 15
    static let metadataSize: CGFloat = 12
    static let padding: CGFloat = 12
    /// Recipe tiles are ordinary app cards, not a separate white design system.
    /// Keeping this routed through the semantic surface token makes every finder,
    /// browser, saved-recipe, and preview card change together in light/dark mode.
    static func surface(isDark: Bool) -> Color { Color.appSurface(isDark) }

    /// The three Recipes destinations form one visual row at standard text sizes.
    /// A shared minimum height prevents optional count copy from making My Collection
    /// look selected or oversized. Content may grow beyond this floor at every text size.
    static func destinationHeight(isAccessibilitySize: Bool) -> CGFloat? {
        isAccessibilitySize ? nil : 164
    }
}

// MARK: - Selectable light palette
nonisolated enum StockedLightTheme: String, CaseIterable, Codable, Sendable {
    case pastel = "Pastel"
    case tan = "Tan"
    static let defaultsKey = "stocked.lightTheme"
}

nonisolated struct StockedLightThemeTrait: UITraitDefinition {
    static let defaultValue = StockedLightTheme.pastel
    static let affectsColorAppearance = true
}

nonisolated struct StockedLightThemeKey: UITraitBridgedEnvironmentKey {
    static let defaultValue = StockedLightTheme.pastel
    static func read(from traitCollection: UITraitCollection) -> StockedLightTheme {
        traitCollection[StockedLightThemeTrait.self]
    }
    static func write(to mutableTraits: inout any UIMutableTraits, value: StockedLightTheme) {
        mutableTraits[StockedLightThemeTrait.self] = value
    }
}

extension EnvironmentValues {
    var stockedLightTheme: StockedLightTheme {
        get { self[StockedLightThemeKey.self] }
        set { self[StockedLightThemeKey.self] = newValue }
    }
}

nonisolated extension Color {
    /// UIKit trait bridging updates legacy colors, SwiftUI surfaces and presented controls together.
    static func stockedPalette(pastel: UIColor, tan: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle != .dark && traits[StockedLightThemeTrait.self] == .tan
                ? tan.resolvedColor(with: traits) : pastel.resolvedColor(with: traits)
        })
    }
}

// MARK: - Brand Colors
nonisolated extension Color {
    // Core backgrounds
    static let stockedBg        = stockedPalette(pastel: UIColor(red: 0.992, green: 0.969, blue: 0.937, alpha: 1), tan: UIColor(red: 0.780, green: 0.671, blue: 0.506, alpha: 1))
    static let stockedDarkBg    = Color(red: 0.086, green: 0.078, blue: 0.063) // #161410 OLED dark

    // Charcoal — buttons, tab bar, cards on tan
    static let stockedCharcoal  = stockedPalette(pastel: UIColor(red: 0.263, green: 0.224, blue: 0.184, alpha: 1), tan: UIColor(red: 0.176, green: 0.173, blue: 0.165, alpha: 1))

    // Gold — accent, active states, Find in Store, bolt
    static let stockedGold      = stockedPalette(pastel: UIColor(red: 0.573, green: 0.416, blue: 0.184, alpha: 1), tan: UIColor(red: 0.561, green: 0.392, blue: 0.075, alpha: 1))
    static let stockedGoldDark  = stockedPalette(pastel: UIColor(red: 0.835, green: 0.702, blue: 0.420, alpha: 1), tan: UIColor(red: 0.870, green: 0.680, blue: 0.290, alpha: 1))
    // Decorative gold is too faint for small labels on tan. Text/actions use a
    // deeper warm-gold shade; artwork, borders and brand illustrations keep their gold.
    static let textAccentLight  = stockedPalette(pastel: UIColor(red: 0.502, green: 0.373, blue: 0.192, alpha: 1), tan: UIColor(red: 0.263, green: 0.165, blue: 0.031, alpha: 1))
    /// Foreground-only accent for legacy screens without an AppSession color role.
    /// Keep fixed brand fills separate so white-on-gold buttons retain their contrast.
    static let stockedAccentInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.835, green: 0.702, blue: 0.420, alpha: 1)
            : (traits[StockedLightThemeTrait.self] == .tan ? UIColor(red: 0.263, green: 0.165, blue: 0.031, alpha: 1) : UIColor(red: 0.502, green: 0.373, blue: 0.192, alpha: 1))
    })

    // Success
    static let stockedGreen     = stockedPalette(pastel: UIColor(red: 0.337, green: 0.420, blue: 0.290, alpha: 1), tan: UIColor(red: 0.086, green: 0.298, blue: 0.141, alpha: 1))
    static let stockedSuccessInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.694, green: 0.784, blue: 0.627, alpha: 1)
            : (traits[StockedLightThemeTrait.self] == .tan ? UIColor(red: 0.086, green: 0.298, blue: 0.141, alpha: 1) : UIColor(red: 0.337, green: 0.420, blue: 0.290, alpha: 1))
    })

    // Text
    static let stockedBlack     = stockedPalette(pastel: UIColor(red: 0.239, green: 0.196, blue: 0.157, alpha: 1), tan: UIColor(red: 0.102, green: 0.090, blue: 0.071, alpha: 1))
    static let stockedWhite     = stockedPalette(pastel: UIColor(red: 1.000, green: 0.980, blue: 0.953, alpha: 1), tan: UIColor(red: 0.961, green: 0.949, blue: 0.922, alpha: 1))

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

    // Text-safe status inks (≥ 4.5:1 on the pastel canvas, the tan canvas and dark mode).
    // The fixed accents above stay for fills and icons; use these whenever the status
    // color IS the text, where the fixed accents measured 1.2–3.4:1.
    static let stockedErrorInk   = stockedStatusInk(pastel: (0.631, 0.165, 0.122), tan: (0.478, 0.102, 0.071), dark: (0.941, 0.541, 0.494))
    static let stockedWarningInk = stockedStatusInk(pastel: (0.541, 0.353, 0.043), tan: (0.369, 0.227, 0.016), dark: (0.949, 0.706, 0.369))
    static let stockedInfoInk    = stockedStatusInk(pastel: (0.122, 0.373, 0.604), tan: (0.090, 0.247, 0.400), dark: (0.549, 0.722, 0.902))

    static func stockedStatusInk(pastel: (Double, Double, Double), tan: (Double, Double, Double),
                                 dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark
                : (traits[StockedLightThemeTrait.self] == .tan ? tan : pastel)
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    // Adaptive helpers
    static func appBg(_ dark: Bool)      -> Color { dark ? stockedDarkBg  : stockedBg      }
    static func appText(_ dark: Bool)    -> Color { dark ? darkLabel      : stockedBlack   }
    // Secondary/supporting text. Solid (not opacity-based) so contrast is predictable.
    // Solid cocoa-gray supports readable body copy on every pastel surface.
    // Use session.themeSecondaryText instead of opacity-based body copy.
    static let secondaryLight = stockedPalette(pastel: UIColor(red: 0.388, green: 0.361, blue: 0.329, alpha: 1), tan: UIColor(red: 0.200, green: 0.184, blue: 0.157, alpha: 1))
    static let secondaryDark  = Color(red: 0.741, green: 0.722, blue: 0.690) // #BDB8B0
    static func appSecondary(_ dark: Bool) -> Color { dark ? secondaryDark : secondaryLight }
    static func appAccent(_ dark: Bool) -> Color { dark ? stockedGoldDark : textAccentLight }
    static func appSubtext(_ dark: Bool) -> Color { appSecondary(dark) }
    static func appButton(_ dark: Bool)  -> Color { dark ? Color(white: 0.22) : stockedCharcoal }
    // Ivory reading cards on the warm cream canvas; dark mode retains warm depth.
    // Pastel accents are separate fills so small text remains readable.
    static let lightSurface = stockedPalette(pastel: UIColor(red: 1.000, green: 0.984, blue: 0.965, alpha: 1), tan: UIColor(red: 0.890, green: 0.820, blue: 0.710, alpha: 1))
    static let darkElevatedSurface = Color(red: 0.176, green: 0.161, blue: 0.137) // #2D2923
    static func appSurface(_ dark: Bool) -> Color { dark ? darkElevatedSurface : lightSurface }

    /// High-contrast reciprocal accent for selected navigation and small focus treatments.
    static func contrastAccent(_ dark: Bool) -> Color { dark ? stockedWhite : stockedCharcoal }

    // Filled feature-choice tokens. Root navigation uses its warm translucent selection.
    static func selectedTabForeground(_ dark: Bool) -> Color { dark ? stockedGoldDark : stockedBg }
    static let selectedTabBackground = stockedCharcoal

    // MARK: Widget semantic roles
    // Home widgets use roles instead of literal colors so light/dark, increased
    // contrast, and Reduce Transparency remain one coherent theme contract.
    static func widgetSurface(_ dark: Bool, increasedContrast: Bool, reduceTransparency: Bool) -> Color {
        if dark { return increasedContrast ? Color(red: 0.205, green: 0.188, blue: 0.158) : darkElevatedSurface }
        if increasedContrast { return stockedPalette(pastel: UIColor(red: 0.965, green: 0.937, blue: 0.894, alpha: 1), tan: UIColor(red: 0.890, green: 0.820, blue: 0.710, alpha: 1)) }
        return reduceTransparency ? lightSurface : stockedPalette(
            pastel: UIColor(red: 1.000, green: 0.980, blue: 0.953, alpha: 0.92),
            tan: UIColor(red: 0.890, green: 0.820, blue: 0.710, alpha: 0.96))
    }

    static func widgetPrimaryText(_ dark: Bool) -> Color { appText(dark) }
    static func widgetSecondaryText(_ dark: Bool) -> Color { appSecondary(dark) }
    static func widgetDivider(_ dark: Bool, increasedContrast: Bool) -> Color {
        contrastAccent(dark).opacity(increasedContrast ? 0.72 : 0.22)
    }
    static func widgetPressedSurface(_ dark: Bool) -> Color {
        dark ? darkLabel.opacity(0.12) : stockedCharcoal.opacity(0.10)
    }
    static func widgetFocus(_ dark: Bool) -> Color { appAccent(dark) }
    static func widgetSuccess(_ dark: Bool) -> Color { dark ? stockedSuccess : stockedGreen }
    static func widgetWarning(_ dark: Bool) -> Color { dark ? stockedWarning : stockedGold }
    static func widgetFailure(_ dark: Bool) -> Color { stockedError }
}

/// Subtle family accents preserve a single Stocked identity while making the
/// user's pantry, cooking, shopping, and planning groups easier to scan.
enum StockedWidgetThemeFamily: String, CaseIterable, Identifiable {
    case pantry = "Pantry"
    case cooking = "Cooking"
    case shopping = "Shopping"
    case planning = "Planning"
    case tools = "Tools"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .pantry: "cabinet"
        case .cooking: "frying.pan"
        case .shopping: "cart"
        case .planning: "calendar"
        case .tools: "wand.and.sparkles"
        }
    }
    func accent(dark: Bool) -> Color {
        switch self {
        case .pantry: return dark ? .stockedGoldDark : .stockedGold
        case .cooking: return dark ? .stockedSuccess : .stockedGreen
        case .shopping: return .stockedInfo
        case .planning: return dark ? .stockedWarning : .stockedGold
        case .tools: return Color.contrastAccent(dark)
        }
    }
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
    /// App-linked replacement for SwiftUI's built-in semantic fonts. Native
    /// semantic values follow only the system category; this also follows the
    /// single Stocked in-app text preference.
    static func stocked(_ style: Font.TextStyle) -> Font {
        let specification: (size: CGFloat, weight: Font.Weight) = switch style {
        case .largeTitle: (34, .regular)
        case .title: (28, .regular)
        case .title2: (22, .regular)
        case .title3: (20, .regular)
        case .headline: (17, .semibold)
        case .subheadline: (15, .regular)
        case .callout: (16, .regular)
        case .footnote: (13, .regular)
        case .caption: (12, .regular)
        case .caption2: (11, .regular)
        default: (17, .regular)
        }
        let typeDesign: Font.Design = switch style {
        case .largeTitle, .title, .title2, .title3: .serif
        default: .default
        }
        return StockedType.font(
            size: specification.size,
            weight: specification.weight,
            design: typeDesign,
            relativeTo: style
        )
    }

    /// Dynamic-Type-aware compatibility constructor for geometry-dependent and conditional
    /// font expressions that cannot use the `scaledFont` view modifier directly.
    static func stockedSystem(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        StockedType.font(size: size, weight: weight, design: design)
    }

    /// The canonical Stocked font constructors. All semantic and compatibility
    /// typography APIs delegate here so Dynamic Type and the in-app interface-size
    /// preference cannot drift between screens.
    static func stockedSerif(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo style: Font.TextStyle? = nil
    ) -> Font {
        StockedType.font(size: size, weight: weight, design: .serif, relativeTo: style)
    }

    static func stockedSans(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo style: Font.TextStyle? = nil
    ) -> Font {
        StockedType.font(size: size, weight: weight, design: .default, relativeTo: style)
    }
}

// Scales a fixed point size with the current Dynamic Type setting, anchored to the nearest
// text style so larger raw sizes scale at the appropriate rate. Used by the stockedSerif and
// stockedSans helpers. UIFontMetrics is used (rather than ScaledMetric) so this works inside a
// plain function that returns a Font value.
enum StockedType {
    static let appTextSizePreferenceKey = "stocked.appTextSize"

    /// Resolve the one app-wide type family. Keeping this pure overload makes the preference
    /// mapping directly testable; the nil form reads the existing AppSession persistence key.
    static func appFontSelection(for rawValue: String? = nil) -> AppFont {
        let selected = rawValue ?? UserDefaults.standard.string(forKey: DBKey.appFont.rawValue)
        return AppFont(rawValue: selected ?? AppFont.serif.rawValue) ?? .serif
    }

    static func appTextScale(for rawValue: String? = nil) -> CGFloat {
        let selected = rawValue ?? UserDefaults.standard.string(forKey: appTextSizePreferenceKey)
        return (AppTextSize(rawValue: selected ?? AppTextSize.standard.rawValue) ?? .standard).multiplier
    }

    static func font(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo style: Font.TextStyle? = nil
    ) -> Font {
        // The standard editorial theme pairs serif headings with clean sans body copy.
        // Explicit Rounded/Monospace/System preferences still apply throughout the app.
        let selection = appFontSelection()
        return .system(size: scaled(size, relativeTo: style), weight: weight,
                       design: selection == .serif ? design : selection.design)
    }

    static func scaled(_ size: CGFloat, relativeTo style: Font.TextStyle? = nil) -> CGFloat {
        let uiStyle = style.map(uiKitStyle) ?? inferredUIKitStyle(for: size)
        return UIFontMetrics(forTextStyle: uiStyle)
            .scaledValue(for: size * appTextScale())
    }

    private static func inferredUIKitStyle(for size: CGFloat) -> UIFont.TextStyle {
        switch size {
        case ..<11.5: return .caption2
        case ..<12.5: return .caption1
        case ..<14.5: return .footnote
        case ..<16.5: return .subheadline
        case ..<18:   return .body
        case ..<20:   return .callout
        case ..<23:   return .title3
        case ..<28:   return .title2
        case ..<34:   return .title1
        default:      return .largeTitle
        }
    }

    private static func uiKitStyle(for style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title:      return .title1
        case .title2:     return .title2
        case .title3:     return .title3
        case .headline:   return .headline
        case .subheadline:return .subheadline
        case .callout:    return .callout
        case .caption:    return .caption1
        case .caption2:   return .caption2
        case .footnote:   return .footnote
        default:          return .body
        }
    }
}

// MARK: - Page background helper
nonisolated extension Color {
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
                Text(name).scaledFont(14, design: .monospaced).foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 6)
        }
    }
    .padding(.vertical, 20)
}
