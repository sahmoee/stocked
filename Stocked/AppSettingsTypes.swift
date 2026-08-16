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

/// App-wide control density. The default is deliberately comfortable so large
/// phones and iPads do not inherit an undersized phone layout, while the user can
/// still choose a denser presentation without changing the system text setting.
enum InterfaceSize: String, Codable, CaseIterable {
    case standard = "Standard"
    case comfortable = "Comfortable"
    case large = "Large"

    var scale: CGFloat {
        switch self {
        case .standard: return 1.0
        case .comfortable: return 1.08
        case .large: return 1.16
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
