import Foundation

/// Bounded stable ranking shared by each Global Search domain. Rows discarded from the
/// window are never materialized by SwiftUI; the caller can disclose that more matches exist.
nonisolated struct GlobalSearchRanking<Value: Sendable>: Sendable {
    struct Candidate: Sendable {
        let id: String
        let title: String
        let score: Double
        let value: Value
    }

    let limit: Int
    private(set) var candidates: [Candidate] = []
    private(set) var hasMore = false

    mutating func consider(id: String, title: String, score: Double, value: Value) {
        guard limit > 0 else { hasMore = true; return }
        if let index = candidates.firstIndex(where: { $0.id == id }) {
            guard score > candidates[index].score else { return }
            candidates.remove(at: index)
        }
        let candidate = Candidate(id: id, title: title.lowercased(), score: score, value: value)
        let index = candidates.firstIndex {
            candidate.score > $0.score || (candidate.score == $0.score &&
                (candidate.title < $0.title || (candidate.title == $0.title && candidate.id < $0.id)))
        } ?? candidates.endIndex
        candidates.insert(candidate, at: index)
        if candidates.count > limit { candidates.removeLast(); hasMore = true }
    }
}
