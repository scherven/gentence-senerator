import Foundation

/// Quiz history: per entry the last results, per plan the rounds. Stored under
/// `Vault.quizLog`. Plan keys are the caller's (the store prefixes the
/// language, since drill ids are not language-scoped).
struct QuizLog: Codable, Hashable {
    var entries: [String: EntryRecord] = [:]
    var plans: [String: PlanRecord] = [:]

    /// Right answers in a row that make an entry `holding`.
    static let runToHold = 3
    static let keep = 8

    struct EntryRecord: Codable, Hashable {
        /// Oldest first, at most `keep`.
        var recent: [Bool] = []
        var last: Date?
        /// Reached holding at some point. Makes a miss afterwards a slip.
        var held = false
        /// When the learner said they knew it. A miss clears it.
        var known: Date?

        init(recent: [Bool] = [], last: Date? = nil, held: Bool = false, known: Date? = nil) {
            self.recent = recent; self.last = last; self.held = held; self.known = known
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            recent = try c.decodeIfPresent([Bool].self, forKey: .recent) ?? []
            last = try c.decodeIfPresent(Date.self, forKey: .last)
            held = try c.decodeIfPresent(Bool.self, forKey: .held) ?? false
            known = try c.decodeIfPresent(Date.self, forKey: .known)
        }

        var holding: Bool {
            recent.count >= QuizLog.runToHold && recent.suffix(QuizLog.runToHold).allSatisfy { $0 }
        }
    }

    struct Score: Codable, Hashable {
        var right: Int
        var total: Int
        var seconds: Int
        var at: Date
    }

    struct PlanRecord: Codable, Hashable {
        var rounds = 0
        var best: Int?
        /// Oldest first, at most `keep`.
        var scores: [Score] = []

        init(rounds: Int = 0, best: Int? = nil, scores: [Score] = []) {
            self.rounds = rounds; self.best = best; self.scores = scores
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rounds = try c.decodeIfPresent(Int.self, forKey: .rounds) ?? 0
            best = try c.decodeIfPresent(Int.self, forKey: .best)
            scores = (try? c.decodeIfPresent([Score].self, forKey: .scores)) ?? []
        }

        var average: Int? {
            scores.isEmpty ? nil
                : Int((Double(scores.map(\.right).reduce(0, +)) / Double(scores.count)).rounded())
        }
    }

    init(entries: [String: EntryRecord] = [:], plans: [String: PlanRecord] = [:]) {
        self.entries = entries; self.plans = plans
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = (try? c.decodeIfPresent([String: EntryRecord].self, forKey: .entries)) ?? [:]
        plans = (try? c.decodeIfPresent([String: PlanRecord].self, forKey: .plans)) ?? [:]
    }

    // MARK: Writing

    mutating func record(entry id: String, right: Bool, at date: Date = .now) {
        var e = entries[id] ?? EntryRecord()
        e.recent = Array((e.recent + [right]).suffix(Self.keep))
        e.last = date
        if e.holding { e.held = true }
        if !right { e.known = nil }
        entries[id] = e
    }

    mutating func markKnown(entry id: String, at date: Date = .now) {
        var e = entries[id] ?? EntryRecord()
        e.known = date
        e.last = date
        entries[id] = e
    }

    /// Every answered item moves its entry; only a finished round counts
    /// toward `planKey`.
    mutating func record(_ round: QuizRound, planKey: String, at date: Date = .now) {
        for (item, answer) in zip(round.items, round.answers) {
            guard let answer else { continue }
            record(entry: item.entry, right: answer.right, at: date)
        }
        guard round.isComplete else { return }
        var p = plans[planKey] ?? PlanRecord()
        p.rounds += 1
        p.best = max(p.best ?? 0, round.right)
        p.scores = Array((p.scores + [Score(right: round.right, total: round.items.count,
                                            seconds: round.seconds(at: date), at: date)])
            .suffix(Self.keep))
        plans[planKey] = p
    }

    // MARK: Reading

    /// `solid` is production's to give: pass whether the entry's curriculum
    /// point stands solid there.
    func state(of entryID: String, pointSolid: Bool = false) -> EntryState {
        let e = entries[entryID]
        let recent = e?.recent ?? []
        let slipping = (e?.held ?? false) && recent.last == false
        let standing: DayPlan.Standing
        if pointSolid { standing = .solid }
        else if recent.isEmpty { standing = .never }
        else if e?.holding == true { standing = .holding }
        else { standing = .tried }
        return EntryState(standing: standing, slipping: slipping, lastSeen: e?.last, recent: recent,
                          known: e?.known != nil)
    }
}

// MARK: - What to quiz next

extension QuizLog {

    /// Misses older than this no longer recommend anything.
    static let fresh: TimeInterval = 14 * 86_400

    /// The chapter with the most recent misses and slips, among chapters that
    /// have items, and why: "条 missed ×2 · 台 slipping". Nil when nothing
    /// was missed.
    static func recommend(book: Book, bank: [QuizItem], state: (Chapter.Entry) -> EntryState,
                          now: Date = .now) -> (chapter: Chapter, reason: String)? {
        let quizzed = Set(bank.map(\.entry))
        var best: (chapter: Chapter, score: Int, last: Date, reason: String)?
        for chapter in book.chapters {
            var score = 0
            var last = Date.distantPast
            var parts: [(n: Int, text: String)] = []
            for entry in chapter.entries where quizzed.contains(entry.id) {
                let s = state(entry)
                guard let seen = s.lastSeen, now.timeIntervalSince(seen) < fresh else { continue }
                let missed = s.recent.filter { !$0 }.count
                guard missed > 0 || s.slipping else { continue }
                let n = missed + (s.slipping ? 2 : 0)
                score += n
                last = max(last, seen)
                parts.append((n, s.slipping && missed <= 1
                              ? "\(entry.head) slipping" : "\(entry.head) missed ×\(missed)"))
            }
            guard score > 0 else { continue }
            let reason = parts.sorted { $0.n > $1.n }.prefix(3).map(\.text).joined(separator: " · ")
            if let b = best, score < b.score || (score == b.score && last <= b.last) { continue }
            best = (chapter, score, last, reason)
        }
        return best.map { ($0.chapter, $0.reason) }
    }
}
