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

/// A small pill that renders a SourceBadge. Opt-in; screens add it where provenance matters.
struct SourceBadgeView: View {
    let badge: SourceBadge
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: 3) {
            Image(systemName: badge.symbol).font(.system(size: 9, weight: .semibold))
            Text(badge.rawValue).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(badge.color(dark: dark))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(badge.color(dark: dark).opacity(dark ? 0.16 : 0.12)))
    }
}
