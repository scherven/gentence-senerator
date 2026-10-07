import Foundation

/// What was done each day, per language, for the History calendar. Kept apart
/// from sessions and quiz scores because both of those are trimmed; this is
/// three flags a day and is not.
struct ActivityLog: Codable, Hashable {
    enum Mark: String, Codable, Hashable, CaseIterable {
        case translate, produce, quiz
    }

    /// "yyyy-MM-dd|<language>" → what was done.
    var days: [String: Set<Mark>] = [:]

    static func key(_ day: Date, _ language: Language) -> String {
        "\(Spend.key(day))|\(language.rawValue)"
    }

    func marks(on day: Date, _ language: Language) -> Set<Mark> {
        days[Self.key(day, language)] ?? []
    }

    /// Returns whether anything changed, so callers only save when it did.
    @discardableResult
    mutating func add(_ mark: Mark, on day: Date, _ language: Language) -> Bool {
        days[Self.key(day, language), default: []].insert(mark).inserted
    }

    /// A translate or produce session counts once its set was finished, even
    /// if a raised goal later reopened it.
    static func mark(for session: Session) -> Mark? {
        guard session.isComplete || (session.filed ?? 0) > 0 else { return nil }
        switch session.mode {
        case .translate: return .translate
        case .produce:   return .produce
        default:         return nil
        }
    }

    /// The day a session belongs to is the one in its id, not when it ended.
    static func day(of session: Session) -> String { String(session.id.prefix(10)) }

    @discardableResult
    mutating func add(_ session: Session) -> Bool {
        guard let mark = Self.mark(for: session) else { return false }
        let key = "\(Self.day(of: session))|\(session.language.rawValue)"
        return days[key, default: []].insert(mark).inserted
    }

    enum Shade { case none, some, all }

    static func shade(_ marks: Set<Mark>) -> Shade {
        marks.isEmpty ? .none : marks.count == Mark.allCases.count ? .all : .some
    }

    /// Translate, produce, quiz: which were done, in cell order.
    static func ticks(_ marks: Set<Mark>) -> [Bool] { Mark.allCases.map(marks.contains) }
}

// MARK: - Scores

/// Every graded translate and produce answer's score, by turn id. Kept apart
/// from the archive for the same reason as `ActivityLog`: sessions are trimmed.
struct ScoreLog: Codable, Hashable {
    struct Entry: Codable, Hashable {
        /// "yyyy-MM-dd", the day the answer was given.
        let day: String
        let language: Language
        let score: Int
    }

    var turns: [String: Entry] = [:]

    @discardableResult
    mutating func add(_ turn: Turn) -> Bool {
        guard turn.mode != .listen, let score = turn.review?.score else { return false }
        let entry = Entry(day: Spend.key(turn.createdAt), language: turn.language, score: score)
        guard turns[turn.id.uuidString] != entry else { return false }
        turns[turn.id.uuidString] = entry
        return true
    }

    /// Mean score over days in `from...through` ("yyyy-MM-dd", inclusive).
    func average(_ language: Language, from: String = "", through: String = "9999") -> Int? {
        let scores = turns.values
            .filter { $0.language == language && $0.day >= from && $0.day <= through }
            .map(\.score)
        return scores.isEmpty ? nil : scores.reduce(0, +) / scores.count
    }
}

// MARK: - History

/// One day of the History archive, in one language: sessions and quiz rounds,
/// newest first.
struct HistoryDay: Identifiable, Hashable {
    /// "yyyy-MM-dd". Also the calendar's scroll target.
    let day: String
    var rows: [Row]
    var id: String { day }

    enum Row: Identifiable, Hashable {
        case session(Session)
        /// A finished quiz round, named after its chapter when it has one.
        case quiz(name: String, score: QuizLog.Score)

        var id: String {
            switch self {
            case .session(let s): return s.id
            case .quiz(let name, let score): return "quiz|\(name)|\(score.at.timeIntervalSince1970)"
            }
        }

        var at: Date {
            switch self {
            case .session(let s): return s.startedAt
            case .quiz(_, let score): return score.at
            }
        }
    }

    /// "SEP 28".
    var label: String { Self.label(day) }

    static func label(_ day: String) -> String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let date = parse.date(from: day) else { return day }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "MMM d"
        return out.string(from: date).uppercased()
    }

    /// `archive` holds every language; `quizzes` is the quiz log's plans,
    /// keyed "<language>|<plan id>". Days before `today` only: today's work is
    /// on the main screen.
    static func build(archive: [ArchiveDay], quizzes: [String: QuizLog.PlanRecord],
                      language: Language, today: String,
                      name: (String) -> String) -> [HistoryDay] {
        var byDay: [String: [Row]] = [:]
        for day in archive {
            let mine = day.sessions.filter { $0.language == language }
            if !mine.isEmpty { byDay[day.day, default: []] += mine.map(Row.session) }
        }
        let prefix = "\(language.rawValue)|"
        for (key, plan) in quizzes where key.hasPrefix(prefix) {
            let planName = name(String(key.dropFirst(prefix.count)))
            for score in plan.scores {
                let day = Spend.key(score.at)
                guard day < today else { continue }
                byDay[day, default: []].append(.quiz(name: planName, score: score))
            }
        }
        return byDay
            .map { HistoryDay(day: $0.key, rows: $0.value.sorted { $0.at > $1.at }) }
            .sorted { $0.day > $1.day }
    }
}

extension Session {
    /// The first thing the learner wrote in the sitting.
    var firstAnswer: String? {
        turns.lazy.map(\.attempt.confirmed).first { !$0.isEmpty }
    }

    var isGraded: Bool { turns.contains { $0.review != nil } }
}
