import Testing
import Foundation
@testable import gentence_senerator

/// Asking for a point tomorrow, and the book's Noted chapter.
struct BookTests {

    // MARK: requestTomorrow

    static let request = StretchRequest(pointID: "deng-zai", language: .mandarin, madeOn: "2026-09-28")
    static let known: Set<String> = ["deng-zai", "yi-jiu"]

    @Test func aRequestIsTheNextDaysStretchAndIsSpent() {
        let (id, spent) = StretchRequest.stretch(on: "2026-09-29", language: .mandarin,
                                                 request: Self.request, known: Self.known) { "yi-jiu" }
        #expect(id == "deng-zai")
        #expect(spent)
    }

    @Test func aRequestWaitsOutTheDayItWasMade() {
        var fellBack = false
        let (id, spent) = StretchRequest.stretch(on: "2026-09-28", language: .mandarin,
                                                 request: Self.request, known: Self.known) {
            fellBack = true
            return "yi-jiu"
        }
        #expect(id == "yi-jiu")
        #expect(fellBack)
        #expect(!spent)
    }

    @Test func aRequestStaysInItsLanguage() {
        let (id, spent) = StretchRequest.stretch(on: "2026-09-29", language: .german,
                                                 request: Self.request, known: Self.known) { nil }
        #expect(id == nil)
        #expect(!spent)
    }

    @Test func aRequestForAPointThePackLostIsDropped() {
        let (id, spent) = StretchRequest.stretch(on: "2026-09-29", language: .mandarin,
                                                 request: Self.request, known: ["yi-jiu"]) { "yi-jiu" }
        #expect(id == "yi-jiu")
        #expect(spent)
    }

    /// The draw only happens once a day: a stored draw never reaches the
    /// request, so it is not spent on a day that already had its stretch.
    @Test func aStoredDrawDoesNotSpendTheRequest() {
        let stored = DayDraw(day: "2026-09-29", language: .mandarin, level: 3,
                             stretchID: "yi-jiu", words: WordSeeds())
        var spent = false
        let drawn = DayDraw.forToday(stored, day: "2026-09-29", language: .mandarin, level: 3) {
            let r = StretchRequest.stretch(on: "2026-09-29", language: .mandarin,
                                           request: Self.request, known: Self.known) { nil }
            spent = r.spent
            return (r.id, WordSeeds())
        }
        #expect(drawn.stretchID == "yi-jiu")
        #expect(!spent)

        let fresh = DayDraw.forToday(nil, day: "2026-09-29", language: .mandarin, level: 3) {
            let r = StretchRequest.stretch(on: "2026-09-29", language: .mandarin,
                                           request: Self.request, known: Self.known) { nil }
            spent = r.spent
            return (r.id, WordSeeds())
        }
        #expect(fresh.stretchID == "deng-zai")
        #expect(spent)
    }

    @Test func tomorrowAlreadyDrawnTakesTheRequestDirectly() {
        let ahead = DayDraw(day: "2026-09-29", language: .mandarin, level: 3,
                            stretchID: "yi-jiu", words: WordSeeds())
        let swapped = Self.request.replacing(ahead, tomorrow: "2026-09-29")
        #expect(swapped?.stretchID == "deng-zai")
        #expect(swapped?.level == 3)
        #expect(Self.request.replacing(ahead, tomorrow: "2026-09-30") == nil)
        #expect(Self.request.replacing(nil, tomorrow: "2026-09-29") == nil)
    }

    @Test func requestsSurviveARoundTrip() throws {
        let data = try JSONEncoder().encode(["mandarin": Self.request])
        let back = try JSONDecoder().decode([String: StretchRequest].self, from: data)
        #expect(back["mandarin"] == Self.request)
    }

    // MARK: Noted chapter

    static func sections(noted: [Textbook.Noted] = [],
                         suggestions: [Textbook.Suggestion] = []) -> [Textbook.Section] {
        Textbook.assemble(language: .mandarin, kinds: TextbookTests.kinds,
                          points: TextbookTests.points, noted: noted, progress: .init(),
                          suggestions: suggestions, bank: [], scope: .mine)
    }

    static func finding(_ subject: String, point: String?) -> Textbook.Noted {
        var atom = TextbookTests.atom(subject)
        atom.seed.pointID = point
        return Textbook.Noted(atom: atom, sentence: "我有三个书", at: .now)
    }

    static let pointIDs = Set(TextbookTests.points.map(\.id))

    @Test func nothingOfYoursIsNoChapter() {
        #expect(Textbook.notedChapter(language: .mandarin, sections: Self.sections(),
                                      bookPoints: [], known: Self.pointIDs) == nil)
    }

    @Test func findingsAndSuggestionsTheBookLacksLandInNoted() throws {
        let sections = Self.sections(
            noted: [Self.finding("本", point: nil)],
            suggestions: [TextbookTests.suggestion("把 order", point: nil)])
        let (chapter, sources) = try #require(Textbook.notedChapter(
            language: .mandarin, sections: sections, bookPoints: ["deng-zai"], known: Self.pointIDs))
        #expect(chapter.id == "zh.noted")
        #expect(chapter.name == "Noted")
        #expect(chapter.layout == .list)
        #expect(chapter.formats.isEmpty)
        #expect(Set(chapter.entries.map(\.head)) == ["本", "把 order"])
        let found = try #require(chapter.entries.first { $0.head == "本" })
        #expect(found.example == "我有三个书")
        #expect(sources[found.id]?.atom != nil)
        #expect(chapter.entries.allSatisfy { sources[$0.id] != nil })
    }

    @Test func anythingOnABookPointIsLeftToThatEntry() {
        let sections = Self.sections(
            noted: [Self.finding("量词", point: "measure-words")],
            suggestions: [TextbookTests.suggestion("等…再…", point: "deng-zai")])
        let got = Textbook.notedChapter(language: .mandarin, sections: sections,
                                        bookPoints: ["measure-words", "deng-zai"],
                                        known: Self.pointIDs)
        #expect(got == nil)
    }

    @Test func aPointTheBookLacksKeepsItsLink() throws {
        let sections = Self.sections(suggestions: [TextbookTests.suggestion("了", point: "le-change")])
        let (chapter, _) = try #require(Textbook.notedChapter(
            language: .mandarin, sections: sections, bookPoints: ["deng-zai"], known: Self.pointIDs))
        #expect(chapter.entries.map(\.point) == ["le-change"])
    }

    @Test func notedStateReadsTheRecord() {
        let sections = Self.sections(noted: [Self.finding("本", point: nil)])
        let entry = sections.flatMap(\.entries).first!
        let state = Textbook.state(of: entry)
        #expect(state.slipping)
        #expect(state.standing == .tried)
    }

    // MARK: Formulas

    @Test func formulaSlotsFillFromTheExample() {
        #expect(Formula.parse("等…再…") == [.word("等"), .slot("A"), .word("再"), .slot("B")])
        #expect(Formula.filled("等…再…", with: "等你下班，我们再吃饭。") ==
                [.word("等"), .filled("你下班，我们"), .word("再"), .filled("吃饭")])
        #expect(Formula.filled("一…就…", with: "我一到家就睡觉") ==
                [.plain("我"), .word("一"), .filled("到家"), .word("就"), .filled("睡觉")])
        #expect(Formula.filled("venir de …", with: "Je viens de manger") == nil)
    }
}
