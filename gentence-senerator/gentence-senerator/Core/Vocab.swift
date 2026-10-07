import Foundation

/// One word of `Curriculum/vocab-<language>.json`: the graded word lists with
/// a gloss, and the article (German, French nouns) or pinyin (Mandarin).
struct VocabWord: Codable, Hashable {
    let w: String
    let band: Int
    var pos: String?
    /// der/die/das, le/la; "die (pl)", "les", "le/la" are not asked.
    var art: String?
    var py: String?
    var en: String?
    var skip: Bool?

    /// Quiz entry id: per language, so the log needs no prefix.
    func entry(_ language: Language) -> String { "vocab.\(language.rawValue).\(w)" }

    /// The article, if it can be asked as a choice.
    var askableArticle: String? {
        guard pos == "noun", let art, ["der", "die", "das", "le", "la"].contains(art) else { return nil }
        return art
    }

    /// As shown: with its article for German and French nouns.
    var display: String { [askableArticle ?? art, w].compactMap { $0 }.joined(separator: " ") }
}

/// The words drill: a round of vocab items made on the spot, spaced per word
/// off the quiz log, so the quiz screen, results and history need nothing new.
enum VocabDrill {
    /// Plan id suffix; the full id is "<lang>.drill.vocab".
    static let suffix = ".drill.vocab"

    static func plan(_ language: Language) -> QuizPlan {
        QuizPlan(id: "\(language.rawValue)\(suffix)", name: "Words", count: 20)
    }

    static func isVocab(_ plan: QuizPlan) -> Bool { plan.id.hasSuffix(suffix) }

    /// Days until a word comes back, by right answers in a row.
    static let intervals: [Double] = [0, 1, 3, 7, 21, 60]
    /// Days a word marked as known stays away.
    static let knownInterval: Double = 180
    /// New words in a round with reviews waiting.
    static let newPerRound = 8

    static func streak(_ s: EntryState) -> Int {
        var n = 0
        for right in s.recent.reversed() { guard right else { break }; n += 1 }
        return n
    }

    static func isDue(_ s: EntryState, now: Date) -> Bool {
        guard let seen = s.lastSeen, !s.recent.isEmpty || s.known else { return false }
        if s.recent.last == false { return true }
        let days = s.known ? knownInterval : intervals[min(streak(s), intervals.count - 1)]
        return now.timeIntervalSince(seen) >= days * 86_400
    }

    /// Due words first (missed, then most overdue), then new words from the
    /// lowest band up to `maxBand`.
    static func round<R: RandomNumberGenerator>(
        words: [VocabWord], language: Language, maxBand: Int,
        state: (String) -> EntryState, now: Date = .now, count: Int = 20,
        using rng: inout R
    ) -> QuizRound {
        let usable = words.filter { $0.skip != true && $0.en?.isEmpty == false }
        let due = usable.filter { isDue(state($0.entry(language)), now: now) }
            .sorted { a, b in
                let sa = state(a.entry(language)), sb = state(b.entry(language))
                if (sa.recent.last == false) != (sb.recent.last == false) { return sa.recent.last == false }
                return (sa.lastSeen ?? now) < (sb.lastSeen ?? now)
            }
        let fresh = usable.filter {
            let s = state($0.entry(language))
            return $0.band <= maxBand && s.recent.isEmpty && !s.known
        }
        let newWords = Dictionary(grouping: fresh, by: \.band).sorted { $0.key < $1.key }
            .flatMap { $0.value.shuffled(using: &rng) }
        var picked = Array(due.prefix(count - min(newPerRound, newWords.count)))
        picked += newWords.prefix(count - picked.count)
        // Nothing due or new: the oldest-seen words up to the band.
        if picked.count < count {
            let seen = Set(picked.map(\.w))
            picked += usable.filter { $0.band <= maxBand && !seen.contains($0.w) }
                .sorted { (state($0.entry(language)).lastSeen ?? now) < (state($1.entry(language)).lastSeen ?? now) }
                .prefix(count - picked.count)
        }
        // Word → meaning and meaning → word take turns.
        let items = picked.shuffled(using: &rng).enumerated().map { i, w in
            item(for: w, language: language, among: usable, toEnglish: i.isMultiple(of: 2), using: &rng)
        }
        return QuizRound(plan: plan(language), items: items, started: now)
    }

    static func round(words: [VocabWord], language: Language, maxBand: Int,
                      state: (String) -> EntryState) -> QuizRound {
        var rng = SystemRandomNumberGenerator()
        return round(words: words, language: language, maxBand: maxBand, state: state, using: &rng)
    }

    /// Word → meaning when `toEnglish`, else meaning → word; a noun's
    /// article now and then instead. No direction given: either, at random.
    static func item<R: RandomNumberGenerator>(for word: VocabWord, language: Language,
                                               among words: [VocabWord], toEnglish: Bool? = nil,
                                               using rng: inout R) -> QuizItem {
        let id = word.entry(language)
        let why = [word.display, word.py, word.en].compactMap { $0 }.joined(separator: " · ")
        let toEnglish = toEnglish ?? Bool.random(using: &rng)
        let kind = word.askableArticle != nil && Int.random(in: 0..<4, using: &rng) == 0
            ? "article" : toEnglish ? "meaning" : "word"
        switch kind {
        case "article":
            let options = language == .german ? ["der", "die", "das"] : ["le", "la"]
            return QuizItem(id: id + "|art", entry: id, format: options.count == 2 ? .flip : .pickOne,
                            prompt: "＿ \(word.w)", gloss: word.en, why: why,
                            steps: [.init(options: options,
                                          answer: options.firstIndex(of: word.askableArticle!) ?? 0)])
        case "word":
            let others = distractors(for: word, among: words, using: &rng)
            let options = ([word] + others).shuffled(using: &rng)
            return QuizItem(id: id + "|word", entry: id, format: .pickOne, prompt: word.en, why: why,
                            steps: [.init(options: options.map(\.display),
                                          answer: options.firstIndex(of: word) ?? 0)])
        default:
            let others = distractors(for: word, among: words, using: &rng)
            let options = ([word] + others).shuffled(using: &rng)
            return QuizItem(id: id + "|meaning", entry: id, format: .pickOne, prompt: word.display, why: why,
                            steps: [.init(options: options.compactMap(\.en),
                                          answer: options.firstIndex(of: word) ?? 0)])
        }
    }

    /// Three others of the same part of speech, close in band, with
    /// different glosses and forms.
    static func distractors<R: RandomNumberGenerator>(for word: VocabWord, among words: [VocabWord],
                                                      using rng: inout R) -> [VocabWord] {
        let near = words.filter {
            $0.w != word.w && $0.en != word.en && $0.pos == word.pos && abs($0.band - word.band) <= 1
        }
        let pool = near.count >= 3 ? near : words.filter { $0.w != word.w && $0.en != word.en }
        var out: [VocabWord] = []
        for candidate in pool.shuffled(using: &rng) where out.count < 3 {
            if !out.contains(where: { $0.en == candidate.en || $0.display == candidate.display }) {
                out.append(candidate)
            }
        }
        return out
    }
}
