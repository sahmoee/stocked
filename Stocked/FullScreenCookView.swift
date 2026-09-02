// FullScreenCookView.swift
// Full-screen cooking flashcards: one giant, readable step at a time with big
// nav targets and optional hands-free voice control ("next", "back", "repeat",
// "finish"). Presented as a fullScreenCover from CookingFlashcardView; step
// progress is shared through bindings so the two views stay in sync.

import SwiftUI

struct FullScreenCookView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.stockedMotion) private var motion
    let recipeTitle: String
    let steps: [String]
    @Binding var currentCard: Int
    @Binding var completedSteps: Set<Int>
    var onFinish: () -> Void

    @State private var voice = VoiceCookControl()
    @State private var dragOffset: CGSize = .zero

    private var atEnd: Bool { currentCard >= steps.count - 1 }

    var body: some View {
        ZStack {
            Color.stockedCharcoal.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Top bar ───────────────────────────────────────────
                HStack(spacing: 12) {
                    Button { voice.stop(); dismiss() } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .scaledFont(16, weight: .semibold)
                            .foregroundStyle(Color.stockedWhite.opacity(0.8))
                            .padding(10)
                            .background(Color.white.opacity(0.10))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Exit full screen")

                    VStack(alignment: .leading, spacing: 1) {
                        Text(recipeTitle)
                            .scaledFont(14, weight: .bold, design: .serif)
                            .foregroundStyle(Color.stockedWhite)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Step \(min(currentCard + 1, steps.count)) of \(steps.count)")
                            .scaledFont(11)
                            .foregroundStyle(Color.stockedWhite.opacity(0.55))
                    }
                    Spacer()

                    // Read aloud
                    Button { SpeechReader.shared.toggle(steps.indices.contains(currentCard) ? steps[currentCard] : "") } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .scaledFont(15)
                            .foregroundStyle(Color.stockedGold)
                            .padding(10)
                            .background(Color.white.opacity(0.10))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Read step aloud")

                    // Voice control toggle
                    Button {
                        voice.toggle { handle($0) }
                    } label: {
                        Image(systemName: voice.isListening ? "mic.fill" : "mic.slash.fill")
                            .scaledFont(15)
                            .foregroundStyle(voice.isListening ? Color.stockedCharcoal : Color.stockedWhite.opacity(0.7))
                            .padding(10)
                            .background(voice.isListening ? Color.stockedGold : Color.white.opacity(0.10))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(voice.isListening ? "Stop voice control" : "Start voice control")
                }
                .padding(.horizontal, 20).padding(.top, 8)

                if voice.isListening {
                    Text("Listening — say \"next\", \"back\", \"repeat\", or \"finish\"")
                        .scaledFont(11.5, weight: .medium)
                        .foregroundStyle(Color.stockedGold.opacity(0.9))
                        .padding(.top, 8)
                } else if voice.authDenied {
                    Text("Voice control needs mic + speech access — enable both in Settings → Stocked.")
                        .scaledFont(11)
                        .foregroundStyle(Color.stockedWhite.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24).padding(.top, 8)
                }

                Spacer()

                // ── The step ──────────────────────────────────────────
                if steps.indices.contains(currentCard) {
                    Text(steps[currentCard])
                        .font(.stockedSystem(size: RecipeTextPrefs.shared.scaled(26), weight: .medium, design: .serif))
                        .foregroundStyle(Color.stockedWhite)
                        .multilineTextAlignment(.center)

                        .padding(.horizontal, 28)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(currentCard)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                        .offset(x: dragOffset.width)
                        .gesture(DragGesture()
                            .onChanged { dragOffset = $0.translation }
                            .onEnded { v in
                                let projectedX = v.predictedEndTranslation.width
                                let target = StockedVelocitySnapPolicy().targetIndex(
                                    currentIndex: currentCard,
                                    currentOffset: CGFloat(currentCard) * 200 - projectedX,
                                    itemExtent: 200,
                                    velocity: 0,
                                    itemCount: steps.count
                                )
                                motion.animate(.settle, intent: .spatial) {
                                    if target > currentCard { completedSteps.insert(currentCard) }
                                    currentCard = target
                                    dragOffset = .zero
                                }
                            })
                }

                Spacer()

                // Dot indicators
                HStack(spacing: 7) {
                    ForEach(steps.indices, id: \.self) { i in
                        Circle()
                            .fill(i == currentCard ? Color.stockedGold
                                  : (completedSteps.contains(i) ? Color.stockedGold.opacity(0.45)
                                     : Color.white.opacity(0.25)))
                            .frame(width: i == currentCard ? 10 : 7, height: i == currentCard ? 10 : 7)
                            .stockedAnimation(.selection, intent: .spatial, value: currentCard)
                    }
                }
                .padding(.bottom, 20)

                // ── Nav + finish ──────────────────────────────────────
                HStack(spacing: 16) {
                    Button { motion.animate(.selection, intent: .spatial) { goBack() } } label: {
                        Image(systemName: "chevron.left")
                            .scaledFont(22, weight: .bold)
                            .foregroundStyle(currentCard == 0 ? Color.white.opacity(0.25) : Color.stockedWhite)
                            .frame(width: 64, height: 56)
                            .background(Color.white.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                    }
                    .buttonStyle(.plain)
                    .disabled(currentCard == 0)

                    Button {
                        if atEnd { finishNow() }
                        else { motion.animate(.selection, intent: .spatial) { goNext() } }
                    } label: {
                        HStack(spacing: 8) {
                            Text(atEnd ? "Finish Cooking" : "Next Step")
                                .scaledFont(17, weight: .semibold, design: .serif)
                            Image(systemName: atEnd ? "flag.fill" : "chevron.right")
                                .scaledFont(15, weight: .bold)
                        }
                        .foregroundStyle(atEnd ? Color.stockedCharcoal : Color.stockedWhite)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(atEnd ? Color.stockedGold : Color.white.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .onDisappear { voice.stop() }
        .statusBarHidden(true)
    }

    private func goNext() {
        guard currentCard < steps.count - 1 else { return }
        completedSteps.insert(currentCard)
        currentCard += 1
    }

    private func goBack() {
        guard currentCard > 0 else { return }
        currentCard -= 1
    }

    private func finishNow() {
        completedSteps.formUnion(steps.indices)
        voice.stop()
        dismiss()
        onFinish()
    }

    private func handle(_ command: VoiceCookCommand) {
        motion.animate(.selection, intent: .spatial) {
            switch command {
            case .next:       atEnd ? finishNow() : goNext()
            case .back:       goBack()
            case .repeatStep: if steps.indices.contains(currentCard) { SpeechReader.shared.toggle(steps[currentCard]) }
            case .finish:     finishNow()
            }
        }
    }
}
