import Testing
import Foundation
@testable import gentence_senerator

struct GradingTests {

    static func turn(_ said: String, mode: Mode = .produce, exchange: UUID? = nil) -> Turn {
        Turn(id: UUID(), mode: mode, language: .german, createdAt: .now,
             prompt: .init(english: "Q", target: "Frage?", audioSource: nil, pointID: nil),
             attempt: .init(heard: said, confirmed: said, wasTyped: true,
                            audioFilename: nil, pronunciation: nil),
             review: nil, exchangeID: exchange)
    }

    /// Five produce answers at three a review: 3 + 2, the short one kept.
    @Test func produceGroupsByExchangeSize() {
        var turns: [Turn] = []
        for n in 0..<5 {
            var t = Self.turn("a\(n)")
            t.exchangeID = Store.exchangeID(after: turns, mode: .produce, size: 3)
            turns.append(t)
        }
        let session = Session(id: "2026-09-24|german|produce", language: .german, mode: .produce,
                              startedAt: .now, turns: turns, goal: 5)
        let groups = GradingJob.exchanges(of: session)
        #expect(groups.map(\.turnIDs.count) == [3, 2])
        #expect(groups.map(\.customID) == ["x0", "x1"])
        #expect(groups[1].turnIDs.last == turns[4].id)
    }

    @Test func translateIsOneTurnEach() {
        var turns: [Turn] = []
        for n in 0..<3 {
            var t = Self.turn("t\(n)", mode: .translate)
            t.exchangeID = Store.exchangeID(after: turns, mode: .translate, size: 3)
            turns.append(t)
        }
        let session = Session(id: "x", language: .german, mode: .translate,
                              startedAt: .now, turns: turns, goal: 3)
        #expect(GradingJob.exchanges(of: session).map(\.turnIDs.count) == [1, 1, 1])
    }

    /// A graded reply becomes a deep review, a lesson keyed where tapping the
    /// finding will look for it, and only known point ids.
    @Test func readsReviewAndLessons() throws {
        let json = """
        {"score":72,"readOfScore":"Understood, one slip.",
         "findings":[
          {"kind":"verb-final","verdict":"weakens","weight":"start",
           "locate":"Answer 2, near the end.","name":"The verb is not last.",
           "fix":"weil ich müde bin","note":"weil sends the verb to the end.",
           "subject":"verb placement in weil clauses"},
          {"kind":"word-choice","verdict":"kept","weight":"also",
           "locate":"Answer 1.","name":"gern, well placed.","fix":"gern",
           "note":"Natural.","subject":"gern"}],
         "natural":null,
         "respeaks":[{"instruction":"Say it about yesterday.","accept":["weil ich müde war"],
                      "correct":"Yes.","incorrect":"Not yet."}],
         "lessons":[{"finding":0,"title":"weil","rule":"weil sends the verb last.",
           "contrastTerm":"denn","contrastNote":"denn keeps verb second.",
           "contrastSubject":"denn versus weil",
           "examples":[{"target":"weil es regnet","gloss":"because it is raining"}],
           "drills":[{"rungs":[
              {"support":"free","prompt":"Because I am tired.","accept":["weil ich müde bin"],"options":null,"answerIndex":null},
              {"support":"choice","prompt":"Pick","accept":["weil ich müde bin"],"options":["weil ich bin müde","weil ich müde bin"],"answerIndex":1}],
             "correct":"Right.","incorrect":"Verb last."}],
           "patterns":[{"target":"weil ich Zeit habe","gloss":"because I have time"}]},
          {"finding":9,"title":"x","rule":"x","contrastTerm":null,"contrastNote":null,
           "contrastSubject":null,"examples":[],"drills":[],"patterns":[]}],
         "used":["not-a-real-point"]}
        """
        let first = Self.turn("Ich gehe gern.")
        let last = Self.turn("weil ich bin müde")
        let reply = Anthropic.Reply(
            text: json,
            usage: .init(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0),
            refusal: nil)

        let (review, lessons) = try Tutor.read(reply, turn: last, history: [first])

        #expect(review.isDeep)
        #expect(review.problems.count == 1)
        #expect(review.problems[0].stages.fix == "weil ich müde bin")
        #expect(review.problems[0].seed.context == "Ich gehe gern. weil ich bin müde")
        #expect(review.usedPoints.isEmpty)
        #expect(review.respeaks.count == 1)

        // The out-of-range lesson is dropped; the real one is complete.
        #expect(lessons.count == 1)
        let lesson = lessons[0]
        #expect(lesson.hasPractice)
        #expect(lesson.patterns.count == 1)
        let atom = review.problems[0]
        let request = LessonRequest(seed: atom.seed, kind: atom.kind, language: .german)
        #expect(lesson.id == request.cacheKey)
    }

    /// Archives from before either field existed still decode.
    @Test func oldTurnsDecode() throws {
        let old = """
        {"id":"\(UUID().uuidString)","mode":"translate","language":"german","createdAt":0,
         "prompt":{"english":"Hi"},
         "attempt":{"heard":"Hallo","confirmed":"Hallo","wasTyped":true}}
        """
        let turn = try JSONDecoder().decode(Turn.self, from: Data(old.utf8))
        #expect(turn.exchangeID == nil)
        #expect(turn.prompt.reference == nil)
    }

    /// A real results file with one success and one errored request, plus a
    /// refusal and a line that will not parse. Every answer that did not come
    /// back graded must come out as failed — never crash the read, never be
    /// mistaken for a review.
    @Test func partialFailureReadsAsFailedAnswers() throws {
        let results = Anthropic.results(from: Data(Self.partial.utf8))
        #expect(results.map(\.customID) == ["x0", "x1", "x2"])
        #expect(results[0].reply?.text == "Hi! 👋")
        #expect(results[1].reply == nil)
        #expect(results[1].error == "Could not process image")
        // A refusal arrives as a success with no text; reading it as a review
        // has to fail, so it is retried rather than landing empty.
        let refused = try #require(results[2].reply)
        #expect(refused.refusal == "declined")
        #expect(throws: (any Error).self) {
            _ = try Tutor.read(refused, turn: Self.turn("x"), history: [])
        }
    }

    /// Jobs saved before `uploading` and `retried` existed still load.
    @Test func oldJobsDecode() throws {
        let old = """
        {"id":"\(UUID().uuidString)","sessionID":"2026-09-24|german|translate",
         "language":"german","mode":"translate","createdAt":0,
         "exchanges":[{"customID":"x0","turnIDs":["\(UUID().uuidString)"]}],
         "batchID":"msgbatch_1","watched":true,"graded":1,"failed":0,"state":"grading"}
        """
        let job = try JSONDecoder().decode(GradingJob.self, from: Data(old.utf8))
        #expect(job.batchID == "msgbatch_1")
        #expect(job.uploading == false)
        #expect(job.retried == false)
        #expect(job.level == nil)
    }

    static let partial = #"""
{"custom_id": "x0", "result": {"type": "succeeded", "message": {"model": "claude-haiku-4-5-20251001", "id": "msg_011CfPLqsQdbfHNcV3FHn9K7", "type": "message", "role": "assistant", "content": [{"type": "text", "text": "Hi! 👋"}], "container": null, "stop_reason": "max_tokens", "stop_sequence": null, "stop_details": null, "usage": {"input_tokens": 9, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 0}, "output_tokens": 5, "service_tier": "batch", "inference_geo": "not_available"}, "diagnostics": null}}}
{"custom_id": "x1", "result": {"type": "errored", "error": {"type": "error", "error": {"details": null, "type": "invalid_request_error", "message": "Could not process image"}, "request_id": "workerreq_01DZnnj4FsCJE9tRjNEbkKvD"}}}
{"custom_id": "x2", "result": {"type": "succeeded", "message": {"content": [], "stop_reason": "refusal", "stop_details": {"type": "refusal", "category": null, "explanation": "declined"}, "usage": {"input_tokens": 10, "output_tokens": 0}}}}
not json
"""#
}
