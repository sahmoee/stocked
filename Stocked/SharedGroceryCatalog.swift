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
        let last = UserDefaults.standard.object(forKey: "sharedCatalog.lastRefresh.v1") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 900, StockedUnifiedWorker.isConfigured else { return }
        do {
            let first = try await fetch(page: 0)
            var incoming = first.page.records
            if first.meta.totalPages > 1 {
                // Fetch every bounded Worker page with modest concurrency. This keeps the
                // full reference catalog available without serially blocking app launch.
                let pageRecords = try await withThrowingTaskGroup(of: (Int, [Record]).self) { group in
                    var next = 1
                    let initial = min(6, first.meta.totalPages - 1)
                    for _ in 0..<initial { let page = next; next += 1; group.addTask { (page, try await self.fetch(page: page).page.records) } }
                    var result: [(Int, [Record])] = []
                    while let value = try await group.next() {
                        result.append(value)
                        if next < first.meta.totalPages { let page = next; next += 1; group.addTask { (page, try await self.fetch(page: page).page.records) } }
                    }
                    return result.sorted { $0.0 < $1.0 }.flatMap(\.1)
                }
                incoming += pageRecords
            }
            var seen = Set<String>()
            records = incoming.filter { seen.insert($0.id).inserted }
            rebuildIndex()
            if let data = try? JSONEncoder().encode(records) { try? data.write(to: cacheURL, options: .atomic) }
            UserDefaults.standard.set(Date(), forKey: "sharedCatalog.lastRefresh.v1")
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
        var request = URLRequest(url: url); request.timeoutInterval = 30
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
