import Testing
import Foundation
@testable import gentence_senerator

/// Foundation has a `Progress` of its own.
typealias Progress = gentence_senerator.Progress

/// Both loops now record without waiting for a tap: a due subject woven into a
/// sentence moves on how the review came back, and a finding the learner never
/// opened still leaves a record. The ladder is the only thing either of them
/// can get wrong quietly, so this is where it is pinned down.
struct ProgressTests {

    static let day = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func days(_ n: Int, after start: Date = ProgressTests.day) -> Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: n,
                             to: calendar.startOfDay(for: start))!
    }

    /// Already on the schedule and due today, which is the only state
    /// `seedsForGeneration` ever hands out.
    static func encounter(_ kind: AtomKind, _ subject: String, stage: Int,
                          knowledge: Progress.Encounter.Knowledge = .gap,
                          language: Language = .mandarin) -> Progress.Encounter {
        var e = Progress.Encounter(
            atomID: Atom.identify(kind, subject), kind: kind, subject: subject,
            language: language, firstSeen: day
        )
        e.knowledge = knowledge
        e.stage = stage
        e.dueAt = day
        return e
    }

    static func progress(_ encounters: Progress.Encounter...) -> Progress {
        var p = Progress()
        for e in encounters { p.encounters[e.atomID] = e }
        return p
    }

    static func atom(_ kind: AtomKind, _ subject: String) -> Atom {
        Atom(id: Atom.identify(kind, subject), kind: kind, verdict: .breaks,
             stages: .init(locate: "Second half."),
             seed: .init(subject: subject, context: "我已经吃", pointID: nil))
    }

    // MARK: Retrieval

    @Test func retrievalHeldGoesUpTheLadder() {
        var progress = Self.progress(Self.encounter(.particle, "已经", stage: 1))
        progress.retrieved(subject: "已经", language: .mandarin, on: Self.day)

        let e = progress.encounters[Atom.identify(.particle, "已经")]
        #expect(e?.stage == 2)
        #expect(e?.dueAt == Self.days(3))
    }

    /// Down a rung, then rescheduled off that rung — so it comes back at the
    /// interval it last held, not the one it just failed.
    @Test func retrievalMissedDropsARung() {
        var progress = Self.progress(Self.encounter(.particle, "已经", stage: 3))
        progress.missed(subject: "已经", language: .mandarin, on: Self.day)

        let e = progress.encounters[Atom.identify(.particle, "已经")]
        #expect(e?.stage == 3)
        #expect(e?.dueAt == Self.days(7))
    }

    @Test func missingAtTheBottomStaysAtTheBottom() {
        var progress = Self.progress(Self.encounter(.particle, "已经", stage: 0))
        progress.missed(subject: "已经", language: .mandarin, on: Self.day)

        let e = progress.encounters[Atom.identify(.particle, "已经")]
        #expect(e?.stage == 1)
        #expect(e?.dueAt == Self.days(1))
    }

    /// A slip gets one recall check. Failing it takes it off the schedule
    /// rather than handing it a second.
    @Test func aFailedSlipIsNotResurrected() {
        var progress = Self.progress(
            Self.encounter(.tone, "shì", stage: 1, knowledge: .slip))
        progress.missed(subject: "shì", language: .mandarin, on: Self.day)

        #expect(progress.encounters[Atom.identify(.tone, "shì")]?.dueAt == nil)
    }

    @Test func aHeldSlipIsAlsoDone() {
        var progress = Self.progress(
            Self.encounter(.tone, "shì", stage: 1, knowledge: .slip))
        progress.retrieved(subject: "shì", language: .mandarin, on: Self.day)

        #expect(progress.encounters[Atom.identify(.tone, "shì")]?.dueAt == nil)
    }

    /// The subject is all `revisited` carries, and the same one sits under more
    /// than one kind.
    @Test func everyKindSharingASubjectMoves() {
        var progress = Self.progress(
            Self.encounter(.particle, "了", stage: 0),
            Self.encounter(.tenseAspect, "了", stage: 0)
        )
        progress.retrieved(subject: "了", language: .mandarin, on: Self.day)

        #expect(progress.encounters[Atom.identify(.particle, "了")]?.stage == 1)
        #expect(progress.encounters[Atom.identify(.tenseAspect, "了")]?.stage == 1)
    }

    /// Subjects collide across languages — `le` is a French article as well as
    /// a Mandarin particle.
    @Test func anotherLanguageIsLeftAlone() {
        var progress = Self.progress(
            Self.encounter(.particle, "le", stage: 0),
            Self.encounter(.gender, "le", stage: 0, language: .french)
        )
        progress.retrieved(subject: "le", language: .french, on: Self.day)

        #expect(progress.encounters[Atom.identify(.particle, "le")]?.stage == 0)
        #expect(progress.encounters[Atom.identify(.gender, "le")]?.stage == 1)
    }

    // MARK: Sightings

    /// An encounter with no date is invisible to `due`, so a finding nobody
    /// opened would still be a record of nothing.
    @Test func aFirstSightingIsScheduled() {
        var progress = Progress()
        progress.saw(Self.atom(.particle, "已经"), language: .mandarin, on: Self.day)

        let e = progress.encounters[Atom.identify(.particle, "已经")]
        #expect(e?.sightings == 1)
        #expect(e?.visits == 0)
        #expect(e?.dueAt == Self.days(1))
    }

    /// Otherwise anything that keeps coming back keeps getting further away.
    @Test func laterSightingsDoNotPushTheDateOut() {
        var progress = Progress()
        let atom = Self.atom(.particle, "已经")
        progress.saw(atom, language: .mandarin, on: Self.day)
        progress.saw(atom, language: .mandarin, on: Self.days(1))

        let e = progress.encounters[atom.id]
        #expect(e?.sightings == 2)
        #expect(e?.stage == 1)
        #expect(e?.dueAt == Self.days(1))
    }

    /// Opening a lesson is the stronger signal and stays that way.
    @Test func seeingIsNotOpening() {
        var progress = Progress()
        let atom = Self.atom(.particle, "已经")
        progress.opened(atom, language: .mandarin, on: Self.day)
        progress.saw(atom, language: .mandarin, on: Self.day)

        let e = progress.encounters[atom.id]
        #expect(e?.visits == 1)
        #expect(e?.stage == 1)
        #expect(e?.dueAt == Self.days(1))
    }

    // MARK: Stored JSON

    /// Sessions written before `revisited` existed have no such key, and a
    /// default value does not save them — the synthesised decoder demands it
    /// anyway, and one failure takes the whole archive.
    @Test func aPromptWithoutRevisitedStillDecodes() throws {
        let stored = #"{"english":"I already ate.","pointID":null}"#
        let prompt = try JSONDecoder().decode(Turn.Prompt.self, from: Data(stored.utf8))

        #expect(prompt.english == "I already ate.")
        #expect(prompt.target == nil)
        #expect(prompt.revisited.isEmpty)
    }

    @Test func revisitedSurvivesARoundTrip() throws {
        let prompt = Turn.Prompt(english: "I already ate.", target: nil,
                                 audioSource: nil, pointID: "zh.guo.experiential",
                                 revisited: ["已经", "了"])
        let data = try JSONEncoder().encode(prompt)
        let back = try JSONDecoder().decode(Turn.Prompt.self, from: data)

        #expect(back == prompt)
    }

    /// Same for `sightings`, where a failed decode costs the learner every
    /// encounter they have.
    @Test func anEncounterWithoutSightingsStillDecodes() throws {
        let stored = """
        {"atomID":"particle/已经","kind":"particle","subject":"已经",
         "language":"mandarin","firstSeen":0,"lastSeen":0,"visits":2,
         "knowledge":"gap","stage":1}
        """
        let e = try JSONDecoder().decode(Progress.Encounter.self,
                                         from: Data(stored.utf8))

        #expect(e.visits == 2)
        #expect(e.sightings == 0)
        #expect(e.dueAt == nil)
    }

    /// Same again for retirement: an archive written before it existed has to
    /// come back as something still on the schedule, not as something the
    /// learner threw away.
    @Test func anEncounterWithoutStandingStillDecodes() throws {
        let stored = """
        {"atomID":"particle/已经","kind":"particle","subject":"已经",
         "language":"mandarin","firstSeen":0,"lastSeen":0,"visits":2,
         "knowledge":"gap","stage":1}
        """
        let e = try JSONDecoder().decode(Progress.Encounter.self,
                                         from: Data(stored.utf8))

        #expect(e.cleanRuns == 0)
        #expect(e.standing == .active)
    }

    /// `levelChangedAt` is optional rather than defaulted, which is the one
    /// shape the synthesised decoder does treat as absent-is-nil. The whole of
    /// the learner's settings rides on that.
    @Test func settingsWithoutTheLevelDateStillDecode() throws {
        let stored = """
        {"language":"mandarin","mode":"translate","level":4,"dailyGoal":3,
         "prefersTyping":false,"showPhonetics":true,"turnsBeforeReview":3,
         "offerStretch":true}
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(stored.utf8))

        #expect(settings.level == 4)
        #expect(settings.levelChangedAt == nil)
    }

    // MARK: Retirement

    /// Otherwise nothing ever leaves: the top rung reschedules itself forever
    /// and the queue only grows.
    @Test func threeCleanRetrievalsAtTheTopRetireIt() {
        var progress = Self.progress(Self.encounter(.particle, "已经", stage: 4))
        for _ in 0..<3 {
            progress.retrieved(subject: "已经", language: .mandarin, on: Self.day)
        }

        let e = progress.encounters[Atom.identify(.particle, "已经")]
        #expect(e?.standing == .held)
        #expect(e?.dueAt == nil)
    }

    @Test func twoCleanRetrievalsAreNotEnough() {
        var progress = Self.progress(Self.encounter(.particle, "已经", stage: 4))
        for _ in 0..<2 {
            progress.retrieved(subject: "已经", language: .mandarin, on: Self.day)
        }

        let e = progress.encounters[Atom.identify(.particle, "已经")]
        #expect(e?.standing == .active)
        #expect(e?.dueAt == Self.days(35))
    }

    /// Three clean runs part-way up the ladder are the ladder working, not a
    /// reason to stop asking.
    @Test func cleanRunsBelowTheTopRungDoNotRetire() {
        var progress = Self.progress(Self.encounter(.particle, "已经", stage: 0))
        for _ in 0..<3 {
            progress.retrieved(subject: "已经", language: .mandarin, on: Self.day)
        }

        let e = progress.encounters[Atom.identify(.particle, "已经")]
        #expect(e?.stage == 3)
        #expect(e?.standing == .active)
        #expect(e?.dueAt == Self.days(7))
    }

    /// Consecutive, not cumulative.
    @Test func aMissResetsTheCleanRun() {
        var progress = Self.progress(Self.encounter(.particle, "已经", stage: 4))
        for _ in 0..<2 {
            progress.retrieved(subject: "已经", language: .mandarin, on: Self.day)
        }
        progress.missed(subject: "已经", language: .mandarin, on: Self.day)
        for _ in 0..<2 {
            progress.retrieved(subject: "已经", language: .mandarin, on: Self.day)
        }

        let e = progress.encounters[Atom.identify(.particle, "已经")]
        #expect(e?.cleanRuns == 2)
        #expect(e?.standing == .active)
    }

    /// Both end with no date. Which one it was is the difference between the
    /// app being confident and the learner being finished with it.
    @Test func retiredIsNotDismissed() {
        var progress = Self.progress(
            Self.encounter(.particle, "已经", stage: 4),
            Self.encounter(.tone, "shì", stage: 4)
        )
        for _ in 0..<3 {
            progress.retrieved(subject: "已经", language: .mandarin, on: Self.day)
        }
        progress.leaveOut(Atom.identify(.tone, "shì"))

        #expect(progress.encounters[Atom.identify(.particle, "已经")]?.standing == .held)
        #expect(progress.encounters[Atom.identify(.tone, "shì")]?.standing == .dismissed)
        #expect(progress.tally(language: .mandarin, on: Self.day).held == 1)
    }

    /// Retiring it was a conclusion, and this is the evidence against it.
    @Test func aRetiredEncounterComesBackOnAMiss() {
        var progress = Self.progress(Self.encounter(.particle, "已经", stage: 4))
        for _ in 0..<3 {
            progress.retrieved(subject: "已经", language: .mandarin, on: Self.day)
        }
        progress.missed(subject: "已经", language: .mandarin, on: Self.day)

        let e = progress.encounters[Atom.identify(.particle, "已经")]
        #expect(e?.standing == .active)
        #expect(e?.dueAt == Self.days(35))
    }

    /// The learner's decision is not overruled by evidence — it was never made
    /// on evidence.
    @Test func aDismissedEncounterStaysOff() {
        var progress = Self.progress(Self.encounter(.particle, "已经", stage: 1))
        progress.leaveOut(Atom.identify(.particle, "已经"))
        progress.retrieved(subject: "已经", language: .mandarin, on: Self.day)

        let e = progress.encounters[Atom.identify(.particle, "已经")]
        #expect(e?.standing == .dismissed)
        #expect(e?.dueAt == nil)
    }

    /// Held, due and failing are three different questions, and a screen asking
    /// them gets three different answers.
    @Test func theTallyTellsThemApart() {
        var progress = Self.progress(
            Self.encounter(.particle, "已经", stage: 4),
            Self.encounter(.tone, "shì", stage: 0),
            Self.encounter(.wordOrder, "把", stage: 0)
        )
        for _ in 0..<3 {
            progress.retrieved(subject: "已经", language: .mandarin, on: Self.day)
        }
        progress.retrieved(subject: "把", language: .mandarin, on: Self.day)

        let tally = progress.tally(language: .mandarin, on: Self.day)
        #expect(tally.held == 1)
        #expect(tally.due == 1)
        #expect(tally.failing == 1)
    }

    // MARK: The level

    static func turn(score: Int, broke: Bool = false) -> Turn {
        Turn(id: UUID(), mode: .translate, language: .mandarin, createdAt: day,
             prompt: .init(english: "I already ate.", target: nil,
                           audioSource: nil, pointID: nil, revisited: []),
             attempt: .init(heard: "", confirmed: "我已经吃了", wasTyped: true,
                            audioFilename: nil, pronunciation: nil),
             review: Review(score: score, readOfScore: "Landed.",
                            atoms: broke ? [atom(.particle, "了")] : []))
    }

    static func window(score: Int, count: Int = LevelEvidence.window) -> [Turn] {
        (0..<count).map { _ in turn(score: score) }
    }

    static let pack = LanguagePacks.mandarin

    @Test func cleanAndUsedUpOffersAMoveUp() {
        let offer = LevelOffer.read(level: 4, in: Self.pack,
                                    turns: Self.window(score: 88), holding: 0.8)

        #expect(offer?.level == 5)
        #expect(offer?.reason == "Nothing broke in 20 sentences at HSK 4, "
                + "and you've used most of what it has. Move up?")
    }

    /// One sentence nobody could follow is the whole case against moving up.
    @Test func oneBreakInTheWindowIsEnoughToStay() {
        var turns = Self.window(score: 88)
        turns[7] = Self.turn(score: 88, broke: true)

        #expect(LevelOffer.read(level: 4, in: Self.pack,
                                turns: turns, holding: 0.8) == nil)
    }

    /// Scoring well on the third of the level they have met says nothing about
    /// the rest of it.
    @Test func aLevelStillUnusedIsNotDoneWith() {
        #expect(LevelOffer.read(level: 4, in: Self.pack,
                                turns: Self.window(score: 88), holding: 0.5) == nil)
    }

    @Test func aRunOfLowScoresOffersAMoveDown() {
        let offer = LevelOffer.read(level: 4, in: Self.pack,
                                    turns: Self.window(score: 55), holding: 0)

        #expect(offer?.level == 3)
        #expect(offer?.reason == "Your last 20 sentences at HSK 4 averaged 55. "
                + "Try HSK 3 for a while?")
    }

    @Test func theMiddleIsStay() {
        #expect(LevelOffer.read(level: 4, in: Self.pack,
                                turns: Self.window(score: 75), holding: 1) == nil)
    }

    /// Too little to go on is stay, not a coin toss.
    @Test func aShortWindowDecidesNothing() {
        #expect(LevelOffer.read(level: 4, in: Self.pack,
                                turns: Self.window(score: 88, count: 19),
                                holding: 1) == nil)
    }

    @Test func theEndsOfTheScaleHaveNowhereToGo() {
        #expect(LevelOffer.read(level: 9, in: Self.pack,
                                turns: Self.window(score: 95), holding: 1) == nil)
        #expect(LevelOffer.read(level: 1, in: Self.pack,
                                turns: Self.window(score: 40), holding: 0) == nil)
    }

    /// Both thresholds are inclusive, and one point either side of them is the
    /// whole difference between an offer and silence.
    @Test func theThresholdsAreInclusive() {
        #expect(LevelOffer.read(level: 4, in: Self.pack,
                                turns: Self.window(score: 85), holding: 0.75)?.level == 5)
        #expect(LevelOffer.read(level: 4, in: Self.pack,
                                turns: Self.window(score: 84), holding: 0.75) == nil)
        #expect(LevelOffer.read(level: 4, in: Self.pack,
                                turns: Self.window(score: 60), holding: 0)?.level == 3)
        #expect(LevelOffer.read(level: 4, in: Self.pack,
                                turns: Self.window(score: 61), holding: 0) == nil)
    }
}
