import Testing
import Foundation
@testable import gentence_senerator

/// The textbook is assembled on read from records that already exist. What
/// lands where, and what merges with what, is decided here and nowhere else.
struct TextbookTests {

    static let kinds: [AtomKind] = [.wordOrder, .particle, .measureWord, .tenseAspect]

    static let points = [
        GrammarPoint(id: "le-change", name: "了 for a change of state", level: 1,
                     kind: .particle, instruction: "Now true.", examples: ["下雨了"]),
        GrammarPoint(id: "deng-zai", name: "等…再…", level: 3,
                     kind: .wordOrder, instruction: "Wait until, then.", examples: ["等他来再吃"]),
        GrammarPoint(id: "measure-words", name: "Number + measure word + noun", level: 1,
                     kind: .measureWord, instruction: "Counting.", examples: ["三本书"]),
    ]

    static func atom(_ subject: String, _ kind: AtomKind = .measureWord,
                     verdict: Atom.Verdict = .breaks, fix: String = "") -> Atom {
        Atom(id: Atom.identify(kind, subject), kind: kind, verdict: verdict,
             stages: .init(locate: "Somewhere.", name: "Wrong one.", fix: fix, note: ""),
             seed: .init(subject: subject, context: "我有三个书", pointID: nil))
    }

    static func suggestion(_ subject: String, kind: AtomKind = .wordOrder,
                           point: String? = nil, at: Date = .now) -> Textbook.Suggestion {
        .init(kind: kind, subject: subject, headline: "Wait, then act.", pointID: point,
              language: .mandarin, question: "How do I say wait until?", context: "我先吃", at: at)
    }

    static func build(noted: [Textbook.Noted] = [],
                      progress: gentence_senerator.Progress = .init(),
                      suggestions: [Textbook.Suggestion] = [],
                      bank: [BankEntry] = [],
                      scope: Textbook.Scope = .all,
                      search: String = "") -> [Textbook.Section] {
        Textbook.assemble(language: .mandarin, kinds: kinds, points: points,
                          noted: noted, progress: progress, suggestions: suggestions,
                          bank: bank, scope: scope, search: search)
    }

    static func entries(_ sections: [Textbook.Section]) -> [Textbook.Entry] {
        sections.flatMap(\.entries)
    }

    @Test func sectionsFollowThePackKindOrder() {
        let sections = Self.build()
        #expect(sections.map(\.kind) == [.wordOrder, .particle, .measureWord])
        #expect(sections.first?.title == "Word order")
    }

    @Test func aFindingIsFiledUnderItsKindWithTheLatestWording() {
        let old = Date(timeIntervalSince1970: 0)
        let noted = [
            Textbook.Noted(atom: Self.atom("本", fix: "三本书"), sentence: "我有三个书", at: .now),
            Textbook.Noted(atom: Self.atom("本", fix: "old"), sentence: "old", at: old),
        ]
        let entries = Self.build(noted: noted, scope: .mine).flatMap(\.entries)
        #expect(entries.count == 1)
        let e = try! #require(entries.first)
        #expect(e.kind == .measureWord)
        #expect(e.noted == 2)
        #expect(e.sentence == "我有三个书")
        #expect(e.detail.hasPrefix("三本书"))
        #expect(e.atom != nil)
    }

    @Test func keptFindingsAreNotNoted() {
        let noted = [Textbook.Noted(atom: Self.atom("本", verdict: .kept), sentence: "", at: .now)]
        #expect(Self.build(noted: noted, scope: .mine).isEmpty)
    }

    @Test func aSuggestionNamingAPointFilesOntoThatPoint() {
        let entries = Self.entries(Self.build(suggestions: [Self.suggestion("等…再…", point: "deng-zai")]))
        let point = try! #require(entries.first { $0.pointID == "deng-zai" })
        #expect(point.origins == [.curriculum, .suggested])
        #expect(point.question == "How do I say wait until?")
        #expect(entries.filter { $0.title == "等…再…" }.count == 1)
    }

    @Test func aSuggestionWithNoPointStandsAloneAndMergesWithAFinding() {
        let s = Self.suggestion("一边…一边…", kind: .wordOrder)
        let finding = Self.atom("一边…一边…", .wordOrder)
        let entries = Self.entries(Self.build(
            noted: [.init(atom: finding, sentence: "我吃饭一边", at: .now)],
            suggestions: [s], scope: .mine))
        #expect(entries.count == 1)
        #expect(entries.first?.origins == [.noted, .suggested])
        #expect(entries.first?.seed.subject == "一边…一边…")
    }

    @Test func aPointIdTheCurriculumLacksIsIgnored() {
        let entries = Self.entries(Self.build(
            suggestions: [Self.suggestion("把", kind: .wordOrder, point: "made-up")], scope: .mine))
        #expect(entries.count == 1)
        #expect(entries.first?.pointID == nil)
    }

    @Test func pinsGetTheirOwnSectionFirstAndAreNotRepeated() {
        let finding = Self.atom("本")
        let bank = [BankEntry(atom: finding, language: .mandarin, sentence: "我有三个书")]
        let sections = Self.build(noted: [.init(atom: finding, sentence: "我有三个书", at: .now)],
                                  bank: bank)
        #expect(sections.first?.kind == nil)
        #expect(sections.first?.entries.map(\.id) == [finding.id])
        #expect(Self.entries(sections).filter { $0.id == finding.id }.count == 1)
    }

    @Test func aPinnedPointRoundTripsThroughTheBank() {
        let point = try! #require(Self.entries(Self.build()).first { $0.pointID == "le-change" })
        let pin = BankEntry(entry: point, language: .mandarin)
        let data = try! JSONEncoder().encode([pin])
        let back = try! JSONDecoder().decode([BankEntry].self, from: data)
        let pinned = Self.build(bank: back, scope: .mine)
        #expect(pinned.count == 1)
        #expect(pinned.first?.entries.first?.id == point.id)
        #expect(pinned.first?.entries.first?.origins == [.curriculum, .kept])
    }

    @Test func aBankEntryFromBeforePointIDStillDecodes() {
        let json = """
        [{"atomID":"measure-word/本","kind":"measure-word","language":"mandarin",
          "subject":"本","fix":"三本书","note":"Books take 本.","sentence":"我有三个书","savedAt":0}]
        """
        let bank = try! JSONDecoder().decode([BankEntry].self, from: Data(json.utf8))
        #expect(bank.first?.pointID == nil)
        let entries = Self.entries(Self.build(bank: bank, scope: .mine))
        #expect(entries.first?.pinned == true)
        #expect(entries.first?.sentence == "我有三个书")
    }

    @Test func scopesFilterTheCurriculumButNeverYours() {
        let s = Self.suggestion("一边…一边…")
        #expect(Self.entries(Self.build(suggestions: [s], scope: .mine)).count == 1)
        let upTo1 = Self.entries(Self.build(suggestions: [s], scope: .upTo(1)))
        #expect(Set(upTo1.map(\.id)) == ["point/le-change", "point/measure-words", s.id])
        #expect(Self.entries(Self.build(suggestions: [s], scope: .all)).count == 4)
    }

    @Test func searchMatchesTitlesAndExamples() {
        #expect(Self.entries(Self.build(search: "三本")).map(\.pointID) == ["measure-words"])
        #expect(Self.entries(Self.build(search: "等")).map(\.pointID) == ["deng-zai"])
    }

    @Test func yoursRankAboveTheSyllabusWithinASection() {
        let finding = Self.atom("了", .particle)
        let entries = Self.build(noted: [.init(atom: finding, sentence: "", at: .now)])
            .first { $0.kind == .particle }?.entries ?? []
        #expect(entries.map(\.id) == [finding.id, "point/le-change"])
    }

    @Test func encountersCarryTheSchedule() {
        var progress = gentence_senerator.Progress()
        let finding = Self.atom("本")
        progress.saw(finding, language: .mandarin)
        let e = try! #require(Self.entries(Self.build(progress: progress, scope: .mine)).first)
        #expect(e.id == finding.id)
        #expect(e.noted == 1)
        #expect(e.returns == "tomorrow")
    }

    @Test func reachComesFromStructureUse() {
        var progress = gentence_senerator.Progress()
        progress.attempted(pointID: "le-change", language: .mandarin, succeeded: true)
        progress.attempted(pointID: "le-change", language: .mandarin, succeeded: false)
        let e = try! #require(Self.entries(Self.build(progress: progress)).first { $0.pointID == "le-change" })
        #expect(e.used == 2)
        #expect(e.clean == 1)
    }

    @Test func otherLanguagesStayOut() {
        var s = Self.suggestion("weil")
        s.language = .german
        #expect(Self.build(suggestions: [s], scope: .mine).isEmpty)
    }

    // MARK: Capturing suggestions

    @Test func anAskReplyBecomesSuggestionsAndAnItem() throws {
        let json = """
        {"id":"a","question":"q","answer":"Use 等…再….","atoms":[
          {"kind":"word-order","headline":"Wait, then.","subject":"等…再…","point":"deng-zai"},
          {"kind":"particle","headline":"Done.","subject":"了","point":"nope"},
          {"kind":"particle","headline":"x","subject":"吧","point":null}]}
        """
        let reply = try JSONDecoder().decode(AskReply.self, from: Data(json.utf8))
        #expect(reply.item.atoms.count == 3)
        let s = reply.suggestions(language: .mandarin, validPoints: ["deng-zai"],
                                  question: "How?", context: "我先吃")
        #expect(s.map(\.pointID) == ["deng-zai", nil, nil])
        #expect(s.allSatisfy { $0.question == "How?" && $0.context == "我先吃" })
    }

    @Test func addingTheSameSuggestionReplacesIt() {
        let old = Self.suggestion("等…再…", at: Date(timeIntervalSince1970: 0))
        let new = Self.suggestion("等…再…")
        var german = Self.suggestion("等…再…")
        german.language = .german
        let list = Textbook.Suggestion.adding([new], to: [old, german])
        #expect(list.count == 2)
        #expect(list.contains { $0.language == .mandarin && $0.at == new.at })
    }

    @Test func suggestionsDecodeWithFieldsMissing() throws {
        let json = #"[{"kind":"word-order","subject":"等…再…","language":"mandarin"}]"#
        let list = try JSONDecoder().decode([Textbook.Suggestion].self, from: Data(json.utf8))
        #expect(list.first?.headline == "")
        #expect(list.first?.pointID == nil)
    }

    @Test func notedReadsProblemsOutOfSessions() {
        let turn = Turn(id: UUID(), mode: .translate, language: .mandarin, createdAt: .now,
                        prompt: .init(english: "I have three books.", target: nil,
                                      audioSource: nil, pointID: nil),
                        attempt: .init(heard: "", confirmed: "我有三个书", wasTyped: true),
                        review: Review(score: 60, readOfScore: "", atoms: [
                            Self.atom("本"), Self.atom("有", .wordOrder, verdict: .kept)]))
        let session = Session(id: "2026-09-20|mandarin|translate", language: .mandarin,
                              mode: .translate, startedAt: .now, turns: [turn], goal: 3)
        var german = session
        german.language = .german
        // The same session twice (live and archived) counts once.
        let noted = Textbook.noted(in: [session, session, german], language: .mandarin)
        #expect(noted.map(\.atom.seed.subject) == ["本"])
        #expect(noted.first?.sentence == "我有三个书")
        #expect(Calendar.current.component(.day, from: noted.first!.at) == 20)
    }
}
