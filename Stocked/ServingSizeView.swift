// ServingSizeView — smooth slider + tappable number buttons
import SwiftUI
import Combine

struct ServingSizeView: View {
    @Environment(AppSession.self) var session
    let isCookNow: Bool
    @State private var servings: Double = 4
    @State private var advance = false

    var body: some View {
        StockedShell(showBack: true, scrollDisabled: false) {
            VStack(spacing: 0) {
                Spacer(minLength: 18)

                // Step marker so the user knows where they are in the cook flow (#8).
                StepIndicator(current: 1, total: isCookNow ? 3 : 2,
                              dim: session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                    .padding(.bottom, 24)

                // Large fork & knife icon
                Image(systemName: "fork.knife")
                    .font(.system(size: 110, weight: .light))
                    .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                    .padding(.bottom, 50)

                // Question
                Text("How many people are we feeding?")
                    .font(.system(size: 18, weight: .regular, design: .serif))
                    .foregroundStyle(session.isDarkMode ? Color.stockedWhite.opacity(0.7) : Color.stockedCharcoal.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 20)

                // Large animated serving count display
                ZStack {
                    Circle()
                        .fill(session.isDarkMode ? Color.darkSurface : Color.stockedCharcoal)
                        .overlay(Circle().stroke(session.isDarkMode ? Color.stockedGold : Color.clear, lineWidth: 2))
                        .frame(width: 90, height: 90)
                    Text("\(Int(servings.rounded()))")
                        .font(.system(size: 40, weight: .bold, design: .serif))
                        .foregroundStyle(Color.stockedWhite)
                        .contentTransition(.numericText())
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: servings)
                .padding(.bottom, 28)

                // Smooth slider — no step, rounds on release
                Slider(value: $servings, in: 1...8)
                    .tint(session.isDarkMode ? Color.stockedGold : Color.stockedCharcoal)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
                    .onChange(of: servings) { _, v in
                        // Snap to nearest integer with haptic feel
                        let rounded = v.rounded()
                        if abs(v - rounded) < 0.15 && servings != rounded {
                            withAnimation(.spring(response: 0.2)) { servings = rounded }
                        }
                    }

                // Tappable number buttons
                HStack(spacing: 8) {
                    ForEach(1...8, id: \.self) { n in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                servings = Double(n)
                            }
                        } label: {
                            let isSelected = Int(servings.rounded()) == n
                            ZStack {
                                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm)
                                    .fill(isSelected
                                          ? (session.isDarkMode ? Color(white: 0.25) : Color.stockedCharcoal)
                                          : (session.isDarkMode ? Color(white: 0.15) : Color.stockedCharcoal.opacity(0.12)))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm)
                                            .stroke(isSelected ? Color.stockedGold : (session.isDarkMode ? Color.stockedGold.opacity(0.2) : Color.clear), lineWidth: 1)
                                    )
                                    .frame(height: 38)
                                Text("\(n)")
                                    .font(.system(size: 15, weight: isSelected ? .bold : .regular))
                                    .foregroundStyle(session.isDarkMode ? Color.stockedWhite : (isSelected ? Color.stockedWhite : Color.stockedCharcoal))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 36)

                Text("Tap a number or drag the slider")
                    .font(.system(size: 12))
                    .foregroundStyle(session.isDarkMode ? Color.stockedWhite.opacity(0.35) : Color.stockedCharcoal.opacity(0.35))
                    .padding(.bottom, 28)

                // Continue
                Button { advance = true } label: {
                    Text("Continue")
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedCharcoal)
                        .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL).stroke(session.isDarkMode ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 32)  // breathe space below Continue
            }
        }
        .navigationDestination(isPresented: $advance) {
            if isCookNow {
                MainHubView(servings: Int(servings.rounded()))
            } else {
                MealPlannerView(servings: Int(servings.rounded()))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            advance = false   // collapse cook flow on iPad
        }
        .onAppear {
            // Default the serving count to the household size chosen during onboarding,
            // clamped to the slider's 1...8 range.
            let h = session.guestStore.cookingProfile.householdSize
            if h >= 1 { servings = Double(min(max(h, 1), 8)) }
        }
    }
}

#Preview { ServingSizeView(isCookNow: true) }
