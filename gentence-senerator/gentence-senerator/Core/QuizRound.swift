import Foundation

/// One run through a plan: the items drawn, and the answers as they come in.
/// Assembly and scoring are pure; the store only supplies history.
struct QuizRound: Identifiable, Hashable {
    let id: UUID
    let plan: QuizPlan
    let items: [QuizItem]
    /// Parallel to `items`; nil until answered.
    private(set) var answers: [Answer?]
    let started: Date
    private(set) var ended: Date?

    struct Answer: Hashable {
        /// One per scored step. Build and transform have one.
        var steps: [Bool]
        /// What was given, per step, as text.
        var given: [String]
        var right: Bool { !steps.isEmpty && steps.allSatisfy { $0 } }
    }

    init(id: UUID = UUID(), plan: QuizPlan, items: [QuizItem], started: Date = .now) {
        self.id = id
        self.plan = plan
        self.items = items
        self.answers = Array(repeating: nil, count: items.count)
        self.started = started
    }

    mutating func answer(_ index: Int, _ answer: Answer, at date: Date = .now) {
        guard answers.indices.contains(index) else { return }
        answers[index] = answer
        if isComplete { ended = date }
    }

    var answered: Int { answers.compactMap { $0 }.count }
    var right: Int { answers.compactMap { $0 }.filter(\.right).count }
    var isComplete: Bool { !items.isEmpty && answers.allSatisfy { $0 != nil } }

    /// Right answers in a row, counting back from the latest.
    var streak: Int {
        var n = 0
        for a in answers.compactMap({ $0 }).reversed() {
            guard a.right else { break }
            n += 1
        }
        return n
    }

    func seconds(at now: Date = .now) -> Int {
        max(0, Int((ended ?? now).timeIntervalSince(started)))
    }

    /// Answered wrong, in round order.
    var misses: [(item: QuizItem, answer: Answer)] {
        zip(items, answers).compactMap { item, a in
            guard let a, !a.right else { return nil }
            return (item, a)
        }
    }
}

// MARK: - Scoring

extension QuizRound {

    /// Steps formats: one pick per step, each scored.
    static func score(_ item: QuizItem, picks: [Int]) -> Answer {
        var steps: [Bool] = []
        var given: [String] = []
        for (i, step) in item.steps.enumerated() {
            let pick = i < picks.count ? picks[i] : -1
            steps.append(pick == step.answer)
            given.append(step.options.indices.contains(pick) ? step.options[pick] : "")
        }
        return Answer(steps: steps, given: given)
    }

    /// Build: compared as a tile sequence against `tiles` and each `accept`
    /// (tiles joined by single spaces), never as rendered text.
    static func score(_ item: QuizItem, tiles placed: [String]) -> Answer {
        let orders = [item.tiles] + item.accept.map { $0.split(separator: " ").map(String.init) }
        return Answer(steps: [orders.contains(placed)], given: [join(placed)])
    }

    /// Transform: typed, compared to `accept` ignoring case, spacing and
    /// punctuation.
    static func score(_ item: QuizItem, typed: String) -> Answer {
        let said = normalise(typed)
        let ok = !said.isEmpty && item.accept.map(normalise).contains(said)
        return Answer(steps: [ok], given: [typed.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    /// Lowercased, curly apostrophes straightened, runs of whitespace one
    /// space (none next to CJK), punctuation off. Apostrophes and hyphens stay:
    /// they are part of "j'en" and "donne-le-moi".
    static func normalise(_ s: String) -> String {
        var t = s.lowercased().replacingOccurrences(of: "’", with: "'")
        t = String(String.UnicodeScalarView(t.unicodeScalars.map {
            $0 == "'" || $0 == "-" || !CharacterSet.punctuationCharacters.contains($0) ? $0 : " "
        }))
        let words = t.split(whereSeparator: \.isWhitespace).map(String.init)
        t = ""
        for w in words {
            if let last = t.last, !isCJK(last), let first = w.first, !isCJK(first) { t += " " }
            t += w
        }
        while let last = t.unicodeScalars.last,
              CharacterSet.punctuationCharacters.union(.whitespaces).contains(last) {
            t.unicodeScalars.removeLast()
        }
        return t
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }

    /// Tiles as text: no spaces in Mandarin, none after an elided or
    /// hyphenated piece (J' · Donne- le- moi).
    static func join(_ tiles: [String]) -> String {
        var out = ""
        for tile in tiles { out += separator(out, tile) + tile }
        return out
    }

    /// What goes between `before` and `after` when tiles or tokens are shown
    /// as text.
    static func separator(_ before: String, _ after: String) -> String {
        guard let last = before.last, let first = after.first,
              !isCJK(last), !isCJK(first), !"'’-".contains(last) else { return "" }
        return " "
    }

    /// The right answer as text, per step.
    static func expected(_ item: QuizItem) -> [String] {
        switch item.format {
        case .build:     return [join(item.tiles)]
        case .transform: return [item.accept.first ?? ""]
        default:
            return item.steps.map { $0.options.indices.contains($0.answer) ? $0.options[$0.answer] : "" }
        }
    }
}

// MARK: - Assembly

extension QuizRound {

    /// Items for `plan`, weighted toward entries that are slipping, missed or
    /// never quizzed and away from ones answered right recently. Each entry
    /// carries the same total weight however many items it has, and the same
    /// entry never comes twice running unless nothing else is left.
    ///
    /// Entries above `maxLevel` are left out. Entries at `maxLevel` (the
    /// learner's level + 1) make at most one item in `stretchOneIn`, unless
    /// there is too little below it to fill the round.
    static func assemble<R: RandomNumberGenerator>(
        plan: QuizPlan, book: Book, bank: [QuizItem],
        maxLevel: Int = .max, levelOf: (String) -> Int = { _ in 1 },
        state: (String) -> EntryState, now: Date = .now,
        using rng: inout R
    ) -> QuizRound {
        let pool = candidates(plan: plan, book: book, bank: bank, maxLevel: maxLevel, levelOf: levelOf)
        let perEntry = Dictionary(grouping: pool, by: \.entry).mapValues(\.count)
        let keyed = pool.map { item -> (QuizItem, Double) in
            let w = weight(state(item.entry), now: now) / Double(perEntry[item.entry] ?? 1)
            // Efraimidis–Spirakis: the top `count` of u^(1/w) is a weighted
            // sample without replacement.
            let u = Double.random(in: Double.ulpOfOne..<1, using: &rng)
            return (item, pow(u, 1 / w))
        }
        let ranked = keyed.sorted { $0.1 > $1.1 }.map(\.0)
        let count = max(0, plan.count)
        let cap = count / stretchOneIn
        var picked: [QuizItem] = []
        var rest: [QuizItem] = []
        var stretch = 0
        for item in ranked where picked.count < count {
            if levelOf(item.entry) >= maxLevel {
                guard stretch < cap else { rest.append(item); continue }
                stretch += 1
            }
            picked.append(item)
        }
        picked += rest.prefix(count - picked.count)
        return QuizRound(plan: plan, items: arrange(picked), started: now)
    }

    static func assemble(plan: QuizPlan, book: Book, bank: [QuizItem],
                         maxLevel: Int = .max, levelOf: (String) -> Int = { _ in 1 },
                         state: (String) -> EntryState, now: Date = .now) -> QuizRound {
        var rng = SystemRandomNumberGenerator()
        return assemble(plan: plan, book: book, bank: bank, maxLevel: maxLevel, levelOf: levelOf,
                        state: state, now: now, using: &rng)
    }

    /// Level + 1 gets at most one item in this many, rounded down.
    static let stretchOneIn = 10

    static func candidates(plan: QuizPlan, book: Book, bank: [QuizItem],
                           maxLevel: Int = .max, levelOf: (String) -> Int = { _ in 1 }) -> [QuizItem] {
        let chapters = plan.chapters.isEmpty ? book.chapters
            : book.chapters.filter { plan.chapters.contains($0.id) }
        let entries = Set(chapters.flatMap { $0.entries.map(\.id) })
        let formats = Set(plan.formats)
        return bank.filter {
            entries.contains($0.entry) && (formats.isEmpty || formats.contains($0.format))
                && levelOf($0.entry) <= maxLevel
        }
    }

    /// Recently = within two days.
    static let recently: TimeInterval = 2 * 86_400

    static func weight(_ s: EntryState, now: Date) -> Double {
        if s.slipping { return 6 }
        var w: Double
        switch s.standing {
        case .never:   w = 4
        case .tried:   w = 3 + Double(s.recent.filter { !$0 }.count) / 2
        case .holding: w = 1.5
        case .solid:   w = 1
        }
        if s.recent.isEmpty { w = max(w, 4) }
        if s.recent.last == true, let seen = s.lastSeen, now.timeIntervalSince(seen) < recently {
            w *= 0.3
        }
        return w
    }

    /// Keeps the drawn order except where it would put one entry twice in a
    /// row, and forces the most crowded entry forward when leaving it would
    /// make that unavoidable later.
    static func arrange(_ items: [QuizItem]) -> [QuizItem] {
        var pool = items
        var out: [QuizItem] = []
        while !pool.isEmpty {
            let prev = out.last?.entry
            let counts = Dictionary(grouping: pool, by: \.entry).mapValues(\.count)
            let crowded = counts.filter { $0.key != prev && $0.value * 2 >= pool.count }
                .max { $0.value < $1.value }?.key
            let i = crowded.flatMap { c in pool.firstIndex { $0.entry == c } }
                ?? pool.firstIndex { $0.entry != prev }
                ?? 0
            out.append(pool.remove(at: i))
        }
        return out
    }
}

// MARK: - Validation

extension QuizItem {
    /// Ways this item breaks its format's `rules`. Mirrors
    /// `tools/check_book.py`; empty means usable.
    var problems: [String] {
        var out: [String] = []
        let r = format.rules
        if !r.steps.contains(steps.count) {
            out.append("\(format.rawValue) needs \(r.steps) steps, has \(steps.count)")
        }
        for (i, s) in steps.enumerated() {
            if let o = r.options, !o.contains(s.options.count) {
                out.append("step \(i) needs \(o) options, has \(s.options.count)")
            }
            if !s.options.indices.contains(s.answer) { out.append("step \(i) answer out of range") }
            if Set(s.options).count != s.options.count { out.append("step \(i) duplicate options") }
        }
        if format == .sort, Set(steps.map(\.options)).count > 1 {
            out.append("sort steps must share buckets")
        }
        if r.tiles, tiles.count < 2 { out.append("build needs 2+ tiles") }
        if r.accept, accept.isEmpty { out.append("transform needs accept") }
        if format == .transform, (task ?? "").isEmpty { out.append("transform needs task") }
        if [.pickOne, .flip, .twoStep].contains(format), !(prompt ?? "").contains(QuizItem.gap) {
            out.append("\(format.rawValue) prompt needs a gap")
        }
        if format == .toneTap, (speak ?? "").isEmpty { out.append("tone-tap needs speak") }
        return out
    }

    static let gap: Character = "＿"
}
