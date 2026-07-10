// CrowdDB.swift — Stocked client for the shared, anonymized crowd item database.
//
// Opt-in: nothing is sent unless the user enables "Improve Stocked for everyone" (a Settings
// toggle stored in UserDefaults key "crowdShareEnabled"). Only item facts are sent — never
// account, name, email, or location. In return the app gets smarter defaults from everyone:
//   • suggested unit / container / quantity when adding or scanning an item
//   • item-name autocomplete
//   • ingredient pairings ("goes well with…")
//
// Configure CROWD_URL + CROWD_KEY in Secrets.xcconfig / Info.plist, or set the constants below.

import Foundation

struct CrowdSuggestion: Codable {
    var count: Int
    var topUnit: String?
    var topContainer: String?
    var topCategory: String?
    var avgQuantity: Double?
}

enum CrowdDB {

    // Point these at your deployed crowd-worker (or read from Info.plist / Secrets.xcconfig).
    static var baseURL: String { bundle("CrowdWorkerURL") ?? "https://stocked-crowd.stocked.workers.dev" }
    static var key: String { bundle("CrowdWorkerKey") ?? "" }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "crowdShareEnabled") }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    // MARK: Report (opt-in, anonymized)

    /// Report item facts. No-ops unless the user opted in. `basket` links items used together
    /// (for pairings) — pass the names added in the same session.
    static func report(items: [(name: String, category: String, unit: String, container: String, quantity: Double)],
                       basket: [String] = []) async {
        guard isEnabled, !key.isEmpty, let url = URL(string: baseURL + "/report") else { return }
        let payload: [String: Any] = [
            "items": items.map { ["name": $0.name, "category": $0.category, "unit": $0.unit,
                                   "container": $0.container, "quantity": $0.quantity] },
            "basket": basket
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-Stocked-Key")
        req.httpBody = body
        _ = try? await session.data(for: req)
    }

    // MARK: Read (available to everyone, no opt-in required)

    /// Smart defaults for an item name — use to prefill the quantity editor after a scan/add.
    static func suggest(name: String) async -> CrowdSuggestion? {
        await get("/suggest", ["name": name], as: CrowdSuggestion.self)
    }

    /// Popular item names matching a prefix, for autocomplete.
    static func autocomplete(prefix: String) async -> [String] {
        struct R: Codable { let items: [String] }
        return (await get("/autocomplete", ["prefix": prefix], as: R.self))?.items ?? []
    }

    /// Ingredients frequently used alongside `name`.
    static func pairings(name: String) async -> [(String, Int)] {
        struct R: Codable { let pairings: [[JSONValue]] }
        guard let r = await get("/pairings", ["name": name], as: R.self) else { return [] }
        return r.pairings.compactMap {
            guard $0.count == 2, case let .string(s) = $0[0], case let .number(n) = $0[1] else { return nil }
            return (s, Int(n))
        }
    }

    // MARK: - Plumbing

    private static func get<T: Decodable>(_ path: String, _ params: [String: String], as: T.Type) async -> T? {
        guard !key.isEmpty, var comps = URLComponents(string: baseURL + path) else { return nil }
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "X-Stocked-Key")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func bundle(_ k: String) -> String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: k) as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Minimal JSON value so pairings ([["tomato", 210], ...]) decode with mixed types.
enum JSONValue: Codable {
    case string(String), number(Double), other
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .other }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .other: try c.encodeNil()
        }
    }
}
