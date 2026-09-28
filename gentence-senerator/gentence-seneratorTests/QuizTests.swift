import Testing
import Foundation
@testable import gentence_senerator

/// Loading, validation, round assembly, scoring and the log. The views only
/// render what these produce.
struct QuizTests {

    // MARK: Fixture

    static let bookJSON = """
    {"language": "mandarin",
     "chapters": [
       {"id": "zh.mw", "name": "Measure words", "sub": "台 · 条", "layout": "cards",
        "formats": ["pick-one", "flip"],
        "entries": [
          {"id": "zh.mw.tai", "head": "台", "reading": "tái", "gloss": "machines"},
          {"id": "zh.mw.tiao", "head": "条", "point": "zh.p1"},
          {"id": "zh.mw.zhang", "head": "张"}
        ]},
       {"id": "zh.st", "name": "Structures", "sub": "等…再…", "layout": "formulas",
        "formats": ["build", "transform"],
        "entries": [{"id": "zh.st.deng", "head": "等…再…"}]}
     ],
     "drills": [{"id": "all-flip", "name": "Flip", "formats": ["flip"]}]}
    """

    static let itemsJSON = """
    [
     {"id": "a", "entry": "zh.mw.tai", "format": "pick-one", "prompt": "三＿电脑", "why": "机器 → 台",
      "steps": [{"options": ["台", "个", "张", "部"], "answer": 0}]},
     {"id": "b", "entry": "zh.mw.tiao", "format": "flip", "prompt": "一＿裤子",
      "steps": [{"options": ["条", "根"], "answer": 0}]},
     {"id": "c", "entry": "zh.st.deng", "format": "build", "gloss": "Let's eat once you're off work.",
      "tiles": ["等", "你下班", "我们", "再", "吃饭"], "decoys": ["就"],
      "accept": ["我们 等 你下班 再 吃饭"]},
     {"id": "d", "entry": "zh.st.deng", "format": "transform", "prompt": "他吃了饭。", "task": "→ 把",
      "accept": ["他把饭吃了。"]},
     {"id": "bad-steps", "entry": "zh.mw.tai", "format": "pick-one", "prompt": "三＿电脑",
      "steps": [{"options": ["台", "个"], "answer": 0}]},
     {"id": "bad-entry", "entry": "zh.nope", "format": "flip", "prompt": "＿",
      "steps": [{"options": ["a", "b"], "answer": 1}]},
     {"id": "bad-json", "entry": "zh.mw.tai", "format": "nonsense"}
    ]
    """

    static var book: Book {
        try! JSONDecoder().decode(Book.self, from: Data(bookJSON.utf8))
    }

    static var items: [QuizItem] {
        BookLibrary.usable(BookLibrary.decodeItems(Data(itemsJSON.utf8)), in: book)
    }

    static func pick(_ id: String, entry: String, format: QuizFormat = .pickOne) -> QuizItem {
        QuizItem(id: id, entry: entry, format: format, prompt: "＿",
                 steps: [.init(options: ["x", "y", "z"], answer: 0)])
    }

    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    // MARK: Decoding

    @Test func missingArraysDecodeEmpty() throws {
        let item = try JSONDecoder().decode(QuizItem.self, from: Data("""
            {"id": "x", "entry": "e", "format": "transform"}
            """.utf8))
        #expect(item.steps.isEmpty && item.tiles.isEmpty && item.decoys.isEmpty && item.accept.isEmpty)
        let plan = try JSONDecoder().decode(QuizPlan.self, from: Data(#"{"id": "p", "name": "P"}"#.utf8))
        #expect(plan.chapters.isEmpty && plan.formats.isEmpty && plan.count == 20)
    }

    @Test func oneBadItemCostsOnlyItself() {
        let decoded = BookLibrary.decodeItems(Data(Self.itemsJSON.utf8))
        #expect(decoded.count == 6)
        #expect(!decoded.contains { $0.id == "bad-json" })
        #expect(Self.items.map(\.id) == ["a", "b", "c", "d"])
    }

    @Test func brokenFilesFailSoft() {
        #expect(BookLibrary.decodeItems(Data("not json".utf8)).isEmpty)
        let b = BookLibrary.decodeBook(Data("{}".utf8), language: .german)
        #expect(b.language == .german && b.chapters.isEmpty)
    }

    // MARK: Rules

    @Test func rulesCatchWhatTheCheckerCatches() {
        var i = Self.pick("p", entry: "e")
        #expect(i.problems.isEmpty)
        i.steps = [.init(options: ["a", "b", "c"], answer: 3)]
        #expect(i.problems.contains("step 0 answer out of range"))
        i.steps = [.init(options: ["a", "a", "c"], answer: 0)]
        #expect(i.problems.contains("step 0 duplicate options"))
        i.steps = [.init(options: ["a", "b", "c"], answer: 0)]
        i.prompt = "no gap"
        #expect(i.problems == ["pick-one prompt needs a gap"])

        let sort = QuizItem(id: "s", entry: "e", format: .sort, steps: [
            .init(prompt: "Tisch", options: ["der", "die"], answer: 0),
            .init(prompt: "Lampe", options: ["der", "die"], answer: 1),
            .init(prompt: "Stuhl", options: ["der", "die"], answer: 0),
            .init(prompt: "Tür", options: ["die", "der"], answer: 0)])
        #expect(sort.problems == ["sort steps must share buckets"])

        #expect(!QuizItem(id: "t", entry: "e", format: .transform, accept: ["x"]).problems.isEmpty)
        #expect(QuizItem(id: "t", entry: "e", format: .transform, task: "→ 把", accept: ["x"]).problems.isEmpty)
        #expect(QuizItem(id: "tt", entry: "e", format: .toneTap,
                         steps: [.init(prompt: "不", options: ["bū", "bú", "bǔ", "bù"], answer: 1)])
            .problems == ["tone-tap needs speak"])
    }

    @Test func fixtureItemsAreValid() {
        for item in Self.items { #expect(item.problems.isEmpty, "\(item.id): \(item.problems)") }
    }

    // MARK: Scoring

    @Test func scoringIsPerStepAndAllOrNothing() {
        let two = QuizItem(id: "t", entry: "e", format: .twoStep, prompt: "Elle ＿ tomb＿", steps: [
            .init(prompt: "aux", options: ["a", "est"], answer: 1),
            .init(prompt: "end", options: ["é", "ée"], answer: 1)])
        let half = QuizRound.score(two, picks: [1, 0])
        #expect(half.steps == [true, false] && !half.right)
        #expect(half.given == ["est", "é"])
        #expect(QuizRound.score(two, picks: [1, 1]).right)
        #expect(!QuizRound.score(two, picks: [1]).right)
    }

    @Test func buildAcceptsAlternatesAndRejectsDecoys() {
        let build = Self.items.first { $0.id == "c" }!
        #expect(QuizRound.score(build, tiles: ["等", "你下班", "我们", "再", "吃饭"]).right)
        #expect(QuizRound.score(build, tiles: ["我们", "等", "你下班", "再", "吃饭"]).right)
        #expect(!QuizRound.score(build, tiles: ["等", "你下班", "我们", "就", "吃饭"]).right)
        #expect(QuizRound.score(build, tiles: ["等", "你下班"]).given == ["等你下班"])
    }

    @Test func transformIgnoresSpacingAndPunctuation() {
        let t = Self.items.first { $0.id == "d" }!
        #expect(QuizRound.score(t, typed: " 他 把饭吃了 ").right)
        #expect(!QuizRound.score(t, typed: "他把吃饭了").right)
        #expect(!QuizRound.score(t, typed: "   ").right)
        let de = QuizItem(id: "de", entry: "e", format: .transform, task: "→ Perfekt",
                          accept: ["Ich habe gegessen."])
        #expect(QuizRound.score(de, typed: "ich habe  Gegessen").right)
        #expect(!QuizRound.score(de, typed: "ich hab gegessen").right)
        let fr = QuizItem(id: "fr", entry: "e", format: .transform, task: "→ passé composé",
                          accept: ["J'en ai mangé."])
        #expect(QuizRound.score(fr, typed: "j’en ai mangé").right)
        #expect(!QuizRound.score(fr, typed: "jen ai mangé").right)
    }

    @Test func elidedAndHyphenatedTilesJoinTight() {
        #expect(QuizRound.join(["J'", "en", "ai", "mangé"]) == "J'en ai mangé")
        #expect(QuizRound.join(["Donne-", "le-", "moi"]) == "Donne-le-moi")
        #expect(QuizRound.join(["等", "你下班", "再"]) == "等你下班再")
        let b = QuizItem(id: "b", entry: "e", format: .build, tiles: ["Donne-", "le-", "moi"],
                         accept: ["Donne- moi- le"])
        #expect(QuizRound.score(b, tiles: ["Donne-", "le-", "moi"]).right)
        #expect(QuizRound.score(b, tiles: ["Donne-", "moi-", "le"]).right)
        #expect(!QuizRound.score(b, tiles: ["Donne-", "le-"]).right)
    }

    // MARK: Assembly

    @Test func planFiltersByChapterAndFormat() {
        let b = Self.book
        let plan = QuizPlan(id: "zh.mw", name: "MW", chapters: ["zh.mw"], formats: [.flip])
        #expect(QuizRound.candidates(plan: plan, book: b, bank: Self.items).map(\.id) == ["b"])
        let all = QuizPlan(id: "all", name: "All")
        #expect(QuizRound.candidates(plan: all, book: b, bank: Self.items).count == 4)
    }

    @Test func countIsCappedByTheBank() {
        var rng = Seeded(state: 7)
        let r = QuizRound.assemble(plan: QuizPlan(id: "all", name: "All", count: 20), book: Self.book,
                                   bank: Self.items, state: { _ in QuizLog().state(of: "") }, using: &rng)
        #expect(r.items.count == 4)
        let three = QuizRound.assemble(plan: QuizPlan(id: "all", name: "All", count: 3), book: Self.book,
                                       bank: Self.items, state: { _ in QuizLog().state(of: "") }, using: &rng)
        #expect(three.items.count == 3)
        #expect(Set(three.items.map(\.id)).count == 3)
    }

    @Test func weightFavoursSlippingAndMissedOverRecentlyRight() {
        let now = Date()
        var log = QuizLog()
        for _ in 0..<3 { log.record(entry: "held", right: true, at: now) }
        for _ in 0..<3 { log.record(entry: "slip", right: true, at: now) }
        log.record(entry: "slip", right: false, at: now)
        log.record(entry: "tried", right: false, at: now)
        let w = { QuizRound.weight(log.state(of: $0), now: now) }
        #expect(w("slip") > w("tried"))
        #expect(w("never") > w("held"))
        #expect(w("tried") > w("held"))
        // Right long ago counts more than right just now.
        var old = QuizLog()
        for _ in 0..<3 { old.record(entry: "held", right: true, at: now.addingTimeInterval(-10 * 86_400)) }
        #expect(QuizRound.weight(old.state(of: "held"), now: now) > w("held"))
    }

    @Test func drawsLeanTowardWeakEntries() {
        // 10 entries with 1 item each; entry 0 slipping, entries 1–9 recently right.
        let now = Date()
        var log = QuizLog()
        for i in 0..<10 { for _ in 0..<3 { log.record(entry: "e\(i)", right: true, at: now) } }
        log.record(entry: "e0", right: false, at: now)
        let entries = (0..<10).map { Chapter.Entry(id: "e\($0)", head: "\($0)") }
        let book = Book(language: .mandarin, chapters: [
            Chapter(id: "c", name: "C", sub: "", layout: .list, entries: entries, formats: [])], drills: [])
        let bank = (0..<10).map { Self.pick("i\($0)", entry: "e\($0)") }
        var rng = Seeded(state: 42)
        var hits = 0
        for _ in 0..<200 {
            let r = QuizRound.assemble(plan: QuizPlan(id: "c", name: "C", count: 2), book: book, bank: bank,
                                       state: { log.state(of: $0) }, now: now, using: &rng)
            if r.items.contains(where: { $0.entry == "e0" }) { hits += 1 }
        }
        // Uniform would be 40 of 200.
        #expect(hits > 120)
    }

    @Test func noEntryTwiceRunning() {
        let bank = ["a", "a", "a", "b", "b", "c"].enumerated().map { Self.pick("\($0.offset)", entry: $0.element) }
        let out = QuizRound.arrange(bank)
        #expect(out.count == 6)
        for (x, y) in zip(out, out.dropFirst()) { #expect(x.entry != y.entry) }
        // Impossible: still returns everything.
        let stuck = QuizRound.arrange([Self.pick("1", entry: "a"), Self.pick("2", entry: "a")])
        #expect(stuck.count == 2)
    }

    @Test func assembledRoundsAvoidRepeats() {
        let entries = ["a", "b"].map { Chapter.Entry(id: $0, head: $0) }
        let book = Book(language: .mandarin, chapters: [
            Chapter(id: "c", name: "C", sub: "", layout: .list, entries: entries, formats: [])], drills: [])
        let bank = (0..<5).flatMap { i in ["a", "b"].map { Self.pick("\($0)\(i)", entry: $0) } }
        var rng = Seeded(state: 3)
        for _ in 0..<20 {
            let r = QuizRound.assemble(plan: QuizPlan(id: "c", name: "C", count: 10), book: book, bank: bank,
                                       state: { _ in QuizLog().state(of: "") }, using: &rng)
            for (x, y) in zip(r.items, r.items.dropFirst()) { #expect(x.entry != y.entry) }
        }
    }

    // MARK: Log

    @Test func entryStateFollowsResults() {
        var log = QuizLog()
        #expect(log.state(of: "e").standing == .never)
        log.record(entry: "e", right: false)
        #expect(log.state(of: "e").standing == .tried)
        log.record(entry: "e", right: true)
        log.record(entry: "e", right: true)
        #expect(log.state(of: "e").standing == .tried)
        log.record(entry: "e", right: true)
        #expect(log.state(of: "e").standing == .holding)
        #expect(!log.state(of: "e").slipping)
        log.record(entry: "e", right: false)
        let s = log.state(of: "e")
        #expect(s.standing == .tried && s.slipping)
        #expect(s.recent == [false, true, true, true, false])
        // Never above holding without production.
        for _ in 0..<8 { log.record(entry: "e", right: true) }
        #expect(log.state(of: "e").standing == .holding)
        #expect(log.state(of: "e").recent.count == QuizLog.keep)
        #expect(log.state(of: "e", pointSolid: true).standing == .solid)
    }

    @Test func missBeforeEverHoldingIsNotASlip() {
        var log = QuizLog()
        log.record(entry: "e", right: true)
        log.record(entry: "e", right: false)
        #expect(!log.state(of: "e").slipping)
    }

    @Test func roundsCountPerPlanOnlyWhenFinished() {
        let items = Self.items
        let plan = QuizPlan(id: "p", name: "P")
        var log = QuizLog()
        var r = QuizRound(plan: plan, items: items, started: Date(timeIntervalSince1970: 0))
        r.answer(0, QuizRound.score(items[0], picks: [0]))
        log.record(r, planKey: "p")
        #expect(log.plans["p"] == nil)
        #expect(log.entries["zh.mw.tai"]?.recent == [true])

        var log2 = QuizLog()
        for (i, item) in items.enumerated() {
            r.answer(i, QuizRound.score(item, picks: [1]), at: Date(timeIntervalSince1970: 90))
        }
        #expect(r.isComplete && r.right == 0 && r.seconds() == 90)
        log2.record(r, planKey: "p")
        log2.record(r, planKey: "p")
        #expect(log2.plans["p"]?.rounds == 2)
        #expect(log2.plans["p"]?.best == 0)
        #expect(log2.plans["p"]?.scores.count == 2)
    }

    @Test func logSurvivesMissingFields() throws {
        let log = try JSONDecoder().decode(QuizLog.self, from: Data("""
            {"entries": {"e": {"recent": [true]}}, "plans": {"p": {"rounds": 3}}}
            """.utf8))
        #expect(log.entries["e"]?.recent == [true])
        #expect(log.plans["p"]?.rounds == 3)
        #expect(try JSONDecoder().decode(QuizLog.self, from: Data("{}".utf8)) == QuizLog())
    }

    @Test func streakCountsBackFromLatest() {
        let items = Self.items
        var r = QuizRound(plan: QuizPlan(id: "p", name: "P"), items: items)
        r.answer(0, .init(steps: [false], given: [""]))
        r.answer(1, .init(steps: [true], given: [""]))
        r.answer(2, .init(steps: [true], given: [""]))
        #expect(r.streak == 2)
        #expect(r.misses.map(\.item.id) == ["a"])
    }

    // MARK: Recommendation and plans

    @Test func recommendsTheChapterWithMisses() {
        let now = Date()
        var log = QuizLog()
        #expect(QuizLog.recommend(book: Self.book, bank: Self.items,
                                  state: { log.state(of: $0.id) }, now: now)?.chapter == nil)
        log.record(entry: "zh.mw.tai", right: false, at: now)
        log.record(entry: "zh.mw.tai", right: false, at: now)
        log.record(entry: "zh.mw.tiao", right: false, at: now)
        let rec = QuizLog.recommend(book: Self.book, bank: Self.items,
                                    state: { log.state(of: $0.id) }, now: now)
        #expect(rec?.chapter.id == "zh.mw")
        #expect(rec?.reason == "台 missed ×2 · 条 missed ×1")
        // Stale misses recommend nothing.
        #expect(QuizLog.recommend(book: Self.book, bank: Self.items, state: { log.state(of: $0.id) },
                                  now: now.addingTimeInterval(30 * 86_400))?.chapter == nil)
    }

    @Test func speedRoundIsTheChapter() {
        let ch = Self.book.chapters[0]
        let plan = Store.speedRound(for: ch)
        #expect(plan.id == ch.id && plan.chapters == [ch.id] && plan.formats == ch.formats)
    }
}
