import Testing
import Foundation
@testable import gentence_senerator

struct TodayTests {

    static func session(_ answered: [String], goal: Int = 3) -> Session {
        Session(id: "2026-09-29|german|translate", language: .german, mode: .translate,
                startedAt: .now, turns: answered.map { GradingTests.turn($0, mode: .translate) },
                goal: goal)
    }

    // MARK: Turn counter

    @Test func counterShowsTheTurnOnScreen() {
        let first = Self.session([])
        #expect(Store.turnNumber(session: first, current: GradingTests.turn("", mode: .translate)) == 1)

        // Second prompt up: one answered, the next unanswered.
        let second = Self.session(["a"])
        #expect(Store.turnNumber(session: second, current: GradingTests.turn("", mode: .translate)) == 2)

        // Reference up after the second answer: still turn 2.
        let answered = Self.session(["a", "b"])
        #expect(Store.turnNumber(session: answered, current: answered.turns[1]) == 2)

        // Never past the goal.
        let full = Self.session(["a", "b", "c"])
        #expect(Store.turnNumber(session: full, current: nil) == 3)
    }

    // MARK: Divergence

    @Test func sameSentenceDivergesNowhere() {
        let d = Store.divergence("Ich habe Hunger.", "ich habe hunger", language: .german)
        #expect(d.said.isEmpty)
        #expect(d.ref.isEmpty)
    }

    @Test func wordOrderMarksOnlyWhatMoved() {
        let said = "Gestern ich habe das Buch gelesen."
        let ref = "Gestern habe ich das Buch gelesen."
        let d = Store.divergence(said, ref, language: .german)
        // One of ich / habe is kept by the common subsequence; the other is marked on each side.
        #expect(d.said.count == 1)
        #expect(d.ref.count == 1)
        let marked = String(Array(said)[d.said[0]])
        #expect(marked == "ich" || marked == "habe")
    }

    @Test func neighbouringDifferencesMerge() {
        let said = "Wir gehen morgen ins Kino"
        let ref = "Wir fahren heute ins Kino"
        let d = Store.divergence(said, ref, language: .german)
        #expect(d.said.map { String(Array(said)[$0]) } == ["gehen morgen"])
        #expect(d.ref.map { String(Array(ref)[$0]) } == ["fahren heute"])
    }

    @Test func mandarinDivergesByCharacter() {
        let said = "我昨天去了商店。"
        let ref = "我昨天去商店了。"
        let d = Store.divergence(said, ref, language: .mandarin)
        #expect(d.said.map { String(Array(said)[$0]) } == ["了"])
        #expect(d.ref.map { String(Array(ref)[$0]) } == ["了"])
    }

    @Test func emptyReferenceMarksTheWholeAnswer() {
        let d = Store.divergence("Hallo Welt", "", language: .german)
        #expect(d.said == [0..<10])
        #expect(d.ref.isEmpty)
    }

    // MARK: Chips

    @Test func chipUseIsCaseInsensitiveContains() {
        #expect(Store.uses("der Umzug", in: "Der Umzug war lang.", language: .german))
        #expect(Store.uses("TROTZDEM", in: "Es regnet, trotzdem gehe ich.", language: .german))
        #expect(!Store.uses("kündigen", in: "Ich kundige.", language: .german))
        #expect(!Store.uses("", in: "anything", language: .german))
    }

    @Test func mandarinChipIsASubstringAndFormulasNeedEveryPart() {
        #expect(Store.uses("电脑", in: "我买了三台电脑。", language: .mandarin))
        #expect(Store.uses("等…再…", in: "等他来了再走。", language: .mandarin))
        #expect(!Store.uses("等…再…", in: "等他来了就走。", language: .mandarin))
    }

    // MARK: Recommendation and sending

    @Test func roundWaitsForADoneModeAndNamesTheWorstItem() {
        let reason = "条 missed ×2 · 台 slipping · 个 missed ×1"
        #expect(Store.roundReason(reason, modesDone: 0) == nil)
        #expect(Store.roundReason(reason, modesDone: 1) == "条 missed ×2")
        #expect(Store.roundReason("wohin? missed ×2", modesDone: 2) == "wohin? missed ×2")
    }

    @Test func sendNowOnlyWhenUnsentAndIdle() {
        var job = GradingJob(id: UUID(), sessionID: "s", language: .german, mode: .translate,
                             createdAt: .now, exchanges: [])
        #expect(Store.showsSendNow(job, sending: false))
        #expect(!Store.showsSendNow(job, sending: true))
        job.uploading = true
        #expect(!Store.showsSendNow(job, sending: false))
        job.uploading = false
        job.batchID = "b"
        job.state = .grading
        #expect(!Store.showsSendNow(job, sending: false))
    }

    // MARK: Written today

    @Test func writtenTodaySkipsListenAndBlanks() {
        var translate = Self.session(["eins", ""])
        translate.turns[0].createdAt = .now.addingTimeInterval(-60)
        var listen = Self.session(["heard"])
        listen.mode = .listen
        let rows = Store.written([translate, listen])
        #expect(rows.map(\.turn.attempt.confirmed) == ["eins"])
        #expect(rows.map(\.number) == [1])
    }
}
