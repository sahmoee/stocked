import Foundation

/// Stable best-first selection. Each candidate is scored once and retained storage
/// grows only with the visible result budget, not with the searchable library.
nonisolated enum BoundedSearchRanking {
    static func select<Element>(
        from elements: [Element],
        limit: Int,
        rank: (Element) -> (relevance: Double, quality: Double)?
    ) -> [Element] {
        guard limit > 0 else { return [] }
        var best: [(element: Element, relevance: Double, quality: Double)] = []
        best.reserveCapacity(min(limit, elements.count))
        for element in elements {
            guard !Task.isCancelled else { return [] }
            guard let score = rank(element) else { continue }
            let candidate = (element: element, relevance: score.relevance, quality: score.quality)
            func precedes(_ other: (element: Element, relevance: Double, quality: Double)) -> Bool {
                if candidate.relevance != other.relevance { return candidate.relevance > other.relevance }
                return candidate.quality > other.quality
            }
            if best.count == limit, let last = best.last, !precedes(last) { continue }
            // Upper-bound insertion preserves original order for equal scores.
            var lower = 0
            var upper = best.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if precedes(best[middle]) { upper = middle } else { lower = middle + 1 }
            }
            best.insert(candidate, at: lower)
            if best.count > limit { best.removeLast() }
        }
        return best.map(\.element)
    }
}
