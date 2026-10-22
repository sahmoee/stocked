import XCTest
import SwiftUI
import UIKit
@testable import Stocked

/// Optional design variants must never change the shipped design by default, must persist
/// and back up additively, and must tolerate old or unknown stored values.
@MainActor
final class DesignVariantTests: XCTestCase {
    // AppSession is an app-lifetime owner. Retain bounded fixtures for this suite rather
    // than testing unrelated service teardown here (Swift 6.2 Intel runtime currently
    // crashes releasing nested actor schedulers; tracked separately in the task report).
    private static var appLifetimeFixtures: [AppSession] = []
    private func makeSession() -> AppSession {
        let session = AppSession()
        Self.appLifetimeFixtures.append(session)
        return session
    }

    private let keys = [StockedDesignVariant.defaultsKey, DBKey.darkMode.rawValue,
                        StockedLightTheme.defaultsKey, DBKey.appFont.rawValue]
    private var saved: [String: Any] = [:]
    private var savedGroupVariant: String?
    private var savedGroupLightTheme: String?
    private var group: UserDefaults? { UserDefaults(suiteName: StockedDesignVariant.appGroupSuite) }

    override func setUp() {
        super.setUp()
        saved = [:]
        for key in keys { if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value } }
        savedGroupVariant = group?.string(forKey: StockedDesignVariant.defaultsKey)
        savedGroupLightTheme = group?.string(forKey: StockedLightTheme.defaultsKey)
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        if let savedGroupVariant { group?.set(savedGroupVariant, forKey: StockedDesignVariant.defaultsKey) }
        else { group?.removeObject(forKey: StockedDesignVariant.defaultsKey) }
        if let savedGroupLightTheme { group?.set(savedGroupLightTheme, forKey: StockedLightTheme.defaultsKey) }
        else { group?.removeObject(forKey: StockedLightTheme.defaultsKey) }
        super.tearDown()
    }

    // MARK: Retired-design migration

    func testOnlyStandardDesignIsSelectable() {
        XCTAssertEqual(StockedDesignVariant.allCases, [.current])
        for value in [nil, "", "current", "pantryJournal", "kitchenStandard", "eveningTable", "futureDesign"] as [String?] {
            XCTAssertEqual(StockedDesignVariant(storedValue: value), .current)
        }
    }

    func testRetiredDesignsMigrateAppAndWidgetsWithoutChangingAppearancePreferences() {
        for retired in ["pantryJournal", "kitchenStandard", "eveningTable"] {
            UserDefaults.standard.set(retired, forKey: StockedDesignVariant.defaultsKey)
            group?.set(retired, forKey: StockedDesignVariant.defaultsKey)
            UserDefaults.standard.set(false, forKey: DBKey.darkMode.rawValue)
            UserDefaults.standard.set(StockedLightTheme.tan.rawValue, forKey: StockedLightTheme.defaultsKey)
            UserDefaults.standard.set(AppFont.rounded.rawValue, forKey: DBKey.appFont.rawValue)
            let session = makeSession()
            XCTAssertEqual(session.designVariant, .current)
            XCTAssertEqual(UserDefaults.standard.string(forKey: StockedDesignVariant.defaultsKey), "current")
            XCTAssertEqual(group?.string(forKey: StockedDesignVariant.defaultsKey), "current")
            XCTAssertFalse(session.isDarkMode)
            XCTAssertEqual(session.lightTheme, .tan)
            XCTAssertEqual(session.appFont, .rounded)
        }
    }

    func testRetiredSelectionsCannotBeReactivatedByOlderCallers() {
        let session = makeSession()
        for retired in [StockedDesignVariant.pantryJournal, .kitchenStandard, .eveningTable] {
            session.designVariant = retired
            XCTAssertEqual(session.designVariant, .current)
            XCTAssertEqual(UserDefaults.standard.string(forKey: StockedDesignVariant.defaultsKey), "current")
            XCTAssertEqual(group?.string(forKey: StockedDesignVariant.defaultsKey), "current")
        }
    }

    func testRestoringRetiredDesignBackupKeepsIndependentPreferences() throws {
        let session = makeSession()
        var prefs = session.capturePreferences()
        prefs.designVariant = "eveningTable"
        prefs.isDarkMode = false
        prefs.lightTheme = StockedLightTheme.tan.rawValue
        let decoded = try JSONDecoder().decode(KitchenPreferences.self, from: JSONEncoder().encode(prefs))
        session.applyPreferences(decoded)
        XCTAssertEqual(session.designVariant, .current)
        XCTAssertFalse(session.isDarkMode)
        XCTAssertEqual(session.lightTheme, .tan)
        XCTAssertEqual(session.capturePreferences().designVariant, "current")
    }

    // MARK: Variant mapping

    func testVariantMapping() {
        XCTAssertNil(StockedDesignVariant.current.palette(dark: false))
        XCTAssertNil(StockedDesignVariant.current.palette(dark: true))
        XCTAssertNil(StockedDesignVariant.current.geometry)
        XCTAssertEqual(StockedDesignVariant.pantryJournal.geometry?.component, 16)
        XCTAssertEqual(StockedDesignVariant.kitchenStandard.geometry?.component, 8)
        XCTAssertEqual(StockedDesignVariant.eveningTable.geometry?.component, 12)
        XCTAssertTrue(StockedDesignVariant.kitchenStandard.geometry?.compactSections ?? false)
        XCTAssertTrue(StockedDesignVariant.eveningTable.forcesDarkAppearance)
        XCTAssertFalse(StockedDesignVariant.pantryJournal.forcesDarkAppearance)

        // Contract colors from the approved mockups.
        XCTAssertEqual(StockedDesignVariant.pantryJournal.palette(dark: false)?.accent, 0x36533C)
        XCTAssertEqual(StockedDesignVariant.pantryJournal.palette(dark: false)?.bg, 0xF5F0E7)
        XCTAssertEqual(StockedDesignVariant.kitchenStandard.palette(dark: false)?.accent, 0x195A47)
        XCTAssertEqual(StockedDesignVariant.eveningTable.palette(dark: false)?.bg, 0x1B211E)
        XCTAssertEqual(StockedDesignVariant.eveningTable.palette(dark: true)?.accent, 0xD9B990)

        // Typography applies only to editorial roles; explicit designs are untouched.
        XCTAssertEqual(StockedDesignVariant.pantryJournal.typeface(for: .serif), .custom("Georgia"))
        XCTAssertEqual(StockedDesignVariant.pantryJournal.typeface(for: .default), .custom("AvenirNext-Regular"))
        XCTAssertEqual(StockedDesignVariant.kitchenStandard.typeface(for: .serif), .system(.default))
        XCTAssertEqual(StockedDesignVariant.eveningTable.typeface(for: .serif), .custom("Georgia"))
        XCTAssertNil(StockedDesignVariant.current.typeface(for: .serif))
        XCTAssertNil(StockedDesignVariant.pantryJournal.typeface(for: .monospaced))
    }

    func testVariantFontFamiliesExistOnDevice() {
        XCTAssertFalse(UIFont.fontNames(forFamilyName: "Georgia").isEmpty)
        XCTAssertFalse(UIFont.fontNames(forFamilyName: "Avenir Next").isEmpty)
        XCTAssertNotNil(UIFont(name: "AvenirNext-Regular", size: 14))
        for weight: Font.Weight in [.regular, .medium, .semibold, .bold, .heavy] {
            let face = StockedType.weightedCustomFace("AvenirNext-Regular", weight: weight)
            XCTAssertNotNil(face.flatMap { UIFont(name: $0, size: 14) })
        }
        XCTAssertEqual(StockedType.weightedCustomFace("AvenirNext-Regular", weight: .semibold), "AvenirNext-DemiBold")
        XCTAssertEqual(StockedType.weightedCustomFace("Georgia", weight: .bold), "Georgia-Bold")
    }

    func testGroceryLabelOnlyCustomizationKeepsContrastInEveryDesign() {
        for variant in StockedDesignVariant.allCases {
            for preference in [false, true] {
                let dark = preference || variant.forcesDarkAppearance
                let palette = variant.palette(dark: dark)
                let traits = UITraitCollection {
                    $0.userInterfaceStyle = dark ? .dark : .light
                    $0[StockedDesignVariantTrait.self] = variant
                }
                traits.performAsCurrent {
                    // Same label-only customization used by Grocery's Start Shopping.
                    let label = Color.selectedTabForeground(dark)
                    let fill = StockedPrimaryButtonStyle.fillColor(palette: palette, explicitLabel: label)
                    XCTAssertGreaterThanOrEqual(contrast(hex(UIColor(label).resolvedColor(with: traits)),
                                                        hex(UIColor(fill).resolvedColor(with: traits))), 4.5,
                                                "\(variant) dark=\(dark) Grocery action")
                }
            }
        }
    }

    func testPrimaryButtonLabelFollowsTheActualFill() {
        for variant in StockedDesignVariant.allCases {
            for dark in [false, true] {
                guard let palette = variant.palette(dark: dark) else { continue }
                let primary = StockedPrimaryButtonStyle.labelColor(palette: palette, explicitFill: false)
                let legacyFill = StockedPrimaryButtonStyle.labelColor(palette: palette, explicitFill: true)
                XCTAssertEqual(hex(UIColor(primary)), palette.onAccent)
                XCTAssertEqual(hex(UIColor(legacyFill)), palette.ivory)
                XCTAssertGreaterThanOrEqual(contrast(hex(UIColor(legacyFill)), palette.fill), 4.5)
            }
        }
    }

    func testLegacyLabelsKeepContrastOnVariantFills() {
        // Existing call sites draw ivory labels on `fill`; the primary action uses onAccent on accent.
        for variant in StockedDesignVariant.allCases {
            for dark in [false, true] {
                guard let palette = variant.palette(dark: dark) else { continue }
                XCTAssertGreaterThanOrEqual(contrast(palette.ivory, palette.fill), 4.5, "\(variant) dark=\(dark) ivory/fill")
                XCTAssertGreaterThanOrEqual(contrast(palette.onAccent, palette.accent), 4.5, "\(variant) dark=\(dark) action")
                XCTAssertGreaterThanOrEqual(contrast(palette.ink, palette.bg), 7, "\(variant) dark=\(dark) body text")
                XCTAssertGreaterThanOrEqual(contrast(palette.muted, palette.surface), 4.5, "\(variant) dark=\(dark) secondary text")
                XCTAssertGreaterThanOrEqual(contrast(palette.warn, palette.surface), 4.5, "\(variant) dark=\(dark) warn label")
                XCTAssertGreaterThanOrEqual(contrast(palette.danger, palette.surface), 4.5, "\(variant) dark=\(dark) danger label")
            }
        }
    }

    // MARK: Default preservation of shared tokens and geometry

    func testColorTokensResolveLegacyValuesForCurrent() {
        let current = UITraitCollection { $0.userInterfaceStyle = .light }
        let journal = UITraitCollection {
            $0.userInterfaceStyle = .light
            $0[StockedDesignVariantTrait.self] = .pantryJournal
        }
        let bg = UIColor(Color.stockedBg)
        XCTAssertEqual(hex(bg.resolvedColor(with: current)), 0xFDF7EF, "Pastel canvas is unchanged by default")
        XCTAssertEqual(hex(bg.resolvedColor(with: journal)), 0xF5F0E7)

        let tanCurrent = UITraitCollection {
            $0.userInterfaceStyle = .light
            $0[StockedLightThemeTrait.self] = .tan
        }
        XCTAssertEqual(hex(bg.resolvedColor(with: tanCurrent)), 0xC7AB81, "Tan canvas is unchanged by default")

        let evening = UITraitCollection {
            $0.userInterfaceStyle = .dark
            $0[StockedDesignVariantTrait.self] = .eveningTable
        }
        XCTAssertEqual(hex(UIColor(Color.stockedDarkBg).resolvedColor(with: evening)), 0x1B211E)
    }

    func testLayoutGeometryUnchangedForCurrent() {
        let current = StockedLayoutMetrics(width: 393, height: 852, isAccessibilityText: false, interfaceScale: 1)
        XCTAssertEqual(current.designVariant, .current)
        XCTAssertEqual(current.controlCornerRadius, 14)
        XCTAssertEqual(current.surfaceCornerRadius, 16)
        var standard = current
        standard.designVariant = .kitchenStandard
        XCTAssertEqual(standard.controlCornerRadius, 8)
        XCTAssertEqual(standard.surfaceCornerRadius, 8)
        XCTAssertEqual(standard.minimumControlHeight, current.minimumControlHeight, "48pt controls in every design")
    }

    func testStockedUIRadiiUnchangedForCurrent() {
        UserDefaults.standard.removeObject(forKey: StockedDesignVariant.defaultsKey)
        XCTAssertEqual(StockedUI.cornerRadiusSm, 8)
        XCTAssertEqual(StockedUI.cornerRadiusMd, 12)
        XCTAssertEqual(StockedUI.cornerRadiusLg, 20)
        XCTAssertEqual(StockedUI.cornerRadiusXL, 30)
        UserDefaults.standard.set("pantryJournal", forKey: StockedDesignVariant.defaultsKey)
        XCTAssertEqual(StockedUI.cornerRadiusMd, 12, "retired selections use standard geometry")
        XCTAssertEqual(StockedUI.cornerRadiusXL, 30, "retired selections use standard geometry")
    }

    // MARK: Explicit status labels

    func testItemAttentionLabels() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 18))!
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }
        XCTAssertEqual(StockedItemAttention.evaluate(expirationDate: day(-1), isLow: false, now: now, calendar: calendar), .expired)
        XCTAssertEqual(StockedItemAttention.evaluate(expirationDate: day(0), isLow: false, now: now, calendar: calendar), .expiresToday)
        XCTAssertEqual(StockedItemAttention.evaluate(expirationDate: day(2), isLow: true, now: now, calendar: calendar), .expiresIn(days: 2))
        XCTAssertEqual(StockedItemAttention.evaluate(expirationDate: day(30), isLow: true, now: now, calendar: calendar), .lowStock)
        XCTAssertNil(StockedItemAttention.evaluate(expirationDate: day(30), isLow: false, now: now, calendar: calendar))
        XCTAssertNil(StockedItemAttention.evaluate(expirationDate: nil, isLow: false, now: now, calendar: calendar))
        XCTAssertEqual(StockedItemAttention.expiresIn(days: 1).label, "1 day left")
        XCTAssertEqual(StockedItemAttention.expiresToday.label, "Use today")
        XCTAssertEqual(StockedItemAttention.lowStock.label, "Low stock")
        XCTAssertEqual(StockedItemAttention.expired.label, "Expired")
    }

    // MARK: Helpers

    private func hex(_ color: UIColor) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt32((r * 255).rounded()) << 16) | (UInt32((g * 255).rounded()) << 8) | UInt32((b * 255).rounded())
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ v: UInt32) -> Double {
                let c = Double(v) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
