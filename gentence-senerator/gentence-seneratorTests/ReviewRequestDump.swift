import Testing
import Foundation
@testable import gentence_senerator

/// Writes the exact review request the app would batch for each scenario in
/// tools/eval/scenarios.json, so tools/eval/review_eval.py replays the real
/// prompt and schema rather than a copy. Does nothing when the file is absent.
struct ReviewRequestDump {

    struct Scenario: Decodable {
        var id: String
        var lang: String
        var mode: String
        var level: Int
        var typed: Bool
        var english: String?
        var target: String?
        var said: String
    }

    static let eval = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/eval")

    @Test func dumpReviewRequests() async throws {
        let source = Self.eval.appendingPathComponent("scenarios.json")
        guard let data = try? Data(contentsOf: source) else { return }
        let scenarios = try JSONDecoder().decode([Scenario].self, from: data)
        let tutor = Tutor(api: Anthropic())
        var out: [String: Any] = [:]
        for s in scenarios {
            let language = try #require(Language(rawValue: s.lang))
            let mode = try #require(Mode(rawValue: s.mode))
            let turn = Turn(id: UUID(), mode: mode, language: language, createdAt: .now,
                            prompt: .init(english: s.english, target: s.target, audioSource: nil, pointID: nil),
                            attempt: .init(heard: s.said, confirmed: s.said, wasTyped: s.typed,
                                           audioFilename: nil, pronunciation: nil),
                            review: nil)
            out[s.id] = tutor.reviewParams(turn: turn, history: [], level: s.level)
        }
        try Schemas.data(out).write(to: Self.eval.appendingPathComponent("requests.json"))
    }
}
