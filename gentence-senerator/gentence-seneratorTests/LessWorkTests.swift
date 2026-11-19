import Testing
import Foundation
@testable import gentence_senerator

/// Redo, the new review fields, Reply and the simulator's dry run.
struct LessWorkTests {

    static func atom(_ wrong: String, _ fix: String, _ name: String = "why",
                     verdict: Atom.Verdict = .weakens, weight: Atom.Weight = .also) -> Atom {
        Atom(id: Atom.identify(.preposition, "subject \(wrong)"), kind: .preposition, verdict: verdict,
             stages: .init(locate: name, name: name, fix: fix, note: "", wrong: wrong),
             seed: .init(subject: "subject \(wrong)", context: "", pointID: nil), weight: weight)
    }

    static func turn(_ said: String, language: Language = .german, mode: Mode = .reply,
                     atoms: [Atom], fixed: String?, gloss: String?, daysAgo: Double = 2) -> Turn {
        var review = Review(score: 70, readOfScore: "", atoms: atoms)
        review.fixed = fixed
        review.gloss = gloss
        return Turn(id: UUID(), mode: mode, language: language,
                    createdAt: Date.now.addingTimeInterval(-daysAgo * 86400),
                    prompt: .init(english: "Q", target: "Frage?", audioSource: nil, pointID: nil),
                    attempt: .init(heard: said, confirmed: said, wasTyped: true,
                                   audioFilename: nil, pronunciation: nil),
                    review: review)
    }

    // MARK: Redo

    @Test func redoChecksEachChange() throws {
        let t = Self.turn("Ich warte für den Bus seit zwanzig Minuten.",
                          atoms: [Self.atom("für", "auf")],
                          fixed: "Ich warte für den Bus seit zwanzig Minuten.".replacingOccurrences(of: "für", with: "auf"),
                          gloss: "I've been waiting for the bus for twenty minutes.")
        let item = try #require(RedoItem(turn: t))
        #expect(item.check("Ich warte auf den Bus seit zwanzig Minuten").passed)
        #expect(item.check("Ich warte seit zwanzig Minuten auf den Bus.").passed)
        #expect(!item.check("Ich warte für den Bus seit zwanzig Minuten.").passed)
        #expect(item.check("ich warte auf den bus seit zwanzig minuten").exact)
    }

    /// Counted in words: "auf" inside "kaufen" is not the fix, and the
    /// wrong word may stay where the fixed sentence also has it.
    @Test func redoCountsWordsNotSubstrings() throws {
        let t = Self.turn("Ich warte für den Bus.", atoms: [Self.atom("für", "auf")],
                          fixed: "Ich warte auf den Bus.", gloss: "I'm waiting for the bus.")
        let item = try #require(RedoItem(turn: t))
        #expect(!item.check("Ich warte für den Bus kaufen.").passed)
        let le = Self.turn("我去了商店了。", language: .mandarin, atoms: [Self.atom("了", "过")],
                           fixed: "我去过商店了。", gloss: "I've been to the shop.")
        let zh = try #require(RedoItem(turn: le))
        #expect(zh.check("我去过商店了").passed)
        #expect(zh.check("我去过了商店了").missed.count == 1)
    }

    @Test func mandarinIsComparedWithoutSpaces() throws {
        let t = Self.turn("我昨天去了超市，都去了书店。", language: .mandarin,
                          atoms: [Self.atom("都", "也")],
                          fixed: "我昨天去了超市，也去了书店。", gloss: "I went to the supermarket and the bookstore too.")
        let item = try #require(RedoItem(turn: t))
        #expect(item.check("我昨天去了超市 也去了书店").exact)
        #expect(!item.check("我昨天去了超市，都去了书店").passed)
    }

    @Test func nothingToRedoWithoutAFixOrAnything() {
        #expect(RedoItem(turn: Self.turn("Gut.", atoms: [], fixed: nil, gloss: nil)) == nil)
        #expect(RedoItem(turn: Self.turn("Gut.", atoms: [Self.atom("Gut", "Gern")], fixed: nil, gloss: "x")) == nil)
        // A translate turn falls back to its own English and reference.
        var t = Self.turn("Ich gehe zu Hause.", mode: .translate, atoms: [Self.atom("zu", "nach")], fixed: nil, gloss: nil)
        t.prompt.english = "I'm going home."
        t.prompt.reference = "Ich gehe nach Hause."
        #expect(RedoItem(turn: t)?.fixed == "Ich gehe nach Hause.")
    }

    @Test func redoLogPicksMissedThenNewestAndSkipsToday() throws {
        let make = { (days: Double) in
            try #require(RedoItem(turn: Self.turn("Ich warte für dich.", atoms: [Self.atom("für", "auf")],
                                                  fixed: "Ich warte auf dich.", gloss: "I'm waiting for you.",
                                                  daysAgo: days)))
        }
        let old = try make(5), newer = try make(1), today = try make(0), missed = try make(9)
        var log = RedoLog()
        log.note(missed.turnID, passed: false, on: .now.addingTimeInterval(-86400 * 3))
        let picked = log.pick([old, newer, today, missed])
        #expect(picked.map(\.turnID) == [missed.turnID, newer.turnID, old.turnID])
        log.note(newer.turnID, passed: true)
        #expect(!log.isDue(newer))
        log.note(old.turnID, passed: false)
        #expect(!log.isDue(old)) // tried today
    }

    /// Leaving and coming back keeps today's round: same sentences, from
    /// the first not yet tried; skipped or finished, none until tomorrow.
    @Test func redoRoundIsRememberedForTheDay() throws {
        let item = try #require(RedoItem(turn: Self.turn("Ich warte für dich.", atoms: [Self.atom("für", "auf")],
                                                         fixed: "Ich warte auf dich.", gloss: "I'm waiting for you.")))
        var log = RedoLog()
        log.deal([item], in: .german)
        let data = try JSONEncoder().encode(log)
        var back = try JSONDecoder().decode(RedoLog.self, from: data)
        #expect(back.round(.german)?.ids == [item.turnID])
        #expect(back.round(.french) == nil)
        #expect(back.round(.german, now: .now.addingTimeInterval(86400 * 2)) == nil)
        back.close(.german)
        #expect(back.round(.german)?.closed == true)
        // A log saved before rounds existed still loads.
        let old = try JSONDecoder().decode(RedoLog.self, from: Data(#"{"entries":[]}"#.utf8))
        #expect(old.rounds.isEmpty)
    }

    // MARK: Take away

    @Test func takeAwayRanksRepeatsThenBreaks() {
        let a = Self.atom("für", "auf"), b = Self.atom("der", "die", verdict: .breaks),
            c = Self.atom("gehe", "fahre"), d = Self.atom("ins", "im")
        let reviews = [Review(score: 70, readOfScore: "", atoms: [a, c]),
                       Review(score: 60, readOfScore: "", atoms: [b, a]),
                       Review(score: 80, readOfScore: "", atoms: [d])]
        let out = Store.takeAway(reviews)
        #expect(out.map(\.atom.id) == [a.id, b.id, c.id])
        #expect(out.first?.count == 2)
    }

    // MARK: Review fields

    @Test func readsFixedGlossAndWrong() throws {
        let json = """
        {"findings":[{"kind":"preposition","verdict":"weakens","weight":"start","wrong":"für",
          "name":"warten auf, never für","fix":"auf","note":"n","subject":"warten auf","point":null}],
         "score":80,"readOfScore":"x","fixed":"Ich warte auf den Bus.","gloss":"I'm waiting for the bus.",
         "natural":null,"respeaks":[],"used":[]}
        """
        let reply = Anthropic.Reply(text: json, usage: .init(inputTokens: 0, outputTokens: 0,
                                                              cacheReadTokens: 0, cacheWriteTokens: 0),
                                    refusal: nil)
        let turn = Self.turn("Ich warte für den Bus.", mode: .translate, atoms: [], fixed: nil, gloss: nil)
        let review = try Tutor.read(reply, turn: turn, history: [])
        #expect(review.fixed == "Ich warte auf den Bus.")
        #expect(review.gloss == "I'm waiting for the bus.")
        #expect(review.atoms.first?.stages.wrong == "für")
        let span = try #require(Store.span(of: review.atoms[0], in: turn.attempt.confirmed))
        #expect(span.wrong == "für" && span.right == "auf")
    }

    /// Batches out before the change still answer with `locate`.
    @Test func readsAnOldShapeReview() throws {
        let json = """
        {"findings":[{"kind":"preposition","verdict":"weakens","weight":"start","locate":"somewhere",
          "name":"what","fix":"auf","note":"n","subject":"warten auf","point":null}],
         "score":80,"readOfScore":"x","natural":null,"respeaks":[],"used":[]}
        """
        let reply = Anthropic.Reply(text: json, usage: .init(inputTokens: 0, outputTokens: 0,
                                                              cacheReadTokens: 0, cacheWriteTokens: 0),
                                    refusal: nil)
        let turn = Self.turn("Ich warte für den Bus.", atoms: [], fixed: nil, gloss: nil)
        let review = try Tutor.read(reply, turn: turn, history: [])
        #expect(review.fixed == nil)
        #expect(review.atoms.first?.stages.locate == "somewhere")
        #expect(review.atoms.first?.stages.wrong == nil)
    }

    @Test func oldStagesDecodeWithoutWrong() throws {
        let json = #"{"locate":"l","name":"n","fix":"f","note":"x"}"#
        let stages = try JSONDecoder().decode(Atom.Stages.self, from: Data(json.utf8))
        #expect(stages.wrong == nil)
    }

    // MARK: Modes

    @Test func produceAndTalkAreNotOwed() {
        for language in Language.allCases {
            #expect(language.modes.contains(.reply))
            #expect(!language.dailyModes.contains(.produce))
            #expect(!language.dailyModes.contains(.converse))
        }
        #expect(Mode.ahead == [.translate, .reply])
    }

    // MARK: Dry run

    @Test func dryRunAnswersEveryShape() throws {
        let api = Anthropic()
        let tutor = Tutor(api: api)
        for language in [Language.mandarin, .german, .french] {
            let turn = Self.turn(language == .mandarin ? "我昨天去了超市，都去了书店。" : "Ich warte für den Bus seit zwanzig Minuten.",
                                 language: language, mode: .translate, atoms: [], fixed: nil, gloss: nil)
            let params = tutor.reviewParams(turn: turn, history: [], level: 2)
            let review = try Tutor.read(DryRun.reply(body: params), turn: turn, history: [])
            #expect(!review.problems.isEmpty)
            #expect(review.fixed != nil && review.fixed != turn.attempt.confirmed)
            #expect(Store.span(of: review.problems[0], in: turn.attempt.confirmed) != nil)
        }
        // A day set, in each written mode, decodes as a set of the size asked.
        for mode in Mode.written {
            let body = api.params(cachedSystem: "You are a German tutor.",
                                  user: "Mode: \(mode.rawValue)\nLevel: A2\nItems: 4",
                                  schema: Schemas.daySet, effort: .low, maxTokens: 10)
            let set = try Anthropic.decode(Tutor.DaySet.self, from: DryRun.reply(body: body))
            #expect(set.items.count == 4)
            if mode == .reply { #expect(set.items.allSatisfy { $0.from != nil }) }
        }
        // Anything without a fixture still decodes.
        let body = api.params(cachedSystem: "You are a French tutor.", user: "x",
                              schema: Schemas.lessonCore(for: .french), effort: .low, maxTokens: 10)
        _ = try Anthropic.decode(Tutor.Core.self, from: DryRun.reply(body: body))
    }
}
