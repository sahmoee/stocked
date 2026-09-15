import Foundation

/// Actor-owned bounded response storage; persisted kitchen data is separate.
actor APIResponseCache {
    static let shared = APIResponseCache(namespace: "NutritionAPIs")
    private var storage: ResponseCacheStorage

    init(namespace: String, rootDirectory: URL? = nil) {
        let base = rootDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        // Preserve the established namespace directory; reject path separators for new callers.
        let safe = !namespace.isEmpty && namespace.count <= 80 && namespace.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            ? namespace : ResponseCacheKey.make([namespace])
        storage = ResponseCacheStorage(directory: base.appendingPathComponent("APICache", isDirectory: true).appendingPathComponent(safe, isDirectory: true),
            limits: .init(memoryBytes: 24 * 1024 * 1024, diskBytes: 150 * 1024 * 1024), legacyName: { name in
                let stem = String(name.dropLast(5))
                return name.hasSuffix(".json") && (1...20).contains(stem.count) && stem.allSatisfy(\.isNumber)
            })
    }
    func value<T: Decodable & Sendable>(for key: String, as type: T.Type) -> T? {
        guard let hit = storage.lookup(key) else { return nil }
        guard let value = try? JSONDecoder().decode(T.self, from: hit.data) else {
            storage.remove(key); return nil
        }
        return value
    }
    func store<T: Encodable & Sendable>(_ value: T, for key: String, ttl: TimeInterval) {
        guard !Task.isCancelled, let data = try? JSONEncoder().encode(value) else { return }
        storage.store(data, for: key, ttl: ttl)
    }
    func diskSizeBytes() -> Int { Int(storage.diskSizeBytes()) }
    func diskSizeString() -> String { ByteCountFormatter.string(fromByteCount: storage.diskSizeBytes(), countStyle: .file) }
    func pruneIfNeeded() { storage.prune() }
    func clear() { storage.clear() }
}
