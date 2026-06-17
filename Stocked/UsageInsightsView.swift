// UsageInsightsView.swift — #20 a read-only window into the LOCAL usage counters.
// Reachable from Settings → it shows which features are actually used (busiest first),
// a detail breakdown for widgets, and an opt-out + reset. Nothing here leaves the device.
import SwiftUI

struct UsageInsightsView: View {
    @Environment(AppSession.self) var session
    @State private var enabled = UsageMetrics.shared.isEnabled
    @State private var stats: [UsageStat] = UsageMetrics.shared.summary()
    @State private var widgetBreakdown: [(String, Int)] = UsageMetrics.shared.detailBreakdown(for: .widgetAdded)
    @State private var showResetConfirm = false

    private var dark: Bool { session.isDarkMode }

    var body: some View {
        StockedShell(showBack: true, scrollDisabled: false) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage Insights")
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("A private, on-device count of which features you use. Nothing is uploaded or shared.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.6))
                }
                .padding(.horizontal, 24).padding(.top, 4)

                // Summary line
                HStack(spacing: 14) {
                    summaryStat("\(UsageMetrics.shared.totalEvents)", "actions logged")
                    summaryStat(daysSinceFirst, "days using Stocked")
                }
                .padding(.horizontal, 24)

                // Opt-out
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Track usage on this device")
                            .font(.system(size: 15, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text("Local only — used to improve the app")
                            .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    }
                }
                .tint(Color.stockedGold)
                .onChange(of: enabled) { _, v in UsageMetrics.shared.isEnabled = v }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)

                // Per-feature counts
                Text("Most used")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .padding(.horizontal, 24)

                VStack(spacing: 0) {
                    ForEach(Array(stats.enumerated()), id: \.element.id) { idx, stat in
                        HStack {
                            Text(stat.label)
                                .font(.system(size: 14))
                                .foregroundStyle(session.themeTextColor.opacity(stat.count == 0 ? 0.4 : 0.9))
                            Spacer()
                            Text("\(stat.count)")
                                .font(.system(size: 14, weight: .bold, design: .serif))
                                .foregroundStyle(stat.count == 0 ? session.themeTextColor.opacity(0.3) : Color.stockedGold)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        if idx < stats.count - 1 {
                            Divider().opacity(0.35).padding(.leading, 18)
                        }
                    }
                }
                .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)

                // Widget detail (only if any recorded)
                if !widgetBreakdown.isEmpty {
                    Text("Widgets added (by type)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .padding(.horizontal, 24)
                    VStack(spacing: 0) {
                        ForEach(Array(widgetBreakdown.enumerated()), id: \.offset) { idx, pair in
                            HStack {
                                Text(pair.0).font(.system(size: 13.5)).foregroundStyle(session.themeTextColor.opacity(0.85))
                                Spacer()
                                Text("\(pair.1)").font(.system(size: 13.5, weight: .bold, design: .serif)).foregroundStyle(Color.stockedGold)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 9)
                            if idx < widgetBreakdown.count - 1 { Divider().opacity(0.3).padding(.leading, 18) }
                        }
                    }
                    .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 20)
                }

                Button(role: .destructive) { showResetConfirm = true } label: {
                    Text("Reset usage data")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.stockedError)
                }
                .padding(.horizontal, 24).padding(.top, 4)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .confirmationDialog("Reset all usage counts?", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("Reset", role: .destructive) {
                    UsageMetrics.shared.reset()
                    stats = UsageMetrics.shared.summary()
                    widgetBreakdown = UsageMetrics.shared.detailBreakdown(for: .widgetAdded)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func summaryStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold, design: .serif)).foregroundStyle(session.themeTextColor)
            Text(label).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var daysSinceFirst: String {
        let days = Calendar.current.dateComponents([.day], from: UsageMetrics.shared.firstLaunch, to: Date()).day ?? 0
        return "\(max(0, days))"
    }
}
