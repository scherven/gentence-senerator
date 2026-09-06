import Foundation

/// Speech in and out. Behind a protocol so the store can be exercised without
/// a microphone, and so a real-audio listen mode can supply clips instead of
/// synthesis without the store knowing.
@MainActor
protocol SpeechIO: AnyObject {
    /// Live partial transcript while listening.
    var partial: String { get }
    var isListening: Bool { get }
    /// The last attempt as 16 kHz mono PCM, for pronunciation assessment.
    var lastRecording: URL? { get }

    func requestAccess() async -> Bool
    func startListening(locale: String) throws
    /// Returns the final transcript.
    func stopListening() -> String
    func speak(_ text: String, locale: String)
    func play(_ source: AudioSource) async throws
}
