// StockedServerStore.swift — offline-first sync store for Stocked, backed by HomeBase.
//
// OFFLINE-FIRST: every item is cached on the phone (JSON in Application Support). The store
// loads instantly from cache on launch and works fully with NO connection. Changes are applied
// locally first, persisted, then queued to HomeBase in a durable outbox that flushes when the
// server is reachable. Receipt photos are saved to the phone immediately and uploaded in the
// background. Live pushes (WebSocket) merge into the cache using last-writer-wins.
//
// Wire up in the App:
//   @StateObject private var server = StockedServerStore()
//   ... .environmentObject(server).task { await server.start() }

import Foundation

struct PantryItem: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var quantity: Double
    var zone: String
    var container: String?
    var amountEach: Double?
    var unitEach: String?
    var updatedAt: Double     // epoch ms (last-writer-wins)
    var deleted: Bool

    init(name: String, quantity: Double = 1, zone: String = "Pantry",
         container: String? = nil, amountEach: Double? = nil, unitEach: String? = nil,
         id: String = UUID().uuidString, updatedAt: Double = Date().timeIntervalSince1970 * 1000,
         deleted: Bool = false) {
        self.id = id; self.name = name; self.quantity = quantity; self.zone = zone
        self.container = container; self.amountEach = amountEach; self.unitEach = unitEach
        self.updatedAt = updatedAt; self.deleted = deleted
    }

    var asServerData: [String: Any] {
        var d: [String: Any] = ["name": name, "quantity": quantity, "zone": zone,
                                "updatedAt": updatedAt, "deleted": deleted]
        if let c = container { d["container"] = c }
        if let a = amountEach { d["amountEach"] = a }
        if let u = unitEach { d["unitEach"] = u }
        return d
    }

    init(record: HBRecord) {
        let d = record.data
        self.id = record.id
        self.name = d["name"] as? String ?? ""
        self.quantity = (d["quantity"] as? NSNumber)?.doubleValue ?? 1
        self.zone = d["zone"] as? String ?? "Pantry"
        self.container = d["container"] as? String
        self.amountEach = (d["amountEach"] as? NSNumber)?.doubleValue
        self.unitEach = d["unitEach"] as? String
        self.updatedAt = record.updatedAt
        self.deleted = record.deleted || (d["deleted"] as? Bool ?? false)
    }
}

@MainActor
final class StockedServerStore: ObservableObject {
    @Published private(set) var items: [String: PantryItem] = [:]
    @Published private(set) var storageOnline = true
    @Published private(set) var syncing = false
    @Published var lastError: String?

    /// Non-deleted items, sorted by name — bind this in views.
    var visibleItems: [PantryItem] {
        items.values.filter { !$0.deleted }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private let client = HomeBaseClient()
    private let collection = "items"

    // MARK: Local cache paths

    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let d = base.appendingPathComponent("StockedServer", isDirectory: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent("files"), withIntermediateDirectories: true)
        return d
    }()
    private var itemsURL: URL { dir.appendingPathComponent("items.json") }
    private var outboxURL: URL { dir.appendingPathComponent("outbox.json") }
    private var fileMapURL: URL { dir.appendingPathComponent("filemap.json") }
    private func fileURL(_ id: String) -> URL { dir.appendingPathComponent("files/\(id).jpg") }

    // MARK: Durable outbox

    struct Op: Codable { enum Kind: String, Codable { case put, delete, upload }
        var kind: Kind; var id: String; var localFile: String?
    }
    private var outbox: [Op] = []
    private var fileMap: [String: String] = [:]   // localID -> serverID (for receipts)

    init() {
        // OFFLINE-FIRST: load cache immediately so the app has data before any network.
        loadCache()
        client.onChange = { [weak self] _, record in self?.merge(PantryItem(record: record), persist: true) }
        client.onStorageOnline = { [weak self] in Task { await self?.resync() } }
    }

    // MARK: Lifecycle

    func start() async {
        guard client.config.isConfigured else { return }   // works offline / unconfigured too
        client.connect()
        await refreshHealth()
        await resync()
        await flushOutbox()
    }

    private func refreshHealth() async {
        storageOnline = await client.health()
    }

    /// Pull the server's current state and merge (LWW), then push anything pending.
    func resync() async {
        guard client.config.isConfigured else { return }
        syncing = true; defer { syncing = false }
        do {
            let records = try await client.list(collection)
            for r in records { merge(PantryItem(record: r), persist: false) }
            saveItems()
            storageOnline = true
        } catch HBError.storageOffline {
            storageOnline = false
        } catch {
            lastError = error.localizedDescription
        }
        await flushOutbox()
    }

    // MARK: Mutations (local-first, then queued)

    func save(_ item: PantryItem) {
        var it = item
        it.updatedAt = Date().timeIntervalSince1970 * 1000
        it.deleted = false
        items[it.id] = it
        saveItems()
        enqueue(Op(kind: .put, id: it.id, localFile: nil))
        Task { await flushOutbox() }
    }

    /// Convenience matching the guide: save(PantryItem(...), id:).
    func save(_ item: PantryItem, id: String) {
        var it = item; it.id = id; save(it)
    }

    func deleteItem(id: String) {
        if var it = items[id] {
            it.deleted = true; it.updatedAt = Date().timeIntervalSince1970 * 1000
            items[id] = it
        }
        saveItems()
        enqueue(Op(kind: .delete, id: id, localFile: nil))
        Task { await flushOutbox() }
    }

    // MARK: Receipts (cached on-device immediately, uploaded in background)

    /// Saves the photo on the phone right away and returns a stable id. Uploads to HomeBase
    /// when reachable; the id keeps working offline via the local copy.
    func uploadReceipt(jpegData: Data) -> String {
        let localID = "local-" + UUID().uuidString
        try? jpegData.write(to: fileURL(localID), options: .atomic)
        enqueue(Op(kind: .upload, id: localID, localFile: fileURL(localID).path))
        Task { await flushOutbox() }
        return localID
    }

    /// Returns receipt bytes — local cache first, else download from HomeBase and cache.
    func receiptData(fileID: String) async -> Data? {
        let resolved = fileMap[fileID] ?? fileID
        if let d = try? Data(contentsOf: fileURL(fileID)) { return d }
        if let d = try? Data(contentsOf: fileURL(resolved)) { return d }
        guard client.config.isConfigured, let d = try? await client.downloadFile(id: resolved) else { return nil }
        try? d.write(to: fileURL(resolved), options: .atomic)
        return d
    }

    // MARK: Merge (last-writer-wins)

    private func merge(_ incoming: PantryItem, persist: Bool) {
        if let existing = items[incoming.id], existing.updatedAt >= incoming.updatedAt { return }
        items[incoming.id] = incoming
        if persist { saveItems() }
    }

    // MARK: Outbox flush

    private func flushOutbox() async {
        guard client.config.isConfigured, !outbox.isEmpty else { return }
        var remaining: [Op] = []
        for op in outbox {
            do {
                switch op.kind {
                case .put:
                    if let it = items[op.id] { _ = try await client.put(collection, id: it.id, data: it.asServerData) }
                case .delete:
                    try await client.delete(collection, id: op.id)
                case .upload:
                    if let path = op.localFile, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                        let serverID = try await client.uploadFile(data)
                        fileMap[op.id] = serverID; saveFileMap()
                    }
                }
                storageOnline = true
            } catch HBError.storageOffline {
                storageOnline = false
                remaining.append(op)          // keep; retry when back online
            } catch {
                remaining.append(op)          // transient; retry later
                lastError = error.localizedDescription
            }
        }
        outbox = remaining
        saveOutbox()
    }

    private func enqueue(_ op: Op) { outbox.append(op); saveOutbox() }

    // MARK: Persistence

    private func loadCache() {
        if let d = try? Data(contentsOf: itemsURL),
           let arr = try? JSONDecoder().decode([PantryItem].self, from: d) {
            items = Dictionary(uniqueKeysWithValues: arr.map { ($0.id, $0) })
        }
        if let d = try? Data(contentsOf: outboxURL),
           let ops = try? JSONDecoder().decode([Op].self, from: d) { outbox = ops }
        if let d = try? Data(contentsOf: fileMapURL),
           let m = try? JSONDecoder().decode([String: String].self, from: d) { fileMap = m }
    }
    private func saveItems() {
        if let d = try? JSONEncoder().encode(Array(items.values)) { try? d.write(to: itemsURL, options: .atomic) }
    }
    private func saveOutbox() {
        if let d = try? JSONEncoder().encode(outbox) { try? d.write(to: outboxURL, options: .atomic) }
    }
    private func saveFileMap() {
        if let d = try? JSONEncoder().encode(fileMap) { try? d.write(to: fileMapURL, options: .atomic) }
    }
}
