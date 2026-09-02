import Foundation

/// Read-only iOS mirror of the catalog curated by StockedMac and its Server Mac.
/// Household inventory remains a separate user-owned collection; this reference data
/// only improves brand/store suggestions and never creates pantry items by itself.
@MainActor
final class SharedGroceryCatalog {
    static let shared = SharedGroceryCatalog()

    struct Record: Codable, Identifiable, Sendable {
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

    private struct Meta: Decodable { var totalPages: Int; var totalRecords: Int }
    private struct Page: Decodable { var records: [Record] }
    private struct Envelope: Decodable { var meta: Meta; var page: Page }

    private(set) var records: [Record] = []
    private var byItem: [String: [Record]] = [:]
    private let cacheURL: URL
    private var isRefreshing = false
    private let refreshKey = "sharedCatalog.lastRefresh.v2"
    private let cursorKey = "sharedCatalog.pageCursor.v2"

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Stocked", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cacheURL = root.appendingPathComponent("shared-grocery-catalog-v1.json")
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([Record].self, from: data) {
            records = cached; rebuildIndex()
        }
    }

    func refreshIfNeeded() async {
        let last = UserDefaults.standard.object(forKey: refreshKey) as? Date ?? .distantPast
        guard !isRefreshing,
              Date().timeIntervalSince(last) > 3_600,
              StockedUnifiedWorker.isConfigured else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let first = try await fetch(page: 0)
            var incoming = first.page.records
            if first.meta.totalPages > 1 {
                // Rotate through a small window instead of opening a connection for every
                // catalog page at launch. The verified disk mirror accumulates pages over
                // time, while each visit performs at most four additional requests.
                let pageCount = min(4, first.meta.totalPages - 1)
                let storedCursor = max(1, UserDefaults.standard.integer(forKey: cursorKey))
                let pages = (0..<pageCount).map { offset in
                    1 + ((storedCursor - 1 + offset) % (first.meta.totalPages - 1))
                }
                let pageRecords = try await withThrowingTaskGroup(of: (Int, [Record]).self) { group in
                    var result: [(Int, [Record])] = []
                    var iterator = pages.makeIterator()
                    for _ in 0..<min(2, pages.count) {
                        if let page = iterator.next() {
                            group.addTask { (page, try await self.fetch(page: page).page.records) }
                        }
                    }
                    while let value = try await group.next() {
                        result.append(value)
                        if let page = iterator.next() {
                            group.addTask { (page, try await self.fetch(page: page).page.records) }
                        }
                    }
                    return result.sorted { $0.0 < $1.0 }.flatMap(\.1)
                }
                incoming += pageRecords
                let nextCursor = 1 + ((pages.last ?? storedCursor) % (first.meta.totalPages - 1))
                UserDefaults.standard.set(nextCursor, forKey: cursorKey)
            }
            var merged = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            for record in incoming { merged[record.id] = record }
            records = merged.values.sorted { $0.id < $1.id }
            rebuildIndex()
            if let data = try? JSONEncoder().encode(records) { try? data.write(to: cacheURL, options: .atomic) }
            UserDefaults.standard.set(Date(), forKey: refreshKey)
        } catch {
            // The last verified disk mirror remains available offline.
        }
    }

    func brandNames(for itemName: String) -> [String] {
        let key = Self.key(itemName)
        let direct = byItem[key] ?? []
        let fuzzy = direct.isEmpty ? records.filter {
            $0.kind == "Product" && (Self.key($0.name).contains(key) || key.contains(Self.key($0.name)))
        } : direct
        return Array(Set(fuzzy.compactMap { $0.brand?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    func stores(matching query: String) -> [Record] {
        let key = Self.key(query)
        return records.filter { $0.kind == "Store" && (key.isEmpty || Self.key([$0.name, $0.address].compactMap { $0 }.joined(separator: " ")).contains(key)) }
    }

    private func fetch(page: Int) async throws -> Envelope {
        guard var components = StockedUnifiedWorker.url("/retail/catalog").flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "page", value: String(page))]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        BuildConfig.authorizeWorkerRequest(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Envelope.self, from: data)
    }

    private func rebuildIndex() {
        byItem = Dictionary(grouping: records.filter { $0.kind == "Product" }, by: { Self.key($0.name) })
    }

    private static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
    }
}
