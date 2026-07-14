// CrowdDB.swift — Stocked client for the shared, anonymized crowd item database.
//
// SHARED BACKEND FOR ALL USERS, BY DEFAULT — served by your EXISTING Cloudflare Worker
// (stocked-receipt-worker) under the /crowd/* routes. It reuses BuildConfig.receiptWorkerURL
// and the same X-Stocked-Key (BuildConfig.stockedWorkerKey), so there is ZERO new configuration:
// deploy the merged worker once and every install uses it automatically.
//
// This is the cross-user layer that makes the app smarter for everyone (CloudKit handles each
// user's own private data). Contribution is ON by default and can be turned off in Settings
// ("Improve Stocked for everyone", UserDefaults key "crowdShareEnabled"). Only anonymized item
// facts are ever sent — NEVER account, name, email, device id, or location. In return every user
// gets: suggested unit/container/quantity, item-name autocomplete, and ingredient pairings.

import Foundation
import os

nonisolated struct CrowdSuggestion: Codable, Sendable {
    var count: Int
    var topUnit: String?
    var topContainer: String?
    var topCategory: String?
    var avgQuantity: Double?
    var avgShelfLifeDays: Double?   // #B4 — crowd-learned typical days until expiry
}

nonisolated enum CrowdDB {

    // Reuse the app's already-configured worker + shared key. No separate URL/key needed.
    static var baseURL: String { BuildConfig.receiptWorkerURL }
    static var key: String { BuildConfig.stockedWorkerKey }

    /// True unless the user explicitly turned contribution OFF. Default ON (opt-out) so the
    /// shared database improves for everyone while staying fully anonymized.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "crowdShareEnabled") as? Bool ?? true
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    // MARK: Report (opt-out; anonymized)

    /// Report item facts. No-ops unless contribution is enabled. `basket` links items used
    /// together (for pairings) — pass the names added in the same session.
    static func report(items: [(name: String, category: String, unit: String, container: String, quantity: Double)],
                       basket: [String] = []) async {
        guard isEnabled else { return }
        let payload: [String: Any] = [
            "items": items.map { ["name": $0.name, "category": $0.category, "unit": $0.unit,
                                  "container": $0.container, "quantity": $0.quantity] },
            "basket": basket
        ]
        _ = await post("/crowd/report", payload, as: DummyOK.self)
    }

    /// #B4 — report how long an item lasts (expiry minus purchase, in days) so the crowd
    /// DB can suggest realistic default expiry windows. Anonymized like everything else;
    /// no-ops unless contribution is enabled.
    static func reportShelfLife(name: String, days: Double) async {
        guard isEnabled, days > 0, days < 720 else { return }
        let payload: [String: Any] = [
            "items": [["name": name, "shelfLifeDays": days]]
        ]
        _ = await post("/crowd/report", payload, as: DummyOK.self)
    }

    // MARK: Read (available to everyone)

    /// Smart defaults for an item name — use to prefill the quantity editor after a scan/add.
    static func suggest(name: String) async -> CrowdSuggestion? {
        await post("/crowd/suggest", ["name": name], as: CrowdSuggestion.self)
    }

    /// Popular item names matching a prefix, for autocomplete.
    static func autocomplete(prefix: String, limit: Int = 10) async -> [String] {
        struct R: Codable { let items: [String] }
        return (await post("/crowd/autocomplete", ["prefix": prefix, "limit": limit], as: R.self))?.items ?? []
    }

    /// Ingredients frequently used alongside `name`.
    static func pairings(name: String) async -> [(String, Int)] {
        struct R: Codable { let pairings: [[JSONValue]] }
        guard let r = await post("/crowd/pairings", ["name": name], as: R.self) else { return [] }
        return r.pairings.compactMap {
            guard $0.count == 2, case let .string(s) = $0[0], case let .number(n) = $0[1] else { return nil }
            return (s, Int(n))
        }
    }

    // MARK: - Plumbing (POST + X-Stocked-Key, matching the worker)

    nonisolated private struct DummyOK: Codable, Sendable {}

    private static func post<T: Decodable & Sendable>(_ path: String, _ payload: [String: Any], as: T.Type) async -> T? {
        do { return try await postResult(path, payload, as: T.self).get() }
        catch {
            Log.net.debug("CrowdDB \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func postResult<T: Decodable & Sendable>(
        _ path: String, _ payload: [String: Any], as: T.Type
    ) async throws -> Result<T, StockedServiceError> {
        guard !key.isEmpty else { return .failure(.notConfigured("Crowd intelligence")) }
        guard ConnectivityMonitor.isOnlineFlag else { return .failure(.offline) }
        guard let url = URL(string: baseURL + path), JSONSerialization.isValidJSONObject(payload) else {
            return .failure(.invalidRequest("The crowd request could not be encoded."))
        }
        let body: Data
        do { body = try JSONSerialization.data(withJSONObject: payload) }
        catch { return .failure(.invalidRequest(error.localizedDescription)) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Stocked-Key")
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.malformedResponse("CrowdDB returned no HTTP response."))
            }
            if http.statusCode == 429 {
                let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                return .failure(.rateLimited(retryAfter: retry))
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
                return .failure(.httpStatus(http.statusCode, detail))
            }
            if T.self == DummyOK.self, let ok = DummyOK() as? T { return .success(ok) }
            do { return .success(try JSONDecoder().decode(T.self, from: data)) }
            catch { return .failure(.malformedResponse(error.localizedDescription)) }
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }
}

/// Minimal JSON value so pairings ([["tomato", 210], ...]) decode with mixed types.
nonisolated enum JSONValue: Codable, Sendable {
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
