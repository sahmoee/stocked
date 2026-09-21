import Foundation

/// A nutrition observation plus the reliability context needed to compare it.
/// Provider names are retained for audit UI; credentials never enter this model.
nonisolated struct NutritionCandidate: Sendable {
    enum Match: Double, Sendable { case estimate = 0.45, name = 0.72, brandedName = 0.84, barcode = 0.98 }
    let facts: NutritionFacts
    let source: String
    let authority: Double
    let match: Match

    var confidence: Double {
        let completeness = [facts.calories > 0, facts.protein > 0, facts.totalCarbs > 0, facts.totalFat > 0]
            .filter { $0 }.count
        return min(1, authority * match.rawValue + Double(completeness) * 0.025)
    }
}

nonisolated struct ReconciledNutrition: Sendable {
    let facts: NutritionFacts
    let source: String
    let confidence: Double
    let agreeingSources: [String]
}

nonisolated enum NutritionReconciler {
    /// Chooses a defensible basis before considering agreement. Values on unlike serving
    /// bases are never averaged. Agreement raises confidence; a >35% calorie conflict
    /// keeps the strongest source and is exposed through `agreeingSources`.
    static func reconcile(_ candidates: [NutritionCandidate]) -> ReconciledNutrition? {
        let usable = candidates.filter { $0.facts.calories > 0 }
        guard var best = usable.max(by: { $0.confidence < $1.confidence }) else { return nil }
        let sameBasis = usable.filter { basis($0.facts.servingSize) == basis(best.facts.servingSize) }
        let agreeing = sameBasis.filter {
            let delta = abs(Double($0.facts.calories - best.facts.calories))
            return delta / Double(max(1, best.facts.calories)) <= 0.20
        }
        if let consensus = agreeing.max(by: { $0.confidence < $1.confidence }),
           consensus.confidence > best.confidence { best = consensus }
        let boost = min(0.08, Double(max(0, agreeing.count - 1)) * 0.04)
        return ReconciledNutrition(facts: best.facts, source: best.source,
                                   confidence: min(1, best.confidence + boost),
                                   agreeingSources: agreeing.map(\.source).uniqued())
    }

    private static func basis(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: " ", with: "")
    }
}

private extension Array where Element == String {
    nonisolated func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
