// QAEnvironmentSnapshot.swift
// ─────────────────────────────────────────────────────────────────────────────
// IMPROVEMENT 4 (Build 74) — the settings the bug was standing in.
//
// A ticket used to carry the numbers that change minute to minute — memory,
// thermal, free disk, hitch — and none of the settings that change how the app
// draws itself. So "the button is cut off" arrived with no way to tell whether
// the reporter had text size at XXL, or the device sideways, or Bold Text on, or
// a 4.7-inch screen. Those are the three or four facts that decide whether a
// layout bug reproduces, and every one of them was missing.
//
// This is one read of everything that is stable for the length of a session but
// varies wildly between testers, captured at the moment the ticket is filed.
// It is a `[String]` rather than a struct with twenty fields on purpose: it is
// read by a human, it is appended to a text report, and a new line added here
// next build needs no migration on the persisted side.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import UIKit

@MainActor
enum QAEnvironmentSnapshot {

    /// One pass over everything worth knowing that isn't already in the context.
    /// Cheap — every call here is a property read, nothing polls or waits.
    static func lines() -> [String] {
        var out: [String] = []

        out.append("text size: \(contentSizeLabel)")
        out.append("appearance: \(appearanceLabel) · \(orientationLabel)")
        out.append("screen: \(screenLabel)")

        let a11y = accessibilityFlags
        out.append("accessibility: " + (a11y.isEmpty ? "nothing on" : a11y.joined(separator: ", ")))

        out.append("battery: \(batteryLabel)")
        out.append("locale: \(localeLabel)")
        out.append("uptime: \(uptimeLabel)")
        if let scene = QAScreenshot.appWindow()?.windowScene {
            out.append("scene: \(sceneLabel(scene))")
        }
        return out
    }

    /// Flattened for the places that want a single line rather than a block.
    static func summaryLine() -> String {
        "\(contentSizeLabel) · \(appearanceLabel) · \(orientationLabel) · " +
        (accessibilityFlags.isEmpty ? "no a11y overrides" : accessibilityFlags.joined(separator: ", "))
    }

    // MARK: Pieces

    /// `UIContentSizeCategory` prints as `UICTContentSizeCategoryXL`, which is
    /// not a thing anyone should have to read in a bug report.
    static var contentSizeLabel: String {
        switch UIApplication.shared.preferredContentSizeCategory {
        case .extraSmall:                        return "XS"
        case .small:                             return "S"
        case .medium:                            return "M"
        case .large:                             return "L (default)"
        case .extraLarge:                        return "XL"
        case .extraExtraLarge:                   return "XXL"
        case .extraExtraExtraLarge:              return "XXXL"
        case .accessibilityMedium:               return "AX M"
        case .accessibilityLarge:                return "AX L"
        case .accessibilityExtraLarge:           return "AX XL"
        case .accessibilityExtraExtraLarge:      return "AX XXL"
        case .accessibilityExtraExtraExtraLarge: return "AX XXXL"
        default:                                 return "unknown"
        }
    }

    static var isAccessibilityTextSize: Bool {
        UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory
    }

    static var appearanceLabel: String {
        switch UITraitCollection.current.userInterfaceStyle {
        case .dark:  return "dark"
        case .light: return "light"
        default:     return "unspecified"
        }
    }

    /// The *interface* orientation, not the device's. A phone lying face-up on a
    /// desk reports `.faceUp`, which tells you nothing about how the app is drawn.
    static var orientationLabel: String {
        guard let scene = QAScreenshot.appWindow()?.windowScene else { return "orientation unknown" }
        let o: UIInterfaceOrientation
        if #available(iOS 26.0, *) {
            o = scene.effectiveGeometry.interfaceOrientation
        } else {
            o = scene.interfaceOrientation
        }
        switch o {
        case .portrait:           return "portrait"
        case .portraitUpsideDown: return "portrait upside down"
        case .landscapeLeft:      return "landscape left"
        case .landscapeRight:     return "landscape right"
        default:                  return "orientation unknown"
        }
    }

    static var screenLabel: String {
        guard let window = QAScreenshot.appWindow() else { return "no window" }
        let b = window.bounds
        // `traitCollection.displayScale` rather than `window.screen.scale`:
        // `UIScreen` is on its way out and the trait is the supported route to the
        // same number.
        let scale = window.traitCollection.displayScale
        let insets = window.safeAreaInsets
        return String(format: "%.0f×%.0f @%.0fx · safe area top %.0f bottom %.0f",
                      b.width, b.height, scale, insets.top, insets.bottom)
    }

    /// Only the ones that are ON. A list of eight "false"s buries the one that
    /// matters; naming only what is switched on makes the line read as a fact.
    static var accessibilityFlags: [String] {
        var on: [String] = []
        if UIAccessibility.isVoiceOverRunning          { on.append("VoiceOver") }
        if UIAccessibility.isSwitchControlRunning      { on.append("Switch Control") }
        if UIAccessibility.isReduceMotionEnabled       { on.append("Reduce Motion") }
        if UIAccessibility.isReduceTransparencyEnabled { on.append("Reduce Transparency") }
        if UIAccessibility.isBoldTextEnabled           { on.append("Bold Text") }
        if UIAccessibility.isDarkerSystemColorsEnabled { on.append("Increase Contrast") }
        if UIAccessibility.isInvertColorsEnabled       { on.append("Invert Colours") }
        if UIAccessibility.isGrayscaleEnabled          { on.append("Grayscale") }
        if UIAccessibility.isSpeakScreenEnabled        { on.append("Speak Screen") }
        if UIAccessibility.isGuidedAccessEnabled       { on.append("Guided Access") }
        if isAccessibilityTextSize                     { on.append("accessibility text size") }
        return on
    }

    /// Battery monitoring is off by default and the level reads -1 until it is
    /// turned on. Turning it on here is idempotent and costs nothing; a report
    /// filed at 4% on a hot phone explains a lot of "the app felt slow".
    static var batteryLabel: String {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        let pct = level < 0 ? "unknown" : "\(Int((level * 100).rounded()))%"
        let state: String
        switch device.batteryState {
        case .charging: state = "charging"
        case .full:     state = "full"
        case .unplugged: state = "on battery"
        default:        state = "state unknown"
        }
        return "\(pct) · \(state)"
    }

    static var localeLabel: String {
        let l = Locale.current
        let lang = l.language.languageCode?.identifier ?? "??"
        let region = l.region?.identifier ?? "??"
        let cal = l.calendar.identifier
        return "\(lang)-\(region) · \(cal) · 24h: \(uses24Hour ? "yes" : "no")"
    }

    private static var uses24Hour: Bool {
        let fmt = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.current) ?? ""
        return !fmt.contains("a")
    }

    /// How long the *device* has been up, which is a different question from how
    /// long the app session has run and occasionally the answer to "why is
    /// everything slow" all by itself.
    static var uptimeLabel: String {
        let seconds = ProcessInfo.processInfo.systemUptime
        let hours = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(mins)m since boot" : "\(mins)m since boot"
    }

    private static func sceneLabel(_ scene: UIWindowScene) -> String {
        let windows = scene.windows.count
        let state: String
        switch scene.activationState {
        case .foregroundActive:   state = "active"
        case .foregroundInactive: state = "inactive"
        case .background:         state = "background"
        default:                  state = "unattached"
        }
        return "\(state) · \(windows) window\(windows == 1 ? "" : "s")"
    }
}
