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
                                 options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
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
        guard Date().timeIntervalSince(lastCommandAt) > 1.2 else { return }
        // Only look at the tail of the transcript so old words don't re-fire.
        let tail = text.split(separator: " ").suffix(4).joined(separator: " ")

        let command: VoiceCookCommand?
        if tail.contains("finish") || tail.contains("done cooking") || tail.contains("end cooking") {
            command = .finish
        } else if tail.hasSuffix("next") || tail.contains("next step") || tail.hasSuffix("continue") {
            command = .next
        } else if tail.hasSuffix("back") || tail.contains("go back") || tail.contains("previous") {
            command = .back
        } else if tail.contains("repeat") || tail.contains("read that") || tail.contains("say again") {
            command = .repeatStep
        } else {
            command = nil
        }
        if let command {
            lastCommandAt = Date()
            HapticManager.select()
            onCommand?(command)
            // Restart the transcript so the same word can be used again later.
            if isListening { beginSession() }
        }
    }
}
