// MarqueeText.swift — a one-line label that auto-scrolls horizontally when the
// text is wider than its container, instead of wrapping or truncating.
//
// Grocery rows use it so long names ("Enchilada sauce (14 oz)") stay on a single
// line and glide back and forth to reveal the tail. Short text renders statically.
// Respects Reduce Motion (falls back to a static truncated line).
//
// Implementation note: the text is measured by an invisible copy that is ALWAYS
// present — the first version only measured inside the overflow branch, so the
// width stayed 0 and the glide never started.
import SwiftUI

struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 15)
    var color: Color = .primary
    var strikethrough: Bool = false
    /// Points per second of glide; the loop pauses briefly at each end.
    var speed: CGFloat = 30

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animating = false

    var body: some View {
        GeometryReader { geo in
            let container = geo.size.width
            let overflows = textWidth > container + 1

            ZStack(alignment: .leading) {
                // Invisible measurer — always laid out at natural width.
                styled(Text(text))
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .background(
                        GeometryReader { tg in
                            Color.clear
                                .onAppear { textWidth = tg.size.width }
                                .onChange(of: tg.size.width) { _, w in textWidth = w }
                        }
                    )

                if overflows && !UIAccessibility.isReduceMotionEnabled {
                    styled(Text(text))
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: offset)
                        .onAppear { glide(container: container) }
                        .onChange(of: text) { _, _ in
                            animating = false; offset = 0
                            glide(container: container)
                        }
                } else {
                    styled(Text(text))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: container, alignment: .leading)
            .clipped()
        }
        .frame(height: UIFont.preferredFont(forTextStyle: .body).lineHeight + 2)
    }

    private func styled(_ t: Text) -> some View {
        t.font(font)
            .foregroundStyle(color)
            .strikethrough(strikethrough)
            .lineLimit(1)
    }

    /// Glide left to reveal the tail, pause, glide back, pause, repeat.
    private func glide(container: CGFloat) {
        let distance = max(0, textWidth - container + 8)
        guard distance > 0, !animating else { return }
        animating = true
        withAnimation(.linear(duration: Double(distance / speed)).delay(0.9)
                        .repeatForever(autoreverses: true)) {
            offset = -distance
        }
    }
}

/// Splits a grocery display name into a clean name plus a leading count or size,
/// so rows read "Corn tortillas" with qty 6 instead of "6 corn tor…". Handles
/// "6 corn tortillas", "14 oz jar Enchilada sauce", "3 Cups shredded cheese".
nonisolated enum GroceryNameParser {
    private static let units: Set<String> = ["oz","g","kg","lb","lbs","ml","l","cup","cups",
        "tbsp","tsp","quart","quarts","pint","pints","gallon","gallons","gram","grams",
        "ounce","ounces","pound","pounds","liter","liters","can","cans","jar","jars",
        "bottle","bottles","bag","bags","box","boxes","pkg","package","packages"]

    /// Returns (cleanName, count, sizeText). count is nil when no leading count applies;
    /// sizeText is "" when no measured size leads the name.
    static func parse(_ raw: String) -> (name: String, count: Int?, sizeText: String) {
        var tokens = raw.split(separator: " ").map(String.init)
        guard tokens.count >= 2, let lead = Double(tokens[0].replacingOccurrences(of: ",", with: ".")) else {
            return (raw, nil, "")
        }
        let second = tokens[1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        if units.contains(second) {
            // "14 oz jar Enchilada sauce" → size "14 oz", name "jar Enchilada sauce" →
            // drop a following container word too ("jar of", "can").
            let size = "\(tokens[0]) \(tokens[1])"
            tokens.removeFirst(2)
            if let first = tokens.first?.lowercased(), units.contains(first) || first == "of" {
                tokens.removeFirst()
            }
            let name = tokens.joined(separator: " ")
            return (name.isEmpty ? raw : name, nil, size)
        }
        // "6 corn tortillas" → count 6, name "corn tortillas"
        if lead > 0, lead <= 50, lead == lead.rounded() {
            tokens.removeFirst()
            let name = tokens.joined(separator: " ")
            return (name.isEmpty ? raw : name, Int(lead), "")
        }
        return (raw, nil, "")
    }
}
