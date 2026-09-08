import Foundation

/// Two mechanisms, deliberately separate:
/// **repetition** works on what went wrong; **reach** works on what never
/// appears at all and so produces no errors to learn from.
struct Progress: Codable, Hashable {
    var encounters: [String: Encounter] = [:]    // by Atom.id
    var structures: [String: StructureUse] = [:] // by grammar point id
    var xp: Int = 0
    var streak: Int = 0
    var lastPractisedOn: Date?

    // MARK: Repetition

    /// Opening counts as a signal, even when the attempt was correct.
    mutating func opened(_ atom: Atom, language: Language, on day: Date = .now) {
        var e = encounters[atom.id] ?? Encounter(
            atomID: atom.id, kind: atom.kind, subject: atom.seed.subject,
            language: language, firstSeen: day
        )
        e.visits += 1
        e.lastSeen = day
        e.schedule(from: day)
        encounters[atom.id] = e
    }

    mutating func classify(_ atom: Atom, as verdict: Encounter.Knowledge,
                           language: Language, on day: Date = .now) {
        var e = encounters[atom.id] ?? Encounter(
            atomID: atom.id, kind: atom.kind, subject: atom.seed.subject,
            language: language, firstSeen: day
        )
        e.knowledge = verdict
        e.lastSeen = day
        e.schedule(from: day)
        encounters[atom.id] = e
    }

    func visits(to atomID: String) -> Int { encounters[atomID]?.visits ?? 0 }

    /// The learner choosing, off the day's summary, what comes back. Overrides
    /// the slip rule — one recall check is the default there, not a cap.
    mutating func bringBack(_ atom: Atom, language: Language, on day: Date = .now) {
        var e = encounters[atom.id] ?? Encounter(
            atomID: atom.id, kind: atom.kind, subject: atom.seed.subject,
            language: language, firstSeen: day
        )
        let step = Encounter.ladder[min(e.stage, Encounter.ladder.count - 1)]
        e.dueAt = Encounter.due(in: step, from: day)
        e.stage += 1
        e.lastSeen = day
        encounters[atom.id] = e
    }

    /// Taken back off the schedule. The encounter stays — visits and slip-or-gap
    /// are still true, it just isn't coming back.
    mutating func leaveOut(_ atomID: String) {
        encounters[atomID]?.dueAt = nil
    }

    func returns(_ atomID: String) -> Bool { encounters[atomID]?.dueAt != nil }
    func dueLabel(_ atomID: String) -> String? {
        guard let e = encounters[atomID], e.dueAt != nil else { return nil }
        return e.dueLabel
    }

    func due(on day: Date = .now, language: Language) -> [Encounter] {
        encounters.values
            .filter { $0.language == language && $0.dueAt.map { $0 <= day } == true }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }

    /// Woven into generated sentences, not served as cards.
    func seedsForGeneration(language: Language, limit: Int = 3) -> [String] {
        let subjects = due(on: .now, language: language).map(\.subject)
        return Array(subjects.prefix(limit))
    }

    // MARK: Reach

    mutating func attempted(pointID: String, language: Language, succeeded: Bool) {
        var u = structures[pointID] ?? StructureUse(pointID: pointID, language: language)
        u.attempts += 1
        if succeeded { u.successes += 1 }
        u.lastAttempted = .now
        structures[pointID] = u
    }

    /// A point has three states, not two, and only the first is a reach signal:
    /// never attempted, attempted and failing, attempted and holding. Something
    /// never attempted produces no errors, so error-driven scheduling can never
    /// surface it.
    ///
    /// Pass points already filtered to what the learner could reach at their
    /// level and in this mode — the passé simple is absent from speech because
    /// that is correct, not because it is missing.
    func neverReached(among candidates: [GrammarPoint]) -> [GrammarPoint] {
        candidates.filter { (structures[$0.id]?.attempts ?? 0) == 0 }
    }

    func state(of pointID: String) -> Reach {
        guard let u = structures[pointID], u.attempts > 0 else { return .neverAttempted }
        return u.successes > 0 ? .holding : .failing
    }

    enum Reach: String, Codable, Hashable {
        case neverAttempted
        case failing
        case holding
    }

    // MARK: Records

    struct Encounter: Identifiable, Codable, Hashable {
        var id: String { atomID }

        let atomID: String
        let kind: AtomKind
        let subject: String
        let language: Language
        let firstSeen: Date
        var lastSeen: Date = .now
        var visits: Int = 0
        var knowledge: Knowledge = .unclassified
        var stage: Int = 0
        var dueAt: Date?

        enum Knowledge: String, Codable, Hashable {
            case unclassified
            case slip   // knew it, misfired
            case gap    // didn't know it
        }

        static let ladder = [1, 3, 7, 16, 35]

        /// Day-aligned, both ends. An interval is a number of days, not a
        /// timestamp: without this a one-day interval reads as "today" the
        /// moment it is set, because the gap to it is a second under 24 hours.
        static func due(in days: Int, from day: Date) -> Date? {
            let calendar = Calendar.current
            return calendar.date(byAdding: .day, value: days,
                                 to: calendar.startOfDay(for: day))
        }

        /// Expanding intervals for gaps; one recall check for slips.
        mutating func schedule(from day: Date) {
            let days: Int
            switch knowledge {
            case .slip:
                guard stage == 0 else { dueAt = nil; return }
                days = 1
            case .gap, .unclassified:
                days = Encounter.ladder[min(stage, Encounter.ladder.count - 1)]
            }
            stage += 1
            dueAt = Encounter.due(in: days, from: day)
        }

        var dueLabel: String {
            guard let dueAt else { return "done" }
            let calendar = Calendar.current
            let days = calendar.dateComponents([.day],
                                               from: calendar.startOfDay(for: .now),
                                               to: calendar.startOfDay(for: dueAt)).day ?? 0
            if days <= 0 { return "today" }
            if days == 1 { return "tomorrow" }
            if days < 14 { return "\(days) days" }
            return "\(days / 7) weeks"
        }
    }

    struct StructureUse: Codable, Hashable {
        let pointID: String
        let language: Language
        var attempts: Int = 0
        var successes: Int = 0
        var lastAttempted: Date?
    }
}
