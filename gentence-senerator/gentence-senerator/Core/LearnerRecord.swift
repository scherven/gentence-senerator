import Foundation

/// What the learner has done, per grammar point and as one feed across every
/// mode. Every mode writes here; the point page and the feed read nothing else.
///
/// Scheduling stays in `Progress` and `QuizLog`. This keeps the evidence those
/// reduce to counts, so it survives the archive being trimmed.
struct LearnerRecord: Codable, Hashable {
    /// By `key(language, pointID)`.
    var points: [String: PointRecord] = [:]
    /// Oldest first, at most `feedCap`.
    var feed: [FeedItem] = []

    static let feedCap = 600
    static let pointCap = 20

    static func key(_ language: Language, _ pointID: String) -> String {
        "\(language.rawValue)|\(pointID)"
    }

    struct PointRecord: Codable, Hashable {
        /// Oldest first, at most `pointCap`.
        var uses: [Use] = []
        /// Oldest first, at most `pointCap`.
        var quiz: [Mark] = []

        init(uses: [Use] = [], quiz: [Mark] = []) { self.uses = uses; self.quiz = quiz }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uses = (try? c.decodeIfPresent([Use].self, forKey: .uses)) ?? []
            quiz = (try? c.decodeIfPresent([Mark].self, forKey: .quiz)) ?? []
        }

        /// The newest production use, if it was not clean.
        var lastUseFailed: Bool { uses.last.map { $0.verdict != .clean } ?? false }
    }

    enum Verdict: String, Codable, Hashable {
        case clean, weakens, breaks
    }

    /// One sentence of the learner's that used, was asked for, or was found
    /// wrong on a point.
    struct Use: Codable, Hashable {
        var turnID: UUID
        var at: Date
        var mode: Mode
        var source: Source
        var verdict: Verdict
        var sentence: String
        /// The correction, when one of its findings was on this point.
        var fix: String = ""

        enum Source: String, Codable, Hashable {
            /// The prompt asked for it.
            case asked
            /// The review tagged it as used.
            case used
            /// Only a finding named it.
            case finding
        }
    }

    /// One quiz answer on one of the point's entries.
    struct Mark: Codable, Hashable {
        var entryID: String
        var right: Bool
        var at: Date
        var prompt: String?
        /// What was right, steps joined.
        var answer: String
        var given: String
    }

    struct FeedItem: Codable, Hashable, Identifiable {
        var id: String
        var at: Date
        var language: Language
        var kind: Kind
        /// The sentence, the round or the dialogue.
        var title: String
        /// The fix, a score line, the misses.
        var detail: String = ""
        var verdict: Verdict?
        var score: Int?
        var points: [String] = []
        /// Produce, translate and listen: the turn, to open its review.
        var turnID: UUID?
        /// Quiz and words: the plan, for its name; answers so far.
        var planID: String?
        var right = 0
        var total = 0

        enum Kind: String, Codable, Hashable {
            case translate, produce, listen, quiz, words, talk, reply
        }
    }
}

// MARK: - Writing

extension LearnerRecord {

    /// A graded answer. Listen clips are dictation: fed, but no point uses.
    mutating func note(_ turn: Turn, review: Review) {
        let sentence = turn.attempt.confirmed
        let problems = review.problems
        var touched: [(String, Use.Source)] = []
        if turn.mode != .listen {
            if let asked = turn.prompt.pointID { touched.append((asked, .asked)) }
            for p in review.usedPoints where !touched.contains(where: { $0.0 == p }) {
                touched.append((p, .used))
            }
            for p in problems.compactMap(\.seed.pointID) where !touched.contains(where: { $0.0 == p }) {
                touched.append((p, .finding))
            }
        }
        for (pointID, source) in touched {
            let on = problems.filter { $0.seed.pointID == pointID }
            let use = Use(turnID: turn.id, at: turn.createdAt, mode: turn.mode, source: source,
                          verdict: Self.worst(on), sentence: sentence,
                          fix: on.first { !$0.stages.fix.isEmpty }?.stages.fix ?? "")
            var r = points[Self.key(turn.language, pointID)] ?? PointRecord()
            r.uses.removeAll { $0.turnID == turn.id }
            r.uses = Array((r.uses + [use]).sorted { $0.at < $1.at }.suffix(Self.pointCap))
            points[Self.key(turn.language, pointID)] = r
        }
        let kind: FeedItem.Kind = turn.mode == .translate ? .translate
            : turn.mode == .produce ? .produce
            : turn.mode == .reply ? .reply
            : turn.mode == .converse ? .talk : .listen
        let first = problems.first { $0.weight == .start } ?? problems.first
        put(FeedItem(id: turn.id.uuidString, at: turn.createdAt, language: turn.language,
                     kind: kind, title: sentence,
                     detail: first?.stages.fix ?? "",
                     verdict: Self.worst(problems), score: review.score,
                     points: touched.map(\.0), turnID: turn.id))
    }

    /// One quiz answer. `pointID` is its entry's point; words have none.
    mutating func note(_ item: QuizItem, answer: QuizRound.Answer, pointID: String?,
                       planID: String, roundID: String, language: Language, words: Bool,
                       miss: String, at: Date = .now) {
        if let pointID {
            let mark = Mark(entryID: item.entry, right: answer.right, at: at, prompt: item.prompt,
                            answer: QuizRound.expected(item).joined(separator: " · "),
                            given: answer.given.joined(separator: " · "))
            var r = points[Self.key(language, pointID)] ?? PointRecord()
            r.quiz = Array((r.quiz + [mark]).suffix(Self.pointCap))
            points[Self.key(language, pointID)] = r
        }
        tallyRound(id: roundID, at: at, language: language, words: words, planID: planID,
                   right: answer.right, miss: miss, pointID: pointID)
    }

    /// Concept-deck marks: one per language, all on one feed line a day.
    mutating func noteWords(_ marks: [(word: String, right: Bool)], language: Language, at: Date = .now) {
        for m in marks {
            tallyRound(id: "words|\(Spend.key(at))", at: at, language: language, words: true,
                       planID: "concepts", right: m.right, miss: m.word, pointID: nil)
        }
    }

    /// A finished dialogue.
    mutating func noteListen(_ turn: Turn, review: Review) {
        put(FeedItem(id: turn.id.uuidString, at: turn.createdAt, language: turn.language,
                     kind: .listen, title: turn.prompt.target ?? "", detail: review.readOfScore,
                     verdict: nil, score: review.score, turnID: turn.id))
    }

    private mutating func tallyRound(id: String, at: Date, language: Language, words: Bool,
                                     planID: String, right: Bool, miss: String, pointID: String?) {
        let key = "\(language.rawValue)|\(id)"
        var item = feed.last { $0.id == key } ?? FeedItem(
            id: key, at: at, language: language, kind: words ? .words : .quiz,
            title: "", planID: planID)
        item.total += 1
        if right { item.right += 1 }
        else if !miss.isEmpty {
            let missed = item.detail.isEmpty ? [] : item.detail.components(separatedBy: " · ")
            if !missed.contains(miss) { item.detail = (missed + [miss]).joined(separator: " · ") }
        }
        if let pointID, !item.points.contains(pointID) { item.points.append(pointID) }
        item.at = at
        put(item)
    }

    private mutating func put(_ item: FeedItem) {
        feed.removeAll { $0.id == item.id }
        feed.append(item)
        if feed.count > Self.feedCap { feed.removeFirst(feed.count - Self.feedCap) }
    }

    static func worst(_ atoms: [Atom]) -> Verdict {
        atoms.contains { $0.verdict == .breaks } ? .breaks
            : atoms.contains { $0.verdict == .weakens } ? .weakens : .clean
    }
}

// MARK: - Reading

extension LearnerRecord {

    func point(_ pointID: String, _ language: Language) -> PointRecord {
        points[Self.key(language, pointID)] ?? PointRecord()
    }

    /// One line of a point's results, newest first in `results`.
    enum Result: Hashable {
        case use(Use)
        case mark(Mark)

        var at: Date {
            switch self {
            case .use(let u): return u.at
            case .mark(let m): return m.at
            }
        }
    }

    func results(_ pointID: String, _ language: Language) -> [Result] {
        let r = point(pointID, language)
        return (r.uses.map(Result.use) + r.quiz.map(Result.mark)).sorted { $0.at > $1.at }
    }

    func feed(_ language: Language) -> [FeedItem] {
        feed.filter { $0.language == language }.reversed()
    }
}

// MARK: - Building from what is already stored

extension LearnerRecord {

    /// Once, on the first launch with a record: every graded turn still in
    /// the archive, and every finished quiz round. Quiz answers kept no text
    /// or dates, so points start with no marks.
    static func built(from sessions: [Session], quizzes: [String: QuizLog.PlanRecord]) -> LearnerRecord {
        var r = LearnerRecord()
        var seen: Set<UUID> = []
        let turns = sessions.flatMap(\.turns).sorted { $0.createdAt < $1.createdAt }
        for turn in turns where seen.insert(turn.id).inserted {
            guard let review = turn.review, !turn.attempt.confirmed.isEmpty else { continue }
            // A dialogue files its title as the answer.
            if turn.mode == .listen, turn.prompt.target == turn.attempt.confirmed {
                r.noteListen(turn, review: review)
            } else {
                r.note(turn, review: review)
            }
        }
        for (key, plan) in quizzes {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let language = Language(rawValue: parts[0]) else { continue }
            for score in plan.scores {
                r.put(FeedItem(id: "\(key)|\(score.at.timeIntervalSinceReferenceDate)", at: score.at,
                               language: language,
                               kind: parts[1].contains("vocab") ? .words : .quiz,
                               title: "", planID: parts[1], right: score.right, total: score.total))
            }
        }
        r.feed.sort { $0.at < $1.at }
        return r
    }
}

extension LearnerRecord {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = (try? c.decodeIfPresent([String: PointRecord].self, forKey: .points)) ?? [:]
        feed = (try? c.decodeIfPresent([FeedItem].self, forKey: .feed)) ?? []
    }
}

extension Vault {
    static let record = "record.v1"
}
