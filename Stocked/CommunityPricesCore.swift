import Foundation

nonisolated struct CommunityPriceResponse: Codable, Sendable {
    struct Observation: Codable, Identifiable, Sendable, Equatable {
        let id: Int
        let price: Double
        let currency: String
        let observedAt: String?
        let pricePer: String?
        let discounted: Bool
        let discountType: String?
        let regularPrice: Double?
        let store: String?
        let city: String?
        let country: String?
        let sourceURL: String
    }
    struct Source: Codable, Sendable {
        let name: String
        let url: String
        let license: String
        let licenseURL: String
        let locationAttribution: String?
        let locationSourceURL: String?
    }
    let barcode: String
    let found: Bool
    let observations: [Observation]
    let source: Source
    let fetchedAt: String
    let cached: Bool
    let note: String
    let moreAvailable: Bool
}

/// Device preferences and community observations, never personal receipt/retailer prices.
nonisolated struct CommunityPriceWatch: Codable, Sendable, Identifiable, Equatable {
    enum Basis: String, Codable, CaseIterable, Sendable {
        case item = "UNIT", kilogram = "KILOGRAM", liter = "LITER"
        var label: String { switch self { case .item: "Per item"; case .kilogram: "Per kilogram"; case .liter: "Per liter" } }
    }
    var id = UUID()
    var label = ""
    var barcode = ""
    var currency = "USD"
    var basis: Basis = .item
    var targetPrice = 1.0
    var country = ""
    var city = ""
    var maximumAgeDays = 30
    var includeDiscounts = false
    var paused = false
    var editID = UUID()
    var lastAttempt: Date?
    var lastSuccess: Date?
    var failure: String?
    var match: CommunityPriceResponse.Observation?
    var excludedCount = 0
    var lastAlertKey: String?

    func validated() throws -> Self {
        var value = self
        value.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        value.barcode = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        value.currency = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        value.country = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        value.city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.label.isEmpty, value.label.count <= 80 else { throw Failure.name }
        guard [8, 12, 13, 14].contains(value.barcode.count), value.barcode.utf8.allSatisfy({ (48...57).contains($0) }) else { throw Failure.barcode }
        guard value.currency.utf8.count == 3, value.currency.utf8.allSatisfy({ (65...90).contains($0) }) else { throw Failure.currency }
        guard value.country.isEmpty || (value.country.utf8.count == 2 && value.country.utf8.allSatisfy({ (65...90).contains($0) })), value.city.count <= 80 else { throw Failure.location }
        guard targetPrice.isFinite, targetPrice > 0, targetPrice <= 100_000, (1...365).contains(maximumAgeDays) else { throw Failure.target }
        return value
    }
    enum Failure: LocalizedError {
        case name, barcode, currency, location, target, changed, limit
        var errorDescription: String? {
            switch self {
            case .name: "Give this price check a name of up to 80 characters."
            case .barcode: "Use a barcode with 8, 12, 13 or 14 digits."
            case .currency: "Use a three-letter currency code, such as USD."
            case .location: "Use a two-letter country code, such as US, and a city of up to 80 characters."
            case .target: "Choose a price above zero and up to 100,000, and reports from the last 1–365 days."
            case .changed: "This price check changed or was removed. Reopen it before saving."
            case .limit: "Keep up to 20 saved price checks on this device. Remove one before adding another."
            }
        }
    }
}

nonisolated enum CommunityPriceWatchEngine {
    struct Result: Sendable { let match: CommunityPriceResponse.Observation?; let excluded: Int }
    static func evaluate(_ observations: [CommunityPriceResponse.Observation], watch: CommunityPriceWatch,
                         now: Date = Date()) throws -> Result {
        let rule = try watch.validated()
        guard now.timeIntervalSince1970.isFinite else { throw CommunityPriceWatch.Failure.target }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        var eligible: [CommunityPriceResponse.Observation] = []
        for row in observations.prefix(25) {
            guard row.price.isFinite, row.price >= 0, row.currency == rule.currency,
                  row.pricePer == rule.basis.rawValue, rule.includeDiscounts || !row.discounted,
                  rule.country.isEmpty || normalize(row.country ?? "") == normalize(rule.country),
                  rule.city.isEmpty || normalize(row.city ?? "") == normalize(rule.city),
                  let date = day(row.observedAt), date <= today,
                  let age = calendar.dateComponents([.day], from: date, to: today).day,
                  age < rule.maximumAgeDays else { continue }
            eligible.append(row)
        }
        let matches = eligible.filter { $0.price <= rule.targetPrice }.sorted {
            if $0.price != $1.price { return $0.price < $1.price }
            if $0.observedAt != $1.observedAt { return ($0.observedAt ?? "") > ($1.observedAt ?? "") }
            return $0.id < $1.id
        }
        return Result(match: matches.first, excluded: min(25, observations.count) - eligible.count)
    }
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func alertKey(_ row: CommunityPriceResponse.Observation) -> String {
        "\(row.id)|\(row.price)|\(row.currency)|\(row.pricePer ?? "")|\(row.observedAt ?? "")|\(row.discounted)"
    }
    static func day(_ input: String?) -> Date? {
        guard let input, input.utf8.count == 10 else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: input), formatter.string(from: date) == input else { return nil }
        return date
    }
}
