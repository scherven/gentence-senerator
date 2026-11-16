import Foundation

/// A typed conversation with someone the model plays. A scene with a goal,
/// then lines back and forth until the goal is met, the cap is reached or the
/// learner ends it. Nothing is corrected while it runs: every learner line is
/// graded afterwards, in one batch, as a `.converse` session.
struct Conversation: Codable, Identifiable, Hashable {
    let id: UUID
    var language: Language
    var level: Int
    var startedAt: Date
    var scene: Scene
    var lines: [Line]
    /// Set once the partner has closed it, or the learner did.
    var ended = false
    var goalMet = false

    /// Learner lines, at most. The partner closes on the last one.
    static let cap = 10

    struct Scene: Codable, Hashable {
        /// Where, in the target language: "Elektromarkt".
        var place: String
        /// English from here to `them`: the brief is read before speaking, and
        /// target-language words in it would hand the learner their lines.
        var you: String
        var want: String
        var them: String
        /// Who they are, in the target language: "Verkäuferin".
        var role: String
        /// Whether the learner should be formal with them (Sie, vous, 您).
        var formal: Bool
        /// Their first line, in the target language.
        var opening: String
    }

    struct Line: Codable, Hashable, Identifiable {
        enum Speaker: String, Codable { case partner, learner }
        /// How the partner answered. Shown only as a count when it ends.
        enum Move: String, Codable { case answer, pushBack = "push back", askAgain = "ask again", close }

        let id: UUID
        var speaker: Speaker
        var text: String
        var move: Move? = nil
    }

    init(language: Language, level: Int, scene: Scene) {
        id = UUID()
        self.language = language
        self.level = level
        startedAt = .now
        self.scene = scene
        lines = [Line(id: UUID(), speaker: .partner, text: scene.opening, move: .answer)]
    }

    var learnerLines: [Line] { lines.filter { $0.speaker == .learner } }
    var turnsLeft: Int { max(0, Self.cap - learnerLines.count) }
    var pushedBack: Int { lines.filter { $0.move == .pushBack }.count }
    var askedAgain: Int { lines.filter { $0.move == .askAgain }.count }

    /// The brief, as the grader and the partner read it.
    var brief: String {
        """
        Place: \(scene.place)
        The learner: \(scene.you)
        They want: \(scene.want)
        The other person (\(scene.role)): \(scene.them)
        Register: \(scene.formal ? "formal" : "informal")
        """
    }

    /// The lines so far, labelled, for a prompt.
    func transcript(upTo end: Int? = nil) -> String {
        lines.prefix(end ?? lines.count).map { line in
            "\(line.speaker == .partner ? scene.role : "Learner"): \(line.text)"
        }.joined(separator: "\n")
    }

    /// One `.converse` turn per learner line: what they answered, the line
    /// they answered, and everything before it as context. Graded one by one.
    func turns() -> [Turn] {
        lines.enumerated().compactMap { index, line in
            guard line.speaker == .learner else { return nil }
            let asked = lines[..<index].last { $0.speaker == .partner }?.text
            let before = lines[..<index].dropLast()
            let context = brief + (before.isEmpty ? "" : "\n\nEarlier:\n" + before.map {
                "\($0.speaker == .partner ? scene.role : "Learner"): \($0.text)"
            }.joined(separator: "\n"))
            return Turn(id: line.id, mode: .converse, language: language,
                        createdAt: startedAt.addingTimeInterval(Double(index)),
                        prompt: .init(english: nil, target: asked, context: context),
                        attempt: .init(heard: line.text, confirmed: line.text, wasTyped: true),
                        exchangeID: UUID())
        }
    }

    /// The archive's copy. Ids are the day, the language and a short tail of
    /// its own, so several in a day stay apart.
    func session() -> Session {
        let turns = turns()
        return Session(id: "\(Spend.key(startedAt))|\(language.rawValue)|converse|\(id.uuidString.prefix(6))",
                       language: language, mode: .converse, startedAt: startedAt,
                       turns: turns, goal: max(turns.count, 1), level: level)
    }
}
