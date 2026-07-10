// StockedServerStore.swift — Stocked's connection to the HomeBase server.
// Drop this + HomeBaseClient.swift into the Stocked target. Nothing else from
// HomeBase is bundled — this is a thin client over HTTP/WebSocket.
//
// For a FUTURE app: copy both files, change `HomeBaseConfig.project`, rename
// the model/store, done. The server needs zero changes.

import Foundation
import SwiftUI

// MARK: - Config (values come from Secrets.xcconfig → Info.plist; see guide §2.2–2.3)

enum HomeBaseConfig {
    /// The one line to change per app.
    static let project = "Stocked"

    static var baseURL: URL {
        if let s = Bundle.main.object(forInfoDictionaryKey: "HomeBaseURL") as? String,
           let url = URL(string: s), url.scheme != nil {
            return url
        }
        assertionFailure("HomeBaseURL missing from Info.plist — see STOCKED_CONNECT_GUIDE.md §2.2")
        return URL(string: "http://localhost:8080")!   // dev fallback only
    }

    static var apiKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "HomeBaseAPIKey") as? String) ?? ""
    }

    static func makeClient() -> HomeBaseClient {
        HomeBaseClient(baseURL: baseURL, apiKey: apiKey, project: project)
    }
}

// MARK: - Example model (adapt to Stocked's real item shape)

struct PantryItem: Codable, Identifiable, Hashable {
    var id = UUID().uuidString.lowercased()
    var name: String
    var quantity: Double = 1
    var zone: String = "Pantry"          // Fridge | Freezer | Pantry | Other
    var brand: String? = nil
    var receiptFileID: String? = nil     // links to a file stored on the server
}

// MARK: - Store

@MainActor
final class StockedServerStore: ObservableObject {

    // State your views can render directly.
    @Published private(set) var items: [String: PantryItem] = [:]   // record id → item
    @Published private(set) var serverReachable = false
    @Published private(set) var storageOnline = false
    @Published private(set) var liveConnected = false
    @Published private(set) var syncing = false
    @Published private(set) var lastError: String?

    var sortedItems: [PantryItem] { items.values.sorted { $0.name < $1.name } }

    private let client = HomeBaseConfig.makeClient()
    private let itemsCollection = "items"

    // MARK: Lifecycle

    /// Call once at app launch (e.g. `.task { await server.start() }`).
    func start() async {
        loadLocalCache()

        client.onLiveStateChange = { [weak self] connected in
            self?.liveConnected = connected
        }
        client.onChange = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                switch event.kind {
                case .change:
                    // Something changed on another device — pull just the delta.
                    if event.collection == self.itemsCollection { await self.syncItems() }
                case .storage:
                    self.storageOnline = event.storageOnline ?? self.storageOnline
                    if event.storageOnline == true { await self.syncItems() }  // drive is back
                default:
                    break
                }
            }
        }
        client.connectLive()

        await checkHealth()
        await syncItems()
    }

    func checkHealth() async {
        do {
            let h = try await client.health()
            serverReachable = h.ok
            storageOnline = h.storageOnline
        } catch {
            serverReachable = false
        }
    }

    // MARK: Items — delta sync

    private var lastSyncKey: String { "hb.lastSync.\(HomeBaseConfig.project).\(itemsCollection)" }
    private var lastSync: Int64 {
        get { Int64(UserDefaults.standard.string(forKey: lastSyncKey) ?? "0") ?? 0 }
        set { UserDefaults.standard.set(String(newValue), forKey: lastSyncKey) }
    }

    func syncItems() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let changes = try await client.list(collection: itemsCollection,
                                                since: lastSync, includeDeleted: true)
            guard !changes.isEmpty else { lastError = nil; return }
            for rec in changes {
                if rec.deleted {
                    items[rec.id] = nil
                } else if var item = rec.decode(PantryItem.self) {
                    item.id = rec.id
                    items[rec.id] = item
                }
                lastSync = max(lastSync, rec.updatedAt)
            }
            saveLocalCache()
            storageOnline = true
            lastError = nil
        } catch HomeBaseError.storageOffline {
            storageOnline = false   // drive unplugged on the Mac — keep local state, a push will resync us
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Create or update an item on the server (all devices get a live push).
    func save(_ item: PantryItem, id: String? = nil) async throws {
        let recordID = id ?? item.id
        let rec = try await client.put(collection: itemsCollection, id: recordID, value: item)
        var saved = item
        saved.id = rec.id
        items[rec.id] = saved
        lastSync = max(lastSync, rec.updatedAt)
        saveLocalCache()
    }

    func deleteItem(id: String) async throws {
        try await client.delete(collection: itemsCollection, id: id)
        items[id] = nil
        saveLocalCache()
    }

    // MARK: Receipt files (raw bytes stored on the server's drive)

    /// Upload a receipt photo; returns the file id to keep on the item.
    /// Pattern: upload the original here, then send the image/text to the
    /// Cloudflare worker for OCR, then `save(...)` the parsed items.
    func uploadReceipt(jpegData: Data, suggestedName: String? = nil) async throws -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let fileID = "receipt-\(stamp)-\(UUID().uuidString.prefix(8)).jpg"
        _ = try await client.uploadFile(id: fileID, data: jpegData,
                                        contentType: "image/jpeg",
                                        filename: suggestedName ?? fileID)
        return fileID
    }

    /// Download a receipt's bytes (from any device).
    func receiptData(fileID: String) async throws -> Data {
        try await client.downloadFile(id: fileID).data
    }

    func deleteReceipt(fileID: String) async throws {
        try await client.deleteFile(id: fileID)
    }

    /// Metadata for all stored receipts (size, filename, sha256, …).
    func listReceipts() async throws -> [HomeBaseRecord] {
        try await client.listFiles()
    }

    // MARK: Local cache (instant launches; survives the server being unreachable)

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Stocked", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("homebase-items.json")
    }

    private func saveLocalCache() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: cacheURL, options: [.atomic])
        }
    }

    private func loadLocalCache() {
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([String: PantryItem].self, from: data) {
            items = cached
        }
    }
}
