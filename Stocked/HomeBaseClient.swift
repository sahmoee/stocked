// HomeBaseClient.swift — networking layer for the HomeBase server (REST + files + WebSocket).
//
// Talks to your Mac's HomeBase server over HTTP/WebSocket. Reads its URL + API key from
// Info.plist (HomeBaseURL / HomeBaseAPIKey, injected from Secrets.xcconfig). Nothing here is
// Stocked-specific except the default project name; reuse it in other apps by changing
// HomeBaseConfig.project.
//
// Data model on the wire (from the HomeBase guide):
//   POST  /v1/{Project}/{collection}          body { "data": {...} }            -> { id }
//   PUT   /v1/{Project}/{collection}/{id}      body { "data": {...} }
//   GET   /v1/{Project}/{collection}                                            -> [ record ]
//   DELETE/v1/{Project}/{collection}/{id}
//   POST  /v1/{Project}/files                  binary body                      -> { id }
//   GET   /v1/{Project}/files/{id}                                              -> bytes
//   GET   /health                                                              -> { storage }
//   WS    /v1/{Project}/ws                      change pushes
// A record is { "id", "data": {...}, "updatedAt": <ms>, "deleted": <bool> }.

import Foundation

struct HomeBaseConfig {
    var project: String = "Stocked"
    var baseURL: String = HomeBaseConfig.bundle("HomeBaseURL") ?? ""
    var apiKey: String  = HomeBaseConfig.bundle("HomeBaseAPIKey") ?? ""

    var isConfigured: Bool { !baseURL.isEmpty && !apiKey.isEmpty }

    var wsURL: String {
        var u = baseURL
        if u.hasPrefix("https://") { u = "wss://" + u.dropFirst(8) }
        else if u.hasPrefix("http://") { u = "ws://" + u.dropFirst(7) }
        return u + "/v1/\(project)/ws"
    }

    static func bundle(_ key: String) -> String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// A server record: id + free-form JSON `data` + LWW metadata.
struct HBRecord {
    let id: String
    let data: [String: Any]
    let updatedAt: Double   // epoch milliseconds
    let deleted: Bool
}

enum HBError: Error, LocalizedError {
    case notConfigured, storageOffline, http(Int), badResponse
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "HomeBase URL/key not set."
        case .storageOffline: return "HomeBase storage drive is offline."
        case .http(let c): return "HomeBase returned HTTP \(c)."
        case .badResponse: return "Unexpected HomeBase response."
        }
    }
}

@MainActor
final class HomeBaseClient: NSObject {
    var config: HomeBaseConfig

    private let session: URLSession
    private var ws: URLSessionWebSocketTask?
    private var wsWantsConnection = false
    private var reconnectDelay: TimeInterval = 1

    /// Called on the main actor when the server pushes a change for `collection`.
    var onChange: ((_ collection: String, _ record: HBRecord) -> Void)?
    /// Called when the server signals storage came back online.
    var onStorageOnline: (() -> Void)?

    init(config: HomeBaseConfig = HomeBaseConfig()) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = true
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    // MARK: REST

    private func request(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json") -> URLRequest? {
        guard config.isConfigured, let url = URL(string: config.baseURL + path) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        if let body = body { r.httpBody = body; r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw HBError.badResponse }
        if http.statusCode == 503 { throw HBError.storageOffline }
        guard (200..<300).contains(http.statusCode) else { throw HBError.http(http.statusCode) }
        return (data, http)
    }

    func health() async -> Bool {
        guard let req = request("GET", "/health") else { return false }
        guard let (data, _) = try? await send(req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (obj["storage"] as? String) == "online"
    }

    /// List all records in a collection (e.g. "items").
    func list(_ collection: String) async throws -> [HBRecord] {
        guard let req = request("GET", "/v1/\(config.project)/\(collection)") else { throw HBError.notConfigured }
        let (data, _) = try await send(req)
        return Self.records(from: data)
    }

    /// Create/update a record. Returns the id the server assigned/confirmed.
    @discardableResult
    func put(_ collection: String, id: String?, data: [String: Any]) async throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: ["data": data])
        let path = id == nil ? "/v1/\(config.project)/\(collection)"
                             : "/v1/\(config.project)/\(collection)/\(id!)"
        guard let req = request(id == nil ? "POST" : "PUT", path, body: payload) else { throw HBError.notConfigured }
        let (respData, _) = try await send(req)
        if let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
           let rid = obj["id"] as? String { return rid }
        return id ?? UUID().uuidString
    }

    func delete(_ collection: String, id: String) async throws {
        guard let req = request("DELETE", "/v1/\(config.project)/\(collection)/\(id)") else { throw HBError.notConfigured }
        _ = try await send(req)
    }

    // MARK: Files

    func uploadFile(_ data: Data, contentType: String = "image/jpeg") async throws -> String {
        guard let req = request("POST", "/v1/\(config.project)/files", body: data, contentType: contentType) else { throw HBError.notConfigured }
        let (respData, _) = try await send(req)
        if let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
           let id = obj["id"] as? String { return id }
        throw HBError.badResponse
    }

    func downloadFile(id: String) async throws -> Data {
        guard let req = request("GET", "/v1/\(config.project)/files/\(id)") else { throw HBError.notConfigured }
        let (data, _) = try await send(req)
        return data
    }

    // MARK: WebSocket (live pushes) with auto-reconnect

    func connect() {
        guard config.isConfigured, let url = URL(string: config.wsURL) else { return }
        wsWantsConnection = true
        var req = URLRequest(url: url)
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: req)
        ws = task
        task.resume()
        receive()
    }

    func disconnect() {
        wsWantsConnection = false
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
    }

    private func receive() {
        ws?.receive { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                switch result {
                case .failure:
                    self.scheduleReconnect()
                case .success(let message):
                    self.reconnectDelay = 1
                    if case let .string(text) = message { self.handle(text) }
                    else if case let .data(d) = message, let s = String(data: d, encoding: .utf8) { self.handle(s) }
                    self.receive()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if (obj["type"] as? String) == "storage" && (obj["state"] as? String) == "online" {
            onStorageOnline?()
        }
        let collection = obj["collection"] as? String ?? "items"
        if let rec = Self.record(from: obj["record"] as? [String: Any] ?? obj) {
            onChange?(collection, rec)
        }
    }

    private func scheduleReconnect() {
        guard wsWantsConnection else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.wsWantsConnection else { return }
            self.connect()
        }
    }

    // MARK: Parsing

    private static func records(from data: Data) -> [HBRecord] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let arr: [[String: Any]]
        if let a = root as? [[String: Any]] { arr = a }
        else if let o = root as? [String: Any], let a = (o["records"] ?? o["items"] ?? o["data"]) as? [[String: Any]] { arr = a }
        else { arr = [] }
        return arr.compactMap { record(from: $0) }
    }

    private static func record(from obj: [String: Any]?) -> HBRecord? {
        guard let obj = obj, let id = (obj["id"] as? String) ?? (obj["_id"] as? String) else { return nil }
        let data = (obj["data"] as? [String: Any]) ?? obj
        let updated = (obj["updatedAt"] as? NSNumber)?.doubleValue
            ?? (obj["updated_at"] as? NSNumber)?.doubleValue
            ?? Date().timeIntervalSince1970 * 1000
        let deleted = (obj["deleted"] as? Bool) ?? false
        return HBRecord(id: id, data: data, updatedAt: updated, deleted: deleted)
    }
}
