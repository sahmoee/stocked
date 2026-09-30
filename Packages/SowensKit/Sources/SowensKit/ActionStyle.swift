import SwiftUI

/// Native-sized controls with shared disabled, press, hover and Reduce Motion behavior.
/// Colors and typography are supplied by each app's existing theme.
public struct SowensActionStyle<Fill: ShapeStyle>: ButtonStyle {
    let fill: Fill
    let foreground: Color
    let radius: CGFloat
    let font: Font
    public init(fill: Fill, foreground: Color, radius: CGFloat = 16, font: Font = .subheadline.bold()) {
        self.fill = fill
        self.foreground = foreground
        self.radius = radius
        self.font = font
    }
    public func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, fill: fill, foreground: foreground, radius: radius, font: font)
    }
    private struct ActionBody: View {
        let configuration: ButtonStyleConfiguration
        let fill: Fill
        let foreground: Color
        let radius: CGFloat
        let font: Font
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        var body: some View {
            configuration.label.font(font).padding(.horizontal, 20).padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(foreground)
                .sowensSurface(fill: fill, border: hovering && enabled ? .white : .clear, radius: radius, lineWidth: 2)
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                #if os(iOS) || os(macOS) || os(visionOS)
                .onHover { hovering = $0 }
                #endif
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        }
    }
}
