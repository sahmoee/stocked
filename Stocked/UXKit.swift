// UXKit.swift — Shared, app-wide UX building blocks introduced in the Build 128 polish pass.
//
// Everything here is additive and reusable so individual screens don't each reinvent
// toasts, count-up numbers, pulses, or step markers. Pieces:
//   • ToastCenter / StockedToastOverlay / .stockedToasts()  — app-wide confirm + undo toasts (#11, #13)
//   • .pulseOnChange(_:)                                     — quick scale/flash when a value changes (#4)
//   • StepIndicator                                          — "step N of M" dots for flows (#8)
//   • Color.appSubtextStrong(_:)                             — WCAG-AA-friendlier muted text (#15)
//   • .stockedCard(...)                                      — one elevation language for tappable cards (#17)
//
// Design language matches the existing in-app toasts (charcoal capsule, gold accent,
// bottom placement) so nothing looks out of place.

import SwiftUI

// MARK: - Toast model

enum StockedToastStyle: Equatable {
    case success     // green check — something completed
    case info        // gold dot — neutral status / the app did something for you
    case undo        // trash + Undo action
    case warning     // orange triangle — an error/failure notice (never a green check)

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info:    return "sparkles"
        case .undo:    return "trash"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .success: return .stockedGreen
        case .info:    return .stockedGold
        case .undo:    return .stockedWhite
        case .warning: return .orange
        }
    }
}

struct StockedToast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var style: StockedToastStyle
    var undoTitle: String = "Undo"
    // Stored as an optional box so Equatable still works (closures aren't Equatable).
    fileprivate var action: ActionBox? = nil

    static func == (lhs: StockedToast, rhs: StockedToast) -> Bool { lhs.id == rhs.id }
}

// Wrapper so we can keep a closure on an Equatable value type.
fileprivate final class ActionBox {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

// MARK: - Toast center (app-wide)
// Injected once at the app root via .environment(ToastCenter.shared) and surfaced by
// .stockedToasts(). Any view can call ToastCenter.shared.success("…") etc.

@Observable
final class ToastCenter {
    static let shared = ToastCenter()
    private init() {}

    private(set) var current: StockedToast? = nil
    private var dismissTask: Task<Void, Never>? = nil

    /// A neutral confirmation that the app did something on the user's behalf (#13).
    func info(_ message: String, duration: Double = 2.4) {
        present(StockedToast(message: message, style: .info), duration: duration)
    }

    /// A success confirmation (e.g. saved, added, completed).
    func success(_ message: String, duration: Double = 2.4) {
        present(StockedToast(message: message, style: .success), duration: duration)
    }

    /// Something went wrong but the app is fine (network failures, server hiccups).
    /// Orange triangle instead of the green check, so errors never look like wins.
    func warning(_ message: String, duration: Double = 3.0) {
        present(StockedToast(message: message, style: .warning), duration: duration)
    }

    /// A destructive action with an Undo affordance (#11). The action runs if the user taps Undo.
    func undo(_ message: String, title: String = "Undo",
              duration: Double = StockedUI.undoToastDuration,
              onUndo: @escaping () -> Void) {
        present(StockedToast(message: message, style: .undo, undoTitle: title,
                             action: ActionBox(onUndo)), duration: duration)
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
            current = nil
        }
    }

    fileprivate func performUndo() {
        current?.action?.run()
        HapticManager.success()
        dismiss()
    }

    private func present(_ toast: StockedToast, duration: Double) {
        dismissTask?.cancel()
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
            current = toast
        }
        if toast.style == .success { HapticManager.success() }
        else { HapticManager.light() }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Only auto-dismiss if it's still the same toast.
            if current?.id == toast.id { dismiss() }
        }
    }
}

// MARK: - Toast overlay + modifier

struct StockedToastOverlay: View {
    @Environment(ToastCenter.self) private var center
    /// Bottom inset so the toast clears the global bottom navigation.
    var bottomInset: CGFloat = StockedUI.navHeight + 52

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if let toast = center.current {
                HStack(spacing: 12) {
                    Image(systemName: toast.style.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(toast.style == .undo ? Color.stockedWhite.opacity(0.7) : toast.style.tint)
                        .a11yDecorative()
                    Text(toast.message)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if toast.style == .undo {
                        Button { center.performUndo() } label: {
                            Text(toast.undoTitle)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.stockedGoldDark)
                        }
                        .buttonStyle(.plain)
                        .a11yButton(toast.undoTitle, hint: "Reverses the last action")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Color.stockedCharcoal)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
                .padding(.horizontal, 24)
                .padding(.bottom, bottomInset)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isModal)
            }
        }
        .allowsHitTesting(center.current?.style == .undo)   // only the undo toast needs taps
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Adds the app-wide toast overlay. Apply once near the root of the live shell.
    func stockedToasts(bottomInset: CGFloat = StockedUI.navHeight + 52) -> some View {
        overlay(StockedToastOverlay(bottomInset: bottomInset).environment(ToastCenter.shared))
    }
}

// MARK: - Count-up number (#4)
// Animates between integer values using SwiftUI's numeric content transition, with a
// brief tint flash on change. Reduce-Motion safe.


// MARK: - Pulse on change (#4)
// A subtle scale bump whenever an Equatable value changes — good for chips/badges.

private struct PulseOnChange<V: Equatable>: ViewModifier {
    let value: V
    @State private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: value) { _, _ in
                guard !UIAccessibility.isReduceMotionEnabled else { return }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { scale = 1.06 }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { scale = 1 }
                }
            }
    }
}

extension View {
    func pulseOnChange<V: Equatable>(_ value: V) -> some View { modifier(PulseOnChange(value: value)) }
}

// MARK: - Step indicator (#8)
// A small "Step N of M" with dots, for multi-step flows (e.g. cook → serving → plan).

struct StepIndicator: View {
    let current: Int   // 1-based
    let total: Int
    var tint: Color = .stockedGold
    var dim: Color = .stockedCharcoal

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(1...max(total, 1), id: \.self) { i in
                    Capsule()
                        .fill(i <= current ? tint : dim.opacity(0.18))
                        .frame(width: i == current ? 18 : 7, height: 7)
                        .animation(UIAccessibility.isReduceMotionEnabled ? nil : .spring(response: 0.3), value: current)
                }
            }
            Text("Step \(current) of \(total)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(dim.opacity(0.55))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current) of \(total)")
    }
}

// MARK: - Contrast-safe muted text (#15)
// The old muted text used opacity 0.55–0.6 over the tan background, which can fall below
// the WCAG-AA 4.5:1 body-text ratio. These tokens use denser values that read clearly in
// both modes while staying visually "secondary".

extension Color {
    /// Higher-contrast secondary/label text for body copy on the app background.
    static func appSubtextStrong(_ dark: Bool) -> Color {
        dark ? Color.darkLabel.opacity(0.72)
             : Color.stockedBlack.opacity(0.72)
    }
}

// MARK: - One elevation language for cards (#17)
// A single, consistent "tappable surface" treatment so users learn what's interactive by
// sight. Use .stockedCard() on grouped content instead of ad-hoc background+shadow combos.

private struct StockedCardModifier: ViewModifier {
    var isDark: Bool
    var padding: CGFloat
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(isDark ? Color.darkSurface : Color.stockedWhite.opacity(0.34))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke((isDark ? Color.white : Color.stockedCharcoal).opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(isDark ? 0.30 : 0.06), radius: 8, y: 3)
    }
}

extension View {
    func stockedCard(isDark: Bool, padding: CGFloat = StockedSpacing.md, radius: CGFloat = StockedUI.cornerRadiusLg) -> some View {
        modifier(StockedCardModifier(isDark: isDark, padding: padding, radius: radius))
    }
}
