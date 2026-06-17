// CookingTipsDatabase.swift
// Shim — all logic lives in StockedDatabase.swift.
// This file replaces the old standalone database. Keep it in your Xcode project.
import Foundation

@MainActor
final class CookingTipsDatabase {
    static let shared = CookingTipsDatabase()
    private init() {}

    var tips: [CookingTip] { StockedDatabase.shared.cookingTips }
    func tips(for cat: CookingTip.TipCategory) -> [CookingTip] {
        StockedDatabase.shared.tips(for: cat)
    }
    var allCategories: [CookingTip.TipCategory] { StockedDatabase.shared.allTipCategories }
    func randomTips(_ count: Int = 3) -> [CookingTip] {
        StockedDatabase.shared.randomTips(count)
    }
}
