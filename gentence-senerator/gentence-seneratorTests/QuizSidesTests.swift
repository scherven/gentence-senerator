import Testing
import Foundation
@testable import gentence_senerator

/// Build's CHECK gate, and two-option pairs keeping their sides in a round.
struct QuizSidesTests {

    static let book = Book(language: .mandarin, chapters: [
        Chapter(id: "zh.neg", name: "Negation", sub: "", layout: .split, entries: [
            Chapter.Entry(id: "zh.neg.bu", head: "不去", tag: "不"),
            Chapter.Entry(id: "zh.neg.mei", head: "没去", tag: "没"),
        ], formats: [.flip, .sort]),
    ], drills: [])

    static func flip(_ id: String, _ options: [String], answer: Int) -> QuizItem {
        QuizItem(id: id, entry: "zh.neg.bu", format: .flip, prompt: "我＿去",
                 steps: [.init(options: options, answer: answer)])
    }

    @Test func buildChecksOnlyWhenEverySlotIsFilled() {
        let item = QuizItem(id: "b", entry: "e", format: .build,
                            tiles: ["我", "明天", "在", "家", "看", "书"], decoys: ["了"])
        #expect(!QuizRound.canCheck(item, placed: 0))
        #expect(!QuizRound.canCheck(item, placed: 2))
        #expect(!QuizRound.canCheck(item, placed: 5))
        #expect(QuizRound.canCheck(item, placed: 6))
    }

    @Test func splitOrderSetsFlipSides() {
        let sides = QuizRound.sides(Self.book)
        let item = QuizRound.fixingSides(Self.flip("f", ["没", "不"], answer: 0), sides)
        #expect(item.steps[0].options == ["不", "没"])
        // Still 没.
        #expect(item.steps[0].options[item.steps[0].answer] == "没")
    }

    @Test func flipAndSortAgreeWithinARound() {
        let sides = QuizRound.sides(Self.book)
        let flip = QuizRound.fixingSides(Self.flip("f", ["没", "不"], answer: 1), sides)
        let sort = QuizRound.fixingSides(QuizItem(
            id: "s", entry: "zh.neg.mei", format: .sort,
            steps: [.init(prompt: "去过", options: ["没", "不"], answer: 0),
                    .init(prompt: "喜欢", options: ["没", "不"], answer: 1)]), sides)
        #expect(flip.steps[0].options == sort.steps[0].options)
        #expect(sort.steps.allSatisfy { $0.options == ["不", "没"] })
        #expect(sort.steps[0].options[sort.steps[0].answer] == "没")
        #expect(sort.steps[1].options[sort.steps[1].answer] == "不")
        #expect(flip.steps[0].options[flip.steps[0].answer] == "不")
    }

    @Test func pairsWithoutASplitChapterSortStably() {
        let a = QuizRound.fixingSides(Self.flip("a", ["le", "la"], answer: 0), [:])
        let b = QuizRound.fixingSides(Self.flip("b", ["la", "le"], answer: 1), [:])
        #expect(a.steps[0].options == b.steps[0].options)
        #expect(a.steps[0].options[a.steps[0].answer] == "le")
        #expect(b.steps[0].options[b.steps[0].answer] == "le")
    }

    @Test func assembledRoundsKeepPairsOnOneSide() {
        let bank = (0..<10).map { i in
            Self.flip("f\(i)", i % 2 == 0 ? ["没", "不"] : ["不", "没"], answer: i % 2)
        }
        let plan = QuizPlan(id: "p", name: "P", chapters: ["zh.neg"], count: 10)
        let round = QuizRound.assemble(plan: plan, book: Self.book, bank: bank,
                                       state: { _ in EntryState(standing: .never, slipping: false,
                                                                lastSeen: nil, recent: []) })
        #expect(round.items.allSatisfy { $0.steps[0].options == ["不", "没"] })
        #expect(round.items.allSatisfy { $0.steps[0].options[$0.steps[0].answer] == "没" })
    }

    @Test func pickOneIsLeftToShuffle() {
        let item = QuizItem(id: "p", entry: "e", format: .pickOne, prompt: "＿",
                            steps: [.init(options: ["b", "a"], answer: 0)])
        #expect(QuizRound.fixingSides(item, [:]) == item)
    }
}
