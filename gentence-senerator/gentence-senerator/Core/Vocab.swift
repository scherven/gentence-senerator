import Foundation

/// One word of `Curriculum/vocab-<language>.json`: the graded word lists with
/// a gloss, and the article (German, French nouns) or pinyin (Mandarin).
struct VocabWord: Codable, Hashable {
    let w: String
    let band: Int
    var pos: String?
    /// der/die/das, le/la, el/la; "die (pl)", "les", "le/la", "el (f)" are
    /// not asked.
    var art: String?
    var py: String?
    var en: String?
    var skip: Bool?

    /// Quiz entry id: per language, so the log needs no prefix.
    func entry(_ language: Language) -> String { "\(Self.entryPrefix)\(language.rawValue).\(w)" }

    /// What every word's entry id starts with.
    static let entryPrefix = "vocab."

    /// The article, if it can be asked as a choice.
    var askableArticle: String? {
        guard pos == "noun", let art, ["der", "die", "das", "le", "la", "el"].contains(art) else { return nil }
        return art
    }

    /// As shown: with its article for German, French and Spanish nouns.
    /// el agua is feminine, and says so.
    var display: String {
        if art == "el (f)" { return "el \(w) f." }
        return [askableArticle ?? art, w].compactMap { $0 }.joined(separator: " ")
    }

    /// As a card shows it: French elides, and says the gender it hides
    /// (l'usine f.).
    func shown(_ language: Language) -> String {
        guard language == .french, let a = askableArticle,
              let first = w.lowercased().unicodeScalars.first,
              "aeiouhâàéèêîïôûœ".unicodeScalars.contains(first) else { return display }
        return "l'\(w) \(a == "la" ? "f." : "m.")"
    }
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
    static let intervals = [0, 1, 3, 7, 21, 60]
    /// Days a word marked as known stays away.
    static let knownInterval = 180
    /// New words in a round with reviews waiting.
    static let newPerRound = 8

    /// Known outranks a miss before it: the learner said so since. Day-aligned,
    /// as `Progress.Encounter` is — a one-day word answered in the evening is
    /// due the next morning.
    static func isDue(_ s: EntryState, now: Date) -> Bool {
        guard let seen = s.lastSeen, !s.recent.isEmpty || s.known else { return false }
        if !s.known, s.recent.last == false { return true }
        let days = s.known ? knownInterval : intervals[min(s.streak, intervals.count - 1)]
        let calendar = Calendar.current
        guard let due = calendar.date(byAdding: .day, value: days,
                                      to: calendar.startOfDay(for: seen)) else { return false }
        return now >= due
    }

    /// Due words, missed first, then the longest unseen.
    static func dueOrder(_ words: [VocabWord], language: Language,
                         state: (String) -> EntryState, now: Date) -> [VocabWord] {
        words.filter { isDue(state($0.entry(language)), now: now) }
            .sorted { a, b in
                let sa = state(a.entry(language)), sb = state(b.entry(language))
                let ma = !sa.known && sa.recent.last == false
                let mb = !sb.known && sb.recent.last == false
                if ma != mb { return ma }
                return (sa.lastSeen ?? now) < (sb.lastSeen ?? now)
            }
    }

    /// Never-seen words up to `maxBand`, lowest band first, shuffled within it.
    static func newWords<R: RandomNumberGenerator>(
        _ words: [VocabWord], language: Language, maxBand: Int,
        state: (String) -> EntryState, using rng: inout R
    ) -> [VocabWord] {
        let fresh = words.filter {
            let s = state($0.entry(language))
            return $0.band <= maxBand && s.recent.isEmpty && !s.known
        }
        return Dictionary(grouping: fresh, by: \.band).sorted { $0.key < $1.key }
            .flatMap { $0.value.shuffled(using: &rng) }
    }

    /// Seen words up to `maxBand`, longest unseen first. Known ones stay away.
    static func oldestSeen(_ words: [VocabWord], language: Language, maxBand: Int,
                           state: (String) -> EntryState, excluding taken: Set<String>,
                           now: Date) -> [VocabWord] {
        words.filter {
            let s = state($0.entry(language))
            return $0.band <= maxBand && !s.recent.isEmpty && !s.known && !taken.contains($0.w)
        }
        .sorted { (state($0.entry(language)).lastSeen ?? now) < (state($1.entry(language)).lastSeen ?? now) }
    }

    /// Due words first (missed, then most overdue), then new words from the
    /// lowest band up to `maxBand`.
    static func round<R: RandomNumberGenerator>(
        words: [VocabWord], language: Language, maxBand: Int,
        state: (String) -> EntryState, now: Date = .now, count: Int = 20,
        using rng: inout R
    ) -> QuizRound {
        let usable = words.filter { $0.skip != true && $0.en?.isEmpty == false }
        let due = dueOrder(usable, language: language, state: state, now: now)
        let fresh = newWords(usable, language: language, maxBand: maxBand, state: state, using: &rng)
        var picked = Array(due.prefix(count - min(newPerRound, fresh.count)))
        picked += fresh.prefix(count - picked.count)
        // Nothing due or new: the oldest-seen words up to the band.
        if picked.count < count {
            picked += oldestSeen(usable, language: language, maxBand: maxBand, state: state,
                                 excluding: Set(picked.map(\.w)), now: now)
                .prefix(count - picked.count)
        }
        // Word → meaning and meaning → word take turns.
        let items = picked.shuffled(using: &rng).enumerated().map { i, w in
            item(for: w, language: language, toEnglish: i.isMultiple(of: 2), using: &rng)
        }
        return QuizRound(plan: plan(language), items: items, started: now)
    }

    static func round(words: [VocabWord], language: Language, maxBand: Int,
                      state: (String) -> EntryState) -> QuizRound {
        var rng = SystemRandomNumberGenerator()
        return round(words: words, language: language, maxBand: maxBand, state: state, using: &rng)
    }

    /// A flashcard. Word → meaning when `toEnglish`, else meaning → word.
    /// A noun's article is on the back either way, so knowing the word
    /// means knowing its gender. No direction given: either, at random.
    static func item<R: RandomNumberGenerator>(for word: VocabWord, language: Language,
                                               toEnglish: Bool? = nil,
                                               using rng: inout R) -> QuizItem {
        let id = word.entry(language)
        let toEnglish = toEnglish ?? Bool.random(using: &rng)
        let form = word.shown(language)
        if toEnglish {
            let under = [form == word.w ? nil : form, word.py].compactMap { $0 }.joined(separator: " · ")
            return QuizItem(id: id + "|meaning", entry: id, format: .card, prompt: word.w,
                            gloss: under.isEmpty ? nil : under, speak: word.w, accept: [word.en ?? ""])
        }
        return QuizItem(id: id + "|word", entry: id, format: .card, prompt: word.en,
                        gloss: word.py, speak: word.w, accept: [form])
    }

    // MARK: Endless

    /// The next `count` words after those already asked: due ones first, then
    /// one new word to every two seen longest ago, so new words never come as
    /// a wall.
    static func next<R: RandomNumberGenerator>(
        words: [VocabWord], language: Language, maxBand: Int,
        state: (String) -> EntryState, asked: Set<String>, now: Date = .now,
        count: Int, startIndex: Int, using rng: inout R
    ) -> [QuizItem] {
        let usable = words.filter {
            $0.skip != true && $0.en?.isEmpty == false && !asked.contains($0.entry(language))
        }
        var picked = Array(dueOrder(usable, language: language, state: state, now: now).prefix(count))
        if picked.count < count {
            let fresh = newWords(usable, language: language, maxBand: maxBand, state: state,
                                 using: &rng)
            let old = oldestSeen(usable, language: language, maxBand: maxBand, state: state,
                                 excluding: Set(picked.map(\.w)), now: now)
            var n = 0, o = 0
            while picked.count < count, n < fresh.count || o < old.count {
                let wantNew = (picked.count % 3 == 0 && n < fresh.count) || o >= old.count
                if wantNew { picked.append(fresh[n]); n += 1 } else { picked.append(old[o]); o += 1 }
            }
        }
        return picked.enumerated().map { i, w in
            item(for: w, language: language, toEnglish: (startIndex + i).isMultiple(of: 2), using: &rng)
        }
    }

    /// Words due now, up to `maxBand` for new ones: what the WORDS key counts.
    static func dueCount(words: [VocabWord], language: Language,
                         state: (String) -> EntryState, now: Date = .now) -> Int {
        words.filter { $0.skip != true && isDue(state($0.entry(language)), now: now) }.count
    }
}
