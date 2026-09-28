import Testing
import Foundation
@testable import gentence_senerator

struct GoalTests {

    static let id = "2026-09-28|german|produce"

    /// `n` answers in produce, grouped the way `submit` groups them.
    static func answered(_ n: Int, onto session: Session = session(goal: 3),
                         size: Int = 3) -> Session {
        var s = session
        for _ in 0..<n {
            var t = GradingTests.turn("a\(s.turns.count)")
            t.exchangeID = Store.exchangeID(after: s.open, mode: s.mode, size: size)
            s.turns.append(t)
        }
        return s
    }

    static func session(goal: Int) -> Session {
        Session(id: id, language: .german, mode: .produce, startedAt: .now, turns: [], goal: goal)
    }

    static func job(for session: Session) -> GradingJob {
        GradingJob(id: UUID(), sessionID: session.id, language: session.language,
                   mode: session.mode, createdAt: .now,
                   exchanges: Store.unfiled(session, jobs: []))
    }

    @Test func raisingReopensAFinishedSession() {
        var s = Self.answered(3)
        #expect(s.isComplete)
        let moved = s.regoal(5)
        #expect(moved)
        #expect(!s.isComplete)
        #expect(s.goal == 5)
        #expect(s.filed == 3)
        #expect(s.open.isEmpty)
    }

    @Test func raisingAHeldSessionFilesNothing() {
        var s = Self.answered(2)
        let moved = s.regoal(5)
        #expect(moved)
        #expect(s.filed == nil)
        #expect(s.open.count == 2)
    }

    @Test func loweringNeverUnfinishesOrDrops() {
        var done = Self.answered(3)
        let movedDone = done.regoal(1)
        #expect(!movedDone)
        #expect(done.goal == 3 && done.turns.count == 3)

        var partway = Self.answered(2, onto: Self.session(goal: 5))
        let movedPartway = partway.regoal(1)
        #expect(!movedPartway)
        #expect(partway.goal == 5 && !partway.isComplete)

        var unstarted = Self.session(goal: 5)
        let movedUnstarted = unstarted.regoal(2)
        #expect(movedUnstarted)
        #expect(unstarted.goal == 2)
    }

    /// Raised then lowered before anything new was answered: finished again,
    /// at what was answered.
    @Test func loweringBackOverAReopenedSession() {
        var s = Self.answered(3)
        s.regoal(5)
        let moved = s.regoal(2)
        #expect(moved)
        #expect(s.goal == 3)
        #expect(s.isComplete)
    }

    /// The first job stands; the extra turns are their own job, in a fresh
    /// exchange even though the last filed one was short.
    @Test func extraTurnsAreGradedAsTheirOwnJob() {
        var s = Self.answered(2, onto: Self.session(goal: 2))
        let first = Self.job(for: s)
        #expect(first.exchanges.map(\.turnIDs.count) == [2])

        s.regoal(4)
        s = Self.answered(2, onto: s)
        #expect(s.isComplete)
        #expect(s.turns[2].exchangeID != s.turns[1].exchangeID)

        let rest = Store.unfiled(s, jobs: [first])
        #expect(rest.map(\.turnIDs) == [[s.turns[2].id, s.turns[3].id]])
        // Nothing is filed twice.
        var second = first
        second.exchanges = rest
        #expect(Store.unfiled(s, jobs: [first, second]).isEmpty)
    }

    /// A session filed before `filed` existed is not graded again.
    @Test func aSentSessionIsNotSentAgain() {
        let s = Self.answered(3)
        #expect(Store.unfiled(s, jobs: [Self.job(for: s)]).isEmpty)
    }

    @Test func oldSessionsDecodeWithoutFiled() throws {
        let data = try JSONEncoder().encode(Self.answered(1))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["filed"] = nil
        let back = try JSONDecoder().decode(Session.self,
                                            from: JSONSerialization.data(withJSONObject: json))
        #expect(back.filed == nil)
        #expect(back.open.count == 1)
    }

    // MARK: Feedback by day

    static func graded(_ sessionID: String, state: GradingJob.State) -> GradingJob {
        var job = GradingJob(id: UUID(), sessionID: sessionID, language: .german,
                             mode: .translate, createdAt: .now, exchanges: [])
        job.state = state
        return job
    }

    @Test func onlyTodaysFeedbackStaysOnTheMainScreen() {
        let today = "2026-09-28"
        let yesterday = "2026-09-27|german|translate"
        #expect(Store.showsToday(Self.graded("2026-09-28|german|translate", state: .done),
                                 landed: nil, today: today))
        #expect(!Store.showsToday(Self.graded(yesterday, state: .done),
                                  landed: "2026-09-27", today: today))
        #expect(!Store.showsToday(Self.graded(yesterday, state: .done),
                                  landed: nil, today: today))
        // Still out, or came back today: today's.
        #expect(Store.showsToday(Self.graded(yesterday, state: .grading),
                                 landed: nil, today: today))
        #expect(Store.showsToday(Self.graded(yesterday, state: .done),
                                 landed: today, today: today))
    }

    @Test func theArchiveIsByDayNewestFirst() {
        func s(_ day: String, _ mode: Mode, _ hour: Double) -> Session {
            Session(id: "\(day)|german|\(mode.rawValue)", language: .german, mode: mode,
                    startedAt: Date(timeIntervalSince1970: hour * 3600), turns: [], goal: 3)
        }
        let past = [s("2026-09-25", .translate, 1), s("2026-09-27", .translate, 50),
                    s("2026-09-27", .produce, 51), s("2026-09-28", .produce, 70),
                    s("2026-09-26", .produce, 30)]
        let days = Store.archive(past, showing: ["2026-09-26|german|produce"],
                                 today: "2026-09-28")
        #expect(days.map(\.day) == ["2026-09-27", "2026-09-25"])
        #expect(days[0].sessions.map(\.mode) == [.produce, .translate])
    }
}
