// CSVInterchange.swift
// Shared, pure CSV helpers for every Stocked CSV export/import (kitchen transfer, recipe
// library, inventory share, standalone inventory/grocery exporter).
//
// Why one place:
//   • Exported cells are user-controlled text (item names, brands, recipe titles, recipe
//     names imported from the web). A cell that starts with = + - @ (or a tab/CR) is run as a
//     formula by Numbers/Excel/Sheets when the CSV is opened ("CSV injection"). We neutralise
//     those cells with a leading apostrophe — the convention spreadsheets themselves use —
//     and strip it again on import so our own exports still round-trip byte-for-byte.
//   • Fields containing a carriage return must be quoted too, or a CR-only line break inside
//     a name splits the row on import.
//   • Excel's "CSV UTF-8" adds a byte-order mark; without stripping it the first header
//     ("Section") no longer matches and grocery rows silently import as pantry items.
import Foundation

nonisolated enum CSVInterchange {

    /// Scalars that make spreadsheet apps evaluate a cell as a formula. Checked per Unicode
    /// scalar because Swift folds "\r\n" into ONE Character that equals neither "\r" nor "\n".
    private static let formulaLeads: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]
    private static let needsQuoting: Set<Unicode.Scalar> = [",", "\"", "\n", "\r"]

    /// Escapes one text cell: neutralises formula leads, then RFC-4180 quotes the field when it
    /// contains a comma, quote, CR or LF (internal quotes doubled).
    static func escape(_ raw: String) -> String {
        var s = raw
        if let first = s.unicodeScalars.first, (formulaLeads.contains(first) || first == "'") { s = "'" + s }
        if s.unicodeScalars.contains(where: { needsQuoting.contains($0) }) {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }

    /// Reverses the formula guard added by `escape` (only when the apostrophe is followed by a
    /// formula lead or another apostrophe). Export doubles a literal leading apostrophe
    /// so names such as "'=literal" round-trip without losing user text.
    static func unguard(_ cell: String) -> String {
        let scalars = cell.unicodeScalars
        guard scalars.first == "'", let next = scalars.dropFirst().first, (formulaLeads.contains(next) || next == "'") else {
            return cell
        }
        return String(cell.dropFirst())
    }

    /// Minimal RFC-4180 parser shared by every CSV importer: quoted fields, embedded commas and
    /// line breaks, doubled quotes, LF / CR / CRLF row endings (CRLF arrives as a single Swift
    /// Character, which the old per-importer parsers never matched — Excel/Windows files were
    /// read as one giant row), and a leading byte-order mark. Whitespace-only rows are dropped.
    static func parseRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []; var field = ""; var row: [String] = []
        var inQuotes = false
        let chars = Array(stripBOM(text))
        func endRow() {
            row.append(field); field = ""
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }
            row = []
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r\n", "\n", "\r":
                    if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                    endRow()
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Removes a leading UTF-8 byte-order mark (U+FEFF), if present.
    static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Upper bound for an imported container count; anything larger is a typo or garbage.
    static let maximumImportedQuantity = 100_000

    /// Parses an imported quantity cell. Accepts integers and decimals ("2", "2.0", "1.5" → 2),
    /// clamps to 1...maximumImportedQuantity, and falls back for blanks/garbage/non-finite.
    static func quantity(_ cell: String, fallback: Int = 1) -> Int {
        let t = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = Int(t) { return min(max(i, 1), maximumImportedQuantity) }
        if let d = Double(t), d.isFinite {
            let rounded = d.rounded()
            if rounded < 1 { return 1 }
            if rounded > Double(maximumImportedQuantity) { return maximumImportedQuantity }
            return Int(rounded)
        }
        return fallback
    }

    /// Parses an imported date cell. Accepts full ISO-8601 timestamps (our kitchen export) and
    /// plain `yyyy-MM-dd` dates (our inventory export and most spreadsheets). Date-only values
    /// land at local noon so a time-zone offset can never shift them to the previous day.
    static func date(_ cell: String, calendar: Calendar = .current) -> Date? {
        let t = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let full = ISO8601DateFormatter().date(from: t) { return full }
        let parts = t.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = 12
        guard let date = calendar.date(from: comps),
              calendar.component(.day, from: date) == d else { return nil }   // rejects Feb 30
        return date
    }
}
