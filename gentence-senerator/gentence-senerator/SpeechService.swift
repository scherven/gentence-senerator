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
    @Published var lastRecordingURL: URL?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let synthDelegate = SynthDelegate()

    /// Folder inside Documents where all recorded attempts are stored.
    static func audioRecordingsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("AudioRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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

    private var currentUtteranceID: Int = 0

    // MARK: - Init

    init() {
        synthesizer.delegate = synthDelegate
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

        // Stop any ongoing TTS before switching the audio session to recording mode.
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false

        // Stop any existing session
        stopRecordingInternal()
        transcript = ""
        error = nil
        lastRecordingURL = nil

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

        // Install audio tap — also writes buffers to a .caf file for later analysis
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        let filename = UUID().uuidString + ".caf"
        let fileURL = SpeechService.audioRecordingsDirectory().appendingPathComponent(filename)
        // Capture the AVAudioFile as a local so the background tap thread never touches MainActor state.
        let capturedFile: AVAudioFile? = try? AVAudioFile(forWriting: fileURL,
                                                          settings: recordingFormat.settings)
        lastRecordingURL = capturedFile != nil ? fileURL : nil

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
            try? capturedFile?.write(from: buffer)
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

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Immediately stops an in-progress recording without waiting for final results.
    /// Use when the session is being abandoned (e.g. tab switch, mode change).
    func cancelRecording() {
        stopRecordingInternal()
        isRecording = false
        transcript = ""
    }

    func resetTranscript() {
        transcript = ""
        error = nil
    }

    // MARK: - Text-to-Speech

    func speak(text: String, language: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Increment utterance ID before stopping old speech so the stale didCancel
        // callback fires with an old closure (captured myID won't match currentUtteranceID).
        currentUtteranceID += 1
        let myID = currentUtteranceID

        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Audio session setup failed — abort so isSpeaking is never left stuck true.
            isSpeaking = false
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: localeMap[language] ?? "zh-CN")
        utterance.rate = 0.45   // slightly slower than default for language learners
        utterance.pitchMultiplier = 1.0

        isSpeaking = true
        synthesizer.speak(utterance)

        // Set onDidFinish AFTER stopSpeaking so any didCancel for the old utterance
        // calls the previous closure (stale myID → guard fails → no-op).
        synthDelegate.onDidFinish = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.currentUtteranceID == myID else { return }
                self.isSpeaking = false
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        // isSpeaking is set to false via the delegate callback
    }
}
