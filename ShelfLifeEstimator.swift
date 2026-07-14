// ShelfLifeEstimator.swift
// Item-aware expiry estimation shared by manual add, receipts, barcode scans, and AI review.
import Foundation

nonisolated struct ShelfLifeEvidence: Sendable, Equatable {
    let days: Int
    let confidence: Double
    let source: String
}

nonisolated enum ShelfLifeEstimator {
    private static let exactDays: [(phrases: [String], days: Int)] = [
        (["raw chicken", "chicken breast", "chicken thigh", "ground chicken"], 2),
        (["raw beef", "ground beef", "steak"], 3),
        (["raw pork", "pork chop"], 3),
        (["fresh fish", "salmon", "tilapia", "cod", "shrimp", "seafood"], 2),
        (["milk", "heavy cream", "half and half"], 7),
        (["yogurt", "yoghurt"], 14),
        (["soft cheese", "cream cheese", "cottage cheese"], 14),
        (["cheese"], 28),
        (["egg"], 28),
        (["lettuce", "spinach", "kale", "fresh herb"], 5),
        (["berry", "strawberry", "blueberry", "raspberry", "blackberry"], 4),
        (["bread", "bagel", "pita"], 5),
        (["tortilla"], 10),
        (["leftover", "cooked meal", "meal prep"], 4)
    ]

    static func estimate(name: String,
                         zone: StorageCategory,
                         from date: Date = Date(),
                         opened: Bool = false,
                         learnedDays: Double? = nil,
                         crowdDays: Double? = nil,
                         aiDays: Int? = nil) -> (date: Date?, evidence: ShelfLifeEvidence?) {
        let candidates: [ShelfLifeEvidence] = [
            learnedDays.flatMap { $0 > 0 ? ShelfLifeEvidence(days: Int($0.rounded()), confidence: 0.96, source: "Your history") : nil },
            crowdDays.flatMap { $0 > 0 ? ShelfLifeEvidence(days: Int($0.rounded()), confidence: 0.82, source: "Community average") : nil },
            exactMatch(name: name).map { ShelfLifeEvidence(days: $0, confidence: 0.8, source: "Food shelf-life table") },
            aiDays.flatMap { (1...730).contains($0) ? ShelfLifeEvidence(days: $0, confidence: 0.55, source: "AI estimate") : nil },
            zoneFallback(zone).map { ShelfLifeEvidence(days: $0, confidence: 0.48, source: "Storage-zone estimate") }
        ].compactMap { $0 }

        guard var best = candidates.max(by: { $0.confidence < $1.confidence }) else { return (nil, nil) }
        if opened { best = ShelfLifeEvidence(days: max(1, Int(Double(best.days) * 0.65)), confidence: best.confidence, source: best.source + " (opened)") }
        return (Calendar.current.date(byAdding: .day, value: best.days, to: date), best)
    }

    private static func exactMatch(name: String) -> Int? {
        for row in exactDays where FoodNameMatcher.anyPhrase(in: name, phrases: row.phrases) { return row.days }
        return nil
    }

    private static func zoneFallback(_ zone: StorageCategory) -> Int? {
        switch zone {
        case .fridge: return 10
        case .freezer: return 120
        case .pantry, .staples: return nil
        }
    }
}
