import Foundation

/// Disposable, bounded storage for exact Cook Now classification results.
/// GuestDataStore remains authoritative; this actor only avoids recomputing a result whose
/// content-addressed input key is unchanged.
actor CookNowPersistentCache {
    static let shared = CookNowPersistentCache()

    private static let ttl: TimeInterval = 30 * 24 * 60 * 60
    private var storage: ResponseCacheStorage

    init(rootDirectory: URL? = nil) {
        let base = rootDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var limits = ResponseCacheStorage.Limits()
        limits.entryBytes = 16 * 1024 * 1024
        limits.memoryBytes = 24 * 1024 * 1024
        limits.diskBytes = 64 * 1024 * 1024
        limits.entries = 8
        limits.maximumTTL = Self.ttl
        storage = ResponseCacheStorage(
            directory: base.appendingPathComponent("CookNowResults", isDirectory: true),
            limits: limits
        )
    }

    func value(for key: String) -> CookNowCompute.Output? {
        guard let hit = storage.lookup(key) else { return nil }
        return try? JSONDecoder().decode(CookNowCompute.Output.self, from: hit.data)
    }

    func store(_ output: CookNowCompute.Output, for key: String) {
        guard let data = try? JSONEncoder().encode(output) else { return }
        storage.store(data, for: key, ttl: Self.ttl)
    }

    func clear() { storage.clear() }
}
