// RecipeTextSize.swift — #9 Live cooking mode.
// ─────────────────────────────────────────────────────────────────
// Two things live here:
//
// 1. RecipeTextPrefs — a user-adjustable text-size setting so ALL recipe
//    text (titles, ingredients, steps, cook-flow steps) scales. Fixed
//    `.system(size:)` fonts do NOT respond to the system Dynamic Type
//    slider, so this multiplier is the mechanism that actually scales
//    them. Persisted in UserDefaults; the control lives in Settings →
//    Preferences (RecipeTextSizeControl below).
//
// 2. TimedStepRow / StepTimerChip / RecipeStepSplitter — recipe detail
//    pages (My Collection + online recipes) render instructions as
//    numbered steps; any step that mentions a duration ("simmer 10
//    minutes") gets a tappable timer chip. Tapping starts a countdown
//    through the existing StepTimerEngine, which also schedules a local
//    notification and a Lock Screen / Dynamic Island Live Activity — so
//    dismissing the recipe sheet does NOT silence the timer.
// ─────────────────────────────────────────────────────────────────
import SwiftUI
import NaturalLanguage

// MARK: - Text size options

enum RecipeTextSize: String, CaseIterable, Identifiable {
    case small, standard, large, extraLarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small:      return "Small"
        case .standard:   return "Default"
        case .large:      return "Large"
        case .extraLarge: return "XL"
        }
    }

    var multiplier: CGFloat {
        switch self {
        case .small:      return 0.9
        case .standard:   return 1.0
        case .large:      return 1.18
        case .extraLarge: return 1.36
        }
    }
}

// MARK: - Persisted preference

@MainActor
@Observable
final class RecipeTextPrefs {
    static let shared = RecipeTextPrefs()
    private static let storageKey = "stocked.recipeTextSize"

    var size: RecipeTextSize {
        didSet { UserDefaults.standard.set(size.rawValue, forKey: Self.storageKey) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
        size = RecipeTextSize(rawValue: raw) ?? .standard
    }

    /// Point size for recipe text, scaled by the user's chosen size.
    /// Reading this inside a view body makes the view re-render on change.
    func scaled(_ base: CGFloat) -> CGFloat {
        (base * size.multiplier).rounded()
    }
}

// MARK: - Settings control (Settings → Preferences)

struct RecipeTextSizeControl: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedMotion) private var motion

    var body: some View {
        let prefs = RecipeTextPrefs.shared
        VStack(alignment: .leading, spacing: 8) {
            Label("Recipe Text Size", systemImage: "textformat.size")
                .scaledFont(14, design: .serif).foregroundStyle(session.themeTextColor)
            StockedEqualHeightGrid(items: RecipeTextSize.allCases, columns: 4, spacing: 6) { option in
                    Button {
                        motion.animate(.selection, intent: .spatial) { prefs.size = option }
                        HapticManager.select()
                    } label: {
                        Text(option.label)
                            .scaledFont(12, weight: .bold)
                            .foregroundStyle(prefs.size == option ? Color.stockedWhite : session.themeTextColor.opacity(0.6))
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                            .background(prefs.size == option ? Color.stockedGold : Color.clear)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(
                                prefs.size == option ? Color.clear : session.themeTextColor.opacity(0.18),
                                lineWidth: 1))
                    }
                    .buttonStyle(.plain)
            }
            // Live preview so the effect is obvious before leaving Settings.
            Text("Simmer for 10 minutes, stirring occasionally.")
                .font(.stockedSystem(size: prefs.scaled(14)))
                .foregroundStyle(session.themeTextColor.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step splitting

nonisolated enum RecipeStepSplitter {

    /// Splits an instructions blob into readable numbered steps.
    /// Newline-separated sources split on lines; single-paragraph sources
    /// (common with TheMealDB) split on sentences grouped into short steps.
    static func split(_ text: String) -> [String] {
        let lines = text
            .components(separatedBy: CharacterSet.newlines)
            .map { stripLeadingMarker($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.count > 2 }
        if lines.count > 1 { return lines }
        guard let paragraph = lines.first else { return [] }

        // Group sentences into steps of a comfortable reading length.
        var steps: [String] = []
        var current = ""
        for sentence in sentences(in: paragraph) {
            if current.isEmpty {
                current = sentence
            } else if current.count + sentence.count + 1 <= 160 {
                current += " " + sentence
            } else {
                steps.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { steps.append(current) }
        return steps
    }

    /// Removes "1.", "2)", "Step 3:" style prefixes so numbering isn't doubled.
    private static func stripLeadingMarker(_ line: String) -> String {
        let pattern = #"^(?:step\s*\d+\s*[:.\)-]?\s*|\d+\s*[:.\)-]\s*)"#
        if let range = line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    private static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result
    }
}

// MARK: - Duration formatting

enum RecipeTimerFormat {
    static func short(_ seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
        }
        if seconds >= 60 {
            let m = seconds / 60
            let s = seconds % 60
            return s == 0 ? "\(m) min" : "\(m) min \(s) sec"
        }
        return "\(seconds) sec"
    }
}

// MARK: - Numbered step row with tappable timer

/// A numbered instruction step for recipe detail pages. If the step text
/// mentions a duration, a tappable timer chip appears under it.
struct TimedStepRow: View {
    @Environment(AppSession.self) var session
    let stepNumber: Int
    let stepText: String
    let timerEngine: StepTimerEngine

    private var stepIndex: Int { stepNumber - 1 }
    private var detectedSeconds: Int? { StepTimerEngine.detectSeconds(in: stepText) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(timerEngine.timers[stepIndex]?.isFinished == true ? Color.stockedGreen : Color.stockedGold)
                    .frame(width: 24, height: 24)
                if timerEngine.timers[stepIndex]?.isFinished == true {
                    Image(systemName: "checkmark")
                        .scaledFont(11, weight: .bold).foregroundStyle(Color.stockedWhite)
                } else {
                    Text("\(stepNumber)")
                        .scaledFont(12, weight: .bold).foregroundStyle(Color.stockedWhite)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(stepText)
                    .font(.stockedSystem(size: RecipeTextPrefs.shared.scaled(14)))
                    .foregroundStyle(session.themeTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                if detectedSeconds != nil || timerEngine.timers[stepIndex] != nil {
                    StepTimerChip(stepIndex: stepIndex,
                                  stepText: stepText,
                                  detectedSeconds: detectedSeconds,
                                  timerEngine: timerEngine)
                }
            }
            Spacer(minLength: 0)
            // #C5 read-aloud — one tap speaks the step for flour-covered hands;
            // tap again (or another step) to stop.
            Button {
                SpeechReader.shared.toggle(id: "\(timerEngine.recipeTitle)-\(stepNumber)", text: stepText)
            } label: {
                Image(systemName: SpeechReader.shared.speakingID == "\(timerEngine.recipeTitle)-\(stepNumber)"
                      ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .scaledFont(13)
                    .foregroundStyle(SpeechReader.shared.speakingID == "\(timerEngine.recipeTitle)-\(stepNumber)"
                                     ? session.accentColor : session.themeSecondaryText)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .a11yButton(SpeechReader.shared.speakingID == "\(timerEngine.recipeTitle)-\(stepNumber)" ? "Stop reading step \(stepNumber)" : "Read step \(stepNumber) aloud")
        }
    }
}

/// Tappable timer state chip: start → running countdown (tap to pause) →
/// paused (tap to resume) → done (tap to reset). Starting a timer also
/// schedules a local notification and a Live Activity via StepTimerEngine,
/// so it keeps working after the recipe sheet is dismissed.
struct StepTimerChip: View {
    @Environment(AppSession.self) var session
    let stepIndex: Int
    let stepText: String
    let detectedSeconds: Int?
    let timerEngine: StepTimerEngine
    private var timer: StepTimer? { timerEngine.timers[stepIndex] }
    private var seconds: Int { timer?.remaining ?? detectedSeconds ?? 0 }
    private var actionLabel: String {
        guard let timer else { return "Start timer" }
        return timer.isFinished ? "Reset timer" : timer.isRunning ? "Pause" : timer.remaining == timer.totalSeconds ? "Start timer" : "Resume"
    }
    private var symbol: String {
        guard let timer else { return "timer" }
        return timer.isFinished ? "arrow.counterclockwise" : timer.isRunning ? "pause.fill" : "play.fill"
    }
    private var stateLabel: String {
        guard let timer else { return "Ready" }
        return timer.isFinished ? "Finished" : timer.isRunning ? "Running" : timer.remaining == timer.totalSeconds ? "Ready" : "Paused"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: performAction) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).accessibilityHidden(true)
                    Text(actionLabel).fixedSize(horizontal: false, vertical: true)
                    if timer?.isFinished == true {
                        Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                    } else {
                        Text(CookingTimerPolicy.display(seconds)).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .scaledFont(14, weight: .semibold)
                .foregroundStyle(session.accentColor)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(minHeight: 44)
                .stockedPastelCard(radius: StockedUI.cornerRadiusMd)
                .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                    .strokeBorder(session.accentColor.opacity(timer?.isRunning == true ? 0.8 : 0.35), lineWidth: timer?.isRunning == true ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Step \(stepIndex + 1) timer, \(stateLabel)")
            .accessibilityValue(CookingTimerPolicy.spoken(seconds))
            .accessibilityHint(actionLabel)
            .contextMenu {
                if timer != nil { Button("Reset timer", systemImage: "arrow.counterclockwise") { timerEngine.resetTimer(stepIndex: stepIndex) } }
            }
            .accessibilityAction(named: "Reset timer") { if timer != nil { timerEngine.resetTimer(stepIndex: stepIndex) } }
            if timer == nil {
                Text("From this step. Time ranges use the longer duration.")
                    .scaledFont(11).foregroundStyle(session.themeSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let status = timerEngine.notificationStatus {
                Label(status, systemImage: "bell.slash")
                    .scaledFont(12).foregroundStyle(session.themeSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .stockedAnimation(.selection, intent: .spatial, value: timer?.isRunning)
    }
    private func performAction() {
        HapticManager.select()
        if timer?.isFinished == true { timerEngine.resetTimer(stepIndex: stepIndex) }
        else if timer?.isRunning == true { timerEngine.pauseTimer(stepIndex: stepIndex) }
        else { timerEngine.startTimer(stepIndex: stepIndex, stepText: stepText) }
    }
}
