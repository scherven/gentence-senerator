import Foundation

/// A sentence the learner got wrong, back as translate: the English of what
/// they meant, and their own sentence fixed as the answer. Checked on the
/// device against that fix, so it costs nothing and answers at once.
struct RedoItem: Identifiable, Hashable {
    let turnID: UUID
    let language: Language
    let saidOn: Date
    /// What they are asked to say.
    let english: String
    /// What they said then.
    let said: String
    /// Their sentence, fixed: the answer.
    let fixed: String
    /// Anything else that counts as right: what a speaker would say, the
    /// translate reference.
    let alsoRight: [String]
    /// Each problem as `wrong → right`, located in what they said. Only the
    /// ones that could be found: they are what is checked one by one.
    let changes: [Change]
    /// The problems' atoms, for the schedule.
    let atoms: [Atom]

    var id: UUID { turnID }

    struct Change: Hashable {
        var wrong: String
        var right: String
        /// The finding it came from.
        var atomID: String
    }

    /// Nil when the turn cannot be redone: no review, nothing wrong, or no
    /// English to ask from and no fixed sentence to check against.
    init?(turn: Turn) {
        // Produce answers run to several sentences: too long to say again
        // from a gloss.
        guard let review = turn.review, !review.problems.isEmpty,
              turn.mode != .listen, turn.mode != .produce else { return nil }
        let english = review.gloss ?? (turn.mode == .translate ? turn.prompt.english : nil)
        let fixed = review.fixed ?? (turn.mode == .translate ? review.natural ?? turn.prompt.reference : nil)
        guard let english, let fixed, !english.isEmpty, !fixed.isEmpty,
              fixed != turn.attempt.confirmed else { return nil }
        turnID = turn.id
        language = turn.language
        saidOn = turn.createdAt
        self.english = english
        said = turn.attempt.confirmed
        self.fixed = fixed
        alsoRight = [review.natural, turn.mode == .translate ? turn.prompt.reference : nil]
            .compactMap { $0 }.filter { $0 != fixed }
        changes = review.problems.compactMap { atom in
            let right = atom.stages.fix.trimmingCharacters(in: .whitespacesAndNewlines)
            let wrong = (atom.stages.wrong ?? Store.span(of: atom, in: turn.attempt.confirmed)?.wrong ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A fix that is the whole sentence says nothing about one change.
            guard !right.isEmpty, right.count < fixed.count else { return nil }
            return Change(wrong: wrong, right: right, atomID: atom.id)
        }
        atoms = review.problems
    }

    struct Result: Hashable {
        /// Matches the fixed sentence, or another right answer, outright.
        var exact: Bool
        /// Findings whose change did not show up in the answer.
        var missed: [String]
        var total: Int
        var made: Int { total - missed.count }
        var passed: Bool { exact || (total > 0 && missed.isEmpty) }
    }

    /// Exact match first. Otherwise each change, counted in words (in
    /// characters for Mandarin) against the fixed sentence: the right words
    /// at least as often as there, the wrong ones no more often. Counting is
    /// what keeps "auf" from passing inside "kaufen", and a 了 that belongs
    /// elsewhere in the sentence from failing it.
    func check(_ answer: String) -> Result {
        let exact = ([fixed] + alsoRight).contains { Rung.normalise($0) == Rung.normalise(answer) }
        let said = units(answer), target = units(fixed)
        let missed = exact ? [] : changes.filter { change in
            let right = units(change.right), wrong = units(change.wrong)
            guard !right.isEmpty else { return false }
            let rightOK = Self.count(right, in: said) >= max(1, Self.count(right, in: target))
            let wrongOK = wrong.isEmpty || Self.count(wrong, in: said) <= Self.count(wrong, in: target)
            return !(rightOK && wrongOK)
        }.map(\.atomID)
        return Result(exact: exact, missed: missed, total: changes.count)
    }

    private func units(_ s: String) -> [String] {
        if language.usesSpaces {
            return s.lowercased()
                .split { $0.isWhitespace || ($0.isPunctuation && $0 != "'" && $0 != "’" && $0 != "-") }
                .map(String.init)
        }
        return Rung.normalise(s).map(String.init)
    }

    private static func count(_ needle: [String], in hay: [String]) -> Int {
        guard !needle.isEmpty, needle.count <= hay.count else { return 0 }
        return (0...(hay.count - needle.count)).filter { Array(hay[$0..<($0 + needle.count)]) == needle }.count
    }
}

/// What came of each redo, so a passed one is not asked again and a missed
/// one waits a day.
struct RedoLog: Codable, Hashable {
    struct Entry: Codable, Hashable {
        var tries = 0
        var passed = false
        var last: Date = .distantPast
    }
    private enum CodingKeys: String, CodingKey { case entries, rounds }
    var entries: [UUID: Entry] = [:]
    /// Today's round in each language, by `Language.rawValue`: which
    /// sentences it holds and whether it is over, so leaving and coming back
    /// carries on with the same ones rather than dealing a fresh three.
    var rounds: [String: Round] = [:]

    struct Round: Codable, Hashable {
        var day: Date
        var ids: [UUID]
        /// Finished or skipped: nothing more today.
        var closed = false
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([UUID: Entry].self, forKey: .entries) ?? [:]
        rounds = try c.decodeIfPresent([String: Round].self, forKey: .rounds) ?? [:]
    }

    /// Today's round in the language, if one was dealt.
    func round(_ language: Language, now: Date = .now) -> Round? {
        guard let r = rounds[language.rawValue],
              Calendar.current.isDate(r.day, inSameDayAs: now) else { return nil }
        return r
    }

    mutating func deal(_ items: [RedoItem], in language: Language, now: Date = .now) {
        rounds[language.rawValue] = Round(day: now, ids: items.map(\.turnID))
    }

    mutating func close(_ language: Language, now: Date = .now) {
        if var r = round(language, now: now) {
            r.closed = true
            rounds[language.rawValue] = r
        } else {
            rounds[language.rawValue] = Round(day: now, ids: [], closed: true)
        }
    }

    /// At most this many at the top of a translate session.
    static let perSession = 3
    /// Older than this, a sentence is not brought back.
    static let maxAge: TimeInterval = 21 * 24 * 3600

    mutating func note(_ id: UUID, passed: Bool, on day: Date = .now) {
        var e = entries[id] ?? Entry()
        e.tries += 1
        e.passed = e.passed || passed
        e.last = day
        entries[id] = e
    }

    /// Due: never passed, not tried today, said before today.
    func isDue(_ item: RedoItem, now: Date = .now) -> Bool {
        let calendar = Calendar.current
        guard !calendar.isDate(item.saidOn, inSameDayAs: now),
              now.timeIntervalSince(item.saidOn) < Self.maxAge else { return false }
        guard let e = entries[item.turnID] else { return true }
        return !e.passed && !calendar.isDate(e.last, inSameDayAs: now)
    }

    /// Missed before first, then the newest.
    func pick(_ items: [RedoItem], now: Date = .now) -> [RedoItem] {
        items.filter { isDue($0, now: now) }
            .sorted { a, b in
                let ta = entries[a.turnID]?.tries ?? 0, tb = entries[b.turnID]?.tries ?? 0
                if (ta > 0) != (tb > 0) { return ta > 0 }
                return a.saidOn > b.saidOn
            }
            .prefix(Self.perSession)
            .map { $0 }
    }
}

/// The redos on screen, ahead of a translate session.
struct RedoRound: Hashable {
    var items: [RedoItem]
    var index = 0
    var answer = ""
    /// Set once the current one is checked.
    var result: RedoItem.Result?

    var current: RedoItem? { items.indices.contains(index) ? items[index] : nil }
}
