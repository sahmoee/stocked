// xcrun swiftc Stocked/CooklangFederation.swift scripts/CooklangFederationChecks.swift -o /tmp/stocked-cooklang-federation
// Optional --live performs only one explicit public search and one matching recipe GET.
import Foundation

@main struct CooklangFederationChecks {
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        let base = try CooklangFederationPolicy.endpoint("https://recipes.cooklang.org/")
        check(base.absoluteString == CooklangFederationPolicy.defaultEndpoint, "canonical trailing slash removed")
        for endpoint in ["http://example.com", "https://127.0.0.1", "https://localhost", "https://myserver.local", "https://user:password@example.com", "https://example.com?q=secret", "https://example.com#fragment", "https://example.com/%2e%2e", "https://example.com:9080", "https://example.com\\@other.com", "https://0x7f.0.0.1"] {
            check(rejects { _ = try CooklangFederationPolicy.endpoint(endpoint) }, "unsafe or incompatible endpoint rejected: \(endpoint)")
        }
        let prefixed = try CooklangFederationPolicy.endpoint("https://example.com/recipes-index")
        let search = try CooklangFederationPolicy.searchURL(endpoint: prefixed, query: "rice & beans", page: 2)
        let components = URLComponents(url: search, resolvingAgainstBaseURL: false)!
        check(search.path == "/recipes-index/api/search" && components.queryItems?.first(where: { $0.name == "q" })?.value == "rice & beans", "custom API prefix and query escaping preserve user words")
        check(components.queryItems?.first(where: { $0.name == "limit" })?.value == "20", "explicit bounded page request")
        check(rejects { _ = try CooklangFederationPolicy.searchURL(endpoint: base, query: "", page: 1) }, "empty full-index query rejected")
        check(rejects { _ = try CooklangFederationPolicy.searchURL(endpoint: base, query: "soup", page: 11) }, "beyond-ten-page request rejected")
        check(rejects { _ = try CooklangFederationPolicy.searchURL(endpoint: base, query: String(repeating: "x", count: 201), page: 1) }, "oversized query rejected")
        check(rejects { _ = try CooklangFederationPolicy.recipeURL(endpoint: base, id: -1) }, "invalid recipe identity rejected")
        let page = Data(#"{"results":[{"id":1,"title":"Fixture soup","summary":null,"tags":["soup"],"locale":"en"},{"id":1,"title":"Repeated","tags":[]}],"pagination":{"page":1,"total_pages":3}}"#.utf8)
        let parsed = try CooklangFederationPolicy.decodePage(page, expectedPage: 1)
        check(parsed.cards.count == 1 && parsed.warning != nil && parsed.hasMore, "duplicate search identities filtered and disclosed")
        check(rejects { _ = try CooklangFederationPolicy.decodePage(page, expectedPage: 2) }, "mismatched response page rejected")
        check(rejects { _ = try CooklangFederationPolicy.decodePage(Data("<html>Error</html>".utf8), expectedPage: 1) }, "HTML cannot masquerade as federation JSON")
        check(rejects { _ = try CooklangFederationPolicy.decodePage(Data(repeating: 32, count: CooklangFederationPolicy.responseBytes + 1), expectedPage: 1) }, "body byte cap enforced before decode")
        let raw = "---\nauthor: Fixture recipe author\n---\nMix @water{1%cup}."
        func detail(content: String?) throws -> Data {
            var object: [String: Any] = ["id": 3, "title": "Fixture", "source_url": "https://example.com/recipe", "enclosure_url": "https://example.com/recipe.cook", "image_url": "http://127.0.0.1/photo", "feed": ["title": "Fixture collection", "author": "Collection curator"]]
            object["content"] = content ?? NSNull()
            return try JSONSerialization.data(withJSONObject: object)
        }
        let decoded = try CooklangFederationPolicy.decodeRecipe(detail(content: raw), endpoint: base, expectedID: 3)
        check(decoded.content == raw && decoded.sourceURL?.absoluteString == "https://example.com/recipe", "exact index text and source are retained")
        check(decoded.imageURL == nil, "unsafe image link is never carried into import")
        check(decoded.attributionNote.contains("Collection author: Collection curator"), "collection author is identified separately from recipe author")
        check(rejects { _ = try CooklangFederationPolicy.decodeRecipe(detail(content: raw), endpoint: base, expectedID: 4) }, "recipe response identity checked")
        check(rejects { _ = try CooklangFederationPolicy.decodeRecipe(detail(content: nil), endpoint: base, expectedID: 3) }, "missing indexed content is not synthesized")
        check(rejects { _ = try CooklangFederationPolicy.decodeRecipe(detail(content: String(repeating: "x", count: 48 * 1024 + 1)), endpoint: base, expectedID: 3) }, "import text bound enforced")
        let cancelled = await Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await CooklangFederationClient.search(endpoint: base, query: "fixture", page: 1); return false }
            catch { return Task.isCancelled }
        }.value
        check(cancelled, "cancellation prevents a completed query")
        if CommandLine.arguments.contains("--live") {
            let live = try await CooklangFederationClient.search(endpoint: base, query: "soup", page: 1)
            guard let first = live.cards.first else { throw CooklangFederationPolicy.Failure.response }
            let recipe = try await CooklangFederationClient.recipe(endpoint: base, id: first.id)
            check(!recipe.content.isEmpty, "official public endpoint serves matching Cooklang source")
            print("Live read-only protocol probe: \(live.cards.count) summaries; one matching Cooklang body. No records saved.")
        }
        print("Cooklang Federation: \(checks) native checks passed")
    }
}
