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

    /// Build: the placed tiles, as text, against `tiles` and each `accept`.
    /// Text rather than tile sequences, because a tile can hold a space
    /// ("im Büro") and `accept` joins tiles with spaces.
    static func score(_ item: QuizItem, tiles placed: [String]) -> Answer {
        let key = { (s: String) in
            normalise(s).replacingOccurrences(of: "' ", with: "'")
                .replacingOccurrences(of: "- ", with: "-")
        }
        let orders = Set([key(join(item.tiles))] + item.accept.map(key))
        return Answer(steps: [orders.contains(key(join(placed)))], given: [join(placed)])
    }

    /// The fixed words of an entry's head: 等…再… → 等, 再; "warten auf" →
    /// warten, auf. Placeholders (A, B, X, V, …) are dropped.
    static func structure(of head: String?) -> [String] {
        guard let head else { return [] }
        let separators = CharacterSet(charactersIn: "…+/·()[]").union(.whitespaces)
        let parts = head.replacingOccurrences(of: "...", with: "…")
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        let placeholders: Set<String> = ["A", "B", "X", "Y", "V", "N", "S", "O", "ADJ", "sb", "sth", "etw", "jdn", "jdm"]
        return parts.filter { !placeholders.contains($0) }
    }

    /// Whether a tile carries one of the structure's words: a substring for
    /// Mandarin, a whole word elsewhere.
    static func isStructure(_ tile: String, _ structure: [String]) -> Bool {
        let words = Set(tile.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init))
        return structure.contains { part in
            part.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) }
                ? tile.contains(part)
                : words.contains(part.lowercased())
        }
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
        let sides = sides(book)
        let items = arrange(picked).map { fixingSides(shuffledOptions($0, using: &rng), sides) }
        return QuizRound(plan: plan, items: items, started: now)
    }

    /// Where an option's position carries no meaning, it moves each round,
    /// so the answer can't be learned by place. Flip halves, tone marks, sort
    /// buckets and spot-it's tokens keep their order; `fixingSides` then sets
    /// every two-option pair.
    static func shuffledOptions<R: RandomNumberGenerator>(_ item: QuizItem,
                                                          using rng: inout R) -> QuizItem {
        let free: [Int]
        switch item.format {
        case .pickOne, .twoStep: free = Array(item.steps.indices)
        case .spotIt:            free = item.steps.count > 1 ? [1] : []
        default:                 free = []
        }
        var out = item
        for i in free {
            let step = item.steps[i]
            let order = step.options.indices.shuffled(using: &rng)
            out.steps[i] = QuizItem.Step(prompt: step.prompt,
                                         options: order.map { step.options[$0] },
                                         answer: order.firstIndex(of: step.answer) ?? step.answer)
        }
        return out
    }

    /// Two-option pairs, lowercased, to the order they are drawn in: a split
    /// chapter's two tags (不 | 没) as the chapter page shows them.
    static func sides(_ book: Book) -> [Set<String>: [String]] {
        var out: [Set<String>: [String]] = [:]
        for chapter in book.chapters where chapter.layout == .split {
            var seen: Set<String> = []
            let tags = chapter.entries.compactMap(\.tag).map { $0.lowercased() }
                .filter { seen.insert($0).inserted }
            guard tags.count >= 2 else { continue }
            out[Set(tags.prefix(2))] = Array(tags.prefix(2))
        }
        return out
    }

    /// The side a pair's options take: the split order, else a stable sort.
    static func pairOrder(_ options: [String], _ sides: [Set<String>: [String]]) -> [String] {
        let lower = options.map { $0.lowercased() }
        if let order = sides[Set(lower)], Set(lower).count == 2 {
            return options.sorted { order.firstIndex(of: $0.lowercased())! < order.firstIndex(of: $1.lowercased())! }
        }
        return options.sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }
    }

    /// A two-option step draws its pair on the same sides wherever it comes:
    /// flip halves, sort buckets, a two-step's two keys.
    static func fixingSides(_ item: QuizItem, _ sides: [Set<String>: [String]]) -> QuizItem {
        guard [.flip, .sort, .twoStep].contains(item.format) else { return item }
        var out = item
        for (i, step) in item.steps.enumerated() where step.options.count == 2 {
            let order = pairOrder(step.options, sides)
            guard order != step.options else { continue }
            let answer = step.options.indices.contains(step.answer)
                ? order.firstIndex(of: step.options[step.answer]) ?? step.answer : step.answer
            out.steps[i] = QuizItem.Step(prompt: step.prompt, options: order, answer: answer)
        }
        return out
    }

    /// Build: CHECK once every slot is filled.
    static func canCheck(_ item: QuizItem, placed: Int) -> Bool {
        !item.tiles.isEmpty && placed == item.tiles.count
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
