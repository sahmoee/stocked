// AppSettingsTypes.swift — value types extracted from AppSession.swift (#8/#9 split).
// Settings/preference enums + small Codable structs. Pure value types, no dependencies on the
// store classes, so they live on their own.
import SwiftUI
import Combine
import os
@preconcurrency import UserNotifications

// MARK: - Cook Button Shape
// MARK: - App Theme
// MARK: - Smart grocery item preference (remembers zone, unit, brand per item)
struct ItemPreference: Codable {
    var zone:  String = "Fridge"
    var unit:  String = ""
    var brand: String = ""
    var addCount: Int  = 1    // how many times added — promotes to default after 2+
}

enum AppTheme: String, Codable, CaseIterable {
    case tan    = "Classic"
    case custom = "Custom"
}

enum AppFont: String, Codable, CaseIterable {
    case serif   = "Serif"
    case rounded = "Rounded"
    case mono    = "Monospace"
    case system  = "System"

    var design: Font.Design {
        switch self {
        case .serif:   return .serif
        case .rounded: return .rounded
        case .mono:    return .monospaced
        case .system:  return .default
        }
    }
}

/// App-wide typography adjustment, independent of the device's Dynamic Type
/// category. System Dynamic Type still applies on top of this preference.
enum AppTextSize: String, Codable, CaseIterable, Identifiable {
    case extraSmall = "XS"
    case small = "Small"
    case standard = "Standard"
    case medium = "Medium"
    case large = "Large"
    case extraLarge = "XL"
    case extraExtraLarge = "XXL"

    var id: String { rawValue }
    var multiplier: CGFloat {
        switch self {
        case .extraSmall: 0.82
        case .small: 0.9
        // Standard remains the geometry baseline, but the type baseline is slightly
        // larger so the default is comfortably readable on Pro Max and iPad screens.
        case .standard: 1.06
        case .medium: 1.1
        case .large: 1.22
        case .extraLarge: 1.36
        case .extraExtraLarge: 1.52
        }
    }
}

/// The single supported interface density. Typography is adjusted independently
/// so controls can retain their placement while growing vertically around text.
enum InterfaceSize: String, Codable, CaseIterable {
    case standard = "Standard"

    var scale: CGFloat { 1 }
}

/// Home-only spacing density. This never changes typography or the four-track
/// placement contract; it only tunes internal breathing room and grid gutters.
enum HomeWidgetDensity: String, Codable, CaseIterable, Identifiable {
    case comfortable = "Comfortable"
    case standard = "Standard"
    case compact = "Compact"

    var id: String { rawValue }
    var spacingScale: CGFloat {
        switch self {
        case .comfortable: 1.16
        case .standard: 1
        case .compact: 0.84
        }
    }
}

enum CookButtonShape: String, Codable, CaseIterable {
    case circle      = "Circle"
    case pill        = "Pill"
    case roundedRect = "Rounded Square"
}

enum HomeButtonLayout: String, Codable, CaseIterable {
    case vertical   = "Vertical"
    case horizontal = "Horizontal"
}

enum HapticIntensity: String, Codable, CaseIterable {
    case off    = "Off"
    case light  = "Light"
    case medium = "Medium"
    case strong = "Strong"

    func fire(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard self != .off else { return }
        let s: UIImpactFeedbackGenerator.FeedbackStyle
        switch self {
        case .off:    return
        case .light:  s = .light
        case .medium: s = .medium
        case .strong: s = .heavy
        }
        UIImpactFeedbackGenerator(style: s).impactOccurred()
    }
}

enum BackupFrequency: String, Codable, CaseIterable {
    case manual  = "Manual"
    case daily   = "Daily"
    case weekly  = "Weekly"
}


// MARK: - Background
enum AppBackground: Codable, Equatable {
    case defaultTan
    case color(Double, Double, Double)
    case photo(Data)

    private enum CK: String, CodingKey { case type, r, g, b, data }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CK.self)
        switch self {
        case .defaultTan: try c.encode("tan", forKey: .type)
        case .color(let r, let g, let b):
            try c.encode("color", forKey: .type)
            try c.encode(r, forKey: .r); try c.encode(g, forKey: .g); try c.encode(b, forKey: .b)
        case .photo(let d):
            try c.encode("photo", forKey: .type); try c.encode(d, forKey: .data)
        }
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CK.self)
        switch try c.decode(String.self, forKey: .type) {
        case "color":
            self = .color(try c.decode(Double.self, forKey: .r),
                          try c.decode(Double.self, forKey: .g),
                          try c.decode(Double.self, forKey: .b))
        case "photo": self = .photo(try c.decode(Data.self, forKey: .data))
        default:      self = .defaultTan
        }
    }
}
