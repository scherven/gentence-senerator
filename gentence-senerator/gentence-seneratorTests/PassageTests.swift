import Testing
import Foundation
@testable import gentence_senerator

/// The dialogue flow grades on the device, so this is where its correctness
/// lives — there is no model call to blame and no server to ask.
struct PassageTests {

    // The cinema dialogue, cut to what the assertions need.
    static let json = """
    [{"id":"t","language":"mandarin","level":1,"title":"外面等",
      "audio":null,"seconds":34,"speakers":["A","B"],
      "lines":[
       {"n":1,"speaker":"A","text":"喂，你到了吗？","english":"Are you here yet?",
        "startSeconds":0,"endSeconds":2.1,"gap":null},
       {"n":2,"speaker":"B","text":"还没有，路上堵车堵得厉害。","english":"Traffic is terrible.",
        "startSeconds":2.1,"endSeconds":5.2,
        "gap":{"answer":"堵车","options":["堵车","打车","停车"],"why":"dǔ against dǎ."}},
       {"n":7,"speaker":"A","text":"票在我这儿呢。","english":"I have the tickets.",
        "startSeconds":5.2,"endSeconds":7.4,
        "gap":{"answer":"票","options":["票","表","标"],"why":"piào against biǎo."}}],
      "quiz":[
       {"id":"q1","question":"B 为什么迟到？","english":"Why is B late?",
        "options":["堵车","找不到票"],"answer":0,"line":2,"optionLines":[2,7]},
       {"id":"q2","question":"谁有票？","english":"Who has the tickets?",
        "options":["A","B"],"answer":0,"line":7,"optionLines":[7,2]}]}]
    """

    static func passage() throws -> Passage {
        try JSONDecoder().decode([Passage].self, from: Data(json.utf8))[0]
    }

    static func run() -> PassageRun {
        PassageRun(passageID: "t", language: .mandarin, startedOn: "2026-09-07")
    }

    @Test func decodesWhatTheScriptWrites() throws {
        let passage = try PassageTests.passage()
        #expect(passage.lines.count == 3)
        #expect(passage.line(7)?.gap?.answer == "票")
        // Lines are addressed by `n`, not by position — the repair jumps around.
        #expect(passage.line(2)?.text.contains("堵车") == true)
        #expect(passage.lines[2].n == 7)
        #expect(passage.wholeSource == nil)   // no recording attached yet
    }

    @Test func answerIndexFindsTheAnswerWhereverItSits() throws {
        let passage = try PassageTests.passage()
        #expect(passage.line(2)?.gap?.answerIndex == 0)
        let shuffled = Passage.Gap(answer: "表", options: ["票", "表", "标"], why: "")
        #expect(shuffled.answerIndex == 1)
    }

    @Test func oneReplayThenNoMore() {
        var run = PassageTests.run()
        #expect(!run.canReplay)          // nothing played yet
        run.played = true
        #expect(run.canReplay)
        run.replays = 1
        #expect(!run.canReplay)
    }

    /// The four outcomes are the point of the design, so each one is pinned.
    @Test func everyOutcomeIsReachable() throws {
        let passage = try PassageTests.passage()

        var clean = PassageTests.run()
        clean.answers = ["q1": 0, "q2": 0]
        #expect(clean.outcome(of: passage) == .clean)

        // Missed both questions, and missed both gaps behind them.
        var sound = PassageTests.run()
        sound.answers = ["q1": 1, "q2": 1]
        sound.repair = [2, 7]
        sound.gaps = [2: 1, 7: 1]
        #expect(sound.outcome(of: passage) == .sound)

        // Got the gist, could not pick the words back out.
        var context = PassageTests.run()
        context.answers = ["q1": 0, "q2": 0]
        context.repair = [2]
        context.gaps = [2: 1]
        #expect(context.outcome(of: passage) == .context)

        // Heard every word and still lost the thread — the learner no other
        // mode in the app can see.
        var thread = PassageTests.run()
        thread.answers = ["q1": 1, "q2": 1]
        thread.repair = [2, 7]
        thread.gaps = [2: 0, 7: 0]
        #expect(thread.outcome(of: passage) == .thread)
    }

    @Test func theScoreIsTheFirstPassOnly() throws {
        let passage = try PassageTests.passage()
        var run = PassageTests.run()
        run.answers = ["q1": 1, "q2": 0]
        run.repair = [2]
        run.gaps = [2: 0]
        // Repaired and answered right the second time; the read still says one
        // of two. Repairing must not flatter the score.
        run.reanswers = ["q1": 0]
        let read = run.read(of: passage)
        #expect(read.first == 1)
        #expect(read.asked == 2)
        #expect(read.gapsRight == 1)
        #expect(read.gaps == 1)
    }

    /// Atom ids are derived, so the same miss on a different day schedules as
    /// the same point rather than piling up new ones.
    @Test func aMissKeepsItsIdentityAcrossDays() {
        let first = Atom.identify(.pronunciation, "堵车 against 打车")
        let later = Atom.identify(.pronunciation, "堵车 against 打车")
        #expect(first == later)
        #expect(first != Atom.identify(.pronunciation, "票 against 表"))
    }

    /// It outlives the day it began — that is the whole reason it is persisted
    /// away from `holds`.
    @Test func survivesARoundTrip() throws {
        var run = PassageTests.run()
        run.stage = .repairing
        run.answers = ["q1": 1]
        run.gaps = [2: 1]
        run.repair = [2]
        run.replays = 1
        let back = try JSONDecoder().decode(
            PassageRun.self, from: JSONEncoder().encode(run))
        #expect(back == run)
        #expect(back.gaps[2] == 1)
        #expect(back.stage == .repairing)
    }
}
