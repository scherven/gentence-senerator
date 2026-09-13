import Testing
import Foundation
@testable import gentence_senerator

/// The plan screen shows what has been picked and how much of the curriculum is
/// working. Both are properties of these functions and nothing else — the view
/// only renders what comes out of here — so they are pinned here.
struct DayPlanTests {

    static let pack = LanguagePacks.pack(for: .mandarin)

    static func point(_ id: String, level: Int = 1) -> GrammarPoint {
        GrammarPoint(id: id, name: "了 for a change of state", level: level,
                     kind: .particle, instruction: "", examples: [])
    }

    static func read(progress: gentence_senerator.Progress = .init(),
                     level: Int = 2,
                     stretch: GrammarPoint? = DayPlanTests.point("le-change"),
                     words: WordSeeds = WordSeeds(),
                     now: Date = .now) -> DayPlan {
        DayPlan.read(pack: pack, level: level, use: .spoken, progress: progress,
                     stretch: stretch, words: words, now: now)
    }

    static func items(_ plan: DayPlan, _ slot: DayPlan.Slot) -> [String] {
        plan.rows.first { $0.slot == slot }?.items ?? []
    }

    // MARK: The four rows

    /// A row is the pick itself. The explanatory line under it is gone — the
    /// owner had read it enough times — so what the row says is the thing.
    @Test func everyRowIsWhatWasPicked() {
        let now = Self.saturday
        var progress = gentence_senerator.Progress()
        progress.classify(Self.atom("把"), as: .gap, language: .mandarin,
                          on: Self.back(3, from: now))

        let plan = Self.read(progress: progress,
                             words: WordSeeds(have: ["环境", "安静"], new: ["复杂"]),
                             now: now)
        #expect(Self.items(plan, .structure) == ["了 for a change of state"])
        #expect(Self.items(plan, .words) == ["环境", "安静"])
        #expect(Self.items(plan, .new) == ["复杂"])
        #expect(Self.items(plan, .back) == ["把"])
    }

    /// Nothing to stretch for, nothing due, nothing drawn. Four empty rows
    /// rather than four invented ones.
    @Test func aRowIsEmptyWhenThereWasNothingToPick() {
        let plan = Self.read(stretch: nil)
        #expect(DayPlan.Slot.allCases.allSatisfy { Self.items(plan, $0).isEmpty })
        #expect(plan.rows.map(\.slot) == DayPlan.Slot.allCases)
    }

    /// The governing rule, checked rather than trusted: a row names the thing
    /// the way a learner would, never the way the source does.
    @Test func noRowLeaksTheMachinery() {
        var progress = gentence_senerator.Progress()
        progress.produced(["好"], language: .mandarin)
        progress.classify(Self.atom("把"), as: .gap, language: .mandarin)
        let plan = Self.read(progress: progress,
                             words: WordSeeds(have: ["环境"], new: ["安静"]))

        let leaks = ["le-change", "pointID", "neverAttempted", "holding", "dueAt"]
        for row in plan.rows {
            for item in row.items {
                for leak in leaks {
                    #expect(!item.lowercased().contains(leak.lowercased()),
                            "\(row.slot.rawValue) says \(leak): \(item)")
                }
            }
        }
    }

    // MARK: The record

    @Test func theRecordIsOneRowPerBandUpToTheirLevel() {
        let plan = Self.read(level: 3)
        #expect(plan.bands.map(\.level) == [1, 2, 3])
        #expect(plan.bands.map(\.name) == ["HSK 1", "HSK 2", "HSK 3"])
        #expect(plan.bands.allSatisfy { !$0.cells.isEmpty })
        // What is above them is not on the map at all.
        #expect(!plan.bands.contains { $0.level > 3 })
    }

    /// Four steps of one thing, and the fourth is the one `Progress.state` does
    /// not have: a point that keeps working, rather than one that has worked.
    @Test func theFourStepsOfTheRamp() {
        var progress = gentence_senerator.Progress()
        #expect(DayPlan.standing(of: "a", in: progress) == .never)

        progress.attempted(pointID: "b", language: .mandarin, succeeded: false)
        #expect(DayPlan.standing(of: "b", in: progress) == .tried)

        progress.attempted(pointID: "c", language: .mandarin, succeeded: true)
        #expect(DayPlan.standing(of: "c", in: progress) == .holding)

        for _ in 0..<DayPlan.solidUses {
            progress.attempted(pointID: "d", language: .mandarin, succeeded: true)
        }
        #expect(DayPlan.standing(of: "d", in: progress) == .solid)
    }

    @Test func theCountIsWhatHasWorkedOutOfWhatIsThere() {
        var progress = gentence_senerator.Progress()
        let first = Self.pack.reachable(at: 1, use: .spoken).filter { $0.level == 1 }
        for point in first.prefix(2) {
            progress.attempted(pointID: point.id, language: .mandarin, succeeded: true)
        }
        // Attempted and never landing does not count as had.
        if let third = first.dropFirst(2).first {
            progress.attempted(pointID: third.id, language: .mandarin, succeeded: false)
        }

        let band = Self.read(progress: progress, level: 1).bands[0]
        #expect(band.held == 2)
        #expect(band.cells.count == first.count)
    }

    @Test func todaysStretchIsMarkedAndNothingElseIs() {
        let target = Self.pack.reachable(at: 2, use: .spoken).first { $0.level == 2 }!
        let plan = Self.read(level: 2, stretch: target)
        let marked = plan.bands.flatMap(\.cells).filter(\.today)
        #expect(marked.count == 1)
        #expect(marked.first?.id == target.id)
    }

    /// The passé simple is absent from speech because that is correct. A record
    /// that counted it would show a permanent hole the learner cannot close.
    @Test func theRecordLeavesOutWhatDoesNotApplyInThisMode() {
        let french = LanguagePacks.pack(for: .french)
        let spoken = DayPlan.read(pack: french, level: 6, use: .spoken,
                                  progress: .init(), stretch: nil, words: WordSeeds())
        let ids = Set(spoken.bands.flatMap(\.cells).map(\.id))
        #expect(!ids.contains("passe-simple"))
        #expect(ids.count == french.reachable(at: 6, use: .spoken).count)
    }

    // MARK: Seeding

    @Test func theBandWordsDrawnAreOnesTheyHaveNeverSaid() {
        var progress = gentence_senerator.Progress()
        progress.produced(["好", "吃"], language: .mandarin)
        let seeds = WordSeeds.read(band: ["好", "吃", "白", "环境"],
                                   above: ["安静", "复杂"],
                                   progress: progress, language: .mandarin)
        #expect(seeds.have.count == 2)
        #expect(Set(seeds.have) == ["白", "环境"])
        #expect(seeds.new.count == 2)
    }

    /// Nothing left to widen into is not an error, and the top level has no
    /// band above it.
    @Test func seedingWithNothingToDrawFrom() {
        var progress = gentence_senerator.Progress()
        progress.produced(["好"], language: .mandarin)
        let seeds = WordSeeds.read(band: ["好"], above: [],
                                   progress: progress, language: .mandarin)
        #expect(seeds.isEmpty)
    }

    // MARK: The day's draw

    static let today = "2026-09-08"

    /// Reopening the app used to deal a new stretch and new words, so the plan
    /// changed under the learner and stopped matching what the day's sentences
    /// had been written from. The draw is made once and kept.
    @Test func theDrawSurvivesARelaunchOnTheSameDay() throws {
        var draws = 0
        let first = DayDraw.forToday(nil, day: Self.today,
                                     language: .mandarin, level: 2) {
            draws += 1
            return ("le-change", WordSeeds(have: ["环境"], new: ["复杂"]))
        }
        #expect(draws == 1)

        // Encoded, decoded, handed back — which is all a relaunch is.
        let stored = try JSONDecoder().decode(
            DayDraw.self, from: JSONEncoder().encode(first))
        let again = DayDraw.forToday(stored, day: Self.today,
                                     language: .mandarin, level: 2) {
            draws += 1
            return (nil, WordSeeds())
        }
        #expect(draws == 1)
        #expect(again == first)
        #expect(again.stretchID == "le-change")
        #expect(again.words == WordSeeds(have: ["环境"], new: ["复杂"]))
    }

    /// Three things move the day on, and finishing a session is not one of
    /// them: the record behind the plan is rebuilt every time, but the draw is
    /// not, so ending a session does not hand back a different day.
    @Test func onlyANewDayLanguageOrLevelDrawsAgain() {
        let held = DayDraw(day: Self.today, language: .mandarin, level: 2,
                           stretchID: "le-change", words: WordSeeds(have: ["环境"]))
        let fresh: (stretchID: String?, words: WordSeeds) = ("ba-construction", WordSeeds())

        #expect(DayDraw.forToday(held, day: Self.today, language: .mandarin,
                                 level: 2) { fresh } == held)
        #expect(DayDraw.forToday(held, day: "2026-09-09", language: .mandarin,
                                 level: 2) { fresh }.stretchID == "ba-construction")
        #expect(DayDraw.forToday(held, day: Self.today, language: .german,
                                 level: 2) { fresh }.stretchID == "ba-construction")
        #expect(DayDraw.forToday(held, day: Self.today, language: .mandarin,
                                 level: 3) { fresh }.stretchID == "ba-construction")
    }

    /// `Vault.load` decodes behind `try?`, so a synthesised initialiser that
    /// threw on a missing key would silently discard the whole draw. It reads
    /// every field as optional instead, and lands on a day matching nothing —
    /// a half-written draw redraws rather than standing.
    @Test func aHalfWrittenDrawRedrawsRatherThanStanding() throws {
        let stored = try JSONDecoder().decode(
            DayDraw.self, from: Data(#"{"language":"mandarin","level":2}"#.utf8))
        #expect(stored.day == "")
        #expect(stored.stretchID == nil)
        #expect(stored.words.isEmpty)

        var drew = false
        _ = DayDraw.forToday(stored, day: Self.today, language: .mandarin, level: 2) {
            drew = true
            return (nil, WordSeeds())
        }
        #expect(drew)

        // The seeds carry the same hazard, one level down.
        #expect(try JSONDecoder().decode(WordSeeds.self, from: Data("{}".utf8)).isEmpty)
    }

    /// Saturday 5 September 2026, so "three days ago" is inside the window a
    /// due item is drawn from.
    static let saturday = Calendar.current.date(
        from: DateComponents(year: 2026, month: 9, day: 5, hour: 12))!

    static func back(_ days: Int, from date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: date)!
    }

    private static func atom(_ subject: String) -> Atom {
        Atom(id: Atom.identify(.wordChoice, subject), kind: .wordChoice,
             verdict: .breaks, stages: .init(locate: "Second half."),
             seed: .init(subject: subject, context: "", pointID: nil))
    }
}
