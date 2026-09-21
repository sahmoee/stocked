import Foundation

@main
struct GlobalSearchRankingChecks {
    static func main() async {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        var ranking = GlobalSearchRanking<String>(limit: 12)
        for index in 0..<10_000 {
            ranking.consider(id: String(index), title: "Item \(index)", score: Double(index), value: String(index))
            expect(ranking.candidates.count <= 12, "A large household must never grow the retained result window")
        }
        expect(ranking.candidates.first?.value == "9999", "A later best match must replace earlier weak matches")
        expect(ranking.hasMore, "Truncation must be disclosed")
        expect(ranking.candidates.last?.score == 9988, "The window must keep the strongest matches")

        let fixtures = [("c", "Apple"), ("a", "Apple"), ("b", "Banana")]
        var forward = GlobalSearchRanking<String>(limit: 3)
        var reverse = GlobalSearchRanking<String>(limit: 3)
        for (id, title) in fixtures { forward.consider(id: id, title: title, score: 75, value: id) }
        for (id, title) in fixtures.reversed() { reverse.consider(id: id, title: title, score: 75, value: id) }
        expect(forward.candidates.map(\.id) == ["a", "c", "b"], "Equal scores need title then identity tie breaks")
        expect(forward.candidates.map(\.id) == reverse.candidates.map(\.id), "Source-array reordering must not shuffle matching cards")
        forward.consider(id: "b", title: "Banana", score: 100, value: "b")
        expect(forward.candidates.count == 3 && forward.candidates.first?.id == "b", "An upgraded duplicate must update its existing row")
        var none = GlobalSearchRanking<String>(limit: 0)
        none.consider(id: "x", title: "X", score: 100, value: "x")
        expect(none.candidates.isEmpty && none.hasMore, "A zero-sized window must remain empty")
        let normalized = await Task.detached(priority: .utility) {
            (DBNormalize.key("  JALAPEÑO\n"), DBNormalize.prefixBucket("  CRÈME", length: 3))
        }.value
        expect(normalized.0 == "jalapeno" && normalized.1 == "cre", "Background matching must use the canonical case/diacritic/whitespace normalization")
        print("Global Search ranking: \(checks) checks passed")
    }
}
