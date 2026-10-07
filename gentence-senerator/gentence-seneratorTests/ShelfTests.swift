import Testing
import Foundation
@testable import gentence_senerator

/// The picker's order is the suggestion: its first entry is what "up next"
/// offers, so the order is the behaviour.
struct ShelfTests {

    static func passage(_ id: String, seconds: Double, lesson: Int) -> Passage {
        Passage(id: id, lesson: lesson, language: .mandarin, level: 4, title: id, audio: nil,
                seconds: seconds, setup: "", speakers: [],
                lines: [.init(n: 1, speaker: "A", text: "", english: "", start: 0, end: seconds, words: [])],
                gist: [], chunks: [])
    }

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let today = Date(timeIntervalSince1970: 1_790_000_000)
    static func daysAgo(_ n: Int) -> Date { today.addingTimeInterval(-Double(n) * 86_400) }

    static func heard(_ days: Int, right: Int = 2) -> Heard {
        Heard(on: daysAgo(days), right: right, asked: 3, before: .some, after: .most)
    }

    @Test func halfDoneThenDueThenShortestNewThenTheRest() {
        let ps = [ShelfTests.passage("long-new", seconds: 120, lesson: 1),
                  ShelfTests.passage("short-new", seconds: 40, lesson: 2),
                  ShelfTests.passage("recent", seconds: 50, lesson: 3),
                  ShelfTests.passage("due-9", seconds: 50, lesson: 4),
                  ShelfTests.passage("due-20", seconds: 50, lesson: 5),
                  ShelfTests.passage("half", seconds: 80, lesson: 6)]
        var run = PassageRun(passageID: "half", language: .mandarin, startedOn: "")
        run.stage = .read
        let shelf = Shelf.entries(ps, runs: ["half": run],
                                  heard: ["recent": [ShelfTests.heard(2), ShelfTests.heard(5)],
                                          "due-9": [ShelfTests.heard(9)],
                                          "due-20": [ShelfTests.heard(20)]],
                                  today: ShelfTests.today, calendar: ShelfTests.calendar)
        #expect(shelf.map(\.id) == ["half", "due-20", "due-9", "short-new", "long-new", "recent"])
        #expect(shelf[0].status == .inProgress(pass: 2))
        #expect(shelf[1].status == .due(days: 20))
        #expect(shelf.last?.status == .done(days: 2))
    }

    /// Heard once: due the next day. Twice: after three. A listen that ended
    /// at "some" starts over at one day.
    @Test func dueAfterGrowsWithEachListen() {
        let ps = ["once", "twice-2", "twice-3", "lost"].enumerated().map {
            ShelfTests.passage($0.element, seconds: 40, lesson: $0.offset)
        }
        let lost = Heard(on: ShelfTests.daysAgo(1), right: 1, asked: 3, before: .little, after: .some)
        let shelf = Shelf.entries(ps, runs: [:],
                                  heard: ["once": [ShelfTests.heard(1)],
                                          "twice-2": [ShelfTests.heard(2), ShelfTests.heard(9)],
                                          "twice-3": [ShelfTests.heard(3), ShelfTests.heard(9)],
                                          "lost": [lost, ShelfTests.heard(9), ShelfTests.heard(20)]],
                                  today: ShelfTests.today, calendar: ShelfTests.calendar)
        let status = { (id: String) in shelf.first { $0.id == id }?.status }
        #expect(status("once") == .due(days: 1))
        #expect(status("twice-2") == .done(days: 2))
        #expect(status("twice-3") == .due(days: 3))
        #expect(status("lost") == .due(days: 1))
    }

    /// The newest listen is the one the row reports, whatever order they were saved in.
    @Test func lastIsTheNewest() {
        let shelf = Shelf.entries([ShelfTests.passage("a", seconds: 40, lesson: 1)], runs: [:],
                                  heard: ["a": [ShelfTests.heard(20, right: 1), ShelfTests.heard(3, right: 3)]],
                                  today: ShelfTests.today, calendar: ShelfTests.calendar)
        #expect(shelf[0].last?.right == 3)
        #expect(shelf[0].heard.count == 2)
    }

    /// A finished run left behind is not "in progress".
    @Test func aDoneRunIsNotHalfDone() {
        var run = PassageRun(passageID: "a", language: .mandarin, startedOn: "")
        run.stage = .done
        let shelf = Shelf.entries([ShelfTests.passage("a", seconds: 40, lesson: 1)], runs: ["a": run],
                                  heard: [:], today: ShelfTests.today, calendar: ShelfTests.calendar)
        #expect(shelf[0].status == .new)
    }
}
