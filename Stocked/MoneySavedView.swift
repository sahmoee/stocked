// MoneySavedView.swift — Overall improvement #5: turn invisible good habits into a number.
//
// Stocked already tracks the value of food that gets used vs. wasted (ConsumptionRecord) and the
// market value of home-grown produce (HarvestStore). Nothing ever added those up for the user.
// This is the retention hook: a plain, honest "here's what your kitchen habits are worth" view.
// Pure read-over-existing-data; it stores nothing of its own.

import SwiftUI

struct MoneySavedView: View {
    @Environment(AppSession.self) private var session
    private let harvest = HarvestStore.shared

    private var currencyCode: String { Locale.current.currency?.identifier ?? "USD" }

    // Food that was fully used rather than binned — money that would otherwise have been re-spent.
    private var usedValue: Double {
        session.guestStore.consumptionLog
            .filter { !$0.wasted }
            .reduce(0) { $0 + ($1.estimatedValue ?? 0) }
    }
    private var wastedValue: Double {
        session.guestStore.consumptionLog
            .filter { $0.wasted }
            .reduce(0) { $0 + ($1.estimatedValue ?? 0) }
    }
    private var grownValue: Double { HarvestMath.totalValue(harvest.entries) }
    private var totalSaved: Double { usedValue + grownValue }

    // Share of tracked food value that didn't go in the bin.
    private var savingsRate: Int {
        let denom = usedValue + wastedValue
        guard denom > 0 else { return 0 }
        return Int((usedValue / denom * 100).rounded())
    }

    private var hasData: Bool { !session.guestStore.consumptionLog.isEmpty || !harvest.entries.isEmpty }

    var body: some View {
        ScrollView {
            if !hasData {
                VStack(spacing: 12) {
                    Image(systemName: "banknote")
                        .scaledFont(34).foregroundStyle(session.themeTextColor.opacity(0.25))
                    Text("Nothing to total yet").scaledFont(16, weight: .semibold)
                        .foregroundStyle(session.themeTextColor)
                    Text("As you cook, use things up, and log garden harvests, Stocked tracks the value you keep instead of throwing away — and shows it here.")
                        .scaledFont(13).multilineTextAlignment(.center)
                        .foregroundStyle(session.themeTextColor.opacity(0.55)).padding(.horizontal, 34)
                }.frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                VStack(spacing: 16) {
                    // Hero
                    VStack(spacing: 4) {
                        Text("Kept, not wasted").scaledFont(13, weight: .medium)
                            .foregroundStyle(session.themeSecondaryText)
                        Text(totalSaved.formatted(.currency(code: currencyCode)))
                            .scaledFont(40, weight: .bold, design: .serif)
                            .foregroundStyle(session.accentColor)
                        if savingsRate > 0 {
                            Text("\(savingsRate)% of tracked food value used")
                                .scaledFont(12).foregroundStyle(session.themeSecondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                    .background(session.accentColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    HStack(spacing: 12) {
                        stat("Used up", usedValue, "checkmark.circle", .green)
                        stat("Grown", grownValue, "leaf.circle", session.accentColor)
                        stat("Wasted", wastedValue, "trash", .red)
                    }

                    if wastedValue > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Most wasted").scaledFont(12, weight: .bold)
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                            ForEach(topWasted, id: \.name) { row in
                                HStack {
                                    Text(row.name.capitalized).scaledFont(14)
                                        .foregroundStyle(session.themeTextColor)
                                    Spacer()
                                    Text(row.value.formatted(.currency(code: currencyCode)))
                                        .scaledFont(14, weight: .semibold)
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                                .padding(.vertical, 6)
                                Divider().opacity(0.3)
                            }
                        }
                        .padding(14)
                        .background(session.themeTextColor.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    Text("Values are estimates from prices you've entered and typical market prices. They're a guide, not accounting.")
                        .scaledFont(11).foregroundStyle(session.themeSecondaryText)
                        .multilineTextAlignment(.center).padding(.horizontal, 12)
                }
                .padding(18)
            }
        }
        .stockedScreen()
        .navigationTitle("Money Saved")
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct WasteRow { let name: String; let value: Double }
    private var topWasted: [WasteRow] {
        var byName: [String: Double] = [:]
        for r in session.guestStore.consumptionLog where r.wasted {
            byName[r.itemName.lowercased(), default: 0] += (r.estimatedValue ?? 0)
        }
        return byName.map { WasteRow(name: $0.key, value: $0.value) }
            .sorted { $0.value > $1.value }.prefix(4).map { $0 }
    }

    private func stat(_ label: String, _ value: Double, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).scaledFont(16).foregroundStyle(color)
            Text(value.formatted(.currency(code: currencyCode)))
                .scaledFont(15, weight: .bold).foregroundStyle(session.themeTextColor)
                .fixedSize(horizontal: false, vertical: true)
            Text(label).scaledFont(11).foregroundStyle(session.themeSecondaryText)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(session.themeTextColor.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
