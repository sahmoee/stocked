// KitchenWrappedView.swift — "Your Kitchen, Wrapped" (#29)
//
// A delightful recap of the user's cooking story, built entirely from data already
// collected: pastMeals, cookStreak/longestStreak, consumptionLog (waste + value),
// priceHistory, userRecipes (cookCount), and inventory. No new persistence — pure
// read-over-existing-state. Presented from Kitchen Stats.
import SwiftUI

struct KitchenWrappedView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { scheme == .dark }
    private var bg: Color { dark ? Color.stockedBlack : Color.stockedBg }
    private var primaryText: Color { dark ? Color.stockedWhite : Color.stockedCharcoal }
    private var cardSurface: Color { dark ? Color.white.opacity(0.06) : Color.stockedCharcoal.opacity(0.9) }

    // MARK: Derived story numbers
    private var mealsCooked: Int { store.pastMeals.count }
    private var longestStreak: Int { session.longestStreak }

    /// Most-cooked recipe by cookCount, falling back to the most frequent past-meal title.
    private var topRecipe: (title: String, count: Int)? {
        if let r = store.userRecipes.filter({ $0.cookCount > 0 }).max(by: { $0.cookCount < $1.cookCount }) {
            return (r.title, r.cookCount)
        }
        let counts = Dictionary(grouping: store.pastMeals, by: { $0.title }).mapValues { $0.count }
        guard let best = counts.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value)
    }

    /// Highest-rated past meal (rating ties → most recent kept by first match).
    private var favoriteMeal: LocalPastMeal? {
        store.pastMeals.filter { $0.rating > 0 }.max(by: { $0.rating < $1.rating })
    }

    private var moneySaved: Int { mealsCooked * 10 }   // matches Stats' estimate

    /// Items used up (not wasted) — the win — and money lost to waste.
    private var itemsUsedUp: Int { store.consumptionLog.filter { !$0.wasted }.count }
    private var wastedValue: Double {
        store.consumptionLog.filter { $0.wasted }.compactMap { $0.estimatedValue }.reduce(0, +)
    }
    private var wasteFreeRate: Int {
        let total = store.consumptionLog.count
        guard total > 0 else { return 100 }
        return Int((Double(itemsUsedUp) / Double(total) * 100).rounded())
    }
    private var itemsTracked: Int { store.inventoryItems.count }
    private var totalSpend: Double { store.priceHistory.map(\.price).reduce(0, +) }

    private func money(_ v: Double) -> String { String(format: "$%.0f", v) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                header
                heroCard
                statsGrid
                if let top = topRecipe { topRecipeCard(top) }
                if let fav = favoriteMeal, fav.rating > 0 { favoriteCard(fav) }
                savingsCard
                closingCard
                Color.clear.frame(height: 30)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
        .background(bg.ignoresSafeArea())
    }

    // MARK: Header
    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(primaryText)
            }.buttonStyle(.plain)
            Spacer()
            StockedWordmark(size: 24)
            Spacer()
            Color.clear.frame(width: 24)
        }
        .padding(.top, 8)
    }

    // MARK: Hero
    private var heroCard: some View {
        VStack(spacing: 8) {
            Text("Your Kitchen,")
                .font(.system(size: 30, weight: .bold, design: .serif))
                .foregroundStyle(primaryText)
            Text("Wrapped")
                .font(.system(size: 40, weight: .heavy, design: .serif))
                .foregroundStyle(Color.stockedGold)
            Text(mealsCooked > 0
                 ? "Here's what your kitchen got up to."
                 : "Cook your first meal and your story starts here.")
                .font(.system(size: 14))
                .foregroundStyle(primaryText.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: Stats grid
    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            wrapStat("\(mealsCooked)", "meals cooked", "fork.knife", Color.stockedGold)
            wrapStat("\(longestStreak)", longestStreak == 1 ? "day streak" : "day best streak", "flame.fill", Color.stockedGreen)
            wrapStat("\(itemsTracked)", "items tracked", "refrigerator.fill", Color.stockedInfo)
            wrapStat("\(wasteFreeRate)%", "used, not wasted", "leaf.fill", Color.stockedGreen)
        }
    }

    private func wrapStat(_ value: String, _ label: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(tint)
            Text(value)
                .font(.system(size: 34, weight: .heavy, design: .serif))
                .foregroundStyle(primaryText)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(primaryText.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(dark ? 0.12 : 0.10))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }

    // MARK: Highlight cards
    private func topRecipeCard(_ top: (title: String, count: Int)) -> some View {
        highlightCard(
            eyebrow: "MOST COOKED",
            title: top.title,
            detail: "You made it \(top.count) time\(top.count == 1 ? "" : "s"). A certified house favorite.",
            icon: "trophy.fill", tint: Color.stockedGold)
    }

    private func favoriteCard(_ meal: LocalPastMeal) -> some View {
        highlightCard(
            eyebrow: "TOP RATED",
            title: meal.title,
            detail: "You gave it \(meal.rating)★" + (meal.notes.isEmpty ? "." : " — \u{201C}\(meal.notes)\u{201D}"),
            icon: "star.fill", tint: Color.stockedGreen)
    }

    private func highlightCard(eyebrow: String, title: String, detail: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 44, height: 44)
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow)
                    .font(.system(size: 10, weight: .bold)).tracking(1.5)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
    }

    // MARK: Savings
    private var savingsCard: some View {
        VStack(spacing: 6) {
            Text("YOU SAVED ABOUT")
                .font(.system(size: 11, weight: .bold)).tracking(1.5)
                .foregroundStyle(.white.opacity(0.6))
            Text("~\(money(Double(moneySaved)))")
                .font(.system(size: 46, weight: .heavy, design: .serif))
                .foregroundStyle(Color.stockedGold)
            Text("cooking at home instead of ordering out\(totalSpend > 0 ? " · \(money(totalSpend)) tracked in groceries" : "")")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
            if wastedValue > 0 {
                Text("Heads up: about \(money(wastedValue)) went to waste — room to save more next season.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26).padding(.horizontal, 18)
        .background(cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
    }

    // MARK: Closing
    private var closingCard: some View {
        VStack(spacing: 10) {
            StockedWordmark(size: 28)
            Text(mealsCooked > 0
                 ? "Here's to many more good meals."
                 : "Your kitchen story is just getting started.")
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(primaryText.opacity(0.6))
                .multilineTextAlignment(.center)
            Button { dismiss() } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 40).padding(.vertical, 13)
                    .background(Color.stockedGold)
                    .clipShape(Capsule())
            }.buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
