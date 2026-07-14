//
//  APIResponseCache.swift
//  Stocked
//
//  Shared response cache for external nutrition/recipe APIs.
//  Two-tier: in-memory (fast, per-launch) plus on-disk JSON (survives relaunch),
//  each entry stamped with a time-to-live. Used by ChompFoodClient,
//  SuggesticClient, and LogMealClient so repeated lookups do not re-hit the network.
//

import Foundation

/// A small, generic, thread-safe cache for Codable API payloads.
/// Keyed by an arbitrary string (the caller builds a stable signature for the request).
actor APIResponseCache {

    /// Shared instance used by all nutrition/recipe clients.
    static let shared = APIResponseCache(namespace: "NutritionAPIs")

    private struct Entry: Codable {
        let expires: Date
        let payload: Data
    }

    private let namespace: String
    private let directory: URL
    private let maxDiskBytes: Int = 150 * 1_048_576
    private var memory: [String: Entry] = [:]
    private var writesSincePrune = 0

    init(namespace: String) {
        self.namespace = namespace
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = base.appendingPathComponent("APICache", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Returns a decoded value if a fresh (non-expired) entry exists, otherwise nil.
    func value<T: Decodable & Sendable>(for key: String, as type: T.Type) -> T? {
        let now = Date()

        if let entry = memory[key] {
            if entry.expires > now {
                return try? JSONDecoder().decode(T.self, from: entry.payload)
            }
            memory[key] = nil
        }

        let fileURL = Self.fileURL(in: directory, key: key)
        guard let data = try? Data(contentsOf: fileURL),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }

        if entry.expires <= now {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        memory[key] = entry
        try? FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: fileURL.path
        )
        return try? JSONDecoder().decode(T.self, from: entry.payload)
    }

    /// Stores a value with the given time-to-live (seconds).
    func store<T: Encodable & Sendable>(_ value: T, for key: String, ttl: TimeInterval) {
        guard let payload = try? JSONEncoder().encode(value) else { return }
        let entry = Entry(expires: Date().addingTimeInterval(ttl), payload: payload)
        memory[key] = entry

        let fileURL = Self.fileURL(in: directory, key: key)
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: fileURL, options: .atomic)
            writesSincePrune += 1
            if writesSincePrune >= 20 {
                writesSincePrune = 0
                pruneIfNeeded()
            }
        }
    }

    /// Current on-disk usage for storage settings.
    func diskSizeBytes() -> Int {
        Self.files(in: directory).reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func diskSizeString() -> String {
        ByteCountFormatter.string(fromByteCount: Int64(diskSizeBytes()), countStyle: .file)
    }

    /// Removes expired entries first, then oldest files until the cache is comfortably below
    /// its limit. This keeps API payloads persistent without allowing unbounded growth.
    func pruneIfNeeded() {
        let now = Date()
        var records: [(url: URL, size: Int, date: Date)] = []
        for url in Self.files(in: directory) {
            if let data = try? Data(contentsOf: url),
               let entry = try? JSONDecoder().decode(Entry.self, from: data),
               entry.expires <= now {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            records.append((url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast))
        }
        var total = records.reduce(0) { $0 + $1.size }
        guard total > maxDiskBytes else { return }
        let target = Int(Double(maxDiskBytes) * 0.85)
        for record in records.sorted(by: { $0.date < $1.date }) where total > target {
            try? FileManager.default.removeItem(at: record.url)
            total -= record.size
        }
    }

    /// Removes every cached entry in this namespace (memory and disk).
    func clear() {
        memory.removeAll()
        if let items = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                    includingPropertiesForKeys: nil) {
            for item in items {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    private static func files(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// Maps an arbitrary key to a safe filename via a stable hash.
    private static func fileURL(in directory: URL, key: String) -> URL {
        let hashed = String(UInt64(bitPattern: Int64(key.stableHash)))
        return directory.appendingPathComponent(hashed).appendingPathExtension("json")
    }
}

private extension String {
    /// Deterministic hash (djb2). Foundation's String.hashValue is randomized per launch,
    /// so it cannot be used for on-disk cache filenames.
    nonisolated var stableHash: Int {
        var result = 5381
        for byte in self.utf8 {
            result = (result &* 33) &+ Int(byte)
        }
        return result
    }
}
