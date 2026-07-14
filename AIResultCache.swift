// AIResultCache.swift
// Persistent, bounded client cache for deterministic Worker results.
import Foundation

actor AIResultCache {
    static let shared = AIResultCache()

    nonisolated struct Entry: Codable, Sendable {
        let savedAt: Date
        let expiresAt: Date
        let data: Data
    }

    private let directory: URL
    private let maxBytes = 24 * 1024 * 1024

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("StockedAIResults", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func value(route: String, schemaVersion: Int, payloadData: Data) -> Data? {
        let url = fileURL(route: route, schemaVersion: schemaVersion, payloadData: payloadData)
        guard let raw = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: raw) else { return nil }
        guard entry.expiresAt > Date() else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return entry.data
    }

    func save(_ data: Data, route: String, schemaVersion: Int,
              payloadData: Data, ttl: TimeInterval) {
        guard ttl > 0 else { return }
        let entry = Entry(savedAt: Date(), expiresAt: Date().addingTimeInterval(ttl), data: data)
        guard let raw = try? JSONEncoder().encode(entry) else { return }
        let url = fileURL(route: route, schemaVersion: schemaVersion, payloadData: payloadData)
        try? raw.write(to: url, options: .atomic)
        pruneIfNeeded()
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func sizeBytes() -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        return urls.reduce(Int64(0)) { partial, url in
            partial + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func fileURL(route: String, schemaVersion: Int, payloadData: Data) -> URL {
        let seed = Data("\(route)|\(schemaVersion)|".utf8) + payloadData
        let key = Self.fnv1a(seed)
        return directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    private func pruneIfNeeded() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let rows = urls.map { url -> (URL, Int, Date) in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
        var total = rows.reduce(0) { $0 + $1.1 }
        guard total > maxBytes else { return }
        for row in rows.sorted(by: { $0.2 < $1.2 }) where total > maxBytes {
            try? FileManager.default.removeItem(at: row.0)
            total -= row.1
        }
    }

    nonisolated private static func fnv1a(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}
