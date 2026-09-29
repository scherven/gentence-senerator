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

    @Test func languagesAreSeparate() {
        var log = ActivityLog()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        log.add(.quiz, on: day, .german)
        #expect(log.marks(on: day, .german) == [.quiz])
        #expect(log.marks(on: day, .french).isEmpty)
    }
}
