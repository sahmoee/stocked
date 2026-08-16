// DesignSystem.swift — Unified typography, haptics, skeletons, empty states, toasts
// UI #1-15 foundation  |  UX #1,3,15
import SwiftUI

// MARK: - Dynamic Type scaling (#20)
// Adds relative: true to system fonts so they scale with the user's text size setting
extension View {
    func dynamicFont(_ style: Font.TextStyle, size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        self.font(.system(size: size, weight: weight, design: design))
            .dynamicTypeSize(.xSmall ... .accessibility2)
    }
}

/// The default boundary for every page, sheet, popover, and full-screen cover.
/// SwiftUI presentations otherwise reveal the system white/gray host behind Forms and
/// short content. The max width keeps large iPads readable without imposing a fixed
/// phone-sized frame; compact windows continue to use every available point.
struct StockedPresentationSurface: ViewModifier {
    @Environment(AppSession.self) private var session
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            content
                .frame(maxWidth: horizontalSizeClass == .regular ? 760 : .infinity,
                       maxHeight: .infinity,
                       alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(session.themeBgColor)
        .presentationBackground(session.themeBgColor)
        .tint(session.accentColor)
        .foregroundStyle(session.themeTextColor)
        .dynamicTypeSize(.xSmall ... .accessibility5)
    }
}

extension View {
    func stockedPresentationSurface() -> some View {
        modifier(StockedPresentationSurface())
    }
}

// MARK: - Semantic type scale (#7)
// Use these instead of .system(size: N) for Dynamic Type compatibility
extension Font {
    // Serif display
    static let stockedDisplay  = Font.system(size: 28, weight: .bold,      design: .serif)
    static let stockedTitle    = Font.system(size: 22, weight: .bold,      design: .serif)
    static let stockedHeadline = Font.system(size: 18, weight: .semibold,  design: .serif)
    // Sans body
    static let stockedBody     = Font.system(size: 15, weight: .regular,   design: .default)
    static let stockedBodyBold = Font.system(size: 15, weight: .semibold,  design: .default)
    static let stockedCaption  = Font.system(size: 12, weight: .regular,   design: .default)
    static let stockedLabel    = Font.system(size: 11, weight: .semibold,  design: .default)
}


// MARK: - Theme text color environment key
// #5: stockedTextColor is deprecated — use @Environment(AppSession.self) then session.themeTextColor.
// Kept for build compatibility during migration. Remove after all views updated.
struct StockedTextColorKey: EnvironmentKey {
    static let defaultValue: Color = .stockedCharcoal
}
extension EnvironmentValues {
    @available(*, deprecated, renamed: "AppSession.themeTextColor",
               message: "Read session.themeTextColor via @Environment(AppSession.self) instead")
    var stockedTextColor: Color {
        get { self[StockedTextColorKey.self] }
        set { self[StockedTextColorKey.self] = newValue }
    }
}

// MARK: - Typography scale (UI #2)
enum StockedFont {
    case display, title, headline, body, callout, caption, label
    var font: Font {
        switch self {
        case .display:  return .system(size: 40, weight: .bold,     design: .serif)
        case .title:    return .system(size: 28, weight: .bold,     design: .serif)
        case .headline: return .system(size: 22, weight: .semibold, design: .serif)
        case .body:     return .system(size: 15, weight: .regular)
        case .callout:  return .system(size: 13, weight: .semibold)
        case .caption:  return .system(size: 11, weight: .regular)
        case .label:    return .system(size: 10, weight: .bold)
        }
    }
}
extension View {
    func stocked(_ s: StockedFont) -> some View { font(s.font) }
}

// MARK: - Primary / Secondary button styles (UI #13)
struct StockedPrimaryButtonStyle: ButtonStyle {
    var accent: Color = Color.stockedCharcoal
    var fg: Color = Color.stockedWhite
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 17, weight: .semibold, design: .serif))
            .foregroundStyle(fg).frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(accent).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                .stroke(fg.opacity(0.48), lineWidth: 1.25))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.18), value: configuration.isPressed)
    }
}
struct StockedSecondaryButtonStyle: ButtonStyle {
    var accent: Color = Color.stockedGold
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold, design: .serif))
            .foregroundStyle(accent).frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(accent.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL).stroke(accent.opacity(0.65), lineWidth: 1.25))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.18), value: configuration.isPressed)
    }
}

// MARK: - App-wide text-entry outline
// MainTabView installs this once so plain TextFields inherit a visible reciprocal edge.
// Explicit field styles can still opt out where a platform-native control is intentional.
struct StockedOutlinedTextFieldStyle: TextFieldStyle {
    @Environment(\.colorScheme) private var colorScheme

    func _body(configuration: TextField<Self._Label>) -> some View {
        let dark = colorScheme == .dark
        configuration
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.appSurface(dark).opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm, style: .continuous)
                    .stroke(Color.contrastAccent(dark).opacity(0.38), lineWidth: 1.25)
            }
    }
}
extension View {
    func stockedPrimary(accent: Color = Color.stockedCharcoal, fg: Color = Color.stockedWhite) -> some View {
        buttonStyle(StockedPrimaryButtonStyle(accent: accent, fg: fg))
    }
    func stockedSecondary(accent: Color = Color.stockedGold) -> some View {
        buttonStyle(StockedSecondaryButtonStyle(accent: accent))
    }
}

// MARK: - Haptics (UI #15)
struct HapticManager {
    static func light()   { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium()  { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error()   { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func select()  { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - Skeleton loading (UI #1)
struct SkeletonView: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm)
            .fill(LinearGradient(
                colors: [Color.stockedCharcoal.opacity(0.06), Color.stockedCharcoal.opacity(0.13), Color.stockedCharcoal.opacity(0.06)],
                startPoint: .init(x: phase - 1, y: 0), endPoint: .init(x: phase, y: 0)))
            .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 2 } }
    }
}
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 14) {
            SkeletonView().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
            VStack(alignment: .leading, spacing: 8) {
                SkeletonView().frame(maxWidth: .infinity).frame(height: 14)
                SkeletonView().frame(width: 140).frame(height: 10)
            }
        }.padding(14).background(Color.stockedWhite.opacity(0.28)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }
}
struct SkeletonListView: View {
    var count: Int = StockedUI.skeletonRows
    var body: some View {
        VStack(spacing: 12) { ForEach(0..<count, id: \.self) { _ in SkeletonRow() } }.padding(.horizontal, 20)
    }
}

// MARK: - Empty states (UI #3)
// MARK: - Placeholder color fix (#1)
// Apply once on root view — makes placeholder text readable on tan background
struct FixPlaceholderColor: ViewModifier {
    @Environment(AppSession.self) var session
    func body(content: Content) -> some View {
        content.onAppear { applyTextFieldAppearance() }
               .onChange(of: session.isDarkMode) { _, _ in applyTextFieldAppearance() }
    }
    private func applyTextFieldAppearance() {
        let isDark = session.isDarkMode
        // Text color — forces typed text to be readable in both modes
        UITextField.appearance().textColor = isDark
            ? UIColor.white
            : UIColor(red: 0.13, green: 0.12, blue: 0.10, alpha: 1.0)  // stockedCharcoal
        // Placeholder color — slightly muted
        let phColor = isDark
            ? UIColor.white.withAlphaComponent(0.4)
            : UIColor(red: 0.13, green: 0.12, blue: 0.10, alpha: 0.45)
        _ = [NSAttributedString.Key.foregroundColor: phColor] // placeholder attrs reserved for future use
        UITextField.appearance().defaultTextAttributes = [
            .foregroundColor: (isDark ? UIColor.white : UIColor(red: 0.13, green: 0.12, blue: 0.10, alpha: 1.0))
        ]
        // Tint / cursor
        UITextField.appearance().tintColor = UIColor(Color.stockedGold)
    }
}

extension View {
    func fixPlaceholderColor() -> some View { modifier(FixPlaceholderColor()) }
}

struct StockedEmptyState: View {
    @Environment(AppSession.self) private var _dsSession
    @Environment(AppSession.self) var session
    let icon: String; let title: String; let subtitle: String
    var ctaLabel: String? = nil; var onCTA: (() -> Void)? = nil
    var tips: [String] = []   // optional contextual tips (#2)

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            // Animated icon
            Text(icon)
                .font(.system(size: 72))
                .padding(.bottom, 20)
            Text(title)
                .stocked(.headline)
                .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            Text(subtitle)
                .stocked(.body)
                .foregroundStyle(session.isDarkMode ? Color.stockedWhite.opacity(0.5) : Color.stockedCharcoal.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            // CTA button (only when provided)
            if let ctaLabel, let onCTA {
                Button(ctaLabel, action: onCTA).padding(.horizontal, 32).stockedPrimary()
            }
            // Contextual tips (#2)
            if !tips.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick tips")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.stockedGold)
                        .padding(.bottom, 2)
                    ForEach(tips, id: \.self) { tip in
                        HStack(alignment: .top, spacing: 8) {
                            Text("·").foregroundStyle(Color.stockedGold)
                            Text(tip)
                                .font(.system(size: 13))
                                .foregroundStyle(session.isDarkMode ? Color.stockedWhite.opacity(0.6) : Color.stockedCharcoal.opacity(0.6))
                        }
                    }
                }
                .padding(16)
                .background((session.isDarkMode ? Color.white : Color.stockedCharcoal).opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                .padding(.horizontal, 32)
                .padding(.top, 24)
            }
            Spacer()
        }.frame(maxWidth: .infinity).padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

// MARK: - Completion celebration (UX #15)
struct CelebrationOverlay: View {
    @Environment(AppSession.self) private var _dsSession
    @Binding var isShowing: Bool
    let title: String; let message: String; let emoji: String
    @State private var scale: CGFloat = 0.3; @State private var opacity: Double = 0
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { dismiss() }
            VStack(spacing: 20) {
                Text(emoji).font(.system(size: 80)).scaleEffect(scale)
                Text(title).stocked(.title).foregroundStyle(_dsSession.themeTextColor).multilineTextAlignment(.center)
                Text(message).stocked(.body).foregroundStyle(_dsSession.themeTextColor.opacity(0.6)).multilineTextAlignment(.center).padding(.horizontal, 32)
                Button("Continue") { dismiss() }.padding(.horizontal, 40).stockedPrimary()
            }
            .padding(32).background(Color.stockedBg).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
            .padding(.horizontal, 32).scaleEffect(scale).opacity(opacity)
        }
        .onAppear {
            HapticManager.success()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { scale = 1; opacity = 1 }
        }
    }
    private func dismiss() {
        withAnimation(.spring(response: 0.3)) { scale = 0.8; opacity = 0 }
        Task {
            try? await Task.sleep(nanoseconds: 300000000)
            isShowing = false
        }
    }
}

// MARK: - First-use tooltip (UX #3)

// MARK: - Triangle shape (for tooltips)
struct Triangle: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath(); return p
    }
}

// MARK: - Expiry colour (UI #11)
extension Color {
    static func expiryColor(daysLeft: Int?) -> Color {
        guard let d = daysLeft else { return .stockedGreen }
        if d < 0  { return .red }
        if d <= 1 { return .red }
        if d <= 3 { return .orange }
        if d <= 7 { return Color(red: 0.85, green: 0.65, blue: 0.1) }
        return .stockedGreen
    }
}

// MARK: - Dark mode aware card background (UI #14)
extension Color {
    static func cardSurface(dark: Bool) -> Color {
        dark ? Color(red: 0.14, green: 0.12, blue: 0.10) : Color.stockedWhite.opacity(0.32)
    }
    static func rowSurface(dark: Bool) -> Color {
        dark ? Color(white: 0.18) : Color.stockedWhite.opacity(0.20)
    }
}

// MARK: - Pressable scale button style (micro-animation on every button)
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
extension View {
    /// Apply to any button that isn't already using stockedPrimary/Secondary
    func pressable(scale: CGFloat = 0.96) -> some View { buttonStyle(PressableStyle(scale: scale)) }
}

// MARK: - List item spring-in modifier
struct SpringInModifier: ViewModifier {
    @State private var appeared = false
    let delay: Double
    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            .scaleEffect(appeared ? 1 : 0.97)
            .onAppear {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.78).delay(delay)) {
                    appeared = true
                }
            }
    }
}
extension View {
    func springIn(delay: Double = 0) -> some View { modifier(SpringInModifier(delay: delay)) }
}

// MARK: - Consistent corner radius shorthands
extension View {
    func cardRadius()  -> some View { cornerRadius(StockedUI.cornerRadiusMd) }
    func pillRadius()  -> some View { cornerRadius(StockedUI.cornerRadiusXL) }
    func sheetRadius() -> some View { cornerRadius(StockedUI.cornerRadiusLg) }
}

// MARK: - Wordmark (signature)
// The brand's signature touch: the period in "Stocked." is set in gold while the word
// takes the primary color. The period is literally part of the name, so the one accent
// lands on the most characteristic mark — applied consistently everywhere the wordmark
// appears, rather than scattering gold across the UI.
struct StockedWordmark: View {
    var size: CGFloat = 26
    var color: Color? = nil          // nil → caller's theme text color via environment
    var dotColor: Color? = nil       // nil → matches the wordmark text color (black in light mode)
    @Environment(AppSession.self) private var session

    var body: some View {
        let base = color ?? session.themeTextColor
        var word = AttributedString("Stocked")
        word.foregroundColor = base
        var dot = AttributedString(".")
        dot.foregroundColor = dotColor ?? base
        return Text(word + dot)
            .font(.system(size: size, weight: .bold, design: .serif))
    }
}

// MARK: - Section header (shared, redundancy cleanup #6)
// One styled section header for list/section labels across the app. Previously this same
// idea was reimplemented as private helpers in six different views (sectionHeader /
// sectionLabel / drawerHeader / sidebarHeader / drawerHeaderText) with slightly different
// sizes, tracking, and opacity. Those now route here for a consistent look. Text is rendered
// as-is (callers that want uppercase pass uppercase), so emoji/mixed-case labels are safe.
struct SectionHeader: View {
    let text: String
    var padded: Bool = true
    @Environment(AppSession.self) private var session

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(1)
            .foregroundStyle(session.themeTextColor.opacity(0.4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padded ? EdgeInsets(top: 10, leading: 24, bottom: 4, trailing: 24)
                             : EdgeInsets())
    }
}



// MARK: - Global keyboard dismissal
// Use .dismissKeyboardOnTap() on any container to let tapping outside dismiss the keyboard.
// Use .keyboardDoneToolbar() on any TextField that needs an explicit Done button.
extension View {
    /// Dismisses the keyboard when the user taps anywhere outside a text field.
    func dismissKeyboardOnTap() -> some View {
        self.onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
    }

    /// Adds a "Done" button above the keyboard that dismisses it.
    func keyboardDoneToolbar() -> some View {
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.stockedGold)
            }
        }
    }
}

// MARK: - StockedSheet — consistent wrapper for ALL popup/sheet views
// Use this instead of raw ZStack in every sheet. Provides:
//   • App-coloured background
//   • Drag handle
//   • Bold serif title + X close button
//   • Divider under header
struct StockedSheet<Content: View>: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    let title: String
    var showClose: Bool = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
                // Handle
                Capsule()
                    .fill(session.themeTextColor.opacity(0.18))
                    .frame(width: 40, height: 4)
                    .padding(.top, 12)
                // Header
                HStack(alignment: .center) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    if showClose {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(session.themeTextColor.opacity(0.22))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 14)
                Divider().padding(.horizontal, 24)
                // Content
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(session.themeBgColor.ignoresSafeArea())
            .presentationDragIndicator(.hidden)
    }
}

// MARK: - Title Tap Environment Key (triggers Daily Brief from StockedShell)
struct StockedTitleTapKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
extension EnvironmentValues {
    var stockedTitleTap: (() -> Void)? {
        get { self[StockedTitleTapKey.self] }
        set { self[StockedTitleTapKey.self] = newValue }
    }
}

// MARK: - Dismiss Environment Key (for screens shown as custom overlays, where the
// SwiftUI @Environment(\.dismiss) does nothing). The Shell Header back button prefers
// this when present so "back" works on overlay-presented screens (Stats, Search, etc.).
struct StockedDismissKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
extension EnvironmentValues {
    var stockedDismiss: (() -> Void)? {
        get { self[StockedDismissKey.self] }
        set { self[StockedDismissKey.self] = newValue }
    }
}

// MARK: - Go Home Environment Key (pops NavigationStack to root + selects Home tab)
// Used by deep flows (e.g. cook → rating) to return to the live shell instead of
// pushing a second MainTabView, which would nest a duplicate NavigationStack + tab bar.
struct StockedGoHomeKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
extension EnvironmentValues {
    var stockedGoHome: (() -> Void)? {
        get { self[StockedGoHomeKey.self] }
        set { self[StockedGoHomeKey.self] = newValue }
    }
}

// MARK: - Overlay Active Environment Key (dims header + tab bar behind prompts)
struct StockedOverlayActiveKey: EnvironmentKey {
    static let defaultValue: Bool = false
}
extension EnvironmentValues {
    var stockedOverlayActive: Bool {
        get { self[StockedOverlayActiveKey.self] }
        set { self[StockedOverlayActiveKey.self] = newValue }
    }
}

// MARK: - StockedFlowLayout
// A wrapping (flow) layout that arranges subviews left-to-right, wrapping to a new
// row when the next subview would exceed the proposed width. Uses the SwiftUI Layout
// protocol — measures real subview sizes, so it needs no GeometryReader and no
// character-count width guessing. Replaces the old GeometryReader-based tag clouds.
struct StockedFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + lineSpacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && (x - bounds.minX) + size.width > maxWidth {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - StockedTopShell — top-aligned screen/sheet container
// A bulletproof top-pinned container: a ROOT VStack (no centering ZStack) with the
// background applied as a modifier. Content always starts at the top — fixes the
// "floating in the middle with a gap above" problem that ZStack { bg; VStack } causes
// when the inner content sizes to itself instead of filling. Use for sheets/pages that
// want the standard "Stocked." header + a subtitle, then their own scrollable content.
struct StockedTopShell<Content: View>: View {
    @Environment(AppSession.self) private var session
    let subtitle: String
    var onBack: (() -> Void)? = nil
    var showHandle: Bool = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if showHandle {
                Capsule().fill(session.themeTextColor.opacity(0.18))
                    .frame(width: 40, height: 4)
                    .padding(.top, 10).padding(.bottom, 6)
            }
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                    }.buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 24)
                }
                Spacer()
                Text("Stocked.")
                    .font(.system(size: 26, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                Color.clear.frame(width: 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, showHandle ? 2 : 12)
            .padding(.bottom, 4)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 18, weight: .regular, design: .serif))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                    .padding(.bottom, 14)
            }

            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(session.themeBgColor.ignoresSafeArea())
    }
}
