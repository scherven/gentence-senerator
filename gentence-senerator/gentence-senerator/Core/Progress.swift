import Foundation

/// Two mechanisms, deliberately separate:
/// **repetition** works on what went wrong; **reach** works on what never
/// appears at all and so produces no errors to learn from.
struct Progress: Codable, Hashable {
    var encounters: [String: Encounter] = [:]    // by Atom.id
    var structures: [String: StructureUse] = [:] // by grammar point id
    /// Band words the learner has produced, by language then word, with how
    /// often. Bounded by the `Lexicon`, which is the only thing that puts
    /// anything in here — all of this lives in `UserDefaults`.
    var words: [String: [String: Int]] = [:]     // language.rawValue → word → times
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

    /// A finding that landed in front of the learner, opened or not. Enough to
    /// know the atom exists and to get it a first date; the ladder moves on
    /// evidence, and reading past something is not evidence.
    mutating func saw(_ atom: Atom, language: Language, on day: Date = .now) {
        if encounters[atom.id] != nil {
            encounters[atom.id]?.sightings += 1
            encounters[atom.id]?.lastSeen = day
            return
        }
        var e = Encounter(
            atomID: atom.id, kind: atom.kind, subject: atom.seed.subject,
            language: language, firstSeen: day
        )
        e.sightings = 1
        // An encounter with no date is invisible to `due`, so a first sighting
        // schedules. Later ones do not, or nothing would ever come back.
        e.schedule(from: day)
        encounters[atom.id] = e
    }

    /// A woven-in subject the review found nothing wrong with: retrieval held,
    /// so up a rung — or off the schedule, once the top rung has held three
    /// times running.
    mutating func retrieved(subject: String, language: Language, on day: Date = .now) {
        for id in encounterIDs(matching: subject, language: language) {
            guard var e = encounters[id], e.standing != .dismissed else { continue }
            e.cleanRuns += 1
            e.lastSeen = day
            if e.atTopRung, e.cleanRuns >= Encounter.cleanRunsToHold {
                e.standing = .held
                e.dueAt = nil
            } else {
                e.schedule(from: day)
            }
            encounters[id] = e
        }
    }

    /// The same subject back and still wrong: down a rung, then round again. A
    /// slip keeps its single check — dropping a rung there would hand it a
    /// second one. A retired encounter comes back: this is the evidence that
    /// retiring it was wrong.
    mutating func missed(subject: String, language: Language, on day: Date = .now) {
        for id in encounterIDs(matching: subject, language: language) {
            guard var e = encounters[id], e.standing != .dismissed else { continue }
            e.cleanRuns = 0
            if e.knowledge != .slip { e.stage = max(0, e.stage - 1) }
            e.lastSeen = day
            e.schedule(from: day)
            encounters[id] = e
        }
    }

    /// Encounters are keyed by atom id, which carries the kind; a subject woven
    /// into a sentence does not, so it is matched on the subject alone and every
    /// kind that shares it counts.
    private func encounterIDs(matching subject: String, language: Language) -> [String] {
        let wanted = subject.lowercased()
        return encounters.values
            .filter { $0.language == language && $0.subject.lowercased() == wanted }
            .map(\.atomID)
    }

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
        e.standing = .active
        encounters[atom.id] = e
    }

    /// Taken back off the schedule. The encounter stays — visits and slip-or-gap
    /// are still true, it just isn't coming back.
    mutating func leaveOut(_ atomID: String) {
        encounters[atomID]?.dueAt = nil
        encounters[atomID]?.standing = .dismissed
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

    /// Where the learner's errors stand. `due` and `failing` answer different
    /// questions — when it comes back, and whether it has ever come back clean
    /// — so one encounter can be both. What the learner dismissed is in none of
    /// them; that was their decision, not a measurement.
    func tally(language: Language, on day: Date = .now) -> (held: Int, due: Int, failing: Int) {
        let mine = encounters.values.filter { $0.language == language }
        return (
            held: mine.filter { $0.standing == .held }.count,
            due: mine.filter { $0.dueAt.map { $0 <= day } == true }.count,
            failing: mine.filter { $0.dueAt != nil && $0.cleanRuns == 0 }.count
        )
    }

    /// Woven into generated sentences, not served as cards.
    func seedsForGeneration(language: Language, on day: Date = .now,
                            limit: Int = 3) -> [String] {
        let subjects = due(on: day, language: language).map(\.subject)
        return Array(subjects.prefix(limit))
    }

    // MARK: Reach

    /// Attempts before a point stops counting as never reached. Two, because
    /// most attempts now come from the deep review tagging what a sentence
    /// used, and it over-tags: one tag is evidence, not a verdict. The
    /// threshold sits here, at the read, so nothing has to decide at the write
    /// whether a tag was trustworthy.
    static let reached = 2

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
    func neverReached(among candidates: [GrammarPoint],
                      proof: Int = Progress.reached) -> [GrammarPoint] {
        candidates.filter { (structures[$0.id]?.attempts ?? 0) < proof }
    }

    /// How often a point has come back clean. `state(of:)` says whether it has
    /// ever worked; this says whether it keeps working.
    func successes(of pointID: String) -> Int { structures[pointID]?.successes ?? 0 }

    func state(of pointID: String) -> Reach {
        guard let u = structures[pointID], u.attempts > 0 else { return .neverAttempted }
        return u.successes > 0 ? .holding : .failing
    }

    enum Reach: String, Codable, Hashable {
        case neverAttempted
        case failing
        case holding
    }

    // MARK: Words
    //
    // The other axis of reach, and the one that costs nothing: which words the
    // learner has ever said. Counted rather than collected, because "you have
    // said 好 41 times" is a different fact from "you have said 好".

    mutating func produced(_ said: [String], language: Language) {
        guard !said.isEmpty else { return }
        var tally = words[language.rawValue] ?? [:]
        for word in said { tally[word, default: 0] += 1 }
        words[language.rawValue] = tally
    }

    func timesProduced(_ word: String, language: Language) -> Int {
        words[language.rawValue]?[word] ?? 0
    }

    /// Band words with nothing against them. Pass `Lexicon.band(upTo:)`: what
    /// the learner has never once said is what widening their range means.
    func neverProduced(among candidates: [String], language: Language) -> [String] {
        let tally = words[language.rawValue] ?? [:]
        return candidates.filter { tally[$0] == nil }
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
        /// Times a lesson on it was opened.
        var visits: Int = 0
        /// Times it came back as a finding, opened or not.
        var sightings: Int = 0
        var knowledge: Knowledge = .unclassified
        var stage: Int = 0
        var dueAt: Date?
        /// Clean retrievals since the last miss. Reset by one.
        var cleanRuns: Int = 0
        var standing: Standing = .active

        enum Knowledge: String, Codable, Hashable {
            case unclassified
            case slip   // knew it, misfired
            case gap    // didn't know it
        }

        /// Two ways off the schedule, and they mean opposite things: the app
        /// concluding it is solid, and the learner saying they are done with it.
        /// Both leave `dueAt` nil, so nothing else tells them apart.
        enum Standing: String, Codable, Hashable {
            case active
            case held
            case dismissed
        }

        static let ladder = [1, 3, 7, 16, 35]
        /// Three, because two is a coincidence at 35-day spacing and four is
        /// four months of asking about something that has stopped being wrong.
        static let cleanRunsToHold = 3

        /// The last interval the ladder has: 35 days.
        var atTopRung: Bool { stage >= Encounter.ladder.count - 1 }

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
            // On the schedule is what active means; a retired encounter that is
            // being scheduled again has stopped being retired.
            standing = .active
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

/// A default value is not a fallback: the synthesised decoder still demands the
/// key, and a stored `Progress` written before `sightings` existed would fail
/// whole rather than lose one number. In an extension, so the memberwise
/// initialiser survives.
extension Progress.Encounter {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        atomID = try container.decode(String.self, forKey: .atomID)
        kind = try container.decode(AtomKind.self, forKey: .kind)
        subject = try container.decode(String.self, forKey: .subject)
        language = try container.decode(Language.self, forKey: .language)
        firstSeen = try container.decode(Date.self, forKey: .firstSeen)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        visits = try container.decode(Int.self, forKey: .visits)
        sightings = try container.decodeIfPresent(Int.self, forKey: .sightings) ?? 0
        knowledge = try container.decode(Knowledge.self, forKey: .knowledge)
        stage = try container.decode(Int.self, forKey: .stage)
        dueAt = try container.decodeIfPresent(Date.self, forKey: .dueAt)
        cleanRuns = try container.decodeIfPresent(Int.self, forKey: .cleanRuns) ?? 0
        standing = try container.decodeIfPresent(Standing.self, forKey: .standing) ?? .active
    }
}

/// The same hazard one level up, and the worst place for it: `words` is new,
/// and without this the first launch on a build carrying it decodes nothing and
/// hands the learner an empty archive.
extension Progress {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        encounters = try container.decode([String: Encounter].self, forKey: .encounters)
        structures = try container.decode([String: StructureUse].self, forKey: .structures)
        words = try container.decodeIfPresent([String: [String: Int]].self,
                                              forKey: .words) ?? [:]
        xp = try container.decode(Int.self, forKey: .xp)
        streak = try container.decode(Int.self, forKey: .streak)
        lastPractisedOn = try container.decodeIfPresent(Date.self, forKey: .lastPractisedOn)
    }
}
