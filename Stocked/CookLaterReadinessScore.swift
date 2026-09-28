// CookLaterReadinessScore.swift
// Pure scoring for the Cook Later command center's "week readiness" ring, pulled out of
// CookLaterCommandCenterView so it can be unit-tested without building the view.

import Foundation

nonisolated enum CookLaterReadinessScore {
  /// 0–100 readiness for the upcoming week. Starts from the share of upcoming meals that are
  /// fully stocked plus a 0.45 baseline, then subtracts capped penalties for outstanding
  /// shopping needs (3.5% each, max 35%) and unfinished prep actions (2% each, max 20%).
  /// Returns 0 when there are no upcoming meals.
  static func percent(
    upcomingMealCount: Int,
    stockedMealCount: Int,
    shoppingNeedCount: Int,
    outstandingPrepCount: Int
  ) -> Int {
    guard upcomingMealCount > 0 else { return 0 }
    let stockedWeight = Double(stockedMealCount) / Double(upcomingMealCount)
    let shoppingPenalty = min(0.35, Double(shoppingNeedCount) * 0.035)
    let prepPenalty = min(0.2, Double(outstandingPrepCount) * 0.02)
    return Int(max(0, min(1, stockedWeight + 0.45 - shoppingPenalty - prepPenalty)) * 100)
  }
}
