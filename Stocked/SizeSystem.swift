// SizeSystem.swift — Adaptive sizing for all iPhone screen sizes.
// Baseline: iPhone 16 Pro (393pt logical width, iOS 26).
// All other sizes scale relative to that baseline.
// Infrastructure is injected once at RootView via DeviceAdaptiveRoot
// and reads via @Environment(\.stockedDevice).
import SwiftUI

// MARK: - Device class
// iPhone 16 Pro = 393pt → .regular (canonical baseline)
// iPhone SE 3rd gen = 375pt → .small
// iPhone 16 Pro Max = 430pt → .large
enum StockedDevice {
    case small    // ≤ 375pt  — SE, mini
    case regular  // 376–413pt — standard Pro (16 Pro baseline)
    case large    // 414pt+  — Pro Max, Plus
    case tablet   // iPad    — horizontalSizeClass = .regular

    static func current(width: CGFloat, hSize: UserInterfaceSizeClass?) -> StockedDevice {
        if hSize == .regular { return .tablet }
        if width <= 375      { return .small }
        if width <= 413      { return .regular }
        return .large
    }

    /// Scale factor relative to the iPhone 16 Pro baseline (393pt).
    /// Used to proportionally scale any value that should grow/shrink with screen.
    var scale: CGFloat {
        switch self {
        case .small:   return 0.88
        case .regular: return 1.00  // baseline
        case .large:   return 1.08
        case .tablet:  return 1.20
        }
    }
}

/// Live container metrics. Unlike physical-screen checks, this follows Split View,
/// Stage Manager, rotation, and resizable windows without naming specific devices.
struct StockedLayoutMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var isAccessibilityText: Bool

    var horizontalPadding: CGFloat { min(max(width * 0.05, 16), 40) }
    var sectionSpacing: CGFloat { min(max(width * 0.03, 10), 24) }
    var readableContentWidth: CGFloat { min(width, 840) }
    var formContentWidth: CGFloat { min(width, 620) }
    var prefersVerticalControls: Bool { width < 360 || isAccessibilityText }

    func gridColumns(minimum: CGFloat, maximum: Int = 3, spacing: CGFloat = 12) -> [GridItem] {
        let usable = max(1, width - horizontalPadding * 2)
        let count = max(1, min(maximum, Int((usable + spacing) / (minimum + spacing))))
        return Array(repeating: GridItem(.flexible(minimum: minimum), spacing: spacing), count: count)
    }

    static let fallback = StockedLayoutMetrics(width: 393, height: 852, isAccessibilityText: false)
}

private struct StockedLayoutMetricsKey: EnvironmentKey {
    static let defaultValue = StockedLayoutMetrics.fallback
}

extension EnvironmentValues {
    var stockedLayout: StockedLayoutMetrics {
        get { self[StockedLayoutMetricsKey.self] }
        set { self[StockedLayoutMetricsKey.self] = newValue }
    }
}

// MARK: - Screen metrics (single source for window size / safe area)
// #6 — every screen-width / safe-area read funnels through here instead of
// being re-implemented with `UIApplication.shared.connectedScenes…` in each
// view. One place to reason about (and later swap for an env-driven value).
enum StockedScreen {
    /// iPhone 16 Pro logical width — used when no window is available yet.
    static let fallbackWidth: CGFloat = 393
    /// iPhone 16 Pro safe-area top inset — fallback before a window exists.
    static let fallbackSafeTop: CGFloat = 59
    /// iPhone 16 Pro logical height — used when no window is available yet.
    static let fallbackHeight: CGFloat = 852

    private static var keyWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    /// Width of the app's active window (not the physical screen), so it's
    /// correct under iPad split view / Stage Manager.
    static var width: CGFloat {
        keyWindowScene?.windows.first?.bounds.width ?? fallbackWidth
    }

    /// Height of the app's active window (correct under split view / Stage Manager).
    static var height: CGFloat {
        keyWindowScene?.windows.first?.bounds.height ?? fallbackHeight
    }

    /// Top safe-area inset of the active window.
    static var safeTopInset: CGFloat {
        keyWindowScene?.windows.first?.safeAreaInsets.top ?? fallbackSafeTop
    }

    /// iPhone home-indicator height — fallback before a window exists.
    static let fallbackSafeBottom: CGFloat = 34
    /// Bottom safe-area inset of the active window.
    static var safeBottomInset: CGFloat {
        keyWindowScene?.windows.first?.safeAreaInsets.bottom ?? fallbackSafeBottom
    }

    /// Whether the active window is currently in a landscape orientation.
    static var isLandscape: Bool {
        keyWindowScene?.effectiveGeometry.interfaceOrientation.isLandscape ?? false
    }

    // ── Cook-button default diameter by width (#2) — user can override 150–500.
    static let cookButtonSmallMaxWidth:   CGFloat = 375
    static let cookButtonRegularMaxWidth: CGFloat = 413
    static let cookButtonSizeSmall:   Double = 220
    static let cookButtonSizeRegular: Double = 260
    static let cookButtonSizeLarge:   Double = 280
    static func defaultCookButtonSize(forWidth w: CGFloat) -> Double {
        if w <= cookButtonSmallMaxWidth   { return cookButtonSizeSmall }
        if w <= cookButtonRegularMaxWidth { return cookButtonSizeRegular }
        return cookButtonSizeLarge
    }
}

// MARK: - Adaptive value helper
struct AdaptiveValue<T> {
    let small: T; let regular: T; let large: T; let tablet: T
    func value(for device: StockedDevice) -> T {
        switch device {
        case .small:   return small
        case .regular: return regular
        case .large:   return large
        case .tablet:  return tablet
        }
    }
}

// MARK: - Global sizing tokens
// All values are tuned for iPhone 16 Pro as baseline.
struct SS {

    // ── Typography ──────────────────────────────────────────────────────
    static let titleLg = AdaptiveValue<CGFloat>(small: 24, regular: 26, large: 28, tablet: 32)
    static let titleMd = AdaptiveValue<CGFloat>(small: 18, regular: 20, large: 22, tablet: 26)
    static let titleSm = AdaptiveValue<CGFloat>(small: 15, regular: 16, large: 17, tablet: 20)
    static let body    = AdaptiveValue<CGFloat>(small: 13, regular: 14, large: 15, tablet: 16)
    static let caption = AdaptiveValue<CGFloat>(small: 10, regular: 11, large: 12, tablet: 13)
    static let header  = AdaptiveValue<CGFloat>(small: 22, regular: 24, large: 26, tablet: 30)

    // ── Horizontal padding ───────────────────────────────────────────────
    // Cards, rows, sections
    static let padH    = AdaptiveValue<CGFloat>(small: 16, regular: 20, large: 24, tablet: 40)
    // Inner card padding
    static let cardPad = AdaptiveValue<CGFloat>(small: 12, regular: 14, large: 16, tablet: 20)
    // Vertical spacing between sections
    static let padV    = AdaptiveValue<CGFloat>(small:  8, regular: 12, large: 14, tablet: 20)
    // Gap between elements in a row/grid
    static let gap     = AdaptiveValue<CGFloat>(small:  8, regular: 10, large: 12, tablet: 16)

    // ── Shell / navigation ───────────────────────────────────────────────
    // Top padding for the header bar (below safe area inset)
    static let shellHeaderPad = AdaptiveValue<CGFloat>(small: 8, regular: 10, large: 12, tablet: 16)
    // Bottom padding after the header bar
    static let shellHeaderBot = AdaptiveValue<CGFloat>(small: 10, regular: 14, large: 16, tablet: 20)

    // ── Tab bar ──────────────────────────────────────────────────────────
    static let tabBarH = AdaptiveValue<CGFloat>(small: 60, regular: 68, large: 72, tablet: 80)

    // ── Left drawer ──────────────────────────────────────────────────────
    static let drawerW = AdaptiveValue<CGFloat>(small: 290, regular: 320, large: 340, tablet: 380)

    // ── Cook button defaults ─────────────────────────────────────────────
    static let cookBtnSz = AdaptiveValue<CGFloat>(small: 180, regular: 220, large: 240, tablet: 260)

    // ── Corner radii ─────────────────────────────────────────────────────
    static let radiusSm = AdaptiveValue<CGFloat>(small: 10, regular: 12, large: 14, tablet: 16)
    static let radiusMd = AdaptiveValue<CGFloat>(small: 12, regular: 14, large: 16, tablet: 20)
    static let radiusLg = AdaptiveValue<CGFloat>(small: 16, regular: 20, large: 24, tablet: 28)

    // ── Icon / avatar sizes ──────────────────────────────────────────────
    static let iconMd   = AdaptiveValue<CGFloat>(small: 40, regular: 44, large: 48, tablet: 52)
    static let iconSm   = AdaptiveValue<CGFloat>(small: 28, regular: 32, large: 36, tablet: 40)

    // ── Convenience: scale any CGFloat from the 16 Pro baseline ─────────
    static func scaled(_ base: CGFloat, for device: StockedDevice) -> CGFloat {
        (base * device.scale).rounded()
    }
}

// MARK: - Environment key
struct StockedDeviceKey: EnvironmentKey {
    static let defaultValue: StockedDevice = .regular
}
extension EnvironmentValues {
    var stockedDevice: StockedDevice {
        get { self[StockedDeviceKey.self] }
        set { self[StockedDeviceKey.self] = newValue }
    }
}

// MARK: - Root injection (used in RootView, wraps the entire app once)
struct DeviceAdaptiveRoot<Content: View>: View {
    @Environment(\.horizontalSizeClass) var hSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let adaptiveSizeClass: UserInterfaceSizeClass? =
                UIDevice.current.userInterfaceIdiom == .pad && width >= 700 ? hSize : .compact
            let device = StockedDevice.current(width: width, hSize: adaptiveSizeClass)
            let metrics = StockedLayoutMetrics(
                width: width,
                height: proxy.size.height,
                isAccessibilityText: dynamicTypeSize.isAccessibilitySize
            )
            content
                .environment(\.stockedDevice, device)
                .environment(\.stockedLayout, metrics)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

// MARK: - View modifier shorthand
extension View {
    func adaptiveDevice() -> some View { modifier(AdaptiveDeviceModifier()) }
}
struct AdaptiveDeviceModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) var hSize
    func body(content: Content) -> some View {
        let width  = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.width ?? 393
        let device = StockedDevice.current(width: width, hSize: hSize)
        content.environment(\.stockedDevice, device)
    }
}

// MARK: - Convenience view extensions
extension View {
    /// Adaptive horizontal padding using SS.padH
    func adaptivePadH(_ device: StockedDevice) -> some View {
        padding(.horizontal, SS.padH.value(for: device))
    }
    /// Adaptive font with serif design
    func adaptiveFont(
        _ size: AdaptiveValue<CGFloat>,
        weight: Font.Weight = .regular,
        device: StockedDevice
    ) -> some View {
        font(.system(size: size.value(for: device), weight: weight, design: .serif))
    }
}
