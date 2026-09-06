import Foundation
import CryptoKit
import CoreFoundation
#if canImport(FoundationXML)
import FoundationXML
#endif

nonisolated enum KitchenConnectionFailure: LocalizedError, Equatable {
    case endpoint, credentials, response, tooLarge, noCalendars, conflict, permission, changed, cancelled, network, storage, rateLimited
    var errorDescription: String? {
        switch self {
        case .endpoint: "Use an HTTPS address without a password, query or fragment. Calendar links must stay on the same server."
        case .credentials: "The server did not accept these credentials. Check the address and key or app password."
        case .response: "The server returned an unsupported response. Nothing was silently imported or replaced."
        case .tooLarge: "This response or selection is too large. Use a smaller list or fewer meals."
        case .noCalendars: "No calendars were found. Enter your calendar home URL or a calendar's full CalDAV URL."
        case .conflict: "This calendar entry changed or belongs to another source. It was kept. Refresh the preview."
        case .permission: "Your household role cannot make this change."
        case .changed: "The source or your kitchen changed during review. Refresh and review again."
        case .cancelled: "Stopped. Any completed additions stay saved."
        case .network: "The server could not be reached securely. Check your connection and try again."
        case .storage: "Device-only connection settings could not be saved. Unlock the device and try again."
        case .rateLimited: "The server asked you to wait. Try again later."
        }
    }
}

nonisolated enum KitchenConnectionPolicy {
    static let maximumResponseBytes = 2 * 1024 * 1024
    static func endpoint(_ text: String) throws -> URL {
        guard text.utf8.count <= 2_048, let c = URLComponents(string: text), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, let url = c.url,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw KitchenConnectionFailure.endpoint
        }
        return url
    }
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == "https" && rhs.scheme?.lowercased() == "https"
            && lhs.host?.lowercased() == rhs.host?.lowercased() && (lhs.port ?? 443) == (rhs.port ?? 443)
            && rhs.user == nil && rhs.password == nil
    }
    static func href(_ text: String, relativeTo base: URL) throws -> URL {
        guard text.utf8.count <= 2_048, let url = URL(string: text, relativeTo: base)?.absoluteURL,
              sameOrigin(base, url), url.query == nil, url.fragment == nil,
              !url.pathComponents.contains("..") else { throw KitchenConnectionFailure.endpoint }
        return try endpoint(url.absoluteString)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    static func nameKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func safeLine(_ text: String, maximum: Int = 500) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= maximum
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }
}

nonisolated struct GrocyImportRow: Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case inventory, shopping }
    let id: String
    let kind: Kind
    let name: String
    let remoteAmount: String
    let unit: String
    let suggestedContainers: Int?
    let note: String
    let fingerprint: String
}

/// Grocy's stock/shopping amounts use product stock units, not necessarily containers.
/// Only explicit count units with positive whole values become a suggested count.
nonisolated enum GrocyReadParser {
    static func parse(stock: Data, shopping: Data, products: Data, units: Data) throws -> [GrocyImportRow] {
        let productRows = try rows(products, maximum: 2_000), unitRows = try rows(units, maximum: 1_000)
        let productMap = Dictionary(productRows.compactMap { row -> (String, [String: Any])? in
            guard let id = identifier(row["id"]) else { return nil }; return (id, row)
        }, uniquingKeysWith: { first, _ in first })
        let unitMap = Dictionary(unitRows.compactMap { row -> (String, String)? in
            guard let id = identifier(row["id"]), let name = row["name"] as? String,
                  KitchenConnectionPolicy.safeLine(name, maximum: 100) else { return nil }; return (id, name)
        }, uniquingKeysWith: { first, _ in first })
        var result: [GrocyImportRow] = [], seen = Set<String>()
        for (kind, data) in [(GrocyImportRow.Kind.inventory, stock), (.shopping, shopping)] {
            for row in try rows(data, maximum: 500) {
                let embedded = row["product"] as? [String: Any]
                let productID = identifier(row["product_id"]) ?? identifier(embedded?["id"])
                let product = embedded ?? productID.flatMap { productMap[$0] }
                let rawNote = row["note"] as? String ?? ""
                let name = product?["name"] as? String ?? (kind == .shopping ? rawNote : "")
                guard KitchenConnectionPolicy.safeLine(name) else { throw KitchenConnectionFailure.response }
                let rowID = kind == .inventory ? productID : identifier(row["id"])
                guard let rowID else { throw KitchenConnectionFailure.response }
                let id = "\(kind.rawValue):\(rowID)"
                guard seen.insert(id).inserted else { throw KitchenConnectionFailure.response }
                let amount = number(row["amount"])
                guard let amount, amount.isFinite, amount >= 0 else { throw KitchenConnectionFailure.response }
                if amount == 0 { continue }
                let unitID = identifier(product?["qu_id_stock"])
                let unit = unitID.flatMap { unitMap[$0] } ?? "unknown unit"
                let countUnits: Set<String> = ["piece", "pieces", "item", "items", "unit", "units", "each"]
                let count = countUnits.contains(unit.lowercased()) && amount.rounded() == amount && amount <= 999 ? Int(amount) : nil
                let amountText = String(format: "%.8g", amount)
                let due = row["best_before_date"] as? String ?? ""
                let notes = [rawNote != name && KitchenConnectionPolicy.safeLine(rawNote) ? rawNote : "",
                             !due.isEmpty && KitchenConnectionPolicy.safeLine(due, maximum: 40) ? "Earliest Grocy due date: \(due). Check individual packages." : ""]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                result.append(GrocyImportRow(id: id, kind: kind, name: name, remoteAmount: amountText, unit: unit,
                                            suggestedContainers: count, note: notes,
                                            fingerprint: KitchenConnectionPolicy.hash([id, name, amountText, unit, notes].joined(separator: "\n"))))
            }
        }
        return result
    }
    private static func rows(_ data: Data, maximum: Int) throws -> [[String: Any]] {
        guard data.count <= KitchenConnectionPolicy.maximumResponseBytes else { throw KitchenConnectionFailure.tooLarge }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw KitchenConnectionFailure.response }
        guard result.count <= maximum else { throw KitchenConnectionFailure.tooLarge }
        return result
    }
    private static func identifier(_ value: Any?) -> String? {
        guard let number = number(value), number >= 0, number <= 9_007_199_254_740_991, number.rounded() == number else { return nil }
        return String(format: "%.0f", number)
    }
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

nonisolated struct CalDAVCalendar: Identifiable, Sendable, Equatable {
    var id: String { url.absoluteString }
    let url: URL
    let title: String
}

nonisolated enum CalDAVReadParser {
    static func calendars(_ data: Data, base: URL) throws -> [CalDAVCalendar] {
        guard data.count <= 512 * 1024 else { throw KitchenConnectionFailure.tooLarge }
        guard let decoded = String(data: data, encoding: .utf8) else { throw KitchenConnectionFailure.response }
        let text = decoded.uppercased()
        guard !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw KitchenConnectionFailure.response }
        let delegate = CalendarXMLReader()
        let parser = XMLParser(data: data); parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.failed else { throw KitchenConnectionFailure.response }
        var seen = Set<String>(), result: [CalDAVCalendar] = []
        for row in delegate.rows {
            guard let url = try? KitchenConnectionPolicy.href(row.href, relativeTo: base), seen.insert(url.absoluteString).inserted else { continue }
            result.append(CalDAVCalendar(url: url, title: KitchenConnectionPolicy.safeLine(row.name, maximum: 256) ? row.name : "Calendar"))
        }
        return result
    }
    private final class CalendarXMLReader: NSObject, XMLParserDelegate {
        struct Row { var href = ""; var name = "" }
        var rows: [Row] = []; var failed = false
        private var depth = 0, responseCount = 0
        private var path: [String] = [], texts: [String] = []
        private var current = Row(), propertyName = "", status = "", calendar = false, responseCalendar = false
        private var componentSeen = false, supportsEvents = false
        private var responseComponentSeen = false, responseSupportsEvents = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            guard depth <= 24 else { failed = true; parser.abortParsing(); return }
            path.append("\(namespaceURI ?? "")|\(name)"); texts.append("")
            if namespaceURI == "DAV:", name == "response" {
                responseCount += 1
                guard responseCount <= 100 else { failed = true; parser.abortParsing(); return }
                current = Row(); responseCalendar = false; responseComponentSeen = false; responseSupportsEvents = false
            }
            if namespaceURI == "DAV:", name == "propstat" { propertyName = ""; status = ""; calendar = false; componentSeen = false; supportsEvents = false }
            if namespaceURI == "urn:ietf:params:xml:ns:caldav", name == "calendar" { calendar = true }
            if namespaceURI == "urn:ietf:params:xml:ns:caldav", name == "supported-calendar-component-set" { componentSeen = true }
            if namespaceURI == "urn:ietf:params:xml:ns:caldav", name == "comp", attributes["name"] == "VEVENT" { supportsEvents = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !texts.isEmpty else { return }
            texts[texts.count - 1] += string
            if texts.last!.utf8.count > 4_096 { failed = true; parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = texts.popLast() ?? ""; _ = path.popLast(); depth -= 1
            if namespaceURI == "DAV:", name == "href", path.last == "DAV:|response" { current.href = value.trimmingCharacters(in: .whitespacesAndNewlines) }
            if namespaceURI == "DAV:", name == "displayname" { propertyName = value }
            if namespaceURI == "DAV:", name == "status" { status = value }
            if namespaceURI == "DAV:", name == "propstat", status.split(separator: " ").contains("200") {
                if !propertyName.isEmpty { current.name = propertyName }
                responseCalendar = responseCalendar || calendar
                responseComponentSeen = responseComponentSeen || componentSeen
                responseSupportsEvents = responseSupportsEvents || supportsEvents
            }
            if namespaceURI == "DAV:", name == "response", responseCalendar,
               !responseComponentSeen || responseSupportsEvents { rows.append(current) }
        }
    }
}

nonisolated struct CalDAVMeal: Identifiable, Sendable, Equatable {
    let id: String // source-specific stable identity, without household/member identifiers
    let civilDate: String
    let title: String
    let mealType: String
    let servings: Int
    var uid: String { "stocked-\(KitchenConnectionPolicy.hash(id))@stocked" }
    var filename: String { "stocked-\(KitchenConnectionPolicy.hash(id)).ics" }
    var contentKey: String { KitchenConnectionPolicy.hash([id, civilDate, title, mealType, String(servings)].joined(separator: "\n")) }
}

nonisolated enum CalDAVMealExport {
    static func calendar(_ meal: CalDAVMeal, now: Date = Date()) throws -> Data {
        guard KitchenConnectionPolicy.safeLine(meal.id, maximum: 200), KitchenConnectionPolicy.safeLine(meal.title),
              KitchenConnectionPolicy.safeLine(meal.mealType, maximum: 40), (1...100).contains(meal.servings),
              now.timeIntervalSinceReferenceDate.isFinite else { throw KitchenConnectionFailure.response }
        let start = try PlanAheadCore.parseDate(meal.civilDate, timeZoneID: "UTC")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { throw KitchenConnectionFailure.response }
        let endKey = try PlanAheadCore.dateKey(for: end, timeZoneID: "UTC").replacingOccurrences(of: "-", with: "")
        let stamp = DateFormatter(); stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.calendar = cal
        stamp.timeZone = cal.timeZone; stamp.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Sowens Studios//Stocked Meal Copy//EN", "BEGIN:VEVENT",
                     "UID:\(meal.uid)", "DTSTAMP:\(stamp.string(from: now))", "DTSTART;VALUE=DATE:\(meal.civilDate.replacingOccurrences(of: "-", with: ""))",
                     "DTEND;VALUE=DATE:\(endKey)", "SUMMARY:\(escape(meal.mealType + ": " + meal.title))",
                     "DESCRIPTION:\(escape("Meal copy from Stocked. Servings: \(meal.servings). Changes are published only after review."))",
                     "CLASS:PRIVATE", "TRANSP:TRANSPARENT", "X-STOCKED-EXPORT:1", "END:VEVENT", "END:VCALENDAR"]
        return Data((lines.map(MealPlanExchange.fold).joined(separator: "\r\n") + "\r\n").utf8)
    }
    static func isOwnEvent(_ data: Data, uid: String) -> Bool {
        guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\r\n\t", with: "")
            .components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.filter { $0 == "BEGIN:VEVENT" }.count == 1 && lines.filter { $0 == "BEGIN:VCALENDAR" }.count == 1
            && lines.filter { $0.hasPrefix("UID:") } == ["UID:\(uid)"] && lines.contains("X-STOCKED-EXPORT:1")
            && !lines.contains(where: { $0.hasPrefix("ATTENDEE") || $0.hasPrefix("ORGANIZER") || $0.hasPrefix("RECURRENCE-ID") || $0.hasPrefix("RRULE") })
    }
    static func strongETag(_ value: String?) -> String? {
        guard let value, value.count <= 256, value.hasPrefix("\""), value.hasSuffix("\""),
              value.count >= 2,
              value.dropFirst().dropLast().unicodeScalars.allSatisfy({ $0.value == 0x21 || (0x23...0x7e).contains($0.value) }) else { return nil }
        return value
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
    }
}
