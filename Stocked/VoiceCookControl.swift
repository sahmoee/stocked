// VoiceCookControl.swift
// Hands-free cooking: on-device speech recognition that listens for short
// commands while cooking — "next", "back", "repeat" (reads the step aloud),
// and "finish" / "done cooking". Opt-in via the mic button in the cook screen;
// requires NSMicrophoneUsageDescription + NSSpeechRecognitionUsageDescription
// (added to Info.plist alongside this file).
//
// Design notes:
// - Recognition restarts itself after each recognized phrase so it keeps
//   listening for the whole cook without hitting the ~1 min task ceiling.
// - Everything runs on-device when the device supports it (no audio leaves the
//   phone); falls back to Apple's server recognition otherwise.
// - Commands are matched against the FINAL words of the transcription so
//   kitchen chatter before a command doesn't block it.

import Foundation
import Speech
import AVFoundation
import Observation

enum VoiceCookCommand: String {
    case next, back, repeatStep, finish
}

@Observable
@MainActor
final class VoiceCookControl {
    var isListening = false
    var lastHeard: String = ""
    var authDenied = false

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private var audioEngine: AVAudioEngine? = nil
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest? = nil
    @ObservationIgnored private var task: SFSpeechRecognitionTask? = nil
    @ObservationIgnored private var onCommand: ((VoiceCookCommand) -> Void)? = nil
    @ObservationIgnored private var lastCommandAt: Date = .distantPast
    // #FB2 — continuous listening: instead of tearing the session down after every
    // command (which made only the FIRST "next" work), the transcript keeps running
    // and we only inspect words spoken AFTER the last command fired.
    @ObservationIgnored private var consumedWordCount: Int = 0

    func toggle(onCommand: @escaping (VoiceCookCommand) -> Void) {
        if isListening { stop() } else { start(onCommand: onCommand) }
    }

    func start(onCommand: @escaping (VoiceCookCommand) -> Void) {
        self.onCommand = onCommand
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else { self.authDenied = true; return }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else { self.authDenied = true; return }
                        self.beginSession()
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isListening = false
    }

    private func beginSession() {
        stop()   // clean slate
        guard let recognizer, recognizer.isAvailable else { return }

        let session = AVAudioSession.sharedInstance()
        // .mixWithOthers so step read-aloud + timer sounds keep working while we listen.
        try? session.setCategory(.playAndRecord, mode: .measurement,
                                 options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }
        engine.prepare()
        guard (try? engine.start()) != nil else { return }

        audioEngine = engine
        request = req
        isListening = true
        consumedWordCount = 0   // fresh transcript — nothing consumed yet

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString.lowercased()
                    self.lastHeard = text
                    self.detectCommand(in: text)
                }
                // Session ended (error, final result, or the ~1 min ceiling) — restart
                // if the user still wants to listen.
                if error != nil || (result?.isFinal ?? false) {
                    if self.isListening {
                        self.beginSession()
                    }
                }
            }
        }
    }

    private func detectCommand(in text: String) {
        // Debounce: partial results repeat the same words many times per second.
        guard Date().timeIntervalSince(lastCommandAt) > 0.9 else { return }

        // #FB2 — only look at words spoken AFTER the last fired command. The old
        // approach restarted the whole session per command, which silently killed
        // recognition after the first one; now the transcript keeps running and
        // "next … next … next" fires every time.
        let words = text.split(separator: " ").map { String($0) }
        guard words.count > consumedWordCount else { return }
        let fresh = words.suffix(from: consumedWordCount).suffix(4).joined(separator: " ")

        let command: VoiceCookCommand?
        if fresh.contains("finish") || fresh.contains("done cooking") || fresh.contains("end cooking") {
            command = .finish
        } else if fresh.contains("next") || fresh.contains("continue") {
            command = .next
        } else if fresh.contains("back") || fresh.contains("previous") {
            command = .back
        } else if fresh.contains("repeat") || fresh.contains("read that") || fresh.contains("say again") {
            command = .repeatStep
        } else {
            command = nil
        }
        if let command {
            lastCommandAt = Date()
            consumedWordCount = words.count   // everything up to here is spent
            HapticManager.select()
            onCommand?(command)
        }
    }
}
