// MainHubView.swift — Cook Now hub: Foods · Moods · Surprise Me
import SwiftUI
import Combine

@MainActor
struct MainHubView: View {
    let servings: Int
    @State private var engine: SurpriseRecipeEngine?
    @Environment(AppSession.self) var session
    @State private var surpriseRecipe: GeneratedRecipe?
    @State private var showSurprise  = false
    @State private var showEmpty     = false
    @State private var isGenerating  = false

    init(servings: Int) {
        self.servings = servings
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Good Morning"
        case 12..<17: return "Good Afternoon"
        default:     return "Good Evening"
        }
    }

    @Environment(\.stockedDevice) private var device

    // Effective layout width: capped to a comfortable column so the three circles fit the
    // iPad screen (both horizontally and vertically) instead of overflowing the edges.
    private static let hubColumnCapTablet:        CGFloat = 560
    private static let pairDiameterCapPhone:      CGFloat = 320
    private static let pairDiameterCapTablet:     CGFloat = 230
    private static let surpriseDiameterCapPhone:  CGFloat = 360
    private static let surpriseDiameterCapTablet: CGFloat = 250
    private var layoutWidth: CGFloat {
        let w = StockedScreen.width
        return device == .tablet ? min(w, Self.hubColumnCapTablet) : w
    }
    // Foods/Moods sit two-up: (width − 28*2 horizontal padding − 14 spacing) / 2.
    // Capped so the pair never grows so large it pushes Surprise Me off-screen on iPad.
    private var pairDiameter: CGFloat {
        min(device == .tablet ? Self.pairDiameterCapTablet : Self.pairDiameterCapPhone,
            max(120, (layoutWidth - 56 - 14) / 2))
    }
    // Surprise Me is one-up with 60pt horizontal padding (capped on iPad).
    private var surpriseDiameter: CGFloat {
        min(device == .tablet ? Self.surpriseDiameterCapTablet : Self.surpriseDiameterCapPhone,
            max(160, layoutWidth - 120))
    }

    // Hub buttons honor the same shape choice as the Home Cook buttons. For pill, the
    // footprint becomes a wide capsule (half-height) instead of a circle.
    private func hubShape(_ d: CGFloat) -> AnyShape {
        switch session.cookButtonShape {
        case .circle:      return AnyShape(Circle())
        case .pill:        return AnyShape(Capsule())
        case .roundedRect: return AnyShape(RoundedRectangle(cornerRadius: d * 0.22))
        }
    }
    private var hubHeightFactor: CGFloat { session.cookButtonShape == .pill ? 0.5 : 1.0 }

    var body: some View {
        StockedShell(showBack: true, scrollDisabled: true) {
            VStack(spacing: 0) {
                // Greeting
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(greeting), \(session.userName)")
                        .font(.system(size: 26, weight: .bold, design: .serif))
                        .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                    Text("Cooking for \(servings) · What are you feeling?")
                        .font(.system(size: 14))
                        .foregroundStyle(session.isDarkMode ? Color.stockedWhite.opacity(0.55) : Color.stockedCharcoal.opacity(0.55))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)

                // Foods + Moods — each fills half the width
                HStack(spacing: 14) {
                    NavigationLink(destination: FoodsCategoryView(servings: servings)) {
                        hubShape(pairDiameter)
                            .fill(session.themeButtonColor)
                            .overlay(hubShape(pairDiameter).stroke(session.isDarkMode ? Color.stockedGold.opacity(0.4) : Color.clear, lineWidth: 1.5))
                            .overlay(
                                Text("Foods")
                                    .font(.system(size: pairDiameter * 0.16, weight: .regular, design: .serif))
                                    .foregroundStyle(Color.stockedWhite)
                            )
                            .frame(width: pairDiameter, height: pairDiameter * hubHeightFactor)
                    }
                    .buttonStyle(.plain)

                    NavigationLink(destination: MoodsCategoryView(servings: servings)) {
                        hubShape(pairDiameter)
                            .fill(session.themeButtonColor)
                            .overlay(hubShape(pairDiameter).stroke(session.isDarkMode ? Color.stockedGold.opacity(0.4) : Color.clear, lineWidth: 1.5))
                            .overlay(
                                Text("Moods")
                                    .font(.system(size: pairDiameter * 0.16, weight: .regular, design: .serif))
                                    .foregroundStyle(Color.stockedWhite)
                            )
                            .frame(width: pairDiameter, height: pairDiameter * hubHeightFactor)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)

                // OR divider
                Text("OR")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                    .padding(.bottom, 12)

                // Surprise Me — wider than the pair above
                Button {
                    guard !session.guestStore.inventoryItems.isEmpty else { showEmpty = true; return }
                    isGenerating = true
                    Task {
                        let eng = engine ?? SurpriseRecipeEngine()
                        if engine == nil { engine = eng }
                        if let r = await eng.generateSurpriseRecipe(
                            from: session.guestStore.inventoryItems, servings: servings) {
                            surpriseRecipe = r; showSurprise = true
                        }
                        isGenerating = false
                    }
                } label: {
                    hubShape(surpriseDiameter)
                        .fill(session.themeButtonColor)
                        .overlay(hubShape(surpriseDiameter).stroke(session.isDarkMode ? Color.stockedGold.opacity(0.4) : Color.clear, lineWidth: 1.5))
                        .overlay(
                            VStack(spacing: 10) {
                                if isGenerating {
                                    ProgressView().tint(Color.stockedWhite).scaleEffect(1.4)
                                } else {
                                    Image(systemName: "gift.fill")
                                        .font(.system(size: surpriseDiameter * 0.13))
                                        .foregroundStyle(Color.stockedWhite)
                                    Text("SURPRISE\nME")
                                        .font(.system(size: surpriseDiameter * 0.11, weight: .bold, design: .serif))
                                        .foregroundStyle(Color.stockedWhite)
                                        .multilineTextAlignment(.center)
                                }
                            }
                        )
                        .frame(width: surpriseDiameter, height: surpriseDiameter * hubHeightFactor)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
        .navigationDestination(isPresented: $showSurprise) {
            if let r = surpriseRecipe { SurpriseRecipeDetailView(recipe: r) }
        }
        .alert("Add inventory items first!", isPresented: $showEmpty) {
            Button("OK", role: .cancel) {}
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            showSurprise = false   // collapse cook flow on iPad
        }
    }
}

#Preview { MainHubView(servings: 4).environment(AppSession()) }
