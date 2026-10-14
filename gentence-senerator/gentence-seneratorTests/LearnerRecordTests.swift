import Testing
import Foundation
@testable import gentence_senerator

struct LearnerRecordTests {

    static func turn(_ said: String, point: String? = nil, mode: Mode = .produce,
                     at: Date = .now) -> Turn {
        Turn(id: UUID(), mode: mode, language: .german, createdAt: at,
             prompt: .init(english: "Q", target: "Frage?", audioSource: nil, pointID: point),
             attempt: .init(heard: said, confirmed: said, wasTyped: true,
                            audioFilename: nil, pronunciation: nil),
             review: nil)
    }

    static func atom(_ subject: String, point: String?, verdict: Atom.Verdict = .breaks,
                     fix: String = "") -> Atom {
        Atom(id: Atom.identify(.caseChoice, subject), kind: .caseChoice, verdict: verdict,
             stages: .init(locate: "Here.", name: "Wrong.", fix: fix, note: ""),
             seed: .init(subject: subject, context: "", pointID: point))
    }

    /// The asked point, tagged points and finding points each get one use;
    /// each is judged by its own findings only.
    @Test func eachPointIsJudgedByItsOwnFindings() {
        var r = LearnerRecord()
        let t = Self.turn("Ich lege es auf dem Tisch.", point: "perfekt")
        let review = Review(score: 70, readOfScore: "", atoms: [
            Self.atom("auf + Akk", point: "two-way", fix: "auf den Tisch")
        ], usedPoints: ["perfekt", "word-order"], isDeep: true)
        r.note(t, review: review)
        #expect(r.point("perfekt", .german).uses.map(\.verdict) == [.clean])
        #expect(r.point("perfekt", .german).uses.first?.source == .asked)
        #expect(r.point("word-order", .german).uses.first?.source == .used)
        let twoWay = r.point("two-way", .german).uses
        #expect(twoWay.map(\.verdict) == [.breaks])
        #expect(twoWay.first?.source == .finding)
        #expect(twoWay.first?.fix == "auf den Tisch")
        #expect(r.feed.count == 1 && r.feed[0].verdict == .breaks)
        #expect(Set(r.feed[0].points) == ["perfekt", "word-order", "two-way"])
    }

    /// Landing the same answer twice replaces rather than doubles.
    @Test func aRelandedAnswerIsOneUse() {
        var r = LearnerRecord()
        let t = Self.turn("Hallo.", point: "p")
        let review = Review(score: 90, readOfScore: "", atoms: [], isDeep: true)
        r.note(t, review: review)
        r.note(t, review: review)
        #expect(r.point("p", .german).uses.count == 1)
        #expect(r.feed.count == 1)
    }

    /// Listen clips are dictation: fed, never a use.
    @Test func listenIsNotProduction() {
        var r = LearnerRecord()
        let review = Review(score: 50, readOfScore: "", atoms: [Self.atom("x", point: "p")],
                            isDeep: true)
        r.note(Self.turn("Hallo.", point: "p", mode: .listen), review: review)
        #expect(r.points.isEmpty)
        #expect(r.feed.first?.kind == .listen)
    }

    /// A round's answers share one feed line, misses named once.
    @Test func aRoundIsOneFeedLine() {
        var r = LearnerRecord()
        let item = QuizItem(id: "i", entry: "de.prep.auf", format: .flip, prompt: "auf ＿ Dach")
        for right in [true, false, false] {
            r.note(item, answer: .init(steps: [right], given: ["dem"]), pointID: "two-way",
                   planID: "de.prep", roundID: "R", language: .german, words: false, miss: "auf")
        }
        #expect(r.feed.count == 1)
        #expect(r.feed[0].right == 1 && r.feed[0].total == 3)
        #expect(r.feed[0].detail == "auf")
        #expect(r.point("two-way", .german).quiz.map(\.right) == [true, false, false])
    }

    @Test func usesAreCapped() {
        var r = LearnerRecord()
        let review = Review(score: 90, readOfScore: "", atoms: [], isDeep: true)
        for i in 0..<(LearnerRecord.pointCap + 5) {
            r.note(Self.turn("s\(i)", point: "p", at: Date(timeIntervalSinceNow: Double(i))),
                   review: review)
        }
        let uses = r.point("p", .german).uses
        #expect(uses.count == LearnerRecord.pointCap)
        #expect(uses.last?.sentence == "s\(LearnerRecord.pointCap + 4)")
    }

    /// Built once from the archive: graded turns become uses and feed lines;
    /// a dialogue, filed under its title, is a listen line.
    @Test func buildsFromTheArchive() {
        var graded = Self.turn("Ich bin gegangen.", point: "perfekt")
        graded.review = Review(score: 95, readOfScore: "", atoms: [], isDeep: true)
        var dialogue = Self.turn("Am Bahnhof", mode: .listen)
        dialogue.prompt.target = "Am Bahnhof"
        dialogue.review = Review(score: 75, readOfScore: "3 of 4 by ear.", atoms: [], isDeep: true)
        let ungraded = Self.turn("Noch nicht.")
        let session = Session(id: "2026-10-01|german|produce", language: .german, mode: .produce,
                              startedAt: .now, turns: [graded, dialogue, ungraded], goal: 3)
        let r = LearnerRecord.built(from: [session, session], quizzes: [
            "german|de.prep": .init(rounds: 1, best: 8,
                                    scores: [.init(right: 8, total: 10, seconds: 60, at: .now)])
        ])
        #expect(r.point("perfekt", .german).uses.count == 1)
        #expect(r.feed.count == 3)
        #expect(r.feed.contains { $0.kind == .listen && $0.detail == "3 of 4 by ear." })
        #expect(r.feed.contains { $0.kind == .quiz && $0.right == 8 && $0.planID == "de.prep" })
    }

    @Test func vocabEntryWord() {
        #expect(Store.word(ofVocabEntry: "vocab.german.z.B.") == "z.B.")
        #expect(Store.word(ofVocabEntry: "vocab.mandarin.好") == "好")
    }

    @Test func standingTakesTheHigher() {
        #expect(Store.higher(.tried, .holding) == .holding)
        #expect(Store.higher(.solid, .never) == .solid)
    }

    /// Old reviews tag every finding with the asked point, so a problem
    /// anywhere still fails it; new ones fail only the point named.
    @Test func cleanIsPerPoint() {
        let review = Review(score: 60, readOfScore: "", atoms: [Self.atom("x", point: "a")],
                            isDeep: true)
        #expect(!Store.clean(review, on: "a"))
        #expect(Store.clean(review, on: "b"))
    }

    /// A deck word missed lately takes one of the two slots.
    @Test func aMissedDeckWordSeedsTheDay() {
        let seeds = WordSeeds.read(band: ["a", "b", "c"], above: ["x"], progress: Progress(),
                                   language: .german, missed: ["m"])
        #expect(seeds.have.count == 2 && seeds.have.first == "m")
        let none = WordSeeds.read(band: ["a", "b", "c"], above: [], progress: Progress(),
                                  language: .german)
        #expect(none.have.count == 2 && !none.have.contains("m"))
    }
}
