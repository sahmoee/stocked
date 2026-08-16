// AccessibilityPolish.swift
// Round 1 (Polish & Trust): reusable accessibility helpers and a shared empty-state view.
//
// The app had zero VoiceOver labels on its many icon-only controls, so screen-reader users
// couldn't tell what most buttons did. These helpers make labeling a one-liner, and the
// StockedEmptyState view gives every list a consistent, friendly first-run / empty message.

import SwiftUI

// MARK: - Accessibility convenience

extension View {
    /// Label an icon-only control for VoiceOver and mark it as a button.
    /// Usage: `Image(systemName: "trash").a11yButton("Delete item")`
    func a11yButton(_ label: String, hint: String? = nil) -> some View {
        self.accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
            .accessibilityAddTraits(.isButton)
    }

    /// Label a non-interactive element (image, decorative status) for VoiceOver.
    func a11yLabel(_ label: String, value: String? = nil) -> some View {
        self.accessibilityLabel(label)
            .accessibilityValue(value ?? "")
    }

    /// Hide purely decorative content from VoiceOver so it doesn't add noise.
    func a11yDecorative() -> some View {
        self.accessibilityHidden(true)
    }

    /// Combine a composite row (icon + title + detail) into one VoiceOver element with a
    /// single spoken label, instead of the user swiping through each sub-view.
    func a11yRow(_ label: String, hint: String? = nil, isButton: Bool = true) -> some View {
        self.accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
            .accessibilityAddTraits(isButton ? .isButton : [])
    }

    func a11yStatus(_ label: String, value: String) -> some View {
        self.accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }
}

/// Announces background completion without moving VoiceOver focus.
@MainActor
func announceAccessibilityStatus(_ message: String) {
    guard UIAccessibility.isVoiceOverRunning else { return }
    UIAccessibility.post(notification: .announcement, argument: message)
}

// MARK: - Reduce Motion

/// A motion-aware animation: returns the given animation normally, or nil (instant) when
/// the user has Reduce Motion enabled. Use as `.animation(.stockedMotion(.spring()), value:)`
/// or via the `motionAware` helper below.
extension Animation {
    static func stockedMotion(_ base: Animation) -> Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : base
    }
}

extension View {
    /// Apply an animation that automatically disables itself under Reduce Motion.
    func motionAware<V: Equatable>(_ base: Animation, value: V) -> some View {
        self.animation(UIAccessibility.isReduceMotionEnabled ? nil : base, value: value)
    }
}
