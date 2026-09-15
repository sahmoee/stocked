import Foundation

/// Disposable, bounded client cache for deterministic Worker responses.
actor AIResultCache {
    static let shared = AIResultCache()
    private var storage: ResponseCacheStorage

    init(rootDirectory: URL? = nil) {
        let base = rootDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        storage = ResponseCacheStorage(directory: base.appendingPathComponent("StockedAIResults", isDirectory: true),
            limits: .init(memoryBytes: 8 * 1024 * 1024, diskBytes: 24 * 1024 * 1024), legacyName: { name in
                let stem = String(name.dropLast(5))
                return name.hasSuffix(".json") && (1...16).contains(stem.count) && stem.allSatisfy(\.isHexDigit)
            })
    }
    func currentGeneration() -> UUID { storage.generation }
    func value(route: String, schemaVersion: Int, payloadData: Data) -> Data? {
        guard payloadData.count <= 8 * 1024 * 1024 else { return nil }
        return storage.lookup(key(route, schemaVersion, payloadData))?.data
    }
    func save(_ data: Data, route: String, schemaVersion: Int, payloadData: Data, ttl: TimeInterval,
              expectedGeneration: UUID? = nil) {
        guard payloadData.count <= 8 * 1024 * 1024 else { return }
        storage.store(data, for: key(route, schemaVersion, payloadData), ttl: ttl, expectedGeneration: expectedGeneration)
    }
    func clear() { storage.clear() }
    func sizeBytes() -> Int64 { storage.diskSizeBytes() }
    private func key(_ route: String, _ schema: Int, _ payload: Data) -> String {
        ResponseCacheKey.make([Data(route.utf8), Data(String(schema).utf8), payload])
    }
}
