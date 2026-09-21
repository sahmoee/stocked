import Foundation

@main
struct BoundedSearchRankingChecks {
    struct Candidate: Equatable {
        let id: Int
        var relevance: Double { Double(id % 17) }
        var quality: Double { Double(id % 11) }
    }

    static func main() async {
        let source = (0..<100_000).map(Candidate.init)
        var evaluations = 0
        let start = ContinuousClock.now
        let actual = BoundedSearchRanking.select(from: source, limit: 12) { item in
            evaluations += 1
            return item.id.isMultiple(of: 3) ? nil : (item.relevance, item.quality)
        }
        let elapsed = start.duration(to: .now)
        let expected = source.filter { !$0.id.isMultiple(of: 3) }.sorted {
            if $0.relevance != $1.relevance { return $0.relevance > $1.relevance }
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            return $0.id < $1.id
        }.prefix(12)
        precondition(actual == Array(expected), "Ranking/filtering/stable ties changed")
        precondition(evaluations == source.count, "A candidate was rescored")
        let zero = BoundedSearchRanking.select(from: source, limit: 0) { _ in
            preconditionFailure("Zero budget should do no work")
        }
        precondition(zero.isEmpty)
        let empty = BoundedSearchRanking.select(from: [Int](), limit: 8) { _ in (0, 0) }
        precondition(empty.isEmpty)
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return BoundedSearchRanking.select(from: source, limit: 12) { _ in
                preconditionFailure("Cancelled search should stop before scoring")
            }
        }
        let cancelledResult = await cancelled.value
        precondition(cancelledResult.isEmpty)
        print("PASS: ranking, filtered candidates, stable ties, zero/empty budgets, cancellation; 100,000 candidates scored once in \(elapsed)")
    }
}
