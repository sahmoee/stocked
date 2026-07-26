// SmartResponseCache.swift — Improvement #15: stale-while-revalidate for the Smart endpoints.
//
// `StockedWorkerClient` already caches through `AIResultCache`. `SmartClient` — which backs
// substitutions, nutrition, seasonal produce, expiry estimates, pantry matching, grocery
// optimisation and meal suggestions — had no caching at all. Every call was a live 12-second-timeout
// request, so on a slow connection the user watched a spinner and on no connection they got an
// empty screen. Kitchens have bad Wi-Fi; the app should never look broken because of it.
//
// The policy here is stale-while-revalidate: return whatever we have IMMEDIATELY, then refresh in
// the background so the next read is current. A slightly-old substitution list is worth far more
// than a correct empty one.

import Foundation

// MARK: - Cache

actor SmartResponseCache {
    static let shared = SmartResponseCache()

    private struct Entry {
        let data: Data
        let storedAt: Date
    }

    private var memory: [String: Entry] = [:]
    private let dir: URL
    /// Past this age we still SERVE the entry, but we also refresh behind it.
    private let freshFor: TimeInterval = 60 * 60          // 1 hour
    /// Past this we stop serving it at all — a season/expiry answer from last month is misleading.
    private let keepFor: TimeInterval = 60 * 60 * 24 * 14 // 14 days
    private let maxEntries = 400

    private init() {
        dir = URL.cachesDirectory.appendingPathComponent("StockedSmartCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: Keys

    /// FNV-1a over endpoint + arguments. Same scheme `AIResultCache` uses, for consistency.
    nonisolated static func key(_ endpoint: String, _ arguments: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Data("\(endpoint)|\(arguments)".utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }

    // MARK: Read

    enum Freshness { case fresh, stale, missing }

    func lookup(_ key: String) -> (data: Data, freshness: Freshness) {
        guard let entry = load(key) else { return (Data(), .missing) }
        let age = Date().timeIntervalSince(entry.storedAt)
        if age > keepFor {
            remove(key)
            return (Data(), .missing)
        }
        return (entry.data, age <= freshFor ? .fresh : .stale)
    }

    func store(_ data: Data, for key: String) {
        let entry = Entry(data: data, storedAt: Date())
        memory[key] = entry
        let url = dir.appendingPathComponent(key)
        try? data.write(to: url, options: .atomic)
        pruneIfNeeded()
    }

    private func load(_ key: String) -> Entry? {
        if let hit = memory[key] { return hit }
        let url = dir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: url),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        let entry = Entry(data: data, storedAt: modified)
        memory[key] = entry
        return entry
    }

    private func remove(_ key: String) {
        memory[key] = nil
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(key))
    }

    /// LRU by file modification date. Cheap and good enough for a few hundred small JSON blobs.
    private func pruneIfNeeded() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > maxEntries else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for url in sorted.prefix(files.count - maxEntries) {
            memory[url.lastPathComponent] = nil
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Maintenance

    func clear() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func sizeBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func entryCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? 0
    }
}

// MARK: - Cached call helper

nonisolated enum SmartCached {

    /// Wrap any `SmartClient` call in stale-while-revalidate.
    ///
    /// - A cached value is returned immediately when one exists, even if stale.
    /// - When it was stale, a background refresh is kicked off so the next read is current.
    /// - When nothing is cached, this behaves exactly like a direct call.
    ///
    /// `decode` and `encode` keep the cache format independent of the model type, so this works
    /// for every one of SmartClient's sixteen differently-shaped responses.
    static func value<T: Codable & Sendable>(
        endpoint: String,
        arguments: String,
        fetch: @escaping @Sendable () async -> T?
    ) async -> T? {
        let key = SmartResponseCache.key(endpoint, arguments)
        let (data, freshness) = await SmartResponseCache.shared.lookup(key)

        if freshness != .missing, let cached = try? JSONDecoder().decode(T.self, from: data) {
            if freshness == .stale {
                // Refresh behind the user's back; they already have an answer on screen.
                Task.detached(priority: .utility) {
                    if let fresh = await fetch(), let encoded = try? JSONEncoder().encode(fresh) {
                        await SmartResponseCache.shared.store(encoded, for: key)
                    }
                }
            }
            return cached
        }

        guard let fresh = await fetch() else { return nil }
        if let encoded = try? JSONEncoder().encode(fresh) {
            await SmartResponseCache.shared.store(encoded, for: key)
        }
        return fresh
    }
}
