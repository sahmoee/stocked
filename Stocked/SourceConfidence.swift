// SourceConfidence.swift
//
// A small, shared vocabulary for "how much do we trust this piece of data?" Recipes, products,
// nutrition facts, and OCR line items all come from sources of varying reliability — a verified
// USDA nutrition record is not the same as an AI-parsed receipt line. This file gives the app one
// way to tag that, so the UI can show a badge and the logic can prefer better data.
//
// This is a data/model layer. It does not change behavior on its own; screens opt in by reading
// `SourceBadge` and showing `SourceBadgeView`. Added as part of the source-quality batch.

import SwiftUI

/// Where a piece of data came from and how much it should be trusted, in plain user-facing terms.
nonisolated enum SourceBadge: String, Codable, CaseIterable, Sendable {
    /// Confirmed against an authoritative source (e.g. USDA nutrition, a barcode-matched product).
    case verified   = "Verified"
    /// A reasonable approximation (e.g. nutrition estimated from a similar item).
    case estimated  = "Estimated"
    /// Entered by the user by hand.
    case userAdded  = "User added"
    /// Extracted by AI/OCR (e.g. a parsed receipt or imported recipe) and not yet confirmed.
    case aiParsed   = "AI parsed"
    /// Low confidence — should be reviewed/corrected by the user.
    case needsReview = "Needs review"

    /// SF Symbol that pairs with each badge.
    var symbol: String {
        switch self {
        case .verified:    return "checkmark.seal.fill"
        case .estimated:   return "circle.dashed"
        case .userAdded:   return "person.fill"
        case .aiParsed:    return "sparkles"
        case .needsReview: return "exclamationmark.triangle.fill"
        }
    }

    /// Rough trust ranking, 1.0 = highest. Used when reconciling two values for the same thing:
    /// prefer the one with the higher confidence.
    var confidence: Double {
        switch self {
        case .verified:    return 1.0
        case .userAdded:   return 0.9   // the user is authoritative about their own kitchen
        case .estimated:   return 0.6
        case .aiParsed:    return 0.4
        case .needsReview: return 0.2
        }
    }

    /// Tint for the badge. Resolves brighter on dark for contrast (mirrors the app's gold rule).
    func color(dark: Bool) -> Color {
        switch self {
        case .verified:    return dark ? Color(red: 0.40, green: 0.78, blue: 0.50) : Color(red: 0.20, green: 0.55, blue: 0.30)
        case .userAdded:   return dark ? Color.stockedGoldDark : Color.stockedGold
        case .estimated:   return dark ? Color(red: 0.70, green: 0.70, blue: 0.74) : Color(red: 0.42, green: 0.42, blue: 0.46)
        case .aiParsed:    return dark ? Color(red: 0.62, green: 0.66, blue: 0.86) : Color(red: 0.34, green: 0.40, blue: 0.74)
        case .needsReview: return dark ? Color(red: 0.90, green: 0.62, blue: 0.40) : Color(red: 0.78, green: 0.45, blue: 0.20)
        }
    }

    /// Map a 0–100 numeric confidence (as the receipt scanner and OCR paths produce) into a
    /// badge, so every surface labels certainty the same way instead of each inventing its own
    /// threshold. Tune points: 90+ reads as verified-quality, 60–89 as AI-parsed-but-usable,
    /// below 60 as needs-review. Callers that KNOW the origin (user typed it, USDA record)
    /// should set the badge directly rather than route through this.
    static func from(confidence: Int) -> SourceBadge {
        switch confidence {
        case 90...:  return .verified
        case 60..<90: return .aiParsed
        default:      return .needsReview
        }
    }

    /// Which review group a badge falls into for the shared grouped-review UI
    /// ("Confident" / "Needs review" / "Ignored"). Ignored is set explicitly by callers for
    /// items filtered out (e.g. non-food receipt lines), not derived from confidence.
    var reviewGroup: ReviewGroup {
        switch self {
        case .verified, .userAdded, .estimated: return .confident
        case .aiParsed, .needsReview:            return .needsReview
        }
    }
}

/// Sections for any confirm-before-apply review screen (receipt scan, AI inventory edits,
/// recipe import, grocery reconciliation). Giving every AI-touches-data flow the same three
/// buckets is what makes them feel like one system. Ordered for display.
nonisolated enum ReviewGroup: Int, CaseIterable, Comparable, Sendable {
    case confident = 0     // high-confidence, pre-checked, safe to apply
    case needsReview = 1   // low-confidence, surfaced for a second look
    case ignored = 2       // filtered out (non-food, duplicates); shown so nothing feels lost

    static func < (l: ReviewGroup, r: ReviewGroup) -> Bool { l.rawValue < r.rawValue }

    var title: String {
        switch self {
        case .confident:   return "Confident"
        case .needsReview: return "Needs review"
        case .ignored:     return "Ignored"
        }
    }
    var subtitle: String {
        switch self {
        case .confident:   return "Looks right — will be added"
        case .needsReview: return "Double-check these before saving"
        case .ignored:     return "Skipped (not food or already listed)"
        }
    }
    var symbol: String {
        switch self {
        case .confident:   return "checkmark.circle.fill"
        case .needsReview: return "exclamationmark.triangle.fill"
        case .ignored:     return "minus.circle"
        }
    }
}

/// A value paired with its provenance. Use for data the app may want to reconcile or badge later,
/// e.g. a nutrition number that might come from USDA (verified) or an estimate.
nonisolated struct Sourced<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var value: Value
    var badge: SourceBadge

    init(_ value: Value, _ badge: SourceBadge) {
        self.value = value
        self.badge = badge
    }

    /// Reconcile two values for the same concept: keep the higher-confidence one. Ties keep `self`.
    func reconciled(with other: Sourced<Value>) -> Sourced<Value> {
        other.badge.confidence > badge.confidence ? other : self
    }
}

// MARK: - Field-level provenance and reconciliation

/// A durable description of one observation used to populate a product or inventory field.
/// `SourceBadge` remains the user-facing trust vocabulary; this adds the source identity and
/// timestamp needed to explain *why* one value won when several providers disagree.
nonisolated struct FieldProvenance: Codable, Equatable, Hashable, Sendable {
    var sourceID: String
    var sourceName: String
    var badge: SourceBadge
    var observedAt: Date

    init(sourceID: String, sourceName: String? = nil, badge: SourceBadge,
         observedAt: Date = Date()) {
        self.sourceID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.sourceName = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? sourceID
        self.badge = badge
        self.observedAt = observedAt
    }
}

/// One candidate value and the evidence supporting it. This is intentionally generic so product
/// name, brand, aisle, storage zone, barcode, nutrition, and future fields all use one policy.
nonisolated struct FieldEvidence<Value: Equatable & Sendable>: Equatable, Sendable {
    var value: Value
    var provenance: FieldProvenance

    init(_ value: Value, provenance: FieldProvenance) {
        self.value = value
        self.provenance = provenance
    }
}

/// Result of reconciling several observations of the same field. Alternatives are retained for
/// review instead of being discarded, which lets receipt/barcode/manual screens explain conflicts.
nonisolated struct ReconciledField<Value: Equatable & Sendable>: Equatable, Sendable {
    var value: Value
    var provenance: FieldProvenance
    var confidence: Double
    var alternatives: [FieldEvidence<Value>]
    var isContested: Bool
    var needsReview: Bool
}

nonisolated private struct RankedFieldEvidence<Value: Equatable & Sendable>: Sendable {
    var evidence: FieldEvidence<Value>
    var score: Double
    var agreementCount: Int
}

/// Shared multi-source field policy. Trust combines the semantic badge, observed provider health,
/// freshness, and independent agreement. User-confirmed and verified observations remain strong
/// even when a provider has little history; a recently unhealthy source cannot silently replace
/// healthier consensus.
nonisolated enum ProductFieldReconciler {
    static func reconcile<Value: Equatable & Sendable>(
        _ evidence: [FieldEvidence<Value>],
        sourceHealth: [String: SourceHealthSnapshot] = [:],
        now: Date = Date(),
        equivalent: (Value, Value) -> Bool = (==)
    ) -> ReconciledField<Value>? {
        guard !evidence.isEmpty else { return nil }

        let normalizedHealth = sourceHealth.reduce(into: [String: SourceHealthSnapshot]()) {
            result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return }
            if let existing = result[key], existing.reliability(at: now) >= pair.value.reliability(at: now) {
                return
            }
            result[key] = pair.value
        }

        let ranked: [RankedFieldEvidence<Value>] = evidence.map { candidate in
            let sourceKey = candidate.provenance.sourceID.lowercased()
            let health = normalizedHealth[sourceKey]?.reliability(at: now) ?? 0.7
            let age = max(0, now.timeIntervalSince(candidate.provenance.observedAt))
            let freshness: Double
            switch age {
            case ..<86_400: freshness = 1
            case ..<(7 * 86_400): freshness = 0.85
            case ..<(30 * 86_400): freshness = 0.65
            default: freshness = 0.4
            }
            let agreements = evidence.filter { equivalent($0.value, candidate.value) }.count
            let consensus = min(0.12, Double(max(0, agreements - 1)) * 0.04)
            var score = candidate.provenance.badge.confidence * 0.55
                + health * 0.30
                + freshness * 0.15
                + consensus
            if candidate.provenance.badge == .userAdded { score = max(score, 0.90) }
            if candidate.provenance.badge == .verified { score = max(score, 0.92) }
            return RankedFieldEvidence(evidence: candidate, score: min(1, score),
                                       agreementCount: agreements)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.agreementCount != $1.agreementCount { return $0.agreementCount > $1.agreementCount }
            if $0.evidence.provenance.observedAt != $1.evidence.provenance.observedAt {
                return $0.evidence.provenance.observedAt > $1.evidence.provenance.observedAt
            }
            return $0.evidence.provenance.sourceID < $1.evidence.provenance.sourceID
        }

        guard let winner = ranked.first else { return nil }
        let alternatives = ranked.dropFirst().map(\.evidence)
        let nearestConflict = ranked.dropFirst().first {
            !equivalent($0.evidence.value, winner.evidence.value)
        }
        let contested = nearestConflict.map { winner.score - $0.score < 0.08 } ?? false
        return ReconciledField(
            value: winner.evidence.value,
            provenance: winner.evidence.provenance,
            confidence: winner.score,
            alternatives: alternatives,
            isContested: contested,
            needsReview: winner.score < 0.70 || contested
        )
    }

    /// String convenience uses the same grocery normalization as identity and receipt matching.
    static func reconcileText(
        _ evidence: [FieldEvidence<String>],
        sourceHealth: [String: SourceHealthSnapshot] = [:],
        now: Date = Date()
    ) -> ReconciledField<String>? {
        reconcile(evidence, sourceHealth: sourceHealth, now: now) {
            GroceryKnowledgeBase.normalize($0) == GroceryKnowledgeBase.normalize($1)
        }
    }
}

/// A small pill that renders a SourceBadge. Opt-in; screens add it where provenance matters.
struct SourceBadgeView: View {
    let badge: SourceBadge
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: 3) {
            Image(systemName: badge.symbol).scaledFont(9, weight: .semibold)
            Text(badge.rawValue).scaledFont(10, weight: .semibold)
        }
        .foregroundStyle(badge.color(dark: dark))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(badge.color(dark: dark).opacity(dark ? 0.16 : 0.12)))
    }
}
