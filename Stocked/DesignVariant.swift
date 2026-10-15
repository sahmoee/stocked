// DesignVariant.swift — Optional whole-app design variants layered over the existing theme.
//
// `current` is the shipped Pastel/Tan design and is always the default. The other variants
// (Pantry Journal, Kitchen Standard, Evening Table) re-map the existing semantic color
// tokens, typography roles and component geometry; they never rewrite the stored Light
// Theme, Dark Mode or App Font preferences, so returning to `current` restores them exactly.
import SwiftUI
import UIKit

// MARK: - Selection

nonisolated enum StockedDesignVariant: String, CaseIterable, Codable, Sendable, Identifiable {
    case current
    case pantryJournal
    case kitchenStandard
    case eveningTable

    /// Same key in the app's standard defaults and the shared App Group (widgets).
    static let defaultsKey = "stocked.designVariant"
    static let appGroupSuite = "group.com.sowens.Stocked"

    var id: String { rawValue }

    /// Missing, empty, or unknown values (for example from a newer build or a corrupt
    /// backup) always fall back to the shipped design rather than failing.
    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .current
    }

    /// The persisted selection. Typography and geometry helpers that have no environment
    /// (static font constructors, StockedUI constants) read this, like App Font does.
    static var active: StockedDesignVariant {
        StockedDesignVariant(storedValue: UserDefaults.standard.string(forKey: defaultsKey))
    }

    var title: String {
        switch self {
        case .current:         return "Current"
        case .pantryJournal:   return "Pantry Journal"
        case .kitchenStandard: return "Kitchen Standard"
        case .eveningTable:    return "Evening Table"
        }
    }

    var summary: String {
        switch self {
        case .current:         return "The Stocked design you know, with your Light Theme and Dark Mode choices."
        case .pantryJournal:   return "Warm cream, forest-green actions, serif headings and roomy grouped lists."
        case .kitchenStandard: return "Crisp white and green, system type, compact sections and squared controls."
        case .eveningTable:    return "Dark stone and brass, serif titles, with tonight's meal first."
        }
    }

    /// Evening Table is a dark composition; it shows dark regardless of the stored Dark
    /// Mode preference, which is kept untouched for the other designs.
    var forcesDarkAppearance: Bool { self == .eveningTable }

    /// Whether the Pastel/Tan light palette is visible in this design.
    var usesLegacyLightTheme: Bool { self == .current }

    var geometry: StockedVariantGeometry? {
        switch self {
        case .current:         return nil
        case .pantryJournal:   return StockedVariantGeometry(component: 16, chip: 10, sheet: 22, heroArtworkHeight: 96, showsHeroArtwork: true, compactSections: false)
        case .kitchenStandard: return StockedVariantGeometry(component: 8, chip: 4, sheet: 10, heroArtworkHeight: 0, showsHeroArtwork: false, compactSections: true)
        case .eveningTable:    return StockedVariantGeometry(component: 12, chip: 8, sheet: 16, heroArtworkHeight: 0, showsHeroArtwork: false, compactSections: false)
        }
    }

    func palette(dark: Bool) -> StockedVariantPalette? {
        switch self {
        case .current:         return nil
        case .pantryJournal:   return dark ? .pantryJournalDark : .pantryJournal
        case .kitchenStandard: return dark ? .kitchenStandardDark : .kitchenStandard
        case .eveningTable:    return .eveningTable
        }
    }

    /// Typeface for a requested design role when the user keeps the default (Serif) App
    /// Font. Explicit Rounded/Monospace/System choices are never overridden. `nil` means
    /// "use the existing behavior".
    func typeface(for requested: Font.Design) -> StockedVariantTypeface? {
        switch (self, requested) {
        case (.pantryJournal, .serif):    return .custom("Georgia")
        case (.pantryJournal, .default):  return .custom("AvenirNext-Regular")
        case (.kitchenStandard, .serif),
             (.kitchenStandard, .default): return .system(.default)
        case (.eveningTable, .serif):     return .custom("Georgia")
        case (.eveningTable, .default):   return .system(.default)
        default:                          return nil
        }
    }

    /// Persist to both the app and the App Group so widgets/extensions can follow along.
    func persist(to standard: UserDefaults = .standard,
                 group: UserDefaults? = UserDefaults(suiteName: StockedDesignVariant.appGroupSuite)) {
        standard.set(rawValue, forKey: Self.defaultsKey)
        group?.set(rawValue, forKey: Self.defaultsKey)
    }
}

nonisolated enum StockedVariantTypeface: Equatable, Sendable {
    case system(Font.Design)
    case custom(String)
}

nonisolated struct StockedVariantGeometry: Equatable, Sendable {
    /// Cards, fields, buttons and grouped sections.
    var component: CGFloat
    /// Badges, chips and status labels.
    var chip: CGFloat
    /// Sheets, large overlays and feature panels.
    var sheet: CGFloat
    /// Editorial hero artwork height. Variants keep heroes short so content appears sooner.
    var heroArtworkHeight: CGFloat
    var showsHeroArtwork: Bool
    /// Kitchen Standard uses compact section bars and denser lists.
    var compactSections: Bool
}

// MARK: - Palette

nonisolated enum StockedColorRole: CaseIterable, Sendable {
    case bg, surface, ink, muted, line
    /// Text/icon/tint accent and the primary action fill.
    case accent
    /// Legacy decorative fills that carry light labels (gold/charcoal fills in the current design).
    case fill
    /// Label color on the primary action (`accent`) fill.
    case onAccent
    /// Light label/surface used where the current design used ivory.
    case ivory
    case soft, softWarm
    case warn, danger, success
    /// Legacy charcoal: dark controls and strong text in light, deep fill in dark.
    case button
}

nonisolated struct StockedVariantPalette: Equatable, Sendable {
    let bg: UInt32, surface: UInt32, ink: UInt32, muted: UInt32, line: UInt32
    let accent: UInt32, fill: UInt32, onAccent: UInt32, ivory: UInt32
    let soft: UInt32, softWarm: UInt32
    let warn: UInt32, danger: UInt32, success: UInt32
    let button: UInt32

    func hex(_ role: StockedColorRole) -> UInt32 {
        switch role {
        case .bg: bg
        case .surface: surface
        case .ink: ink
        case .muted: muted
        case .line: line
        case .accent: accent
        case .fill: fill
        case .onAccent: onAccent
        case .ivory: ivory
        case .soft: soft
        case .softWarm: softWarm
        case .warn: warn
        case .danger: danger
        case .success: success
        case .button: button
        }
    }

    func uiColor(_ role: StockedColorRole) -> UIColor { UIColor(stockedHex: hex(role)) }
    func color(_ role: StockedColorRole) -> Color { Color(uiColor: uiColor(role)) }

    // Values from the approved design contracts (StockedDesign-20261014/*/DESIGN.md).
    // `fill`, `ivory`, `softWarm`, `success`, `button` and the dark variants are derived
    // so legacy fills keep at least 4.5:1 against their labels.
    static let pantryJournal = StockedVariantPalette(
        bg: 0xF5F0E7, surface: 0xFFFCF6, ink: 0x2B3028, muted: 0x626A5B, line: 0xDCDCCF,
        accent: 0x36533C, fill: 0x36533C, onAccent: 0xFFFCF6, ivory: 0xFFFCF6,
        soft: 0xE8EBDD, softWarm: 0xF3E7DA, warn: 0x9A4C2E, danger: 0xA83736, success: 0x3D6B47,
        button: 0x2B3028)
    static let pantryJournalDark = StockedVariantPalette(
        bg: 0x181C17, surface: 0x222821, ink: 0xF1EEE4, muted: 0xB7BEAD, line: 0x3D473B,
        accent: 0xA9C79F, fill: 0x4A7352, onAccent: 0x181C17, ivory: 0xF1EEE4,
        soft: 0x2B3529, softWarm: 0x3A2F27, warn: 0xE8B08A, danger: 0xF2A6A0, success: 0x9FD0A0,
        button: 0x2B3529)
    static let kitchenStandard = StockedVariantPalette(
        bg: 0xF2F5F1, surface: 0xFFFFFF, ink: 0x182C24, muted: 0x55675E, line: 0xCCD8D0,
        accent: 0x195A47, fill: 0x195A47, onAccent: 0xFFFFFF, ivory: 0xFFFFFF,
        soft: 0xE3EEE7, softWarm: 0xF5EDE3, warn: 0x8B4E17, danger: 0xAD3438, success: 0x2E7D4F,
        button: 0x182C24)
    static let kitchenStandardDark = StockedVariantPalette(
        bg: 0x0F1714, surface: 0x18221E, ink: 0xEEF4F0, muted: 0xA6B8AF, line: 0x2F3F38,
        accent: 0x79C6A9, fill: 0x2C6E58, onAccent: 0x0F1714, ivory: 0xEEF4F0,
        soft: 0x1F2D27, softWarm: 0x33291F, warn: 0xE6B27A, danger: 0xF3A3A6, success: 0x8FD3A8,
        button: 0x1F2D27)
    static let eveningTable = StockedVariantPalette(
        bg: 0x1B211E, surface: 0x252D28, ink: 0xF4F0E6, muted: 0xB6C1B8, line: 0x445148,
        accent: 0xD9B990, fill: 0x7F6139, onAccent: 0x1B211E, ivory: 0xF4F0E6,
        soft: 0x354338, softWarm: 0x3B342A, warn: 0xE4B787, danger: 0xF2ADA6, success: 0xA9D3AE,
        button: 0x354338)
}

nonisolated extension UIColor {
    convenience init(stockedHex hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Trait bridging (mirrors StockedLightTheme)

nonisolated struct StockedDesignVariantTrait: UITraitDefinition {
    static let defaultValue = StockedDesignVariant.current
    static let affectsColorAppearance = true
}

nonisolated struct StockedDesignVariantKey: UITraitBridgedEnvironmentKey {
    static let defaultValue = StockedDesignVariant.current
    static func read(from traitCollection: UITraitCollection) -> StockedDesignVariant {
        traitCollection[StockedDesignVariantTrait.self]
    }
    static func write(to mutableTraits: inout any UIMutableTraits, value: StockedDesignVariant) {
        mutableTraits[StockedDesignVariantTrait.self] = value
    }
}

extension EnvironmentValues {
    var stockedDesignVariant: StockedDesignVariant {
        get { self[StockedDesignVariantKey.self] }
        set { self[StockedDesignVariantKey.self] = newValue }
    }
}

nonisolated extension Color {
    /// A semantic token that resolves to the active variant's role, or to the existing
    /// legacy color when the `current` design is selected (or no trait is available).
    static func stockedVariantAware(_ role: StockedColorRole, legacy: UIColor) -> Color {
        Color(uiColor: UIColor.stockedVariantAware(role, legacy: legacy))
    }
}

nonisolated extension UIColor {
    static func stockedVariantAware(_ role: StockedColorRole, legacy: UIColor) -> UIColor {
        UIColor { traits in
            if let palette = traits[StockedDesignVariantTrait.self]
                .palette(dark: traits.userInterfaceStyle == .dark) {
                return palette.uiColor(role)
            }
            return legacy.resolvedColor(with: traits)
        }
    }
}

// MARK: - Session helpers

extension AppSession {
    /// Active variant palette for the current appearance, or nil for the shipped design.
    var variantPalette: StockedVariantPalette? { designVariant.palette(dark: isDarkMode) }
    var variantGeometry: StockedVariantGeometry? { designVariant.geometry }
}
