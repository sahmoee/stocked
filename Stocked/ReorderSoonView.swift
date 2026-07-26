// ReorderSoonView.swift — Overall improvement #9: smart reorder / staple cadence.
//
// The app already records when items get used up (ConsumptionRecord.daysLasted) and the user's
// staple list. Nobody was turning that into "you usually run out of milk about now." This predicts
// the next run-out date per staple from its historical lifespan and surfaces the ones due soon
// that aren't currently in stock, with one tap to add them to grocery.

import SwiftUI

// MARK: - Pure prediction

nonisolated struct ReorderPrediction: Identifiable, Sendable {
    var id: String { name.lowercased() }
    let name: String
    let daysUntilOut: Int          // negative = already overdue
    let avgLifespan: Int
    let samples: Int               // how many past cycles informed this
    var isOverdue: Bool { daysUntilOut <= 0 }
    var confidence: String { samples >= 3 ? "High" : samples == 2 ? "Medium" : "Low" }
}

nonisolated enum ReorderEngine {
    /// For each staple not currently in stock, predict when it runs out from past lifespans.
    static func predictions(staples: [String],
                            log: [ConsumptionRecord],
                            inStock: Set<String>,
                            now: Date = Date()) -> [ReorderPrediction] {
        var out: [ReorderPrediction] = []
        for staple in staples {
            let key = staple.lowercased()
            guard !inStock.contains(where: { $0.contains(key) || key.contains($0) }) else { continue }
            let records = log.filter {
                let n = $0.itemName.lowercased()
                return n.contains(key) || key.contains(n)
            }
            let lifespans = records.compactMap { $0.daysLasted }.filter { $0 > 0 }
            guard let last = records.map(\.depletedAt).max() else { continue }
            // Average lifespan (fallback to a fortnight if we only know it ran out, not for how long).
            let avg = lifespans.isEmpty ? 14.0 : lifespans.reduce(0, +) / Double(lifespans.count)
            let predictedOut = last.addingTimeInterval(avg * 86_400)
            let days = Calendar.current.dateComponents([.day], from: now, to: predictedOut).day ?? 0
            out.append(ReorderPrediction(name: staple,
                                         daysUntilOut: days,
                                         avgLifespan: Int(avg.rounded()),
                                         samples: max(lifespans.count, records.count)))
        }
        // Soonest / most overdue first.
        return out.sorted { $0.daysUntilOut < $1.daysUntilOut }
    }
}

// MARK: - View

struct ReorderSoonView: View {
    @Environment(AppSession.self) private var session
    @State private var added: Set<String> = []

    private var predictions: [ReorderPrediction] {
        ReorderEngine.predictions(staples: session.guestStore.stockStaples,
                                  log: session.guestStore.consumptionLog,
                                  inStock: session.guestStore.inStockNameSet)
    }
    // Only show things due within ~10 days or overdue — the rest isn't actionable yet.
    private var due: [ReorderPrediction] { predictions.filter { $0.daysUntilOut <= 10 } }

    var body: some View {
        ScrollView {
            if session.guestStore.stockStaples.isEmpty {
                empty("Set your staples first",
                      "Mark the things you always keep on hand, and Stocked will learn how fast you go through them and remind you before you run out.")
            } else if due.isEmpty {
                empty("Nothing due to reorder",
                      "None of your staples are predicted to run out in the next week and a half. Check back — this updates as you use things up.")
            } else {
                VStack(spacing: 10) {
                    ForEach(due) { p in row(p) }
                    Text("Predictions come from how long each staple has lasted you before. More history means a better guess.")
                        .font(.system(size: 11)).foregroundStyle(session.themeSecondaryText)
                        .multilineTextAlignment(.center).padding(.top, 6).padding(.horizontal, 12)
                }
                .padding(18)
            }
        }
        .stockedScreen()
        .navigationTitle("Reorder Soon")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ p: ReorderPrediction) -> some View {
        let isAdded = added.contains(p.id)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name.capitalized).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                Text(p.isOverdue
                     ? "Likely out already · usually lasts ~\(p.avgLifespan)d"
                     : "Out in ~\(p.daysUntilOut)d · usually lasts ~\(p.avgLifespan)d")
                    .font(.system(size: 12))
                    .foregroundStyle(p.isOverdue ? .red.opacity(0.8) : session.themeSecondaryText)
            }
            Spacer()
            Button {
                session.guestStore.addToGroceryIfMissing(p.name, recommended: true)
                added.insert(p.id)
                HapticManager.success()
            } label: {
                Label(isAdded ? "Added" : "Add", systemImage: isAdded ? "checkmark" : "cart.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background((isAdded ? Color.green : session.accentColor).opacity(0.15))
                    .foregroundStyle(isAdded ? .green : session.accentColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain).disabled(isAdded)
        }
        .padding(14)
        .background(session.themeTextColor.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func empty(_ title: String, _ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 34)).foregroundStyle(session.themeTextColor.opacity(0.25))
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(session.themeTextColor)
            Text(msg).font(.system(size: 13)).multilineTextAlignment(.center)
                .foregroundStyle(session.themeTextColor.opacity(0.55)).padding(.horizontal, 34)
        }.frame(maxWidth: .infinity).padding(.top, 80)
    }
}
