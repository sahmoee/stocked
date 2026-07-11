// SpeechReader.swift — hands-free step read-aloud for cooking mode (#C5).
//
// Wraps AVSpeechSynthesizer as a single shared reader: tapping a step's speaker
// icon reads that step; tapping again (or reading another step) stops the first.
// Kept deliberately simple — no queueing, no voice settings — flour-covered hands
// need one tap, not a menu.
import AVFoundation
import Observation

@Observable
@MainActor
final class SpeechReader {
    static let shared = SpeechReader()

    private let synthesizer = AVSpeechSynthesizer()
    /// Which step is currently being spoken (nil = silent). Views observe this to
    /// swap the speaker icon.
    private(set) var speakingID: String? = nil

    private init() {}

    func toggle(id: String, text: String) {
        if speakingID == id {
            stop()
            return
        }
        stop()
        // Play through the speaker even if the ringer is silenced — a cooking timer
        // context; mixWithOthers so background music ducks rather than dies.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synthesizer.speak(utterance)
        speakingID = id
        // Clear the flag when this utterance would have finished (approximate; the
        // delegate API needs an NSObject subclass — this keeps the type tiny and the
        // icon resets on the next toggle either way).
        let estimate = Double(text.count) * 0.065 + 1.0
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(estimate * 1_000_000_000))
            if self?.speakingID == id, self?.synthesizer.isSpeaking == false {
                self?.speakingID = nil
            }
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingID = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
