import Foundation

extension Store {

    // MARK: Textbook


    func file(_ new: [Textbook.Suggestion]) {
        guard !new.isEmpty else { return }
        suggestions = Textbook.Suggestion.adding(new, to: suggestions)
        Vault.save(suggestions, Vault.suggestions)
    }

    func textbook(scope: Textbook.Scope, search: String = "") -> [Textbook.Section] {
        let language = settings.language
        let pack = LanguagePacks.pack(for: language)
        let sessions = everySession
        return Textbook.assemble(
            language: language, kinds: pack.kinds, points: pack.points,
            noted: Textbook.noted(in: sessions, language: language),
            progress: progress, suggestions: suggestions, bank: bank,
            scope: scope, search: search
        )
    }

    /// Onto the same lesson path as everything else. A finding counts as a
    /// visit; a point or a suggestion has no atom to record.
    func open(_ entry: Textbook.Entry) {
        if let atom = entry.atom {
            open(atom)
        } else {
            open(seed: entry.seed, kind: entry.kind)
        }
    }

    func togglePin(_ entry: Textbook.Entry) {
        if isKept(entry.id) { unkeep(entry.id) } else { keep(entry) }
    }

    // MARK: Quizzes


    /// The current language's book.
    var book: Book { books.book(for: settings.language) }
    /// Shipped and generated tests, then what the model has written since.
    var quizItems: [QuizItem] { books.items(for: settings.language) + (topUps[settings.language.rawValue] ?? []) }

    /// Quizzes take an entry to holding; its point's production can take it
    /// further, and a sentence gone wrong on the point makes it slipping.
    func state(of entry: Chapter.Entry) -> EntryState {
        let quiz = quizLog.state(of: entry.id)
        return entry.point.map { combined(quiz, pointID: $0) } ?? quiz
    }

    /// Drill ids are not language-scoped, so the log key is.
    private func planKey(_ plan: QuizPlan) -> String { "\(settings.language.rawValue)|\(plan.id)" }

    func roundsDone(_ plan: QuizPlan) -> Int { quizLog.plans[planKey(plan)]?.rounds ?? 0 }

    func record(of plan: QuizPlan) -> QuizLog.PlanRecord { quizLog.plans[planKey(plan)] ?? .init() }

    /// The entry's level, falling back to its point's.
    func level(of entry: Chapter.Entry) -> Int {
        let points = pointLevels
        return entry.effectiveLevel { points[$0] }
    }

    private var pointLevels: [String: Int] {
        Dictionary(pack.points.map { ($0.id, $0.level) }, uniquingKeysWith: { a, _ in a })
    }

    /// The book cut to what the learner sees: up to their level + 1.
    var visibleBook: Book {
        let points = pointLevels
        return book.visible(at: settings.level) { $0.effectiveLevel { points[$0] } }
    }

    /// The level shown on entries a step above the learner's; nil otherwise.
    func stretchTag(_ entry: Chapter.Entry) -> String? {
        let n = level(of: entry)
        return n > settings.level ? pack.level(n) : nil
    }

    /// The current language's rules quizzes.
    var rulesItems: [QuizItem] { books.rules(for: settings.language) }

    /// Rules items in a chapter: what its RULES key counts.
    func rulesCount(in chapter: Chapter) -> Int {
        let ids = Set(chapter.entries.map(\.id))
        return rulesItems.filter { ids.contains($0.entry) }.count
    }

    /// Highest band new words come from: the level, plus the word-only boost
    /// from Advanced. The lists stop at HSK 6 and B2.
    func wordBand(_ language: Language) -> Int {
        min(settings.level + settings.wordLevelBoost, language == .mandarin ? 6 : 4)
    }


    func round(for plan: QuizPlan) -> QuizRound {
        if plan.endless {
            let empty = QuizRound(plan: plan, items: [])
            return QuizRound(plan: plan, items: more(for: plan, after: empty, count: 12))
        }
        if VocabDrill.isVocab(plan) {
            let language = settings.language
            return VocabDrill.round(words: books.words(for: language), language: language,
                                    maxBand: wordBand(language)) {
                self.quizLog.state(of: $0)
            }
        }
        return assemble(plan, bank: plan.rules ? rulesItems : quizItems, minLevel: settings.level)
    }

    private func assemble(_ plan: QuizPlan, bank: [QuizItem], minLevel: Int) -> QuizRound {
        let book = book
        let points = pointLevels
        let entries = Dictionary(book.chapters.flatMap(\.entries).map { ($0.id, $0) },
                                 uniquingKeysWith: { a, _ in a })
        return QuizRound.assemble(
            plan: plan, book: book, bank: bank, maxLevel: settings.level + 1,
            minLevel: minLevel,
            levelOf: { id in entries[id]?.effectiveLevel { points[$0] } ?? 1 }
        ) { id in
            entries[id].map(self.state(of:)) ?? self.quizLog.state(of: id)
        }
    }

    // MARK: Endless

    /// The next items of an endless round: its quiz sources and its words in
    /// proportion, entries asked lately held back while there is anything else.
    /// Chapters picked for it ignore the level floor.
    func more(for plan: QuizPlan, after round: QuizRound, count: Int = 10) -> [QuizItem] {
        guard let mix = plan.mix, !mix.isEmpty else { return [] }
        let sources = (mix.tests.isEmpty ? 0 : 1) + (mix.rules.isEmpty ? 0 : 1) + (mix.words ? 1 : 0)
        let wordCount = mix.words ? (sources == 1 ? count : max(1, count / sources)) : 0
        var quiz: [QuizItem] = []
        if wordCount < count {
            let entryIDs = { (chapters: [String]) in
                Set(self.book.chapters.filter { chapters.contains($0.id) }.flatMap { $0.entries.map(\.id) })
            }
            let tests = entryIDs(mix.tests), rules = entryIDs(mix.rules)
            var bank = quizItems.filter { tests.contains($0.entry) } + rulesItems.filter { rules.contains($0.entry) }
            let recent = Set(round.items.suffix(40).map(\.entry))
            let fresh = bank.filter { !recent.contains($0.entry) }
            if fresh.count >= count - wordCount { bank = fresh }
            let draw = QuizPlan(id: plan.id, name: plan.name, count: count - wordCount)
            quiz = assemble(draw, bank: bank, minLevel: 1).items
            topUpIfLow(mix.tests)
        }
        var words: [QuizItem] = []
        if wordCount > 0 {
            let language = settings.language
            var rng = SystemRandomNumberGenerator()
            words = VocabDrill.next(words: books.words(for: language), language: language,
                                    maxBand: wordBand(language), state: { self.quizLog.state(of: $0) },
                                    asked: Set(round.items.map(\.entry)), count: wordCount,
                                    startIndex: round.items.count, using: &rng)
        }
        // Words spread evenly through the quiz items.
        guard !quiz.isEmpty, !words.isEmpty else { return quiz + words }
        var out: [QuizItem] = []
        var w = 0, q = 0
        while w < words.count || q < quiz.count {
            // Whichever is further behind its share of the batch goes next.
            let word = q >= quiz.count || (w < words.count && (2 * w + 1) * quiz.count <= (2 * q + 1) * words.count)
            if word { out.append(words[w]); w += 1 } else { out.append(quiz[q]); q += 1 }
        }
        return out
    }

    /// Endless rounds record each answer as it comes, so stopping, or the app
    /// going away, loses nothing.
    func recordEndless(_ item: QuizItem, _ answer: QuizRound.Answer, in round: QuizRound) {
        noteAsked([item])
        quizLog.record(entry: item.entry, right: answer.right)
        Vault.save(quizLog, Vault.quizLog)
        noteQuiz(item, answer, in: round)
        saveRecord()
        if activity.add(.quiz, on: .now, settings.language) { Vault.save(activity, Vault.activity) }
    }


    /// The current language's last endless mix.
    var endlessMix: QuizPlan.Mix? { endlessMixes[settings.language.rawValue] }

    func saveEndlessMix(_ mix: QuizPlan.Mix) {
        endlessMixes[settings.language.rawValue] = mix
        Vault.save(endlessMixes, Vault.endlessMixes)
    }

    func endlessPlan(_ mix: QuizPlan.Mix) -> QuizPlan {
        QuizPlan(id: QuizPlan.endlessID(settings.language), name: "Endless", mix: mix)
    }

    /// "GENDER + VERB + PREPOSITION + WORDS".
    func endlessLabel(_ mix: QuizPlan.Mix) -> String {
        let ids = mix.tests + mix.rules.filter { !mix.tests.contains($0) }
        let names = ids.compactMap { book.chapter($0)?.name } + (mix.words ? ["Words"] : [])
        return names.joined(separator: " + ")
    }

    // MARK: Top-ups


    /// Items answered at least once, by their id before any re-ask suffix.
    private func noteAsked(_ items: [QuizItem]) {
        let key = settings.language.rawValue
        var asked = askedItems[key] ?? []
        let before = asked.count
        // Only top-ups read this, and they never ask about words.
        for item in items where !item.entry.hasPrefix(VocabWord.entryPrefix) {
            asked.insert(String(item.id.split(separator: "~").first ?? ""))
        }
        guard asked.count != before else { return }
        askedItems[key] = asked
        Vault.save(askedItems, Vault.askedItems)
    }

    /// Chapters among `ids` (empty: none) down to their last few unseen tests
    /// get more, written in the background. One at a time per chapter, and
    /// two chapters at most at once; a failure waits `TopUp.retryAfter`.
    func topUpIfLow(_ ids: [String]) {
        let asked = askedItems[settings.language.rawValue] ?? []
        let bank = quizItems
        for chapter in book.chapters where ids.contains(chapter.id) && !TopUp.formats(chapter).isEmpty {
            guard toppingUp.count < Store.topUpsAtOnce else { break }
            guard !toppingUp.contains(chapter.id),
                  Date.now.timeIntervalSince(topUpFailed[chapter.id] ?? .distantPast) > TopUp.retryAfter
            else { continue }
            let entries = Set(chapter.entries.map(\.id))
            let unseen = bank.filter { entries.contains($0.entry) && !asked.contains($0.id) }.count
            guard unseen < TopUp.lowWater else { continue }
            toppingUp.insert(chapter.id)
            Task { await topUp(chapter) }
        }
    }

    private static let topUpsAtOnce = 2

    private func topUp(_ chapter: Chapter) async {
        let language = settings.language
        defer { toppingUp.remove(chapter.id) }
        let entries = Set(chapter.entries.map(\.id))
        let bank = quizItems.filter { entries.contains($0.entry) }
        let used = bank.map(TopUp.text)
        let examples = Array(bank.filter { TopUp.formats(chapter).contains($0.format) }.shuffled().prefix(8))
        do {
            let (written, usage) = try await tutor.api.send(
                TopUp.Written.self, cachedSystem: TopUp.system,
                user: TopUp.request(chapter: chapter, level: pack.level(settings.level),
                                    examples: examples, used: used),
                schema: TopUp.schema, effort: .medium, maxTokens: 16_000, model: Anthropic.topUpModel)
            spend.addSonnet(usage)
            var kept = TopUp.keep(written.items, chapter: chapter, used: used,
                                  idPrefix: "top.\(chapter.id).\(Int(Date.now.timeIntervalSince1970))")
            if !kept.isEmpty {
                let (checked, usage) = try await tutor.api.send(
                    TopUp.Checked.self, cachedSystem: TopUp.checkSystem, user: TopUp.checkRequest(kept),
                    schema: TopUp.checkSchema, effort: .medium, maxTokens: 4_000, model: Anthropic.topUpModel)
                spend.addSonnet(usage)
                let fail = Set(checked.fail)
                kept = kept.enumerated().filter { !fail.contains($0.offset) }.map(\.element)
            }
            Vault.save(spend, Vault.spend)
            topUps[language.rawValue, default: []] += kept
            Vault.save(topUps, Vault.topUps)
        } catch {
            Plain.note(error, "top-up")
            Vault.save(spend, Vault.spend)
            topUpFailed[chapter.id] = .now
        }
    }

    // MARK: Word decks

    /// Words due in the current language.
    /// Whether `vocab-<language>.json` shipped.
    var hasWordDeck: Bool { !books.words(for: settings.language).isEmpty }

    var wordsDue: Int {
        let language = settings.language
        return VocabDrill.dueCount(words: books.words(for: language), language: language) {
            self.quizLog.state(of: $0)
        }
    }

    /// The shipped rows with the learner's own words in.
    var concepts: [Concept] { books.concepts().map(edited) }

    /// The ALL LANGUAGES deck's languages: the ones on. Under two, no deck.
    var conceptRing: [Language] { ConceptDeck.ring(settings.languages) }


    private func edited(_ concept: Concept) -> Concept {
        var out = concept
        for (code, word) in conceptEdits[concept.id] ?? [:] {
            if let language = Language(rawValue: code) { out = out.with(language, word) }
        }
        return out
    }

    /// Retypes one side of a meaning; empty puts the list's word back. The
    /// new word has its own schedule, as any word does.
    func retype(_ concept: Concept, _ language: Language, _ word: String) -> Concept {
        let typed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = books.concepts().first { $0.id == concept.id }?.word(language)
        var edits = conceptEdits[concept.id] ?? [:]
        edits[language.rawValue] = typed.isEmpty || typed == original ? nil : typed
        conceptEdits[concept.id] = edits.isEmpty ? nil : edits
        Vault.save(conceptEdits, Vault.conceptEdits)
        return concept.with(language, edits[language.rawValue] ?? original ?? typed)
    }

    /// Every word of the row at or under its language's band. Uncapped unless
    /// the Advanced boost is on. A retyped word is off the lists, so it has
    /// no band to exceed.
    private func withinBand(_ concept: Concept) -> Bool {
        guard settings.wordLevelBoost > 0 else { return true }
        return conceptRing.allSatisfy { language in
            (books.word(concept.word(language), in: language)?.band ?? 0) <= wordBand(language)
        }
    }

    var conceptsDue: Int {
        ConceptDeck.dueCount(concepts, ring: conceptRing) { self.quizLog.state(of: $0) }
    }

    func nextConcepts(asked: Set<String>, count: Int) -> [Concept] {
        ConceptDeck.next(concepts: concepts, ring: conceptRing, state: { self.quizLog.state(of: $0) },
                         asked: asked, count: count, allows: withinBand)
    }

    func vocabWord(_ w: String, in language: Language) -> VocabWord? { books.word(w, in: language) }

    /// One mark per language: each moves that language's word.
    func markConcept(_ concept: Concept, _ marks: [Language: Bool]) {
        for (language, right) in marks {
            quizLog.record(entry: ConceptDeck.entry(concept, language), right: right)
        }
        Vault.save(quizLog, Vault.quizLog)
        noteWords(concept, marks)
        if activity.add(.quiz, on: .now, settings.language) { Vault.save(activity, Vault.activity) }
    }

    /// Spoken in `language`, whichever is current.
    func speak(_ text: String, in language: Language) {
        speech?.speak(text, locale: language.localeID)
    }


    /// A word the learner says they knew: it stays away for months.
    func markKnown(_ entry: String) {
        quizLog.markKnown(entry: entry)
        Vault.save(quizLog, Vault.quizLog)
    }

    /// Answered items move their entries; a finished round counts to its plan.
    func finish(_ round: QuizRound) {
        // Endless rounds were recorded answer by answer.
        guard !round.plan.endless else { return }
        let answered = zip(round.items, round.answers).filter { $0.1 != nil }.map(\.0)
        noteAsked(answered)
        if !round.plan.rules, !VocabDrill.isVocab(round.plan) {
            // No chapter list is every chapter: the ones this round reached.
            let chapters = round.plan.chapters.isEmpty
                ? Array(Set(answered.compactMap { book.chapter(of: $0.entry)?.id }))
                : round.plan.chapters
            topUpIfLow(chapters)
        }
        quizLog.record(round, planKey: planKey(round.plan))
        Vault.save(quizLog, Vault.quizLog)
        for (item, answer) in zip(round.items, round.answers) {
            if let answer { noteQuiz(item, answer, in: round) }
        }
        saveRecord()
        if round.answers.allSatisfy({ $0 != nil }),
           activity.add(.quiz, on: .now, settings.language) {
            Vault.save(activity, Vault.activity)
        }
    }

    /// Entries holding or better.
    func held(in chapter: Chapter) -> Int {
        chapter.entries.filter {
            let s = state(of: $0).standing
            return s == .holding || s == .solid
        }.count
    }

    func recommended() -> (plan: QuizPlan, reason: String)? {
        QuizLog.recommend(book: visibleBook, bank: quizItems, state: state(of:))
            .map { (Store.speedRound(for: $0.chapter), $0.reason) }
    }

    nonisolated static func speedRound(for chapter: Chapter) -> QuizPlan {
        QuizPlan(id: chapter.id, name: chapter.name, chapters: [chapter.id], formats: chapter.formats)
    }

    /// Synthesised, always: `say` would play the current turn's recording.
    func speakQuiz(_ text: String) {
        speech?.speak(text, locale: settings.language.localeID)
    }

    // MARK: Book

    /// The book as the tab shows it: the shipped chapters cut to the
    /// learner's level, then Noted, which is never cut.
    struct BookIndex {
        var book: Book
        var chapters: [Chapter]
        /// Noted chapter entries, back to the textbook entries they came from.
        var noted: [String: Textbook.Entry]

        func chapter(_ id: String) -> Chapter? { chapters.first { $0.id == id } }
    }

    var bookIndex: BookIndex {
        let shown = visibleBook
        let bank = quizItems
        var book = shown
        // A drill with nothing at this level goes with its chapters; so does
        // one whose every entry is below it (ÊTRE / AVOIR at B1), unless some
        // of it is being missed.
        let level = settings.level
        let points = pointLevels
        let entries = Dictionary(shown.chapters.flatMap(\.entries).map { ($0.id, $0) },
                                 uniquingKeysWith: { a, _ in a })
        book.drills = shown.drills.filter { plan in
            QuizRound.candidates(plan: plan, book: shown, bank: bank).contains { item in
                guard let entry = entries[item.entry] else { return false }
                return entry.effectiveLevel(pointLevel: { points[$0] }) >= level
                    || QuizRound.missing(self.state(of: entry))
            }
        }
        // Chapters wholly below the learner's level go to the back.
        let current = book.chapters.filter { chapter in
            chapter.entries.contains { $0.effectiveLevel(pointLevel: { points[$0] }) >= level }
        }
        var chapters = current + book.chapters.filter { c in !current.contains { $0.id == c.id } }
        var noted: [String: Textbook.Entry] = [:]
        if let extra = Textbook.notedChapter(
            language: settings.language, sections: textbook(scope: .mine),
            bookPoints: Set(chapters.flatMap(\.entries).compactMap(\.point)),
            known: Set(pack.points.map(\.id))) {
            chapters.append(extra.chapter)
            noted = extra.sources
        }
        return BookIndex(book: book, chapters: chapters, noted: noted)
    }

    func bookState(of entry: Chapter.Entry, in index: BookIndex) -> EntryState {
        if let source = index.noted[entry.id] { return Textbook.state(of: source) }
        return state(of: entry)
    }

    func point(_ id: String?) -> GrammarPoint? {
        id.flatMap { id in pack.points.first { $0.id == id } }
    }

    /// The learner's own sentences where this point was noted, newest first.
    func noted(point: String) -> [Textbook.Noted] {
        let sessions = everySession
        return Textbook.noted(in: sessions, language: settings.language)
            .filter { $0.atom.seed.pointID == point }
            .sorted { $0.at > $1.at }
    }

    /// The learner's own sentences that used this point, newest first.
    func uses(point: String) -> [Textbook.Use] {
        let sessions = everySession
        return Textbook.uses(of: point, in: sessions, language: settings.language)
    }

    /// Best round for a plan, nil before the first.
    func best(_ plan: QuizPlan) -> Int? { record(of: plan).best }

    /// Questions whose answers pointed at this point, newest first.
    func asked(point: String) -> [Textbook.Suggestion] {
        suggestions.filter { $0.language == settings.language && $0.pointID == point }
            .sorted { $0.at > $1.at }
    }

    /// The same request the textbook's curriculum rows made, so the lesson is
    /// the one already on the shelf.
    func ruleRequest(for point: GrammarPoint) -> LessonRequest {
        LessonRequest(seed: Atom.Seed(subject: point.name, context: point.examples.first ?? "",
                                      pointID: point.id),
                      kind: point.kind, language: settings.language)
    }


    /// Writes the rule and shelves it. The practice half waits for the lesson
    /// to be opened.
    func loadRule(_ request: LessonRequest) async {
        let key = request.cacheKey
        let had = lessons[key] != nil
        await loadCore(request)
        if !had, lessons[key] != nil {
            ruleSaved[key] = .now
            Vault.save(ruleSaved, Vault.bookRules)
        }
    }


    /// Makes `point` tomorrow's stretch.
    func requestTomorrow(point: String) {
        let language = settings.language
        guard pack.points.contains(where: { $0.id == point }) else { return }
        if let target = pack.points.first(where: { $0.id == point }), retargetFrontDay(to: target) {
            requests[language.rawValue] = nil
            Vault.save(requests, Vault.requests)
            return
        }
        let request = StretchRequest(pointID: point, language: language, madeOn: Spend.key(.now))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        let slot = language.rawValue + "|next"
        if let drawn = request.replacing(draws[slot], tomorrow: Spend.key(tomorrow)) {
            // Tomorrow is already drawn: the request goes straight in.
            draws[slot] = drawn
            Vault.save(draws, Vault.plan)
            requests[language.rawValue] = nil
            // Its produce and reply sets were written for the old stretch.
            // Unstarted, they are written again.
            for mode in [Mode.produce, .reply] {
                let key = Store.holdKey(language, mode)
                if let held = holds[key], held.turn == nil, held.session.turns.isEmpty,
                   held.session.id == sessionID(for: mode, on: tomorrow) {
                    holds[key] = nil
                    Vault.save(holds, Vault.holds)
                }
            }
        } else {
            requests[language.rawValue] = request
        }
        Vault.save(requests, Vault.requests)
    }

    func isRequested(point: String) -> Bool {
        let language = settings.language
        if requests[language.rawValue]?.pointID == point { return true }
        if packDays.first(where: fitsNow)?.stretchID == point { return true }
        let tomorrow = Spend.key(Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now)
        guard let ahead = draws[language.rawValue + "|next"], ahead.day == tomorrow else { return false }
        return ahead.stretchID == point
    }

    /// The stretch for a draw on `day`, spending a request that applies.
    func requestedStretch(on day: String, fallback: () -> String?) -> String? {
        let key = settings.language.rawValue
        let (id, spent) = StretchRequest.stretch(on: day, language: settings.language,
                                                 request: requests[key],
                                                 known: Set(pack.points.map(\.id)),
                                                 fallback: fallback)
        if spent {
            requests[key] = nil
            Vault.save(requests, Vault.requests)
        }
        return id
    }
}
