// SplashView — tan bg, "Stocked." centered, 2-second auto-advance OR tap to skip
import SwiftUI

struct SplashView: View {
    @Environment(AppSession.self) var session
    var onFinish: (() -> Void)? = nil

    @State private var opacity: Double  = 0
    @State private var scale:   CGFloat = 0.92
    @State private var finished = false

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()

            VStack(spacing: 12) {
                // Splash wordmark uses a period matching the text color (not gold).
                StockedWordmark(size: 38)

                Text("Kitchen Peace of Mind")
                    .scaledFont(13, weight: .medium, design: .serif)
                    .foregroundStyle(session.themeTextColor.opacity(0.82))
                    .tracking(1.2)
            }
            .opacity(opacity)
            .scaleEffect(scale)

        }
        // Tap anywhere to skip
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) {
                opacity = 1
                scale   = 1
            }
            // Auto-advance after exactly 2 seconds
            Task {
                try? await Task.sleep(nanoseconds: 2000000000)
                advance()
            }
        }
    }

    private func advance() {
        guard !finished else { return }
        finished = true
        // Fade out, but DON'T gate onFinish behind an async sleep — if the app is suspended
        // during a cold launch (e.g. launched from the Share Extension while the share sheet
        // is still foregrounded), a detached Task can be interrupted and the callback never
        // fires, leaving the app stuck on the splash. Calling onFinish synchronously on the
        // main actor guarantees we always advance; the brief fade still reads fine.
        withAnimation(.easeIn(duration: 0.25)) { opacity = 0 }
        onFinish?()
    }
}

#Preview { SplashView() }
