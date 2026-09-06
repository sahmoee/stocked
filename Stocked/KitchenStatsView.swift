import SwiftUI

// #19 Kitchen stats. A personal dashboard drawn from consumptionLog and recipe cook counts:
// money wasted on expired items, items used vs wasted, and most-cooked recipes. Read-only.
// Reachable from Data & Storage or the profile (add a NavigationLink to KitchenStatsView).

struct KitchenStatsView: View {
    @Environment(AppSession.self) private var session

    private var log: [ConsumptionRecord] { session.guestStore.consumptionLog }

    private var totalUsed: Int { log.filter { !$0.wasted }.count }
    private var totalWasted: Int { log.filter { $0.wasted }.count }
    private var moneyWasted: Double { log.filter { $0.wasted }.compactMap { $0.estimatedValue }.reduce(0, +) }
    private var wasteRate: Double {
        let n = log.count
        return n == 0 ? 0 : Double(totalWasted) / Double(n)
    }
    private var topRecipes: [(title: String, count: Int)] {
        session.guestStore.userRecipes
            .filter { $0.cookCount > 0 }
            .sorted { $0.cookCount > $1.cookCount }
            .prefix(5)
            .map { ($0.title, $0.cookCount) }
    }

    var body: some View {
        StockedShell(showBack: true, titleText: "Kitchen Stats") {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    statTile("Used", "\(totalUsed)", "items finished")
                    statTile("Wasted", "\(totalWasted)", "let expire")
                }
                HStack(spacing: 12) {
                    statTile("Waste rate", wasteRate == 0 ? "—" : String(format: "%.0f%%", wasteRate * 100), "of tracked items")
                    statTile("Value wasted", moneyWasted == 0 ? "—" : String(format: "$%.0f", moneyWasted), "expired unused")
                }

                if !topRecipes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Most cooked").scaledFont(14, weight: .semibold).foregroundStyle(session.themeTextColor)
                        ForEach(topRecipes, id: \.title) { r in
                            HStack {
                                Text(r.title).scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.8))
                                Spacer()
                                Text("\(r.count)×").scaledFont(14, weight: .semibold).foregroundStyle(Color.stockedGold)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 20))
                }

                if log.isEmpty {
                    Text("As you use up and remove items, your stats will build here.")
                        .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.5))
                        .multilineTextAlignment(.center).padding(.top, 8)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8)
        }
    }

    private func statTile(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).scaledFont(11, weight: .bold).foregroundStyle(session.themeTextColor.opacity(0.4))
            Text(value).scaledFont(26, weight: .bold, design: .serif).foregroundStyle(session.themeTextColor)
            Text(sub).scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 20))
    }
}
