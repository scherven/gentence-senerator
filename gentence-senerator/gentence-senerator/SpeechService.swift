import Foundation
import Speech
import AVFoundation

// MARK: - TTS Delegate (bridges AVSpeechSynthesizerDelegate → SpeechService)

private final class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onDidFinish: () -> Void = {}
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onDidFinish()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onDidFinish()
    }
}

// MARK: - Errors

enum SpeechError: Error, LocalizedError {
    case notAuthorized
    case micNotAuthorized
    case audioEngineFailure(Error)
    case recognitionUnavailable
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition permission denied. Please enable in Settings."
        case .micNotAuthorized: return "Microphone permission denied. Please enable in Settings."
        case .audioEngineFailure(let e): return "Audio engine error: \(e.localizedDescription)"
        case .recognitionUnavailable: return "Speech recognition is not available for this language on your device."
        case .noSpeechDetected: return "No speech was detected. Please try again."
        }
    }
}

// MARK: - Speech Service

@MainActor
class SpeechService: ObservableObject {

    @Published var isRecording: Bool = false
    @Published var transcript: String = ""
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published var micAuthorized: Bool = false
    @Published var error: SpeechError?
    @Published var isSpeaking: Bool = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let synthDelegate = SynthDelegate()

    // Language → Locale mapping
    private let localeMap: [String: String] = [
        "Mandarin":   "zh-CN",
        "French":     "fr-FR",
        "German":     "de-DE",
        "Spanish":    "es-ES",
        "Italian":    "it-IT",
        "Portuguese": "pt-BR",
        "Japanese":   "ja-JP",
        "Korean":     "ko-KR"
    ]

    // MARK: - Init

    init() {
        synthesizer.delegate = synthDelegate
        synthDelegate.onDidFinish = { [weak self] in
            Task { @MainActor [weak self] in
                self?.isSpeaking = false
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        // Speech recognition
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        authorizationStatus = speechStatus

        // Microphone
        let micStatus = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        micAuthorized = micStatus
    }

    var isFullyAuthorized: Bool {
        authorizationStatus == .authorized && micAuthorized
    }

    // MARK: - Recording

    func startRecording(language: String) throws {
        guard authorizationStatus == .authorized else { throw SpeechError.notAuthorized }
        guard micAuthorized else { throw SpeechError.micNotAuthorized }

        // Stop any existing session
        stopRecordingInternal()
        transcript = ""
        error = nil

        let localeIdentifier = localeMap[language] ?? "zh-CN"
        let locale = Locale(identifier: localeIdentifier)

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechError.recognitionUnavailable
        }
        self.speechRecognizer = recognizer

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw SpeechError.audioEngineFailure(error)
        }

        // Set up recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        self.recognitionRequest = request

        // Start recognition task
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                Task { @MainActor in
                    self.transcript = result.bestTranscription.formattedString
                }
            }
            if let error = error {
                Task { @MainActor in
                    self.isRecording = false
                    // Don't surface cancellation errors
                    let nsError = error as NSError
                    if nsError.domain != "kAFAssistantErrorDomain" || nsError.code != 216 {
                        self.error = .audioEngineFailure(error)
                    }
                }
            }
        }

        // Install audio tap
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw SpeechError.audioEngineFailure(error)
        }

        isRecording = true
    }

    func stopRecording() async -> String {
        stopRecordingInternal()
        // Brief pause to allow final result to arrive
        try? await Task.sleep(nanoseconds: 300_000_000)
        let final = transcript
        isRecording = false
        return final.isEmpty ? "" : final
    }

    private func stopRecordingInternal() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func resetTranscript() {
        transcript = ""
        error = nil
    }

    // MARK: - Text-to-Speech

    func speak(text: String, language: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Stop any ongoing playback first
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Non-fatal — TTS may still work on some devices without explicit session config
        }

        let localeIdentifier = localeMap[language] ?? "zh-CN"
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: localeIdentifier)
        utterance.rate = 0.45   // slightly slower than default for language learners
        utterance.pitchMultiplier = 1.0

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        // isSpeaking is set to false via the delegate callback
    }
}
