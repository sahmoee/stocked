// ThemeEngine.swift — Computed color properties for AppSession.
// The Current design keeps Pastel/Tan and the user's dark preference. Optional
// Journal, Standard and Evening variants resolve through the same semantic tokens.
// Existing call sites retain their names; arbitrary custom color channels stay removed.
import SwiftUI

// MARK: - Semantic theme colors
extension AppSession {
    var accentColor:      Color { Color.appAccent(isDarkMode) }
    var themeBgColor:     Color { Color.appBg(isDarkMode) }
    /// Variants use their action fill (paired with ivory labels at existing call sites).
    var themeButtonColor: Color { variantPalette?.color(.fill) ?? Color.appButton(isDarkMode) }
    var themeTextColor:   Color { Color.appText(isDarkMode) }
    var themeSecondaryText: Color { Color.appSecondary(isDarkMode) }
    var themeCardColor:   Color { Color.appSurface(isDarkMode) }
    var themeContrastAccent: Color { Color.contrastAccent(isDarkMode) }
    var themeTabColor:    Color { themeCardColor }
    var isAppleStockTheme: Bool { true }
}
