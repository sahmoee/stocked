import Foundation

// Native harness for the production browser/query/paging/SQLite code. No simulator.
// Minimal wire-shaped entry only; app-schema adapters are covered in StockedTests.
struct RecipeDatabaseEntry: Codable, Sendable {
    var id = UUID()
    var title: String
    var sourceURL: String
    var searchIndex: String { title }
}

@main struct RecipeWebCoreChecks {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { fatalError("Failed: \(label)") }
        }
        check(RecipeBrowserPolicy.url(" https://example.com/recipe#steps ")?.fragment == "steps", "anchors preserved")
        check(RecipeBrowserPolicy.url("example.com/recipe")?.scheme == "https", "bare public host")
        check(RecipeBrowserPolicy.url("http://example.com:80/a")?.absoluteString == "https://example.com/a", "upgrade HTTP")
        for url in ["", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "https://user:pass@example.com", "http://127.0.0.1", "https://localhost", "https://host.local", "https://10.0.0.1", "https://[::1]", "https://example.com:22", "bad url"] {
            check(RecipeBrowserPolicy.url(url) == nil, "reject \(url)")
        }
        var page = RecipeBrowserPageState()
        check(page.importURL == nil, "empty cannot import")
        page.started(); check(page.importURL == nil, "loading cannot import")
        page.finished(URL(string: "https://example.com/one")); check(page.importURL?.path == "/one", "final displayed URL")
        page.started(); check(page.importURL == nil, "navigation clears stale import URL")
        page.failed("Network"); check(page.importURL == nil, "error cannot import stale page")
        check(RecipeBrowserPolicy.url("//example.com/rice")?.absoluteString == "https://example.com/rice", "scheme-relative paste")
        for value in ["https://example.com./a", "https://host.internal/a", "https://bad..example/a", "https://-bad.example/a", "https://example.com\\@evil.example", "https://example.com/\u{0001}", "https://0x7f.1/recipe", "https://0x7f.0x0.0x0.0x1/recipe", "https://example.com%00/recipe"] {
            check(RecipeBrowserPolicy.url(value) == nil, "reject ambiguous address")
        }
        check(RecipeBrowserPolicy.url("https://example.com/" + String(repeating: "a", count: 8192)) == nil, "address length bounded")
        let clean = RecipeBrowserPolicy.importURL("https://example.com/recipe?ref=42&source=abc&id=7&utm_source=x&fbclid=y#recipe")
        check(clean?.absoluteString == "https://example.com/recipe?ref=42&source=abc&id=7", "functional query preserved, trackers removed")
        check(RecipeBrowserPolicy.hostLabel(URL(string: "https://www.example.com/a")) == "example.com", "publisher hostname display")
        check(RecipeBrowserPolicy.sameDocument(URL(string: "https://example.com/a#one"), URL(string: "https://example.com/a#two")), "same document anchors")
        check(!RecipeBrowserPolicy.sameDocument(URL(string: "https://example.com/a?id=1"), URL(string: "https://example.com/a?id=2")), "different query is not same recipe")
        check(!RecipeBrowserPolicy.sameDocument(nil, nil), "absent documents do not match")
        for status in [401, 403, 404, 410, 429, 500] {
            check(RecipePageResponsePolicy.failure(status: status, mimeType: "text/html") != nil, "HTTP error not importable")
        }
        for mime in ["application/pdf", "image/jpeg", "application/zip", "text/plain"] {
            check(RecipePageResponsePolicy.failure(status: 200, mimeType: mime) != nil, "non HTML rejected")
        }
        check(RecipePageResponsePolicy.failure(status: 200, mimeType: "text/html", expectedBytes: 3_000_000) == nil, "HTML at byte boundary")
        check(RecipePageResponsePolicy.failure(status: 200, mimeType: "application/xhtml+xml", expectedBytes: -1) == nil, "chunked XHTML accepted")
        check(RecipePageResponsePolicy.failure(status: 200, mimeType: "text/html", expectedBytes: 3_000_001) != nil, "oversize rejected")
        check(RecipePageResponsePolicy.message(for: URLError(.timedOut)).contains("too long"), "actionable timeout")
        check(RecipePageResponsePolicy.message(for: URLError(.notConnectedToInternet)).contains("offline"), "actionable offline")
        check(RecipePageResponsePolicy.message(for: URLError(.serverCertificateUntrusted)).contains("won’t bypass"), "TLS error is not bypassed")
        let redirectSession = URLSession(configuration: .ephemeral)
        let redirectTask = redirectSession.dataTask(with: URL(string: "https://example.com")!)
        let redirectResponse = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for target in ["http://127.0.0.1/recipe", "file:///recipe", "https://user:pass@example.com/recipe"] {
            let result: URLRequest? = await withCheckedContinuation { continuation in
                RecipePageRedirectGuard().urlSession(redirectSession, task: redirectTask, willPerformHTTPRedirection: redirectResponse,
                    newRequest: URLRequest(url: URL(string: target)!)) { continuation.resume(returning: $0) }
            }
            check(result == nil, "unsafe redirect rejected before following")
        }
        let upgraded: URLRequest? = await withCheckedContinuation { continuation in
            RecipePageRedirectGuard().urlSession(redirectSession, task: redirectTask, willPerformHTTPRedirection: redirectResponse,
                newRequest: URLRequest(url: URL(string: "http://example.com/recipe")!)) { continuation.resume(returning: $0) }
        }
        check(upgraded?.url?.absoluteString == "https://example.com/recipe", "redirect upgrades transport")
        redirectTask.cancel(); redirectSession.invalidateAndCancel()
        var importing = RecipeBrowserImportState()
        let first = importing.begin(); check(importing.accepts(first), "current import accepts updates")
        importing.cancel(); check(!importing.isRunning && !importing.accepts(first), "cancel immediately invalidates updates")
        let second = importing.begin(); importing.finish(first)
        check(importing.accepts(second), "late old completion cannot finish new request")
        importing.finish(second); check(!importing.isRunning && !importing.accepts(second), "finished import no longer accepts updates")
        check(RecipePageMarkup.text("<b>Rice &amp; beans</b> &#189; cup &#xBC; tsp") == "Rice & beans  ½ cup ¼ tsp", "HTML and numeric entities decoded without renderer")
        check(RecipePageMarkup.text("&unknown; &#0;") == "&unknown; &#0;", "unknown and control entities preserved")
        check(RecipePageMarkup.imageURL("../rice.jpg", pageURL: "https://example.com/recipes/rice") == "https://example.com/rice.jpg", "relative publisher image")
        check(RecipePageMarkup.imageURL("//images.example.com/rice.jpg", pageURL: "https://example.com/rice") == "https://images.example.com/rice.jpg", "scheme-relative publisher image")
        check(RecipePageMarkup.imageURL("data:image/png,abc", pageURL: "https://example.com/rice").isEmpty, "inline image not remote publisher image")
        for value in ["4", "4 servings", "Serves 4", "4 people"] { check(RecipePageMarkup.servings(value) == 4, "explicit serving count") }
        for value in ["", "0", "60", "4-6 servings", "24 cookies", "2 loaves", "4.5 servings"] { check(RecipePageMarkup.servings(value) == nil, "ambiguous yield requires review") }
        var filters = FinderFilters(); filters[.ingredient] = [.chicken, .seafood]; filters[.cuisine] = [.jamaican]
        check(FinderWebPolicy.terms(filters) == ["Jamaican Chicken", "Jamaican Seafood"], "OR seeds deterministic")
        var pantry = FinderFilters(); pantry[.kitchen] = [.mostlyHave]
        check(FinderWebPolicy.terms(pantry, inventoryNames: ["rice", "beans"]) == ["rice", "beans"], "opt-in pantry retrieval seeds")
        pantry[.kitchen] = [.noPreference]
        check(FinderWebPolicy.terms(pantry, inventoryNames: ["rice"]) == ["recipes"], "no pantry disclosure without kitchen preference")
        filters.query = "  JeRK Chicken  "
        check(FinderWebPolicy.terms(filters) == ["jerk chicken"], "normalized search")
        check(FinderWebPolicy.identity("https://www.example.com/a/?utm_source=test#steps") == FinderWebPolicy.identity("https://example.com/a"), "source dedup")
        var record = FinderRecord(id: "a", title: "A", searchText: "a")
        check(FinderWebPolicy.cardTag(record, filters: filters) == nil, "no fabricated tag")
        record.totalMinutes = 30; check(FinderWebPolicy.cardTag(record, filters: filters) == "Under 30 Min", "time tag")
        record.totalMinutes = 31; check(FinderWebPolicy.cardTag(record, filters: filters) == nil, "boundary tag")
        record.facets[.mood] = [.onePot]; check(FinderWebPolicy.cardTag(record, filters: filters) == "One Pot", "explicit style")
        check(try RecipeCataloguePaging.next(current: "a", complete: true, next: nil) == nil, "explicit completion")
        check(try RecipeCataloguePaging.next(current: "a", complete: false, next: "b") == "b", "advance cursor")
        for pair: (Bool?, String?) in [(nil, nil), (false, ""), (false, "a")] {
            do { _ = try RecipeCataloguePaging.next(current: "a", complete: pair.0, next: pair.1); fatalError("Accepted broken cursor") }
            catch { checks += 1 }
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let links = FinderPublisherLinks.candidates(html: #"<nav><a href="/navigation">Menu</a></nav><main><a href="/feed/">RSS</a><a href="/category/dinner">Dinner</a><a href="https://other.example/recipe">Other</a><a href="/soup">Soup</a><a href="/chicken-rice">Chicken</a></main>"#, baseURL: URL(string: "https://example.com/search")!, domain: "example.com", query: "chicken")
        check(links == ["https://example.com/chicken-rice", "https://example.com/soup"], "recipe anchors outrank navigation/feed links")
        if CommandLine.arguments.contains("--live") {
            let url = URL(string: "https://www.budgetbytes.com/?s=chicken")!
            var request = URLRequest(url: url); request.timeoutInterval = 12
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            check((response as? HTTPURLResponse)?.statusCode == 200, "live publisher search")
            let links = FinderPublisherLinks.candidates(html: String(decoding: data, as: UTF8.self), baseURL: url, domain: "budgetbytes.com", query: "chicken")
            guard let link = links.first, let recipeURL = URL(string: link) else { fatalError("No publisher recipe links") }
            request.url = recipeURL
            let (recipeData, recipeResponse) = try await URLSession.shared.data(for: request)
            let html = String(decoding: recipeData, as: UTF8.self)
            check((recipeResponse as? HTTPURLResponse)?.statusCode == 200 && html.contains("recipeIngredient") && html.contains("recipeInstructions"), "live real recipe metadata")
            print("Live publisher recipe: \(link)")
        }
        let db = GrowthDatabase(directory: directory)
        for start in stride(from: 0, to: 8105, by: 100) {
            let rows = (start..<min(start + 100, 8105)).map { RecipeDatabaseEntry(title: "Recipe \($0)", sourceURL: "https://example.com/recipe/\($0)") }
            try await db.storeRecipePage(rows)
        }
        check(await db.recipePageCount() == 8105, "archive exceeds 8000 index")
        try await db.storeRecipePage([RecipeDatabaseEntry(title: "Updated final recipe", sourceURL: "https://www.example.com/recipe/8104/?utm_source=test")])
        check(await db.recipePageCount() == 8105, "reimport idempotent by canonical URL")
        var cursor: Int64 = 0, total = 0
        repeat {
            let result = try await db.recipePage(after: cursor)
            check(result.entries.count <= 256, "bounded SQLite page")
            total += result.entries.count; cursor = result.cursor
            if result.done { break }
        } while true
        check(total == 8105, "all archive pages searchable")
        let match = await db.searchRecipePages(" UPDATED final ", limit: 8)
        check(match.count == 1 && match.first?.title == "Updated final recipe", "last archived row direct search")
        let reopened = GrowthDatabase(directory: directory)
        check(await reopened.recipePageCount() == 8105, "persistent after reopening")
        let request = FinderRequestState()
        check(request.phase == .idle, "initial request state")
        print("PASS: \(checks) web/browser/pagination/SQLite checks")
    }
}
