// SizeSystem.swift — Adaptive sizing for all iPhone screen sizes.
// Baseline: iPhone 16 Pro (393pt logical width, iOS 26).
// All other sizes scale relative to that baseline.
// Infrastructure is injected once at RootView via DeviceAdaptiveRoot
// and reads via @Environment(\.stockedDevice).
import SwiftUI
import WidgetKit

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
    var interfaceScale: CGFloat
    /// Continuous approximation of the active Dynamic Type category. Layout uses
    /// this before text reaches accessibility categories so controls widen/reflow
    /// instead of waiting until labels have already wrapped or escaped their shape.
    var textScale: CGFloat = 1
    var safeAreaInsets: EdgeInsets = EdgeInsets()

    var contentWidth: CGFloat {
        max(1, width - safeAreaInsets.leading - safeAreaInsets.trailing)
    }

    var contentHeight: CGFloat {
        max(1, height - safeAreaInsets.top - safeAreaInsets.bottom)
    }

    /// Keep controls close enough to the edge to use the available canvas. The
    /// former five-percent rule made Pro Max phones and iPads feel needlessly narrow.
    var horizontalPadding: CGFloat { contentWidth >= 600 ? 24 : contentWidth < 350 ? 12 : 16 }
    var sectionSpacing: CGFloat { min(max(contentWidth * 0.03, 10), 24) }
    var readableContentWidth: CGFloat { min(contentWidth, 1_180) }
    var formContentWidth: CGFloat { min(contentWidth, 760) }
    var minimumControlHeight: CGFloat { max(44, 48 * interfaceScale * min(textScale, 1.7)) }
    var controlHorizontalPadding: CGFloat { 12 * max(interfaceScale, min(textScale, 1.45)) }
    var controlCornerRadius: CGFloat { min(24, 14 * max(interfaceScale, min(textScale, 1.35))) }
    /// Shared presentation geometry. Width decides horizontal placement; Dynamic Type
    /// only increases intrinsic vertical space so fields and cards never jump columns.
    var presentationHorizontalPadding: CGFloat { horizontalPadding }
    var listRowMinimumHeight: CGFloat { minimumControlHeight }
    var surfaceContentPadding: CGFloat { contentWidth >= 700 ? 24 : (contentWidth < 350 ? 12 : 16) }
    var surfaceCornerRadius: CGFloat { contentWidth >= 700 ? 20 : 16 }
    var textEditorMinimumHeight: CGFloat { max(96, minimumControlHeight * 2) }
    /// Placement responds to available width, never font size. Enlarged labels
    /// grow controls vertically instead of moving them to another row.
    var prefersVerticalControls: Bool { contentWidth < 360 }

    /// The hero always reserves a right-hand column for its artwork and leaves the
    /// remaining width to the pinned Stock Level card. Text size never changes columns.
    var homeHeroArtworkWidth: CGFloat {
        contentWidth >= 700 ? 230 : min(180, max(120, contentWidth * 0.42))
    }

    /// Shared geometry for every illustrated Home widget. Available width may grow
    /// or shrink artwork, spacing, and padding; text size is intentionally excluded
    /// so Dynamic Type only increases the widget's intrinsic vertical height.
    var homeWidgetWidthScale: CGFloat {
        min(max(contentWidth / 393, 0.72), 1.25)
    }

    var homeWidgetRowSpacing: CGFloat {
        min(18, max(8, 14 * homeWidgetWidthScale))
    }

    var homeWidgetContentPadding: CGFloat {
        contentWidth >= 700 ? 20 : (contentWidth < 340 ? 12 : 16)
    }

    var homeWidgetGridSpacing: CGFloat {
        // Keep neighboring cards visually grouped. Wide canvases get only the
        // extra room needed to preserve distinct hit regions; they should not
        // turn the board into a set of disconnected sections.
        contentWidth >= 700 ? 8 : 6
    }

    /// Four logical tracks are stable on every device. Compact widgets consume two
    /// tracks, so phones still show a balanced two-up grid without narrow text columns.
    var homeWidgetLogicalColumnCount: Int { 4 }

    /// Height uses a fine independent lattice rather than square physical cells.
    /// Intrinsic content still expands to as many rows as it needs, while the
    /// smaller unit prevents a card from leaving nearly a full 70-point blank
    /// band before the next widget after its height is rounded up.
    var homeWidgetGridRowUnit: CGFloat {
        contentWidth >= 700 ? 24 : 20
    }

    func homeWidgetMinimumHeight(rowSpan: Int) -> CGFloat {
        let rows = max(1, rowSpan)
        return homeWidgetGridRowUnit * CGFloat(rows)
            + homeWidgetGridSpacing * CGFloat(rows - 1)
    }

    func homeWidgetIllustrationSize(
        preferredWidth: CGFloat,
        preferredHeight: CGFloat
    ) -> CGSize {
        let safeWidth = max(1, preferredWidth)
        let proposedWidth = safeWidth * homeWidgetWidthScale
        let width = min(proposedWidth, max(48, contentWidth * 0.28))
        return CGSize(
            width: width,
            height: max(1, preferredHeight) * (width / safeWidth)
        )
    }

    /// Shared bottom-navigation geometry. Labels may use two lines instead of
    /// truncating, while the selected shape and touch target still match across tabs.
    var tabBarHorizontalPadding: CGFloat { contentWidth < 350 ? 8 : min(16, horizontalPadding) }
    var tabBarTopPadding: CGFloat { isAccessibilityText ? 6 : 8 }
    var tabBarBottomPadding: CGFloat { 4 }
    var tabBarItemSpacing: CGFloat { isAccessibilityText ? 2 : 3 }
    var tabBarIconSize: CGFloat { min(max(18 * interfaceScale, 18), 24) }
    var tabBarItemMinimumHeight: CGFloat {
        max(minimumControlHeight, isAccessibilityText ? 68 : 50 * interfaceScale)
    }
    var tabBarCornerRadius: CGFloat { min(max(11 * interfaceScale, 11), 16) }

    /// Width for cards in horizontally scrolling rails. The approved 393-point phone
    /// composition remains the baseline while narrow windows shrink and iPad/landscape
    /// windows use their additional room. Callers no longer need device-specific literals.
    func horizontalCardWidth(
        preferred: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let usable = max(1, contentWidth - horizontalPadding * 2)
        let relativeScale = min(max(contentWidth / 393, 0.85), 1.30)
        let lower = min(max(minimum, 1), usable)
        let upper = min(max(maximum, lower), usable)
        return min(max(preferred * relativeScale, lower), upper)
    }

    /// Makes a short horizontal rail use the complete readable canvas on wide windows.
    /// Phone rails keep their compact card size and scroll normally; iPad, landscape,
    /// and Stage Manager divide the live container into visible columns so a three-item
    /// rail does not strand a phone-width block beside a large empty region.
    func wideRailCardWidth(
        itemCount: Int,
        preferred: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        guard contentWidth >= 700, itemCount > 0 else {
            return horizontalCardWidth(preferred: preferred, minimum: minimum, maximum: maximum)
        }

        let available = max(1, readableContentWidth - 36)
        let visibleCount = min(itemCount, isAccessibilityText ? 2 : 3)
        return max(1, (available - spacing * CGFloat(max(0, visibleCount - 1))) / CGFloat(visibleCount))
    }

    /// Insets a center-snapping rail far enough that its first and last cards can
    /// actually reach the viewport center. The page gutter remains the floor for
    /// oversized cards and compact containers.
    func centeredRailContentMargin(
        cardWidth: CGFloat,
        minimum: CGFloat? = nil
    ) -> CGFloat {
        let minimumMargin = max(0, minimum ?? horizontalPadding)
        let centeredMargin = (contentWidth - max(0, cardWidth)) / 2
        return max(minimumMargin, centeredMargin)
    }

    /// The featured recipe keeps its approved 190-point baseline while gaining
    /// vertical room as text controls grow. Width never changes this placement.
    var recipeFeatureHeroMinimumHeight: CGFloat {
        max(190, 142 + minimumControlHeight)
    }

    func gridColumns(minimum: CGFloat, maximum: Int = 3, spacing: CGFloat = 12) -> [GridItem] {
        let usable = max(1, contentWidth - horizontalPadding * 2)
        let safeMaximum = max(1, maximum)
        // Preserve the designed placement as text grows. Controls increase their
        // vertical intrinsic size and wrap internally instead of changing column
        // count merely because the app text preference changed.
        let safeMinimum = max(1, minimum)
        let count = max(1, min(safeMaximum, Int((usable + spacing) / (safeMinimum + spacing))))
        return Array(repeating: GridItem(.flexible(minimum: safeMinimum), spacing: spacing), count: count)
    }

    static let fallback = StockedLayoutMetrics(width: 393, height: 852,
                                               isAccessibilityText: false,
                                               interfaceScale: InterfaceSize.standard.scale,
                                               textScale: 1)
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
    @AppStorage("stocked.appTextSize") private var appTextSizeRaw = AppTextSize.standard.rawValue
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
                isAccessibilityText: dynamicTypeSize.isAccessibilitySize,
                interfaceScale: InterfaceSize.standard.scale,
                textScale: dynamicTypeSize.stockedLayoutScale *
                    (AppTextSize(rawValue: appTextSizeRaw)?.multiplier ?? 1),
                safeAreaInsets: proxy.safeAreaInsets
            )
            content
                .environment(\.stockedDevice, device)
                .environment(\.stockedLayout, metrics)
                .environment(
                    \.dynamicTypeSize,
                    dynamicTypeSize.stockedLinked(
                        to: AppTextSize(rawValue: appTextSizeRaw) ?? .standard
                    )
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onChange(of: appTextSizeRaw, initial: true) { _, newValue in
                    UserDefaults(suiteName: "group.com.sowens.Stocked")?
                        .set(newValue, forKey: StockedType.appTextSizePreferenceKey)
                    WidgetCenter.shared.reloadAllTimelines()
                }
        }
    }
}

private extension DynamicTypeSize {
    /// System-owned labels inside controls cannot use StockedType directly, so
    /// link their semantic category to the same in-app preference at the root.
    func stockedLinked(to appSize: AppTextSize) -> DynamicTypeSize {
        let ordered: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
            .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5,
        ]
        guard let current = ordered.firstIndex(of: self) else { return self }
        let offset: Int = switch appSize {
        case .extraSmall: -2
        case .small: -1
        case .standard: 0
        case .medium: 1
        case .large: 2
        case .extraLarge: 3
        case .extraExtraLarge: 4
        }
        return ordered[min(max(0, current + offset), ordered.count - 1)]
    }

    var stockedLayoutScale: CGFloat {
        switch self {
        case .xSmall: 0.82
        case .small: 0.9
        case .medium: 0.96
        case .large: 1
        case .xLarge: 1.12
        case .xxLarge: 1.24
        case .xxxLarge: 1.36
        case .accessibility1: 1.5
        case .accessibility2: 1.65
        case .accessibility3: 1.82
        case .accessibility4: 2
        case .accessibility5: 2.2
        @unknown default: 1
        }
    }
}

// MARK: - View modifier shorthand
extension View {
    func adaptiveDevice() -> some View { modifier(AdaptiveDeviceModifier()) }
}
struct AdaptiveDeviceModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) var hSize
    @Environment(\.stockedLayout) private var layoutMetrics
    func body(content: Content) -> some View {
        let width = layoutMetrics.contentWidth
        let adaptiveSizeClass: UserInterfaceSizeClass? =
            UIDevice.current.userInterfaceIdiom == .pad && width >= 700 ? hSize : .compact
        let device = StockedDevice.current(width: width, hSize: adaptiveSizeClass)
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
        font(.stockedSerif(size.value(for: device), weight: weight))
    }
}
