// MarqueeText.swift — retained as a source-compatible name for grocery rows.
// Labels now wrap before scaling so larger Dynamic Type sizes never turn a useful
// item name into "xyz…" or require motion to reveal the value.
//
// The old marquee was inaccessible with Reduce Motion and still truncated in that
// mode.  A wrap-first layout is deterministic, readable, and grows with the user's
// preferred content size.
import SwiftUI

struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 15)
    var color: Color = .primary
    var strikethrough: Bool = false
    /// Kept for API compatibility with existing callers. No motion is performed.
    var speed: CGFloat = 30

    var body: some View {
        styled(Text(text))
            .stockedAdaptiveLabel(maxLines: 3, alignment: .leading, minimumScale: 0.82)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func styled(_ t: Text) -> some View {
        t.font(font)
            .foregroundStyle(color)
            .strikethrough(strikethrough)
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
