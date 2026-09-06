import Foundation
import Speech
import AVFoundation
import Observation

/// Recognition, synthesis and clip playback.
///
/// Recognition is treated as a draft, never as truth: the transcript goes to
/// the learner to confirm before anything is assessed.
@MainActor
@Observable
final class Voice: NSObject, SpeechIO {

    private(set) var partial = ""
    private(set) var isListening = false

    private let engine = AVAudioEngine()
    private var recogniser: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?

    enum Trouble: LocalizedError {
        case denied
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                return "Microphone or speech access is off. Turn it on in Settings."
            case .unavailable(let locale):
                return "Speech recognition is not available for \(locale) on this device."
            }
        }
    }

    func requestAccess() async -> Bool {
        let speech = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await withCheckedContinuation { done in
            AVAudioApplication.requestRecordPermission { done.resume(returning: $0) }
        }
    }

    func startListening(locale: String) throws {
        stopEngine()

        guard let recogniser = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recogniser.isAvailable else {
            throw Trouble.unavailable(locale)
        }
        self.recogniser = recogniser

        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
        try audio.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device where the locale supports it: faster, and nothing leaves
        // the phone.
        request.requiresOnDeviceRecognition = recogniser.supportsOnDeviceRecognition
        self.request = request

        partial = ""
        task = recogniser.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            Task { @MainActor in self.partial = result.bestTranscription.formattedString }
        }

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
        isListening = true
    }

    @discardableResult
    func stopListening() -> String {
        stopEngine()
        isListening = false
        return partial
    }

    private func stopEngine() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func speak(_ text: String, locale: String) {
        guard !text.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: locale)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synth.speak(utterance)
    }

    /// Real recordings where a clip exists, synthesis otherwise. The learner is
    /// told which they are hearing; the store is not involved either way.
    func play(_ source: AudioSource) async throws {
        guard source.kind == .recording, let url = source.url else { return }
        let (data, _) = try await URLSession.shared.data(from: url)
        try AVAudioSession.sharedInstance().setCategory(.playback, options: .duckOthers)
        try AVAudioSession.sharedInstance().setActive(true)
        player = try AVAudioPlayer(data: data)
        player?.play()
    }
}
