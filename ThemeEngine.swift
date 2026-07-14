// ThemeEngine.swift — Computed color properties for AppSession.
// Custom 6-channel theming has been removed: the app now supports ONLY the standard
// light and dark appearance. These vars keep their original names (775+ call sites use
// them) but resolve from the light/dark design tokens, so every surface follows the
// system-style light/dark palette and the user's isDarkMode choice.
import SwiftUI

// MARK: - Computed theme colors (light/dark only)
extension AppSession {
    var accentColor:      Color { isDarkMode ? Color.stockedGoldDark : Color.stockedGold }
    var themeBgColor:     Color { Color.appBg(isDarkMode) }
    var themeButtonColor: Color { Color.appButton(isDarkMode) }
    var themeTextColor:   Color { Color.appText(isDarkMode) }
    var themeSecondaryText: Color { Color.appSecondary(isDarkMode) }
    var themeCardColor:   Color { Color.appSurface(isDarkMode) }
    var themeTabColor:    Color { isDarkMode ? Color.stockedCharcoal : Color.stockedCharcoal }
    var isAppleStockTheme: Bool { true }
}
