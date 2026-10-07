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
        for (i, item) in round.items.enumerated() where !item.id.hasSuffix("|art") {
            #expect(item.id.hasSuffix(i.isMultiple(of: 2) ? "|meaning" : "|word"))
        }
    }

    @Test func itemsHaveOneRightAnswerAndNoDuplicateOptions() {
        var rng = QuizTests.Seeded(state: 3)
        for w in Self.words.prefix(20) {
            let item = VocabDrill.item(for: w, language: .german, among: Self.words, using: &rng)
            let step = item.steps[0]
            #expect(Set(step.options).count == step.options.count)
            #expect(step.options.indices.contains(step.answer))
            #expect(item.format.rules.options?.contains(step.options.count) ?? false)
        }
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
                    #expect(Set(item.steps[0].options).count == item.steps[0].options.count, "\(item.id)")
                    #expect(item.format.rules.options?.contains(item.steps[0].options.count) ?? false)
                }
            }
        }
    }
}
