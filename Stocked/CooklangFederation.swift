import Foundation

/// Original client for cooklang/federation's documented HTTP API. No server code is embedded.
nonisolated struct CooklangFederationCard: Identifiable, Decodable, Sendable {
    let id: Int64
    let title: String
    let summary: String?
    let tags: [String]
    let locale: String?
}

nonisolated struct CooklangFederationPage: Sendable {
    var cards: [CooklangFederationCard]
    var page: Int
    var hasMore: Bool
    var warning: String?
}

nonisolated struct CooklangFederationRecipe: Identifiable, Sendable {
    let id: String
    let recipeID: Int64
    let federationURL: URL
    let title: String
    let content: String
    let sourceURL: URL?
    let enclosureURL: URL?
    let imageURL: URL?
    let feedName: String
    let feedAuthor: String

    var filename: String { "cooklang-\(recipeID).cook" }
    var attributionNote: String {
        "Discovered with Cooklang Federation: \(federationURL.absoluteString)\nRecipe collection: \(feedName.isEmpty ? "Not supplied" : feedName)\nCollection author: \(feedAuthor.isEmpty ? "Not supplied" : feedAuthor)\nThe index supplied this Cooklang text. Check the original source for updates and sharing rights."
    }
}

nonisolated enum CooklangFederationPolicy {
    static let defaultEndpoint = "https://recipes.cooklang.org"
    static let pageSize = 20
    static let maximumPages = 10
    static let responseBytes = 256 * 1024
    static let recipeBytes = 48 * 1024

    enum Failure: LocalizedError {
        case endpoint, query, response, tooLarge, noContent, identity, http(Int)
        var errorDescription: String? {
            switch self {
            case .endpoint: "Use a public HTTPS Cooklang Federation address, without a password, query or fragment. CookCLI's local server uses a different API."
            case .query: "Enter 1 to 200 characters to search. Choose a page from 1 to 10."
            case .response: "This address did not return a supported Cooklang Federation response. Your saved recipes are unchanged."
            case .tooLarge: "This response is too large for a safe preview. Try a narrower search or download a smaller recipe file yourself."
            case .noContent: "The index has no usable Cooklang text for this recipe. Open its original source instead."
            case .identity: "The server returned a different recipe than requested. Nothing was imported."
            case .http(let code) where code == 429: "The recipe index is busy and asked us to slow down. Try again later."
            case .http(let code) where (300..<400).contains(code): "This source redirected the request. Enter its final HTTPS Federation address to continue."
            case .http(let code) where code == 401 || code == 403: "This recipe index requires access Stocked does not have. No login or paid fallback is attempted."
            case .http(let code): "The recipe index returned an error (\(code)). Try again later; saved recipes are unchanged."
            }
        }
    }

    /// Matches the browser's public HTTPS boundary. No credentials, cookies, literal
    /// addresses or local hostnames. This is URL validation, not a DNS firewall.
    static func publicURL(_ text: String) -> URL? {
        guard !text.isEmpty, text.utf8.count <= 2048,
              !text.contains(where: { $0.isWhitespace }), !text.contains("\\"),
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), host.contains("."), host.contains(where: \.isLetter),
              !host.hasSuffix("."), !host.contains(".."),
              ![".local", ".localhost", ".internal", ".lan", ".home", ".test"].contains(where: host.hasSuffix),
              host.split(separator: ".").allSatisfy({ part in
                  !part.isEmpty && !part.hasPrefix("-") && !part.hasSuffix("-") && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }),
              !host.split(separator: ".").allSatisfy({ $0.range(of: #"^(?:0x[0-9a-f]+|[0-9]+)$"#, options: .regularExpression) != nil }) else { return nil }
        return parts.url
    }

    static func endpoint(_ text: String) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = publicURL(value), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.query == nil, parts.fragment == nil, parts.path.utf8.count <= 200,
              parts.path.split(separator: "/").allSatisfy({ part in
                  part != "." && part != ".." && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
              }) else { throw Failure.endpoint }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let base = parts.url else { throw Failure.endpoint }
        return base
    }

    static func searchURL(endpoint: URL, query: String, page: Int) throws -> URL {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 200, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...maximumPages).contains(page) else { throw Failure.query }
        let base = try self.endpoint(endpoint.absoluteString)
        var parts = URLComponents(url: base.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "q", value: text), URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: String(pageSize))]
        guard let url = parts.url else { throw Failure.query }
        return url
    }

    static func recipeURL(endpoint: URL, id: Int64) throws -> URL {
        guard id > 0 else { throw Failure.identity }
        return try self.endpoint(endpoint.absoluteString).appendingPathComponent("api/recipes/\(id)")
    }

    static func decodePage(_ data: Data, expectedPage: Int) throws -> CooklangFederationPage {
        guard data.count <= responseBytes else { throw Failure.tooLarge }
        struct Wire: Decodable {
            struct Pagination: Decodable { let page: Int; let total_pages: Int }
            let results: [CooklangFederationCard]
            let pagination: Pagination
        }
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: data) } catch { throw Failure.response }
        guard wire.pagination.page == expectedPage, wire.pagination.total_pages >= 0, wire.results.count <= 100 else { throw Failure.response }
        var seen: Set<Int64> = []
        let valid = wire.results.filter {
            $0.id > 0 && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.utf8.count <= 2000
                && ($0.summary?.utf8.count ?? 0) <= 4000 && $0.tags.count <= 50
                && $0.tags.allSatisfy { $0.utf8.count <= 200 } && ($0.locale?.utf8.count ?? 0) <= 80 && seen.insert($0.id).inserted
        }
        return CooklangFederationPage(cards: Array(valid.prefix(pageSize)), page: expectedPage,
            hasMore: expectedPage < maximumPages && expectedPage < wire.pagination.total_pages,
            warning: valid.count == wire.results.count && valid.count <= pageSize ? nil : "Some repeated, oversized or extra results were left out of this bounded preview.")
    }

    static func decodeRecipe(_ data: Data, endpoint: URL, expectedID: Int64) throws -> CooklangFederationRecipe {
        guard data.count <= responseBytes else { throw Failure.tooLarge }
        struct Wire: Decodable {
            struct Feed: Decodable { let title: String?; let author: String? }
            let id: Int64; let title: String; let content: String?
            let source_url: String?; let enclosure_url: String?; let image_url: String?; let feed: Feed
        }
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: data) } catch { throw Failure.response }
        guard wire.id == expectedID else { throw Failure.identity }
        guard let content = wire.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.noContent }
        guard content.utf8.count <= recipeBytes, wire.title.utf8.count <= 2000,
              (wire.feed.title?.utf8.count ?? 0) <= 2000, (wire.feed.author?.utf8.count ?? 0) <= 2000,
              try JSONEncoder().encode(content).count <= 60 * 1024 else { throw Failure.tooLarge }
        let base = try self.endpoint(endpoint.absoluteString)
        return CooklangFederationRecipe(id: "\(base.absoluteString)#\(wire.id)", recipeID: wire.id, federationURL: base,
            title: wire.title, content: content, sourceURL: wire.source_url.flatMap(publicURL),
            enclosureURL: wire.enclosure_url.flatMap(publicURL), imageURL: wire.image_url.flatMap(publicURL),
            feedName: wire.feed.title ?? "", feedAuthor: wire.feed.author ?? "")
    }
}

nonisolated enum CooklangFederationClient {
    static func search(endpoint: URL, query: String, page: Int) async throws -> CooklangFederationPage {
        let url = try CooklangFederationPolicy.searchURL(endpoint: endpoint, query: query, page: page)
        let data = try await read(url)
        try Task.checkCancellation()
        return try await parse { try CooklangFederationPolicy.decodePage(data, expectedPage: page) }
    }
    static func recipe(endpoint: URL, id: Int64) async throws -> CooklangFederationRecipe {
        let url = try CooklangFederationPolicy.recipeURL(endpoint: endpoint, id: id)
        let data = try await read(url)
        try Task.checkCancellation()
        return try await parse { try CooklangFederationPolicy.decodeRecipe(data, endpoint: endpoint, expectedID: id) }
    }
    private static func parse<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility) { try Task.checkCancellation(); return try body() }
        return try await withTaskCancellationHandler {
            let result = try await task.value; try Task.checkCancellation(); return result
        } onCancel: { task.cancel() }
    }
    private static func read(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: CooklangNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Stocked-Cooklang-Reader/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw CooklangFederationPolicy.Failure.response }
        guard http.statusCode == 200 else { throw CooklangFederationPolicy.Failure.http(http.statusCode) }
        guard http.mimeType?.lowercased() == "application/json" else { throw CooklangFederationPolicy.Failure.response }
        guard response.expectedContentLength <= CooklangFederationPolicy.responseBytes else { throw CooklangFederationPolicy.Failure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < CooklangFederationPolicy.responseBytes else { throw CooklangFederationPolicy.Failure.tooLarge }
            data.append(byte)
        }
        return data
    }
}

nonisolated private final class CooklangNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
