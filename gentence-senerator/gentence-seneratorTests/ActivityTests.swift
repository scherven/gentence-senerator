import Testing
import Foundation
@testable import gentence_senerator

struct ActivityTests {

    static func session(_ mode: Mode, answered: Int, goal: Int = 2,
                        day: String = "2026-09-20") -> Session {
        var s = Session(id: "\(day)|german|\(mode.rawValue)", language: .german, mode: mode,
                        startedAt: .now, turns: [], goal: goal)
        for i in 0..<answered { s.turns.append(GradingTests.turn("a\(i)")) }
        return s
    }

    @Test func shadeCountsAllThree() {
        #expect(ActivityLog.shade([]) == .none)
        #expect(ActivityLog.shade([.quiz]) == .some)
        #expect(ActivityLog.shade([.translate, .produce]) == .some)
        #expect(ActivityLog.shade([.translate, .produce, .quiz]) == .all)
    }

    @Test func onlyAFinishedSetCounts() {
        var log = ActivityLog()
        let unfinished = log.add(Self.session(.translate, answered: 1))
        let finished = log.add(Self.session(.translate, answered: 2))
        let again = log.add(Self.session(.translate, answered: 2))
        let listen = log.add(Self.session(.listen, answered: 2))
        #expect(!unfinished)
        #expect(finished)
        #expect(!again)
        #expect(!listen)
        #expect(log.days["2026-09-20|german"] == [.translate])
    }

    @Test func aReopenedSetStillCounts() {
        var s = Self.session(.produce, answered: 2)
        s.regoal(4)
        #expect(!s.isComplete)
        #expect(ActivityLog.mark(for: s) == .produce)
    }

    @Test func ticksSayWhichInCellOrder() {
        #expect(ActivityLog.ticks([]) == [false, false, false])
        #expect(ActivityLog.ticks([.quiz]) == [false, false, true])
        #expect(ActivityLog.ticks([.produce, .translate]) == [true, true, false])
        #expect(ActivityLog.ticks([.translate, .produce, .quiz]) == [true, true, true])
    }

    @Test func historyKeepsOneLanguage() throws {
        let german = Self.session(.translate, answered: 2, day: "2026-09-20")
        var french = Self.session(.produce, answered: 2, day: "2026-09-20")
        french.language = .french
        let archive = [ArchiveDay(day: "2026-09-20", sessions: [german, french]),
                       ArchiveDay(day: "2026-09-19", sessions: [french])]
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd HH:mm"
        let at = try #require(parse.date(from: "2026-09-18 10:00"))
        let today = try #require(parse.date(from: "2026-09-29 10:00"))
        let score = QuizLog.Score(right: 17, total: 20, seconds: 60, at: at)
        let quizzes = ["german|de.case": QuizLog.PlanRecord(rounds: 2, scores: [
                           score, QuizLog.Score(right: 5, total: 5, seconds: 9, at: today)]),
                       "french|fr.gender": QuizLog.PlanRecord(rounds: 1, scores: [score])]

        let days = HistoryDay.build(archive: archive, quizzes: quizzes, language: .german,
                                    today: "2026-09-29") { $0 == "de.case" ? "Case" : "Quiz" }
        #expect(days.map(\.day) == ["2026-09-20", "2026-09-18"])
        #expect(days[0].rows == [.session(german)])
        #expect(days[1].rows == [.quiz(name: "Case", score: score)])
        #expect(days[1].label == "SEP 18")
    }

    @Test func firstAnswerSkipsBlanks() {
        var s = Self.session(.produce, answered: 0)
        #expect(s.firstAnswer == nil)
        var blank = GradingTests.turn("x")
        blank.attempt.confirmed = ""
        s.turns = [blank, GradingTests.turn("Ich bin da.")]
        #expect(s.firstAnswer == "Ich bin da.")
    }

    @Test func languagesAreSeparate() {
        var log = ActivityLog()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        log.add(.quiz, on: day, .german)
        #expect(log.marks(on: day, .german) == [.quiz])
        #expect(log.marks(on: day, .french).isEmpty)
    }
}
