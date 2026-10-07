import Testing
import Foundation
@testable import gentence_senerator

/// The words drill and the level floor on quiz rounds.
struct VocabTests {

    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func word(_ w: String, band: Int = 1, pos: String = "noun", art: String? = "die",
                     en: String? = nil) -> VocabWord {
        VocabWord(w: w, band: band, pos: pos, art: art, py: nil, en: en ?? "gloss \(w)", skip: nil)
    }

    static let words = (0..<40).map { word("W\($0)", band: $0 < 30 ? 1 : 3) }

    @Test func dueFollowsTheStreak() {
        var log = QuizLog()
        log.record(entry: "a", right: true, at: Self.now.addingTimeInterval(-2 * 86_400))
        #expect(VocabDrill.isDue(log.state(of: "a"), now: Self.now))     // 1 right: one day
        log.record(entry: "a", right: true, at: Self.now.addingTimeInterval(-2 * 86_400))
        #expect(!VocabDrill.isDue(log.state(of: "a"), now: Self.now))    // 2 right: three days
        log.record(entry: "a", right: false, at: Self.now)
        #expect(VocabDrill.isDue(log.state(of: "a"), now: Self.now))     // a miss: now
        #expect(!VocabDrill.isDue(log.state(of: "never"), now: Self.now))
    }

    @Test func aKnownWordStaysAwayUntilMissed() {
        var log = QuizLog()
        let day = 86_400.0
        log.markKnown(entry: "k", at: Self.now.addingTimeInterval(-30 * day))
        #expect(!VocabDrill.isDue(log.state(of: "k"), now: Self.now))
        #expect(VocabDrill.isDue(log.state(of: "k"), now: Self.now.addingTimeInterval(151 * day)))
        log.record(entry: "k", right: false, at: Self.now)
        #expect(!log.state(of: "k").known)
        #expect(VocabDrill.isDue(log.state(of: "k"), now: Self.now))
    }

    @Test func missedWordsComeFirstAndNewOnesStayInBand() {
        var log = QuizLog()
        let missed = Self.words[5].entry(.german)
        log.record(entry: missed, right: false, at: Self.now)
        var rng = QuizTests.Seeded(state: 7)
        let round = VocabDrill.round(words: Self.words, language: .german, maxBand: 2,
                                     state: { log.state(of: $0) }, now: Self.now, using: &rng)
        #expect(round.items.count == 20)
        #expect(round.items.contains { $0.entry == missed })
        // Band 3 is above the learner.
        #expect(!round.items.contains { $0.entry.hasSuffix("W35") })
        #expect(VocabDrill.isVocab(round.plan))
    }

    @Test func directionsAlternate() {
        var rng = QuizTests.Seeded(state: 5)
        let round = VocabDrill.round(words: Self.words, language: .german, maxBand: 3,
                                     state: { QuizLog().state(of: $0) }, now: Self.now, using: &rng)
        for (i, item) in round.items.enumerated() {
            #expect(item.id.hasSuffix(i.isMultiple(of: 2) ? "|meaning" : "|word"))
        }
    }

    @Test func cardsCarryTheArticleOnTheBack() {
        var rng = QuizTests.Seeded(state: 3)
        let w = Self.word("Zeitung", en: "newspaper")
        let toEnglish = VocabDrill.item(for: w, language: .german, toEnglish: true, using: &rng)
        #expect(toEnglish.format == .card && toEnglish.prompt == "Zeitung")
        #expect(toEnglish.accept == ["newspaper"] && toEnglish.gloss == "die Zeitung")
        let toWord = VocabDrill.item(for: w, language: .german, toEnglish: false, using: &rng)
        #expect(toWord.prompt == "newspaper" && toWord.accept == ["die Zeitung"])
        #expect(toWord.problems.isEmpty && toEnglish.problems.isEmpty)
    }

    @Test func frenchElides() {
        let usine = VocabWord(w: "usine", band: 1, pos: "noun", art: "la", py: nil, en: "factory", skip: nil)
        #expect(usine.shown(.french) == "l'usine f.")
        #expect(Self.word("table", art: "la").shown(.french) == "la table")
    }

    /// Endless words: what's due, then new words one in three.
    @Test func endlessWordsMixNewAndOld() {
        var log = QuizLog()
        let day = 86_400.0
        for w in Self.words.prefix(12) {
            log.record(entry: w.entry(.german), right: true, at: Self.now.addingTimeInterval(-0.5 * day))
        }
        log.record(entry: Self.words[0].entry(.german), right: false, at: Self.now)
        var rng = QuizTests.Seeded(state: 9)
        let items = VocabDrill.next(words: Self.words, language: .german, maxBand: 2,
                                    state: { log.state(of: $0) }, asked: [], now: Self.now,
                                    count: 9, startIndex: 0, using: &rng)
        #expect(items.count == 9)
        #expect(items[0].entry == Self.words[0].entry(.german))
        let new = items.filter { log.state(of: $0.entry).recent.isEmpty }
        #expect(new.count == 2)
        let again = VocabDrill.next(words: Self.words, language: .german, maxBand: 2,
                                    state: { log.state(of: $0) }, asked: Set(items.map(\.entry)),
                                    now: Self.now, count: 9, startIndex: 9, using: &rng)
        #expect(Set(again.map(\.entry)).isDisjoint(with: items.map(\.entry)))
    }

    @Test func pluralOnlyNounsAreNotAskedTheirArticle() {
        #expect(Self.word("Leute", art: "die (pl)").askableArticle == nil)
        #expect(Self.word("élève", art: "le/la").askableArticle == nil)
        #expect(Self.word("Zeitung").display == "die Zeitung")
    }

    /// Below the learner's level only what is being missed comes back, unless
    /// nothing else fills the round.
    @Test func entriesBelowLevelOnlyWhenMissed() {
        var log = QuizLog()
        log.record(entry: "low-missed", right: false, at: Self.now)
        let ids = ["low", "low-missed", "here"]
        let book = Book(language: .french, chapters: [
            Chapter(id: "c", name: "C", sub: "", layout: .list,
                    entries: ids.map { Chapter.Entry(id: $0, head: $0) }, formats: [])], drills: [])
        let bank = ids.map { QuizTests.pick("i-\($0)", entry: $0) }
        let level = { (id: String) in id == "here" ? 3 : 1 }
        var rng = QuizTests.Seeded(state: 1)
        let two = QuizRound.assemble(plan: QuizPlan(id: "c", name: "C", count: 2), book: book, bank: bank,
                                     maxLevel: 4, minLevel: 3, levelOf: level,
                                     state: { log.state(of: $0) }, now: Self.now, using: &rng)
        #expect(Set(two.items.map(\.entry)) == ["here", "low-missed"])
        let three = QuizRound.assemble(plan: QuizPlan(id: "c", name: "C", count: 3), book: book, bank: bank,
                                       maxLevel: 4, minLevel: 3, levelOf: level,
                                       state: { log.state(of: $0) }, now: Self.now, using: &rng)
        #expect(three.items.count == 3)
    }

    /// The shipped lists decode and make full rounds at every band.
    @MainActor @Test func shippedListsMakeRounds() {
        let library = BookLibrary()
        for (language, top) in [(Language.german, 4), (.french, 4), (.mandarin, 6)] {
            let words = library.words(for: language)
            #expect(words.count > 3000, "\(language)")
            for band in 1...top {
                let round = VocabDrill.round(words: words, language: language, maxBand: band,
                                             state: { QuizLog().state(of: $0) })
                #expect(round.items.count == 20)
                for item in round.items {
                    #expect(item.problems.isEmpty, "\(item.id)")
                    #expect(!(item.accept.first ?? "").isEmpty, "\(item.id)")
                }
            }
        }
    }

    // MARK: All languages

    @Test func frontsTurnAndEnglishComesSecond() {
        typealias F = ConceptDeck.Face
        #expect(ConceptDeck.faces(turn: 0) == [F.language(.german), .en, .language(.french), .language(.mandarin)])
        #expect(ConceptDeck.faces(turn: 1) == [F.language(.french), .en, .language(.mandarin), .language(.german)])
        #expect(ConceptDeck.faces(turn: 2) == [F.language(.mandarin), .en, .language(.german), .language(.french)])
        #expect(ConceptDeck.faces(turn: 3) == [F.en, .language(.german), .language(.french), .language(.mandarin)])
        #expect(ConceptDeck.faces(turn: 4) == ConceptDeck.faces(turn: 0))
    }

    @Test func dueConceptsFirst() {
        let rows = (0..<5).map { Concept(en: "e\($0)", de: "d\($0)", fr: "f\($0)", zh: "z\($0)") }
        var log = QuizLog()
        log.record(entry: ConceptDeck.entry(rows[3], .french), right: false, at: Self.now)
        let next = ConceptDeck.next(concepts: rows, state: { log.state(of: $0) }, asked: [],
                                    now: Self.now, count: 3)
        #expect(next.first == rows[3])
        #expect(next.count == 3)
    }

    /// The shipped rows point at words that exist.
    @MainActor @Test func shippedConceptsResolve() {
        let library = BookLibrary()
        let rows = library.concepts()
        #expect(rows.count > 1000)
        for row in rows.prefix(200) {
            for language in ConceptDeck.ring {
                #expect(library.word(row.word(language), in: language) != nil, "\(row.en) \(language)")
            }
        }
    }

    // MARK: Rules and endless

    /// Every rules item ships usable: none dropped on load.
    @MainActor @Test func shippedRulesLoad() throws {
        let library = BookLibrary()
        for language in Language.allCases {
            let rules = library.rules(for: language)
            #expect(rules.count > 100, "\(language)")
            let url = try #require(Bundle.main.url(forResource: "rules-\(language.rawValue)", withExtension: "json"))
            let raw = try JSONDecoder().decode([QuizItem].self, from: Data(contentsOf: url))
            #expect(raw.count == rules.count, "\(language)")
        }
    }

    @Test func aMissComesBackLater() {
        let items = (0..<6).map { QuizTests.pick("i\($0)", entry: "e\($0)") }
        var round = QuizRound(plan: QuizPlan(id: "x", name: "X", mix: .init(words: true)), items: items)
        round.answer(1, .init(steps: [false], given: ["a"]))
        round.again(1, after: 3)
        #expect(round.items.count == 7)
        #expect(round.items[5].entry == "e1" && round.items[5].id != "i1")
        #expect(round.answers[5] == nil)
        round.append([QuizTests.pick("i9", entry: "e9")])
        #expect(round.items.count == 8 && round.answers.count == 8)
    }

    // MARK: Top-ups

    static func draft(_ prompt: String, entry: String = "c.a", format: String = "pick-one",
                      options: [String] = ["auf", "an", "für"]) -> TopUp.Written.Draft {
        TopUp.Written.Draft(entry: entry, format: format, prompt: prompt, gloss: "g", task: "", why: "w",
                            steps: [.init(prompt: "", options: options, answer: 0)],
                            tiles: [], decoys: [], accept: [])
    }

    /// Only new, well-formed items for this chapter's entries and formats.
    @Test func topUpsKeepOnlyWhatIsNew() {
        let chapter = Chapter(id: "c", name: "C", sub: "", layout: .list,
                              entries: [Chapter.Entry(id: "c.a", head: "warten auf")], formats: [.pickOne])
        let used = ["Wir warten seit zehn Minuten ＿ den Bus."]
        let kept = TopUp.keep([
            Self.draft("Wir warten seit zehn Minuten ＿ den Bus!"),           // the used one again
            Self.draft("Sie wartet am Bahnhof ＿ ihre Schwester."),          // new
            Self.draft("Sie wartet am Bahnhof ＿ ihre Schwester."),          // twice in one reply
            Self.draft("Er denkt ＿ dich.", entry: "other.entry"),           // not this chapter
            Self.draft("Er wartet ＿ dich.", format: "flip"),               // format not allowed
            Self.draft("Er wartet ＿ dich.", options: ["auf", "auf", "an"]), // breaks the rules
        ], chapter: chapter, used: used, idPrefix: "t")
        #expect(kept.map(\.prompt) == ["Sie wartet am Bahnhof ＿ ihre Schwester."])
        #expect(kept[0].steps[0].prompt == nil && kept[0].task == nil)
    }

    @Test func similarityReadsLikeAReader() {
        #expect(TopUp.similarity("Ich warte auf den Bus.", "ich warte auf den Bus") == 1)
        #expect(TopUp.similarity("Ich warte auf den Bus.", "Wir freuen uns auf das Wochenende.") < TopUp.sameAt)
    }

    @Test func oldSpendDaysStillDecode() throws {
        let old = #"{"days":{"2026-10-01":{"input":1000000,"output":0,"cacheRead":0,"cacheWrite":0}}}"#
        var spend = try JSONDecoder().decode(Spend.self, from: Data(old.utf8))
        #expect(spend.days["2026-10-01"]?.dollars == 5)
        spend.addTopUp(.init(inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0),
                       on: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(spend.days.values.contains { abs($0.topUps - 2) < 0.0001 })
    }
}
