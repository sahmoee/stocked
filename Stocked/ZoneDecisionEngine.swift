// ZoneDecisionEngine.swift
// Reconciles learned placement, deterministic classification, product metadata, and AI proposals.
import Foundation

nonisolated struct ZoneSignal: Sendable, Equatable {
    nonisolated enum Source: String, Sendable { case learned, classifier, productMetadata, ai }
    let source: Source
    let zone: StorageCategory
    let confidence: Double
    let reason: String
}

nonisolated struct ZoneDecision: Sendable, Equatable {
    let zone: StorageCategory
    let confidence: Double
    let signals: [ZoneSignal]
    let needsConfirmation: Bool
    var reason: String { signals.map(\.reason).joined(separator: " · ") }
}

nonisolated enum ZoneDecisionEngine {
    static func decide(name: String,
                       current: StorageCategory? = nil,
                       learnedZone: StorageCategory? = nil,
                       learnedCount: Int = 0,
                       productCategories: [String] = [],
                       aiZone: StorageCategory? = nil,
                       aiConfidence: Double = 0.65) -> ZoneDecision {
        var signals: [ZoneSignal] = []
        let local = ZoneClassifier.classify(name)
        signals.append(ZoneSignal(source: .classifier, zone: local, confidence: 0.76,
                                  reason: "On-device food classification"))

        if let learnedZone {
            let confidence = min(0.98, 0.78 + Double(min(learnedCount, 10)) * 0.02)
            signals.append(ZoneSignal(source: .learned, zone: learnedZone, confidence: confidence,
                                      reason: "Your previous placement"))
        }

        if let metadata = zoneFromProductCategories(productCategories) {
            signals.append(ZoneSignal(source: .productMetadata, zone: metadata, confidence: 0.82,
                                      reason: "Product category metadata"))
        }

        if let aiZone {
            signals.append(ZoneSignal(source: .ai, zone: aiZone,
                                      confidence: max(0.3, min(0.95, aiConfidence)),
                                      reason: "AI scan suggestion"))
        }

        var weights: [StorageCategory: Double] = [:]
        for signal in signals { weights[signal.zone, default: 0] += signal.confidence }
        let ranked = weights.sorted { $0.value > $1.value }
        let winner = ranked.first?.key ?? current ?? .pantry
        let top = ranked.first?.value ?? 0
        let second = ranked.dropFirst().first?.value ?? 0
        let agreementCount = signals.filter { $0.zone == winner }.count
        let conflict = Set(signals.map(\.zone)).count > 1
        let coldConflict = (winner == .fridge || winner == .freezer) &&
            signals.contains { ($0.zone == .pantry || $0.zone == .staples) && $0.confidence >= 0.75 }
        let confidence = min(0.99, top / max(1, signals.reduce(0) { $0 + $1.confidence }))
        let needsConfirmation = coldConflict || (conflict && agreementCount < 2 && top - second < 0.45)

        return ZoneDecision(zone: needsConfirmation ? (current ?? local) : winner,
                            confidence: confidence,
                            signals: signals,
                            needsConfirmation: needsConfirmation)
    }

    private static func zoneFromProductCategories(_ categories: [String]) -> StorageCategory? {
        let text = categories.joined(separator: " ")
        if FoodNameMatcher.anyPhrase(in: text, phrases: ["frozen foods", "ice cream", "frozen dessert"]) { return .freezer }
        if FoodNameMatcher.anyPhrase(in: text, phrases: ["dairy", "fresh meat", "fresh fish", "refrigerated", "yogurt", "cheese"]) { return .fridge }
        if FoodNameMatcher.anyPhrase(in: text, phrases: ["spices", "seasonings", "condiments", "cooking oils", "baking supplies"]) { return .staples }
        if FoodNameMatcher.anyPhrase(in: text, phrases: ["snacks", "chips", "cereals", "canned foods", "dry foods", "beverages"]) { return .pantry }
        return nil
    }
}
