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

/// Slide transition that becomes a cross-fade under Reduce Motion. All `.move(edge:)`
/// transitions route through this, so screens stop sliding for people who asked them not to.
/// (Replaces two unused helpers, `Animation.stockedMotion` and `motionAware`.)
extension AnyTransition {
    @MainActor static func stockedMove(edge: Edge) -> AnyTransition {
        UIAccessibility.isReduceMotionEnabled ? .opacity : .move(edge: edge)
    }
}
