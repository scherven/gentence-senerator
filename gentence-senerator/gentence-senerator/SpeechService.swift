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

    // PCM accumulator for WAV writing (thread-safe, lock-protected)
    private var currentPCMCapture: PCMCapture?
    private var pendingRecordingURL: URL?

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

        // Install audio tap — converts hardware buffers (float32 44.1/48kHz) to
        // 16kHz 16-bit mono PCM using AVAudioConverter, accumulates raw PCM bytes,
        // and writes a proper WAV file in stopRecording().
        //
        // prepare() must be called before reading outputFormat — the engine must be
        // configured so that inputNode reports a valid sample rate / channel count.
        audioEngine.prepare()

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw SpeechError.audioEngineFailure(
                NSError(domain: "SpeechService", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Audio input format is invalid (sampleRate=\(hardwareFormat.sampleRate), channels=\(hardwareFormat.channelCount))"]))
        }

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16000,
                                         channels: 1,
                                         interleaved: true)!

        guard let audioConverter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw SpeechError.audioEngineFailure(
                NSError(domain: "SpeechService", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Could not create 16kHz audio converter"]))
        }

        let filename = UUID().uuidString + ".wav"
        let fileURL = SpeechService.audioRecordingsDirectory().appendingPathComponent(filename)
        pendingRecordingURL = fileURL
        lastRecordingURL = nil

        let capture = PCMCapture()
        currentPCMCapture = capture

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { buffer, _ in
            request.append(buffer)

            let inputFrames = buffer.frameLength
            guard inputFrames > 0 else { return }
            let ratio = 16000.0 / hardwareFormat.sampleRate
            let outputFrames = AVAudioFrameCount(max(1, UInt32((Double(inputFrames) * ratio).rounded(.up))))
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else { return }

            var didProvide = false
            let status = audioConverter.convert(to: outBuffer, error: nil) { _, outStatus in
                if didProvide { outStatus.pointee = .noDataNow; return nil }
                didProvide = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, outBuffer.frameLength > 0,
                  let channelData = outBuffer.int16ChannelData else { return }
            let bytes = Data(bytes: channelData[0], count: Int(outBuffer.frameLength) * 2)
            capture.append(bytes)
        }

        do {
            try audioEngine.start()
        } catch {
            throw SpeechError.audioEngineFailure(error)
        }

        isRecording = true
    }

    func stopRecording() async -> String {
        // Snapshot before stopRecordingInternal clears state
        let captureSnapshot = currentPCMCapture
        let fileURL = pendingRecordingURL
        currentPCMCapture = nil
        pendingRecordingURL = nil

        stopRecordingInternal()

        // audioEngine.stop() is synchronous — no more tap callbacks after this point.
        // Safe to read accumulated PCM and write the WAV file.
        if let fileURL, let capture = captureSnapshot {
            let pcm = capture.finalize()
            if !pcm.isEmpty {
                let wav = buildWAVData(pcm: pcm)
                try? wav.write(to: fileURL)
                lastRecordingURL = fileURL
                print("[SpeechService] Wrote WAV: \(fileURL.lastPathComponent) (\(wav.count) bytes, \(pcm.count / 32000)s)")
            }
        }

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
        currentPCMCapture = nil
        pendingRecordingURL = nil
        stopRecordingInternal()
        isRecording = false
        transcript = ""
    }

    // MARK: - WAV Construction

    private func buildWAVData(pcm: Data) -> Data {
        var wav = Data()
        let pcmSize = UInt32(pcm.count)
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        func u32(_ v: UInt32) { wav.append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
        func u16(_ v: UInt16) { wav.append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }

        wav.append(contentsOf: "RIFF".utf8); u32(36 + pcmSize)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8); u32(16)
        u16(1); u16(channels); u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        wav.append(contentsOf: "data".utf8); u32(pcmSize)
        wav.append(pcm)
        return wav
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

// MARK: - Thread-safe PCM accumulator

/// Collects converted 16-bit PCM chunks from the audio tap (background thread)
/// and provides a snapshot for WAV writing on the main thread.
private final class PCMCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []

    func append(_ data: Data) {
        lock.withLock { chunks.append(data) }
    }

    /// Returns accumulated PCM and clears the buffer.
    func finalize() -> Data {
        lock.withLock {
            var result = Data()
            for chunk in chunks { result.append(chunk) }
            chunks.removeAll()
            return result
        }
    }
}
