// MarqueeText.swift — a one-line label that auto-scrolls horizontally when the
// text is wider than its container, instead of wrapping or truncating.
//
// Grocery rows use it so long names ("Enchilada sauce (14 oz)") stay on a single
// line and glide back and forth to reveal the tail. Short text renders as a plain
// static Text with zero overhead. Respects Reduce Motion (falls back to a static
// truncated line).
import SwiftUI

struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 15)
    var color: Color = .primary
    var strikethrough: Bool = false
    /// Points per second of glide; the loop pauses briefly at each end.
    var speed: CGFloat = 30

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflows: Bool { textWidth > containerWidth + 1 }

    var body: some View {
        GeometryReader { geo in
            let label = Text(text)
                .font(font)
                .foregroundStyle(color)
                .strikethrough(strikethrough)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { tg in
                        Color.clear.onAppear { textWidth = tg.size.width }
                            .onChange(of: text) { _, _ in textWidth = tg.size.width }
                    }
                )

            Group {
                if overflows && !UIAccessibility.isReduceMotionEnabled {
                    label
                        .offset(x: offset)
                        .onAppear { startGlide(container: geo.size.width) }
                        .onChange(of: text) { _, _ in offset = 0; startGlide(container: geo.size.width) }
                } else {
                    // Fits (or Reduce Motion): plain single line, truncated if needed.
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .strikethrough(strikethrough)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in containerWidth = w }
        }
        // GeometryReader is greedy vertically; pin to the label's natural height.
        .frame(height: UIFont.preferredFont(forTextStyle: .body).lineHeight)
    }

    /// Glide left to reveal the tail, pause, glide back, pause, repeat.
    private func startGlide(container: CGFloat) {
        let distance = max(0, textWidth - container + 8)
        guard distance > 0 else { return }
        let duration = Double(distance / speed)
        withAnimation(.linear(duration: duration).delay(0.9)
                        .repeatForever(autoreverses: true)) {
            offset = -distance
        }
    }
}
