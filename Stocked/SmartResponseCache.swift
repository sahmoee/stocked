import Foundation

/// Stale-while-revalidate responses with one owned refresh per request identity.
actor SmartResponseCache {
    static let shared = SmartResponseCache()
    enum Freshness: Sendable { case fresh, stale, missing }
    private struct Flight { let id: UUID; let task: Task<Data?, Never> }
    private var storage: ResponseCacheStorage
    private var flights: [String: Flight] = [:]
    private var retryAfter: [String: TimeInterval] = [:]
    private let uptime: @Sendable () -> TimeInterval
    private let freshFor: TimeInterval = 3600
    private let keepFor: TimeInterval = 14 * 24 * 3600

    init(rootDirectory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() },
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        let base = rootDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        storage = ResponseCacheStorage(directory: base.appendingPathComponent("StockedSmartCache", isDirectory: true),
            limits: .init(memoryBytes: 8 * 1024 * 1024, diskBytes: 24 * 1024 * 1024), now: now,
            legacyName: { name in (1...13).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
        self.uptime = uptime
    }
    nonisolated static func key(_ endpoint: String, _ arguments: String, responseType: String = "") -> String {
        ResponseCacheKey.make([endpoint, arguments, responseType])
    }
    func currentGeneration() -> UUID { storage.generation }
    func lookup(_ key: String) -> (data: Data, freshness: Freshness) {
        guard let hit = storage.lookup(key) else { return (Data(), .missing) }
        return (hit.data, hit.age < freshFor ? .fresh : .stale)
    }
    func store(_ data: Data, for key: String) { storage.store(data, for: key, ttl: keepFor) }
    func remove(_ key: String) { storage.remove(key) }

    /// Launch without waiting when an existing answer is on screen.
    func refreshInBackground(_ key: String, expectedGeneration: UUID? = nil, fetch: @escaping @Sendable () async -> Data?) {
        _ = flight(for: key, expectedGeneration: expectedGeneration, fetch: fetch)
    }
    func refreshedData(_ key: String, expectedGeneration: UUID? = nil, fetch: @escaping @Sendable () async -> Data?) async -> Data? {
        guard !Task.isCancelled, let task = flight(for: key, expectedGeneration: expectedGeneration, fetch: fetch) else { return nil }
        let result = await task.value
        return Task.isCancelled || task.isCancelled ? nil : result
    }
    private func flight(for key: String, expectedGeneration: UUID?, fetch: @escaping @Sendable () async -> Data?) -> Task<Data?, Never>? {
        guard !Task.isCancelled, expectedGeneration == nil || expectedGeneration == storage.generation else { return nil }
        if let existing = flights[key] { return existing.task }
        if let hit = storage.lookup(key), hit.age < freshFor { return Task { hit.data } }
        let now = uptime()
        retryAfter = retryAfter.filter { $0.value > now }
        guard retryAfter[key] == nil, flights.count < 32 else { return nil }
        let id = UUID(), generation = storage.generation
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return Optional<Data>.none }
            let result = await fetch()
            guard let self else { return nil }
            return await self.complete(result, key: key, id: id, generation: generation)
        }
        flights[key] = Flight(id: id, task: task)
        return task
    }
    private func complete(_ data: Data?, key: String, id: UUID, generation: UUID) -> Data? {
        guard flights[key]?.id == id else { return nil }
        flights[key] = nil
        guard !Task.isCancelled, generation == storage.generation else { return nil }
        if let data, !data.isEmpty {
            storage.store(data, for: key, ttl: keepFor, expectedGeneration: generation)
            retryAfter[key] = nil
            return data
        }
        if retryAfter.count >= 256, let oldest = retryAfter.min(by: { $0.value < $1.value })?.key { retryAfter[oldest] = nil }
        retryAfter[key] = uptime() + 30
        return nil
    }
    func clear() {
        for flight in flights.values { flight.task.cancel() }
        flights.removeAll(); retryAfter.removeAll(); storage.clear()
    }
    func sizeBytes() -> Int64 { storage.diskSizeBytes() }
    func entryCount() -> Int { storage.diskEntryCount() }
}

nonisolated enum SmartCached {
    static func value<T: Codable & Sendable>(endpoint: String, arguments: String,
                                             fetch: @escaping @Sendable () async -> T?) async -> T? {
        guard !Task.isCancelled else { return nil }
        let cache = SmartResponseCache.shared
        let key = SmartResponseCache.key(endpoint, arguments, responseType: String(reflecting: T.self))
        let generation = await cache.currentGeneration()
        let (data, freshness) = await cache.lookup(key)
        guard !Task.isCancelled else { return nil }
        let load: @Sendable () async -> Data? = {
            guard !Task.isCancelled, let value = await fetch(), !Task.isCancelled else { return nil }
            return try? JSONEncoder().encode(value)
        }
        if freshness != .missing {
            if let cached = try? JSONDecoder().decode(T.self, from: data) {
                if freshness == .stale { await cache.refreshInBackground(key, expectedGeneration: generation, fetch: load) }
                return Task.isCancelled ? nil : cached
            }
            // A model/schema mismatch must not be returned again on every lookup.
            await cache.remove(key)
        }
        guard let fresh = await cache.refreshedData(key, expectedGeneration: generation, fetch: load), !Task.isCancelled else { return nil }
        return try? JSONDecoder().decode(T.self, from: fresh)
    }
}
