import Foundation

/// Read-only iOS mirror of the catalog curated by StockedMac and its Server Mac.
/// The server catalog is intentionally much larger than app presentation needs. Keep only a
/// bounded working set in memory and on disk; decode/encode work stays off the main actor.
@MainActor
final class SharedGroceryCatalog {
    static let shared = SharedGroceryCatalog()

    nonisolated struct Record: Codable, Identifiable, Sendable {
        var id: String
        var kind: String
        var name: String
        var brand: String?
        var store: String?
        var category: String?
        var aisle: String?
        var address: String?
        var barcode: String?
        var source: String?
        var sourceURL: String?
        var imageURL: String?
        var imageSourceURL: String?
        var imageAttribution: String?
        var updatedAt: String?
    }

    private nonisolated struct Meta: Decodable, Sendable { var totalPages: Int; var totalRecords: Int }
    private nonisolated struct Page: Decodable, Sendable { var records: [Record] }
    private nonisolated struct Envelope: Decodable, Sendable { var meta: Meta; var page: Page }
    private nonisolated struct ProductLookup: Sendable { var nameKey: String; var brand: String }
    private nonisolated struct StoreLookup: Sendable { var key: String; var record: Record }
    private nonisolated struct PreparedSnapshot: Sendable {
        var records: [Record]
        var byItem: [String: [String]]
        var productBuckets: [String: [ProductLookup]]
        var stores: [StoreLookup]
    }

    /// The former unbounded mirror reached 161,846 records / 70.8 MB JSON and produced several
    /// more full-size copies while merging, sorting, encoding, and rebuilding its index.
    private nonisolated static let maximumRecords = 12_000
    private nonisolated static let maximumCacheBytes = 16 * 1_024 * 1_024
    private nonisolated static let maximumBrandResults = 40
    private nonisolated static let maximumStoreResults = 50

    private(set) var records: [Record] = []
    private var byItem: [String: [String]] = [:]
    private var productBuckets: [String: [ProductLookup]] = [:]
    private var storeLookups: [StoreLookup] = []
    private let cacheURL: URL
    private var didLoadCache = false
    private var isRefreshing = false
    private let refreshKey = "sharedCatalog.lastRefresh.v3"
    private let cursorKey = "sharedCatalog.pageCursor.v3"

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Stocked", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Never decode the old unbounded v1 mirror. The first successful refresh writes a bounded
        // replacement. Keeping the old file untouched makes this migration non-destructive.
        cacheURL = root.appendingPathComponent("shared-grocery-catalog-v2.json")
    }

    func refreshIfNeeded() async {
        if !didLoadCache {
            didLoadCache = true
            let url = cacheURL
            if let cached = await Task.detached(priority: .utility, operation: {
                Self.loadBoundedCache(from: url)
            }).value {
                let prepared = await Task.detached(priority: .utility) { Self.prepare(cached) }.value
                apply(prepared)
            }
        }

        let last = UserDefaults.standard.object(forKey: refreshKey) as? Date ?? .distantPast
        guard !isRefreshing, Date().timeIntervalSince(last) > 3_600,
              StockedUnifiedWorker.isConfigured else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let first = try await Self.fetchPage(0)
            var incoming = first.page.records
            if first.meta.totalPages > 1 {
                let pageCount = min(4, first.meta.totalPages - 1)
                let storedCursor = max(1, UserDefaults.standard.integer(forKey: cursorKey))
                let pages = (0..<pageCount).map { 1 + ((storedCursor - 1 + $0) % (first.meta.totalPages - 1)) }
                let pageRecords = try await withThrowingTaskGroup(of: (Int, [Record]).self) { group in
                    var result: [(Int, [Record])] = []
                    var iterator = pages.makeIterator()
                    for _ in 0..<min(2, pages.count) {
                        if let page = iterator.next() {
                            group.addTask { (page, try await Self.fetchPage(page).page.records) }
                        }
                    }
                    while let value = try await group.next() {
                        result.append(value)
                        if let page = iterator.next() {
                            group.addTask { (page, try await Self.fetchPage(page).page.records) }
                        }
                    }
                    return result.sorted { $0.0 < $1.0 }.flatMap(\.1)
                }
                incoming += pageRecords
                let nextCursor = 1 + ((pages.last ?? storedCursor) % (first.meta.totalPages - 1))
                UserDefaults.standard.set(nextCursor, forKey: cursorKey)
            }

            let existing = records
            let prepared = await Task.detached(priority: .utility) {
                Self.prepare(Self.mergeBounded(existing: existing, incoming: incoming))
            }.value
            apply(prepared)
            let url = cacheURL
            let records = prepared.records
            Task.detached(priority: .utility) { Self.persist(records, to: url) }
            UserDefaults.standard.set(Date(), forKey: refreshKey)
        } catch {
            // The last verified bounded disk mirror remains available offline.
        }
    }

    func brandNames(for itemName: String) -> [String] {
        let key = Self.key(itemName)
        guard !key.isEmpty else { return [] }
        if let direct = byItem[key] { return direct }
        let candidates = productBuckets[Self.bucket(for: key)] ?? []
        var seen = Set<String>(), result: [String] = []
        for item in candidates where item.nameKey.contains(key) || key.contains(item.nameKey) {
            if seen.insert(item.brand.lowercased()).inserted {
                result.append(item.brand)
                if result.count == Self.maximumBrandResults { break }
            }
        }
        return result.sorted()
    }

    func stores(matching query: String) -> [Record] {
        let key = Self.key(query)
        let matches = key.isEmpty ? storeLookups : storeLookups.filter { $0.key.contains(key) }
        return matches.prefix(Self.maximumStoreResults).map(\.record)
    }

    private static func fetchPage(_ page: Int) async throws -> Envelope {
        guard var components = StockedUnifiedWorker.url("/retail/catalog").flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "page", value: String(page))]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        BuildConfig.authorizeWorkerRequest(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard data.count <= 4 * 1_024 * 1_024,
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode
        else { throw URLError(.badServerResponse) }
        return try await Task.detached(priority: .utility) {
            try JSONDecoder().decode(Envelope.self, from: data)
        }.value
    }

    private func apply(_ prepared: PreparedSnapshot) {
        records = prepared.records
        byItem = prepared.byItem
        productBuckets = prepared.productBuckets
        storeLookups = prepared.stores
    }

    private nonisolated static func prepare(_ records: [Record]) -> PreparedSnapshot {
        var exact: [String: Set<String>] = [:]
        var buckets: [String: [ProductLookup]] = [:]
        var stores: [StoreLookup] = []
        for record in records {
            let nameKey = Self.key(record.name)
            if record.kind == "Product", let brand = record.brand?.trimmingCharacters(in: .whitespacesAndNewlines),
               !nameKey.isEmpty, !brand.isEmpty {
                exact[nameKey, default: []].insert(brand)
                buckets[Self.bucket(for: nameKey), default: []].append(.init(nameKey: nameKey, brand: brand))
            } else if record.kind == "Store" {
                stores.append(.init(
                    key: Self.key([record.name, record.address].compactMap { $0 }.joined(separator: " ")),
                    record: record
                ))
            }
        }
        return .init(
            records: records,
            byItem: exact.mapValues { Array($0).sorted() },
            productBuckets: buckets,
            stores: stores
        )
    }

    private nonisolated static func loadBoundedCache(from url: URL) -> [Record]? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size > 0, size <= maximumCacheBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let decoded = try? JSONDecoder().decode([Record].self, from: data),
              decoded.count <= maximumRecords else { return nil }
        return decoded
    }

    private nonisolated static func mergeBounded(existing: [Record], incoming: [Record]) -> [Record] {
        var merged: [String: Record] = [:]
        merged.reserveCapacity(min(maximumRecords, existing.count + incoming.count))
        for record in incoming.reversed() where merged.count < maximumRecords { merged[record.id] = record }
        for record in existing.reversed() where merged.count < maximumRecords && merged[record.id] == nil {
            merged[record.id] = record
        }
        return merged.values.sorted { $0.id < $1.id }
    }

    private nonisolated static func persist(_ records: [Record], to url: URL) {
        guard records.count <= maximumRecords, let data = try? JSONEncoder().encode(records),
              data.count <= maximumCacheBytes else { return }
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated static func bucket(for key: String) -> String { String(key.prefix(3)) }

    private nonisolated static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
    }
}
