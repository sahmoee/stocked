import Foundation

// ─────────────────────────────────────────────────────────────────────
// Build 255 — Single source of truth for kitchen counts (#3).
//
// Before this, "expiring soon" was computed four different ways across
// screens (urgentItems.count, daysUntilExpiry <= 3, <= 5, <= 7), and
// "low stock" two ways (effectiveLevel < 0.33 vs item.isLow). That made
// Home, the Daily Brief, the Inventory hub, and the Kitchen Report
// disagree — the fastest way to erode trust in the numbers.
//
// KitchenMetrics centralizes every count and the thresholds behind them.
// AppSession exposes a single `metrics` value; all screens read from it.
// ─────────────────────────────────────────────────────────────────────

/// Canonical thresholds. Change a number here and every screen updates together.
/// `nonisolated` so these pure constants can be read from any context — including
/// default-argument expressions and background/actor code — under Swift's
/// main-actor-by-default mode.
nonisolated enum KitchenThresholds {
    /// Days-until-expiry at or under which an item counts as "expiring soon".
    /// Previously ALSO written as `86400 * 3` (Daily Brief notification),
    /// `86400 * 5` (Daily Brief list), and `d <= 3` (Inventory hub chips) —
    /// four windows for one concept. Everything reads this now.
    static let expiringSoonDays = 4

    /// Fill level under which a non-par item counts as "running low".
    /// Previously ALSO written as 0.2 (widget, Daily Brief x2) and 0.33
    /// (inventory details sheet) — so the same jar was "low" on one screen and
    /// fine on another. Everything reads this now.
    static let lowFillLevel = 0.25

    /// Fill level under which an item is near-empty rather than merely low.
    /// The widget and notification copy want a tighter bar than the grocery
    /// suggestions do; this is that bar, named instead of inlined as 0.2.
    static let criticalFillLevel = 0.1

    /// Fill level at or above which an item reads as "Full" in the fill-word
    /// labels, with the midpoint below it reading as "Half". Was inlined as
    /// 0.66 / 0.33 in three views.
    static let fullFillLevel = 0.66
    static let halfFillLevel = 0.33
}

/// A snapshot of the kitchen's headline numbers, computed once from the store.
/// Cheap to build (a handful of passes over inventory) and read identically everywhere.
struct KitchenMetrics: Equatable {
    var totalItems: Int = 0
    var stockPercent: Int = 0
    var mealsReady: Int = 0
    var expiringSoonCount: Int = 0
    var expiredCount: Int = 0
    var lowStockCount: Int = 0
    var freshCount: Int = 0
    var groceryToBuy: Int = 0
    var groceryRunDays: Int = 0
    /// Materialized alongside the other Home figures so SwiftUI does not rescan
    /// recipe and plan collections once per widget/body evaluation.
    var favoriteRecipeCount: Int = 0
    var plannedMealCount: Int = 0

    /// One short status phrase for the stock level, used by several cards.
    var stockStatusPhrase: String {
        switch stockPercent {
        case 80...: return "great shape"
        case 60..<80: return "good shape"
        default: return "restock soon"
        }
    }
    var stockStatusSentence: String {
        switch stockPercent {
        case 80...: return "Your kitchen is in great shape"
        case 60..<80: return "Your kitchen is in good shape"
        default: return "Time to restock soon"
        }
    }
}
