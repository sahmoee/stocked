// WrappableText.swift
// #FB3 — recipe text scraped from the web (TheMealDB instructions especially)
// often carries non-breaking spaces (U+00A0), narrow no-break spaces, zero-width
// characters, carriage returns, and tabs. SwiftUI's Text cannot break a line
// inside a run of non-breaking spaces, so a long step laid out wider than the
// screen and clipped mid-word at the right edge. Normalizing that whitespace
// before display makes every step and ingredient wrap normally.

import Foundation

extension String {
    /// The same text with exotic whitespace normalized to plain spaces/newlines
    /// so SwiftUI can wrap it. Safe to apply repeatedly.
    var stockedWrappable: String {
        var s = self
        // Non-breaking + narrow no-break + figure spaces → plain space.
        for ch in ["\u{00A0}", "\u{202F}", "\u{2007}", "\u{2009}", "\t"] {
            s = s.replacingOccurrences(of: ch, with: " ")
        }
        // Zero-width characters → removed outright.
        for ch in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2060}"] {
            s = s.replacingOccurrences(of: ch, with: "")
        }
        // Carriage returns → newlines (Windows-style scrapes).
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
             .replacingOccurrences(of: "\r", with: "\n")
        return s
    }
}
