// StockedWorkerClient.swift — typed, cached transport for the Stocked Cloudflare Worker.
import Foundation
import os

nonisolated enum StockedWorkerRoute: String, Sendable {
    case receiptText
    case receiptImage
    case barcode
    case recipeImport
    case recipeGeneration
    case inventoryIntent
    case inventoryScan

    var schemaVersion: Int {
        switch self {
        case .receiptText, .receiptImage: return 2
        case .barcode: return 1
        case .recipeImport, .recipeGeneration: return 2
        case .inventoryIntent: return 2
        case .inventoryScan: return 2
        }
    }

    /// Bump when prompt semantics change without a response-schema change. It participates in
    /// the stable request hash, preventing an old on-device AI result from surviving a prompt fix.
    var cacheRevision: Int {
        switch self {
        case .receiptText, .receiptImage: return 2
        case .barcode: return 2
        case .recipeImport, .recipeGeneration: return 3
        case .inventoryIntent: return 3
        case .inventoryScan: return 3
        }
    }

    /// Only deterministic or revision-keyed requests are persisted. Receipt photos/text are
    /// intentionally excluded so sensitive purchase data is not retained in the cache.
    var defaultCacheTTL: TimeInterval {
        switch self {
        case .barcode: return 30 * 24 * 3600
        case .recipeImport: return 30 * 24 * 3600
        case .recipeGeneration: return 0
        case .inventoryIntent: return 7 * 24 * 3600
        case .inventoryScan: return 2 * 3600
        case .receiptText, .receiptImage: return 0
        }
    }
}

nonisolated enum StockedWorkerClient {
    static func url() -> URL? {
        let value = BuildConfig.receiptWorkerURL
        guard !value.contains("REPLACE-WITH-YOUR-WORKER"), let url = URL(string: value) else { return nil }
        return url
    }

    static var isConfigured: Bool { url() != nil }

    /// Central request primitive, wrapped in QA process tracking.
    ///
    /// EVERY network call in the app funnels through this one function, which is
    /// why the tracking lives here: it makes "Actions attempted" and "Failures"
    /// report real numbers without touching a single call site. Before this, both
    /// counters read 0 in every QA session because `QARecorder.attempt(...)` had
    /// essentially no callers — the counters were right and nothing was feeding them.
    static func requestData(route: StockedWorkerRoute,
                            payload: [String: Any],
                            timeout: TimeInterval = 30,
                            cacheTTL: TimeInterval? = nil) async throws -> Data {
        let handle = await QAProcessTracker.shared.begin("Worker: \(route.rawValue)",
                                                         detail: "network request")
        do {
            let data = try await performRequest(route: route, payload: payload,
                                                timeout: timeout, cacheTTL: cacheTTL)
            await handle.finish(detail: "\(data.count) bytes")
            return data
        } catch {
            await handle.fail(error.localizedDescription)
            throw error
        }
    }

    /// Payloads remain JSON-compatible dictionaries at call sites, but are encoded before
    /// crossing the cache actor boundary so no `[String: Any]` crosses actors.
    private static func performRequest(route: StockedWorkerRoute,
                            payload: [String: Any],
                            timeout: TimeInterval = 30,
                            cacheTTL: TimeInterval? = nil) async throws -> Data {
        guard let endpoint = url() else { throw StockedServiceError.notConfigured("Stocked AI") }
        guard ConnectivityMonitor.isOnlineFlag else { throw StockedServiceError.offline }
        // Remote kill switch (GET /configuration): a broken/runaway AI feature can be turned
        // off server-side without an app update. Fails open when no config was fetched.
        if await StockedRemoteConfig.shared.isRouteKilled(route.rawValue) {
            throw StockedServiceError.notConfigured("This feature is temporarily unavailable")
        }

        var enriched = payload
        enriched["route"] = route.rawValue
        enriched["schemaVersion"] = route.schemaVersion
        enriched["clientVersion"] = BuildConfig.version
        enriched["cacheRevision"] = route.cacheRevision
        guard JSONSerialization.isValidJSONObject(enriched) else {
            throw StockedServiceError.invalidRequest("The request contains unsupported values.")
        }
        let payloadData: Data
        do { payloadData = try JSONSerialization.data(withJSONObject: enriched, options: [.sortedKeys]) }
        catch { throw StockedServiceError.invalidRequest(error.localizedDescription) }

        let ttl = cacheTTL ?? route.defaultCacheTTL
        if ttl > 0, let cached = await AIResultCache.shared.value(
            route: route.rawValue, schemaVersion: route.schemaVersion, payloadData: payloadData
        ) { return cached }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&request)
        // Additive short-lived session credential (best-effort; X-Stocked-Key still authorizes
        // the request if this is nil). See StockedSession.
        if let session = await StockedSession.shared.currentToken() {
            request.setValue(session, forHTTPHeaderField: "X-Stocked-Session")
        }
        request.httpBody = payloadData
        request.timeoutInterval = timeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw StockedServiceError.malformedResponse("The Worker returned no HTTP response.")
            }
            if http.statusCode == 429 {
                let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                throw StockedServiceError.rateLimited(retryAfter: retry)
            }
            guard (200..<300).contains(http.statusCode) else {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let baseDetail = object?["error"] as? String
                let code = object?["code"] as? String
                if code == "kvQuota" { throw StockedServiceError.quotaExhausted(baseDetail ?? "Household sync storage is temporarily unavailable.") }
                throw StockedServiceError.httpStatus(http.statusCode, Self.diagnosticDetail(base: baseDetail, code: code, object: object))
            }
            // Validate the envelope now so truncation and empty responses never enter the cache.
            _ = try AIResponseDecoder.textResponse(from: data)
            if ttl > 0 {
                await AIResultCache.shared.save(data, route: route.rawValue,
                                                schemaVersion: route.schemaVersion,
                                                payloadData: payloadData, ttl: ttl)
            }
            return data
        } catch let error as StockedServiceError { throw error }
        catch is CancellationError { throw StockedServiceError.cancelled }
        catch { throw StockedServiceError.transport(error.localizedDescription) }
    }

    /// Unpacks the Worker's error envelope ({ error, code, requestId, ...extra }) into one
    /// readable line so a failure is diagnosable straight from the app's error text — no
    /// server-side log access needed. The Worker attaches different `extra` fields depending
    /// on where the failure happened:
    ///   • upstream call never produced a response to validate → upstreamStatus/upstreamBody
    ///     (the raw Anthropic HTTP status + error body, e.g. an auth or model-id problem)
    ///   • the model answered but its JSON failed schema validation → errors[] (field/code pairs)
    private static func diagnosticDetail(base: String?, code: String?, object: [String: Any]?) -> String? {
        var parts: [String] = []
        if let base, !base.isEmpty { parts.append(base) }
        if let code, !code.isEmpty { parts.append("[\(code)]") }
        if let status = object?["upstreamStatus"] as? Int {
            var bit = "upstream \(status)"
            if let body = object?["upstreamBody"] as? String, !body.isEmpty {
                bit += ": \(body.prefix(240))"
            }
            parts.append(bit)
        }
        if let errors = object?["errors"] as? [[String: Any]], !errors.isEmpty {
            let summary = errors.prefix(5).map { e -> String in
                let field = (e["field"] as? String) ?? "?"
                let ecode = (e["code"] as? String) ?? "?"
                return "\(field):\(ecode)"
            }.joined(separator: ", ")
            parts.append("schema errors: \(summary)")
        }
        return parts.isEmpty ? base : parts.joined(separator: " — ")
    }

    static func completionResponse(route: StockedWorkerRoute,
                                   payload: [String: Any],
                                   timeout: TimeInterval = 30,
                                   cacheTTL: TimeInterval? = nil) async throws -> AITextResponse {
        let data = try await requestData(route: route, payload: payload, timeout: timeout, cacheTTL: cacheTTL)
        let response = try AIResponseDecoder.textResponse(from: data)
        if let actual = response.schemaVersion, actual != route.schemaVersion {
            throw StockedServiceError.schemaMismatch(expected: route.schemaVersion, actual: actual)
        }
        return response
    }

    /// Compatibility wrapper for existing recipe callers while migrations land incrementally.
    static func completionText(payload: [String: Any], timeout: TimeInterval = 30) async -> String? {
        let route: StockedWorkerRoute
        if payload["recipeText"] != nil { route = .recipeImport }
        else if payload["recipeIdea"] != nil { route = .recipeGeneration }
        else if payload["barcode"] != nil { route = .barcode }
        else if payload["intent"] != nil { route = .inventoryIntent }
        else if payload["inventoryScan"] != nil { route = .inventoryScan }
        else if payload["imageBase64"] != nil { route = .receiptImage }
        else { route = .receiptText }
        do { return try await completionResponse(route: route, payload: payload, timeout: timeout).text }
        catch {
            Log.app.error("WorkerClient \(route.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
