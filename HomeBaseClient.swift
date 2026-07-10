// HomeBaseClient.swift — drop this single file into any iOS / macOS / watchOS app
// that talks to your HomeBase server. No third-party dependencies: URLSession
// with async/await for REST, URLSessionWebSocketTask (with auto-reconnect) for
// live pushes.
//
// QUICK START
// -----------
//   let client = HomeBaseClient(
//       baseURL: URL(string: "http://your-mac.tailnet-name.ts.net:8080")!,
//       apiKey:  HomeBaseSecrets.apiKey,          // never hard-code; see note below
//       project: "MyNewApp")
//
//   // Create
//   let saved = try await client.create(collection: "notes",
//                                       data: ["title": "Hello", "body": "First note"])
//   // List (full)
//   let all = try await client.list(collection: "notes")
//
//   // Delta sync (only what changed since your last sync stamp)
//   let changes = try await client.list(collection: "notes",
//                                       since: lastSyncStamp, includeDeleted: true)
//
//   // Live pushes
//   client.onChange = { event in
//       // event.project / event.collection / event.id / event.action
//       Task { await refreshFromServer() }
//   }
//   client.connectLive()
//
// KEY HANDLING
// ------------
// Put the API key in an .xcconfig / Info.plist variable or the Keychain — never
// in source. Example: add `HOMEBASE_API_KEY = hb_xxx` to Secrets.xcconfig, expose
// it through Info.plist as $(HOMEBASE_API_KEY), and read it at launch.
//
// OFFLINE STORAGE ON THE SERVER
// -----------------------------
// If the Mac's external drive is unplugged, the server answers data calls with
// HTTP 503 and {"error":"storage_offline"}. This client surfaces that as
// HomeBaseError.storageOffline so you can show "server storage offline — will
// retry" instead of a generic failure, and it keeps the WebSocket open so you
// get a {"type":"storage","online":true} push the moment the drive is back.

import Foundation

// MARK: - Models

/// One stored record. `data` is your app's own JSON payload — HomeBase never
/// interprets it, so any future app can store any shape it likes.
public struct HomeBaseRecord: Identifiable, Hashable {
    public let id: String
    public let project: String
    public let collection: String
    public let data: [String: Any]
    public let createdAt: Int64      // ms since epoch (server clock)
    public let updatedAt: Int64      // ms since epoch — use as your sync cursor
    public let deleted: Bool         // tombstone; remove locally when true

    public static func == (l: HomeBaseRecord, r: HomeBaseRecord) -> Bool {
        l.id == r.id && l.updatedAt == r.updatedAt && l.deleted == r.deleted
    }
    public func hash(into h: inout Hasher) { h.combine(id); h.combine(updatedAt) }

    /// Decode `data` into one of your Codable types.
    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard JSONSerialization.isValidJSONObject(data),
              let raw = try? JSONSerialization.data(withJSONObject: data) else { return nil }
        return try? JSONDecoder().decode(T.self, from: raw)
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let project = json["project"] as? String,
              let collection = json["collection"] as? String else { return nil }
        self.id = id
        self.project = project
        self.collection = collection
        self.data = json["data"] as? [String: Any] ?? [:]
        self.createdAt = (json["createdAt"] as? NSNumber)?.int64Value ?? 0
        self.updatedAt = (json["updatedAt"] as? NSNumber)?.int64Value ?? 0
        self.deleted = (json["deleted"] as? NSNumber)?.boolValue ?? false
    }
}

/// A push received over the WebSocket.
public struct HomeBaseEvent {
    public enum Kind { case change, storage, hello, other(String) }
    public let kind: Kind
    public let action: String?       // "upsert" | "delete" (for .change)
    public let project: String?
    public let collection: String?
    public let id: String?
    public let storageOnline: Bool?  // for .storage
}

public enum HomeBaseError: Error, LocalizedError {
    case badURL
    case unauthorized                 // 401 — key wrong or revoked
    case storageOffline               // 503 — external drive unplugged; retry later
    case notFound
    case server(status: Int, message: String)
    case decoding

    public var errorDescription: String? {
        switch self {
        case .badURL:          return "Invalid HomeBase URL."
        case .unauthorized:    return "HomeBase rejected the API key."
        case .storageOffline:  return "HomeBase storage is offline (drive unplugged). It will resume automatically."
        case .notFound:        return "Record not found."
        case .server(let s, let m): return "HomeBase error \(s): \(m)"
        case .decoding:        return "Could not decode the HomeBase response."
        }
    }
}

// MARK: - Client

public final class HomeBaseClient {

    public let baseURL: URL
    public let project: String
    private let apiKey: String
    private let session: URLSession

    /// Fired for every WebSocket push (already on the main thread).
    public var onChange: ((HomeBaseEvent) -> Void)?
    /// Fired when the live connection state changes (already on the main thread).
    public var onLiveStateChange: ((Bool) -> Void)?

    private var wsTask: URLSessionWebSocketTask?
    private var wantLive = false
    private var reconnectDelay: TimeInterval = 1

    public init(baseURL: URL, apiKey: String, project: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.project = project
        self.session = session
    }

    // MARK: REST

    /// List records. Pass `since` (the largest `updatedAt` you've seen) for delta
    /// sync; pass `includeDeleted: true` when delta-syncing so tombstones arrive.
    public func list(collection: String, since: Int64? = nil, includeDeleted: Bool = false) async throws -> [HomeBaseRecord] {
        var comps = URLComponents(url: url(collection), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []
        if let since { items.append(URLQueryItem(name: "since", value: String(since))) }
        if includeDeleted { items.append(URLQueryItem(name: "includeDeleted", value: "true")) }
        if !items.isEmpty { comps?.queryItems = items }
        guard let u = comps?.url else { throw HomeBaseError.badURL }
        let json = try await request("GET", u)
        guard let arr = (json as? [String: Any])?["records"] as? [[String: Any]] else { throw HomeBaseError.decoding }
        return arr.compactMap(HomeBaseRecord.init(json:))
    }

    public func get(collection: String, id: String) async throws -> HomeBaseRecord {
        let json = try await request("GET", url(collection).appendingPathComponent(id))
        guard let obj = json as? [String: Any], let rec = HomeBaseRecord(json: obj) else { throw HomeBaseError.decoding }
        return rec
    }

    /// Create a record. Omit `id` to let the server assign a UUID.
    @discardableResult
    public func create(collection: String, id: String? = nil, data: [String: Any]) async throws -> HomeBaseRecord {
        var body: [String: Any] = ["data": data]
        if let id { body["id"] = id }
        let json = try await request("POST", url(collection), body: body)
        guard let obj = json as? [String: Any], let rec = HomeBaseRecord(json: obj) else { throw HomeBaseError.decoding }
        return rec
    }

    /// Create from a Codable value.
    @discardableResult
    public func create<T: Encodable>(collection: String, id: String? = nil, value: T) async throws -> HomeBaseRecord {
        try await create(collection: collection, id: id, data: try Self.jsonObject(from: value))
    }

    /// Upsert (create-or-replace) by id.
    @discardableResult
    public func put(collection: String, id: String, data: [String: Any]) async throws -> HomeBaseRecord {
        let json = try await request("PUT", url(collection).appendingPathComponent(id), body: ["data": data])
        guard let obj = json as? [String: Any], let rec = HomeBaseRecord(json: obj) else { throw HomeBaseError.decoding }
        return rec
    }

    @discardableResult
    public func put<T: Encodable>(collection: String, id: String, value: T) async throws -> HomeBaseRecord {
        try await put(collection: collection, id: id, data: try Self.jsonObject(from: value))
    }

    /// Soft-delete (writes a tombstone so other devices learn about it via sync).
    public func delete(collection: String, id: String) async throws {
        _ = try await request("DELETE", url(collection).appendingPathComponent(id))
    }

    // MARK: Files (raw bytes stored on the server's storage drive)
    //
    // File ids: letters, digits, - _ . (max 128) — e.g. "receipt-2026-07-10.jpg".
    // Metadata (size, contentType, filename, sha256) is synced like any other
    // records in the reserved "_files" collection, so `listFiles(since:)` gives
    // you delta sync and WebSocket `change` events fire for uploads/deletes too.

    /// Upload (create-or-replace) a file. Returns its metadata record.
    @discardableResult
    public func uploadFile(id: String, data: Data, contentType: String,
                           filename: String? = nil) async throws -> HomeBaseRecord {
        var comps = URLComponents(url: fileURL(id), resolvingAgainstBaseURL: false)
        if let filename, !filename.isEmpty {
            comps?.queryItems = [URLQueryItem(name: "filename", value: filename)]
        }
        guard let u = comps?.url else { throw HomeBaseError.badURL }
        var req = URLRequest(url: u)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (respData, http) = try await perform(req)
        guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              (200...299).contains(http.statusCode), let rec = HomeBaseRecord(json: obj) else {
            throw HomeBaseError.decoding
        }
        return rec
    }

    /// Download a file's raw bytes (and its content type).
    public func downloadFile(id: String) async throws -> (data: Data, contentType: String) {
        var req = URLRequest(url: fileURL(id))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await perform(req)
        let ct = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        return (data, ct)
    }

    /// Delete a file (bytes removed; a tombstone metadata record propagates to
    /// every device via sync).
    public func deleteFile(id: String) async throws {
        var req = URLRequest(url: fileURL(id))
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        _ = try await perform(req)
    }

    /// List file metadata records (delta sync works exactly like `list`).
    public func listFiles(since: Int64? = nil, includeDeleted: Bool = false) async throws -> [HomeBaseRecord] {
        try await list(collection: "_files", since: since, includeDeleted: includeDeleted)
    }

    private func fileURL(_ id: String) -> URL {
        baseURL.appendingPathComponent("v1").appendingPathComponent(project)
            .appendingPathComponent("files").appendingPathComponent(id)
    }

    /// Shared raw request path with the same status→error mapping as `request`.
    private func perform(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw HomeBaseError.decoding }
        switch http.statusCode {
        case 200...299: return (data, http)
        case 401: throw HomeBaseError.unauthorized
        case 404: throw HomeBaseError.notFound
        case 503: throw HomeBaseError.storageOffline
        default:
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw HomeBaseError.server(status: http.statusCode, message: msg ?? "unknown")
        }
    }

    /// Server heartbeat — also tells you if storage is online. Never needs auth.
    public func health() async throws -> (ok: Bool, storageOnline: Bool) {
        let json = try await request("GET", baseURL.appendingPathComponent("health"), authorized: false)
        guard let obj = json as? [String: Any] else { throw HomeBaseError.decoding }
        return ((obj["status"] as? String) == "ok", (obj["storage"] as? String) == "online")
    }

    // MARK: Live (WebSocket)

    /// Open the live channel. Reconnects automatically with backoff until
    /// `disconnectLive()` is called.
    public func connectLive() {
        wantLive = true
        openSocket()
    }

    public func disconnectLive() {
        wantLive = false
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    private func openSocket() {
        guard wantLive else { return }
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/ws"), resolvingAgainstBaseURL: false)
        if let scheme = comps?.scheme { comps?.scheme = (scheme == "https") ? "wss" : "ws" }
        guard let wsURL = comps?.url else { return }
        var req = URLRequest(url: wsURL)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: req)
        wsTask = task
        task.resume()
        DispatchQueue.main.async { self.onLiveStateChange?(true) }
        listen(on: task)
    }

    private func listen(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async { self.onLiveStateChange?(false) }
                self.scheduleReconnect()
            case .success(let message):
                self.reconnectDelay = 1
                if case .string(let text) = message { self.handlePush(text) }
                self.listen(on: task)
            }
        }
    }

    private func scheduleReconnect() {
        guard wantLive else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)   // 1, 2, 4 … capped at 30s
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.openSocket()
        }
    }

    private func handlePush(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let kind: HomeBaseEvent.Kind
        switch type {
        case "change":  kind = .change
        case "storage": kind = .storage
        case "hello":   kind = .hello
        default:        kind = .other(type)
        }
        let event = HomeBaseEvent(
            kind: kind,
            action: obj["action"] as? String,
            project: obj["project"] as? String,
            collection: obj["collection"] as? String,
            id: obj["id"] as? String,
            storageOnline: (obj["online"] as? NSNumber)?.boolValue)
        DispatchQueue.main.async { self.onChange?(event) }
    }

    // MARK: Plumbing

    private func url(_ collection: String) -> URL {
        baseURL.appendingPathComponent("v1").appendingPathComponent(project).appendingPathComponent(collection)
    }

    private func request(_ method: String, _ url: URL, body: [String: Any]? = nil, authorized: Bool = true) async throws -> Any {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if authorized { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw HomeBaseError.decoding }
        switch http.statusCode {
        case 200...299:
            if data.isEmpty { return [:] as [String: Any] }
            return try JSONSerialization.jsonObject(with: data)
        case 401: throw HomeBaseError.unauthorized
        case 404: throw HomeBaseError.notFound
        case 503: throw HomeBaseError.storageOffline
        default:
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw HomeBaseError.server(status: http.statusCode, message: msg ?? "unknown")
        }
    }

    private static func jsonObject<T: Encodable>(from value: T) throws -> [String: Any] {
        let raw = try JSONEncoder().encode(value)
        guard let obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw HomeBaseError.decoding
        }
        return obj
    }
}
