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
    static let expiringSoonDays = 4
    /// Fill level under which a non-par item counts as "running low".
    static let lowFillLevel = 0.25
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
