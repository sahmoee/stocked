// CookTimerLiveActivity.swift — WIDGET EXTENSION TARGET ONLY.
// The Lock Screen + Dynamic Island UI for the cook-step timer Live Activity (#16).
// Added to StockedWidgetBundle. Uses Text(timerInterval:) so the countdown runs on-device.
import ActivityKit
import WidgetKit
import SwiftUI

private extension Color {
    static let ctGold = Color(red: 0.635, green: 0.447, blue: 0.098) // #A27219
}

struct CookTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CookTimerAttributes.self) { context in
            // ── Lock Screen / banner ──
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.ctGold.opacity(0.18)).frame(width: 46, height: 46)
                    Image(systemName: "timer").font(.system(size: 20)).foregroundStyle(Color.ctGold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.recipeTitle)
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .foregroundStyle(.primary).lineLimit(1)
                    Text("Step \(context.state.stepNumber) of \(context.state.totalSteps) · \(context.state.stepText)")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(timerInterval: Date()...context.state.endDate, countsDown: true)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.ctGold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.trailing)
                    .fixedSize()
            }
            .padding(16)
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Stocked.", systemImage: "timer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ctGold)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...context.state.endDate, countsDown: true)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.ctGold)
                        .lineLimit(1)
                        .fixedSize()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.recipeTitle)
                            .font(.system(size: 14, weight: .bold, design: .serif)).lineLimit(1)
                        Text("Step \(context.state.stepNumber) of \(context.state.totalSteps) · \(context.state.stepText)")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(Color.ctGold)
            } compactTrailing: {
                Text(timerInterval: Date()...context.state.endDate, countsDown: true)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Color.ctGold)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(Color.ctGold)
            }
        }
    }
}
