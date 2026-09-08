import Testing
import Foundation
@testable import gentence_senerator

/// Reach used to move only when the app asked for a structure by name, so a
/// learner who already produced something kept being offered it. Both new
/// signals — tags off the deep review, words counted on the device — write into
/// `Progress`, and both can quietly wipe an archive if their decoding is wrong.
/// That is what this covers.
struct ReachTests {

    static func point(_ id: String) -> GrammarPoint {
        GrammarPoint(id: id, name: id, level: 1, kind: .particle,
                     instruction: "", examples: [])
    }

    // MARK: Structures

    /// The model over-tags, so one tag is evidence and not a verdict. Reach
    /// stops offering a point on the second, which is the second attempt —
    /// tags are recorded once per review.
    @Test func oneTagDoesNotRetireAPoint() {
        var progress = gentence_senerator.Progress()
        let candidates = [ReachTests.point("le-change")]

        #expect(progress.neverReached(among: candidates).count == 1)
        progress.attempted(pointID: "le-change", language: .mandarin, succeeded: true)
        #expect(progress.neverReached(among: candidates).count == 1)
        progress.attempted(pointID: "le-change", language: .mandarin, succeeded: true)
        #expect(progress.neverReached(among: candidates).isEmpty)
    }

    /// Three states, and the threshold above does not touch them: one attempt
    /// is still enough to know the point is no longer unattempted.
    @Test func aSingleAttemptStillLeavesTheNeverAttemptedState() {
        var progress = gentence_senerator.Progress()
        #expect(progress.state(of: "le-change") == .neverAttempted)
        progress.attempted(pointID: "le-change", language: .mandarin, succeeded: false)
        #expect(progress.state(of: "le-change") == .failing)
    }

    // MARK: Words

    @Test func wordsAreCountedPerLanguageAndNotJustCollected() {
        var progress = gentence_senerator.Progress()
        progress.produced(["好", "吃"], language: .mandarin)
        progress.produced(["好"], language: .mandarin)
        progress.produced(["haus"], language: .german)

        #expect(progress.timesProduced("好", language: .mandarin) == 2)
        #expect(progress.timesProduced("吃", language: .mandarin) == 1)
        #expect(progress.timesProduced("好", language: .german) == 0)
        #expect(progress.timesProduced("haus", language: .german) == 1)
    }

    @Test func neverProducedIsTheBandMinusTheTally() {
        var progress = gentence_senerator.Progress()
        progress.produced(["好", "吃"], language: .mandarin)

        let band = ["好", "吃", "白", "环境"]
        #expect(Set(progress.neverProduced(among: band, language: .mandarin))
                == ["白", "环境"])
        // A word said in another language has not been said in this one.
        #expect(Set(progress.neverProduced(among: band, language: .german))
                == Set(band))
    }

    /// End to end, the way the store will use it: what the lexicon found in an
    /// attempt goes in, and the band minus that comes out.
    @Test func anAttemptNarrowsWhatIsStillNeverProduced() {
        let lexicon = Lexicon([.mandarin: ["好": 1, "吃": 1, "环境": 3]])
        var progress = gentence_senerator.Progress()
        progress.produced(lexicon.words(in: "这里的环境很好", language: .mandarin),
                          language: .mandarin)

        let band = lexicon.band(upTo: 3, language: .mandarin)
        #expect(Set(progress.neverProduced(among: band, language: .mandarin)) == ["吃"])
    }

    // MARK: What a stored archive looks like without any of this

    /// `Vault.load` is a plain decoder behind `try?`, and a default value is
    /// not a fallback — without the shim this returns nil and every encounter,
    /// every structure and the whole streak go with it.
    @Test func progressWrittenBeforeWordsExistedStillDecodes() throws {
        let stored = #"{"encounters":{},"structures":{},"xp":140,"streak":6}"#
        let progress = try JSONDecoder().decode(gentence_senerator.Progress.self,
                                                from: Data(stored.utf8))
        #expect(progress.xp == 140)
        #expect(progress.streak == 6)
        #expect(progress.words.isEmpty)
    }

    /// The same hazard in the sessions archive. `respeaks` and `isDeep` never
    /// had a fallback either, so this covers all three at once.
    @Test func reviewWrittenBeforeItsSecondStageStillDecodes() throws {
        let stored = #"{"score":71,"readOfScore":"Understandable.","atoms":[]}"#
        let review = try JSONDecoder().decode(Review.self, from: Data(stored.utf8))
        #expect(review.score == 71)
        #expect(review.usedPoints.isEmpty)
        #expect(review.respeaks.isEmpty)
        #expect(review.isDeep == false)
    }

    /// And a round trip, so the shim cannot drift from what is written.
    @Test func aReviewCarryingTagsSurvivesBeingStored() throws {
        var review = Review(score: 80, readOfScore: "Clear.", atoms: [])
        review.usedPoints = ["le-change", "ma-question"]
        review.isDeep = true

        let back = try JSONDecoder().decode(
            Review.self, from: try JSONEncoder().encode(review))
        #expect(back.usedPoints == ["le-change", "ma-question"])
        #expect(back.isDeep)
    }
}
