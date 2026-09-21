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
                    Image(systemName: "timer").widgetScaledFont(20).foregroundStyle(Color.ctGold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.recipeTitle)
                        .widgetScaledFont(15, weight: .bold, design: .serif)
                        .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    Text("Step \(context.state.stepNumber) of \(context.state.totalSteps) · \(context.state.stepText)")
                        .widgetScaledFont(12).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: Double(context.state.stepNumber), total: Double(max(context.state.totalSteps, 1)))
                        .tint(Color.ctGold)
                }
                Spacer(minLength: 8)
                Text(timerInterval: Date()...context.state.endDate, countsDown: true)
                    .widgetScaledFont(24, weight: .heavy, design: .rounded)
                    .monospacedDigit()
                    .foregroundStyle(Color.ctGold)
                    .fixedSize(horizontal: false, vertical: true)

                    .multilineTextAlignment(.trailing)
                    .fixedSize()
                    .contentTransition(.numericText(countsDown: true))
            }
            .padding(16)
            .widgetURL(URL(string: "stocked://cook"))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Cooking \(context.attributes.recipeTitle), step \(context.state.stepNumber) of \(context.state.totalSteps)")
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Stocked.", systemImage: "timer")
                        .widgetScaledFont(13, weight: .semibold)
                        .foregroundStyle(Color.ctGold)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...context.state.endDate, countsDown: true)
                        .widgetScaledFont(16, weight: .bold, design: .rounded)
                        .monospacedDigit()
                        .foregroundStyle(Color.ctGold)
                        .fixedSize(horizontal: false, vertical: true)
                        .fixedSize()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.recipeTitle)
                            .widgetScaledFont(14, weight: .bold, design: .serif).fixedSize(horizontal: false, vertical: true)
                        Text("Step \(context.state.stepNumber) of \(context.state.totalSteps) · \(context.state.stepText)")
                            .widgetScaledFont(12).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ProgressView(value: Double(context.state.stepNumber), total: Double(max(context.state.totalSteps, 1)))
                            .tint(Color.ctGold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(Color.ctGold)
            } compactTrailing: {
                Text(timerInterval: Date()...context.state.endDate, countsDown: true)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .fixedSize()
                    .foregroundStyle(Color.ctGold)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(Color.ctGold)
            }
            .widgetURL(URL(string: "stocked://cook"))
            .keylineTint(Color.ctGold)
        }
    }
}
