import Foundation
import Testing
@testable import gentence_senerator

struct PingsTests {
    let cal = Calendar.current
    let langs: [Language] = [.mandarin, .french, .german]

    func at(_ h: Int, _ m: Int = 0) -> Date {
        cal.date(bySettingHour: h, minute: m, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
    }

    func plan(now: Date, done: Set<Pings.Item> = [], talk: Language? = .french) -> [Pings.Fire] {
        Pings.plan(languages: langs, from: 8, to: 23, now: now,
                   done: { done.contains($0) }, body: { "line \($0.label)" },
                   talk: talk, calendar: cal)
    }

    @Test func sixSlotsTwoAndAHalfHoursApart() {
        let slots = Pings.slots(languages: langs, from: 8, to: 23, day: at(12), calendar: cal)
        #expect(slots.map(\.at) == [at(8), at(10, 30), at(13), at(15, 30), at(18), at(20, 30)])
        #expect(slots.map(\.item.label) == ["zh translate", "fr translate", "de translate",
                                            "zh reply", "fr reply", "de reply"])
    }

    @Test func beforeTheDayEveryOneIsAhead() {
        let fires = plan(now: at(7))
        #expect(fires.count == 6)
        #expect(fires[0].title == "zh translate")
        #expect(fires[0].body == "line zh translate")
        #expect(fires[0].end == at(10, 30))
        #expect(fires[5].end == at(23))
        #expect(fires[0].ticks == [1, 2, 2, 2, 2, 2])
    }

    @Test func aMissedSlotRollsIn() {
        let fires = plan(now: at(11), done: [.init(language: .mandarin, mode: .translate)])
        // 10:30 is running and owed; 13:00 carries it.
        #expect(fires[0].at == at(10, 30))
        #expect(fires[1].title == "fr translate · de translate")
        #expect(fires[1].body == "line fr translate")
        #expect(fires[1].ticks == [0, 1, 1, 2, 2, 2])
        #expect(plan(now: at(14))[1].title == "zh translate +3")
    }

    @Test func doneSlotsDoNotFire() {
        let done: Set<Pings.Item> = [.init(language: .mandarin, mode: .translate),
                                     .init(language: .french, mode: .translate)]
        let fires = plan(now: at(9), done: done)
        #expect(fires.map(\.title).first == "de translate")
        #expect(!fires.contains { $0.at == at(8) || $0.at == at(10, 30) })
    }

    @Test func talkOnlyOnceEverythingIsDone() {
        let all = Set(langs.flatMap { [Pings.Item(language: $0, mode: .translate),
                                       Pings.Item(language: $0, mode: .reply)] })
        #expect(!plan(now: at(12)).contains { $0.title == "talk" })
        let fires = plan(now: at(12), done: all)
        #expect(fires.map(\.title) == ["talk"])
        #expect(fires[0].at == at(22))
        #expect(plan(now: at(12), done: all, talk: nil).isEmpty)
    }

    @Test func liveActivityState() {
        let fire = plan(now: at(11))[1]
        let state = Pinger.state(fire)
        #expect(state.lead == "zh+2")
        #expect(state.end == at(15, 30).timeIntervalSince1970)
    }
}
