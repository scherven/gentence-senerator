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
                                  heard: ["recent": [ShelfTests.heard(2)],
                                          "due-9": [ShelfTests.heard(9)],
                                          "due-20": [ShelfTests.heard(20)]],
                                  today: ShelfTests.today, calendar: ShelfTests.calendar)
        #expect(shelf.map(\.id) == ["half", "due-20", "due-9", "short-new", "long-new", "recent"])
        #expect(shelf[0].status == .inProgress(pass: 2))
        #expect(shelf[1].status == .due(days: 20))
        #expect(shelf.last?.status == .done(days: 2))
    }

    /// Due is a line, not a gradient: six days is done, seven is due.
    @Test func dueFromSevenDays() {
        let ps = [ShelfTests.passage("a", seconds: 40, lesson: 1), ShelfTests.passage("b", seconds: 40, lesson: 2)]
        let shelf = Shelf.entries(ps, runs: [:],
                                  heard: ["a": [ShelfTests.heard(6)], "b": [ShelfTests.heard(7)]],
                                  today: ShelfTests.today, calendar: ShelfTests.calendar)
        #expect(shelf.first { $0.id == "a" }?.status == .done(days: 6))
        #expect(shelf.first { $0.id == "b" }?.status == .due(days: 7))
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
