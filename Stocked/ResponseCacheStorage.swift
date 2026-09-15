import Foundation
import CryptoKit

/// Framed SHA-256 identities keep separators, binary payloads and response shapes distinct.
nonisolated enum ResponseCacheKey {
    static func make(_ parts: [Data]) -> String {
        var hash = SHA256()
        for part in parts {
            var count = UInt64(part.count).bigEndian
            withUnsafeBytes(of: &count) { hash.update(data: Data($0)) }
            hash.update(data: part)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func make(_ parts: [String]) -> String { make(parts.map { Data($0.utf8) }) }
}

/// Synchronous storage owned by a cache actor. Never use it from a SwiftUI body.
/// Responses are disposable; kitchen records and provider credentials do not belong here.
nonisolated struct ResponseCacheStorage {
    struct Limits: Sendable {
        var entryBytes = 4 * 1024 * 1024
        var memoryBytes = 16 * 1024 * 1024
        var diskBytes = 64 * 1024 * 1024
        var entries = 400
        var maximumTTL: TimeInterval = 365 * 24 * 60 * 60
    }
    struct Hit: Sendable { let data: Data; let age: TimeInterval }
    private struct Entry: Codable {
        let version: Int
        let key: String
        let storedAt: Date
        let expiresAt: Date
        let data: Data
    }
    private struct Memory { let entry: Entry; var access: UInt64 }
    private struct DiskFile { let url: URL; let size: Int; let touched: Date }
    let directory: URL
    let limits: Limits
    private let now: @Sendable () -> Date
    private let legacyName: @Sendable (String) -> Bool
    private var memory: [String: Memory] = [:]
    private var memoryBytes = 0
    private var access: UInt64 = 0
    private(set) var generation = UUID()

    init(directory: URL, limits: Limits = Limits(), now: @escaping @Sendable () -> Date = { Date() },
         legacyName: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.directory = directory
        var bounded = limits
        bounded.entryBytes = min(16 * 1024 * 1024, max(1, limits.entryBytes))
        bounded.memoryBytes = min(128 * 1024 * 1024, max(0, limits.memoryBytes))
        bounded.diskBytes = min(512 * 1024 * 1024, max(1, limits.diskBytes))
        bounded.entries = min(2000, max(1, limits.entries))
        bounded.maximumTTL = limits.maximumTTL.isFinite ? min(365 * 24 * 60 * 60, max(0, limits.maximumTTL)) : 0
        self.limits = bounded; self.now = now; self.legacyName = legacyName
    }

    mutating func lookup(_ key: String) -> Hit? {
        guard !Task.isCancelled, key.utf8.count <= 65_536 else { return nil }
        let digest = ResponseCacheKey.make([key])
        let current = now()
        if var cached = memory[digest] {
            guard valid(cached.entry, digest: digest, at: current) else { removeDigest(digest); return nil }
            access &+= 1; cached.access = access; memory[digest] = cached
            touch(file(digest), at: current)
            return Hit(data: cached.entry.data, age: max(0, current.timeIntervalSince(cached.entry.storedAt)))
        }
        let url = file(digest)
        guard ownedRegularFile(url) else { return nil }
        let encodedLimit = limits.entryBytes * 2 + 4096
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= encodedLimit,
              let handle = try? FileHandle(forReadingFrom: url) else { removeDigest(digest); return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: encodedLimit + 1), data.count <= encodedLimit,
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              valid(entry, digest: digest, at: current) else { removeDigest(digest); return nil }
        guard !Task.isCancelled else { return nil }
        retain(entry, digest: digest)
        touch(url, at: current)
        return Hit(data: entry.data, age: max(0, current.timeIntervalSince(entry.storedAt)))
    }

    @discardableResult
    mutating func store(_ data: Data, for key: String, ttl: TimeInterval, expectedGeneration: UUID? = nil) -> Bool {
        guard !Task.isCancelled, expectedGeneration == nil || expectedGeneration == generation,
              key.utf8.count <= 65_536 else { return false }
        let digest = ResponseCacheKey.make([key])
        guard ttl.isFinite, ttl > 0 else { removeDigest(digest); return false }
        guard !data.isEmpty, data.count <= limits.entryBytes else { return false }
        let current = now(), duration = min(ttl, limits.maximumTTL)
        guard duration > 0, current.timeIntervalSince1970.isFinite else { return false }
        let entry = Entry(version: 2, key: digest, storedAt: current,
                          expiresAt: current.addingTimeInterval(duration), data: data)
        guard valid(entry, digest: digest, at: current),
              let encoded = try? JSONEncoder().encode(entry), encoded.count <= limits.diskBytes else { return false }
        // A full/read-only cache disk must not discard the freshly fetched in-memory answer.
        retain(entry, digest: digest)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoded.write(to: file(digest), options: .atomic)
            touch(file(digest), at: current)
            prune()
        } catch { /* A cache write is best effort; the caller still has the response. */ }
        return true
    }

    mutating func remove(_ key: String) { removeDigest(ResponseCacheKey.make([key])) }
    mutating func clear() {
        generation = UUID(); memory.removeAll(); memoryBytes = 0
        for row in files() { try? FileManager.default.removeItem(at: row.url) }
    }
    var retainedCount: Int { memory.count }
    var retainedBytes: Int { memoryBytes }
    func diskSizeBytes() -> Int64 { files().reduce(0) { $0 + Int64($1.size) } }
    func diskEntryCount() -> Int { files().count }

    mutating func prune() {
        let rows = files().sorted { $0.touched == $1.touched ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.touched < $1.touched }
        var bytes = rows.reduce(Int64(0)) { $0 + Int64($1.size) }, count = rows.count
        let current = now()
        for row in rows {
            let expired = current.timeIntervalSince(row.touched) >= limits.maximumTTL
            guard expired || bytes > Int64(limits.diskBytes) || count > limits.entries else { continue }
            do {
                try FileManager.default.removeItem(at: row.url)
                bytes -= Int64(row.size); count -= 1
                let digest = String(row.url.deletingPathExtension().lastPathComponent.dropFirst(3))
                removeMemory(digest)
            } catch { continue } // Only successful removal reduces the remaining budget.
        }
    }

    private func valid(_ entry: Entry, digest: String, at date: Date) -> Bool {
        let age = date.timeIntervalSince(entry.storedAt)
        let lifetime = entry.expiresAt.timeIntervalSince(entry.storedAt)
        return entry.version == 2 && entry.key == digest && !entry.data.isEmpty && entry.data.count <= limits.entryBytes
            && age.isFinite && age >= -300 && lifetime.isFinite && lifetime > 0
            && lifetime <= limits.maximumTTL && entry.expiresAt > date
    }
    private mutating func retain(_ entry: Entry, digest: String) {
        removeMemory(digest)
        guard entry.data.count <= limits.memoryBytes else { return }
        while memory.count >= limits.entries || memoryBytes > limits.memoryBytes - entry.data.count {
            guard let victim = memory.min(by: { $0.value.access == $1.value.access ? $0.key < $1.key : $0.value.access < $1.value.access })?.key else { break }
            removeMemory(victim)
        }
        access &+= 1; memory[digest] = Memory(entry: entry, access: access); memoryBytes += entry.data.count
    }
    private mutating func removeMemory(_ digest: String) {
        if let old = memory.removeValue(forKey: digest) { memoryBytes -= old.entry.data.count }
    }
    private mutating func removeDigest(_ digest: String) {
        removeMemory(digest)
        let url = file(digest)
        if ownedRegularFile(url) { try? FileManager.default.removeItem(at: url) }
    }
    private func file(_ digest: String) -> URL { directory.appendingPathComponent("v2_" + digest + ".json") }
    private func touch(_ url: URL, at date: Date) { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    private func ownedRegularFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let digest = String(name.dropFirst(3).dropLast(5))
        let currentName = name.hasPrefix("v2_") && name.hasSuffix(".json") && digest.count == 64 && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        guard currentName || legacyName(name),
              let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return info.isRegularFile == true && info.isSymbolicLink != true
    }
    private func files() -> [DiskFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []).compactMap { url in
            guard ownedRegularFile(url), let info = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return DiskFile(url: url, size: max(0, info.fileSize ?? 0), touched: info.contentModificationDate ?? .distantPast)
        }
    }
}
