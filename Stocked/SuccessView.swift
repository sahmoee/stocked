// Screen 3 — Auth success: tan bg, "Stocked." top, white rounded-rect with green circle checkmark center
import SwiftUI
import Combine
struct SuccessView: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedMotion) private var motion
    @State private var scale: CGFloat = 0.5
    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                StockedWordmark(size: 26)
                    .padding(.top, 52)
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color.white).frame(width: 180, height: 180)
                    ZStack {
                        Circle().stroke(Color.stockedGreen, lineWidth: 3).frame(width: 90, height: 90)
                        Image(systemName: "checkmark")
                            .scaledFont(40, weight: .medium)
                            .foregroundStyle(Color.stockedGreen)
                    }
                }
                .scaleEffect(scale)
                .onAppear {
                    motion.animate(.settle, intent: .decorative) { scale = 1 }
                    Task {
                        try? await Task.sleep(nanoseconds: 1200000000)
                        withAnimation { session.isLoggedIn = true }
                    }
                }
                Spacer()
            }
        }
    }
}
#Preview { SuccessView().environment(AppSession()) }
