import Foundation

/// Everything the app asks the model, in one place.
///
/// The important property is that `expand` takes a `LessonRequest` and nothing
/// else. Depth 0 and depth 7 are the same call — the request is built from the
/// atom that was tapped, not from the screen it was tapped on, so a new kind of
/// feedback never needs a new prompt or a new view.
actor Tutor {

    private let api: Anthropic
    private var lessons: [String: Lesson] = [:]

    init(api: Anthropic) { self.api = api }

    // MARK: Expansion — the recursive call

    func expand(_ request: LessonRequest) async throws -> (Lesson, Anthropic.Usage?) {
        if let cached = lessons[request.cacheKey] { return (cached, nil) }

        let pack = LanguagePacks.pack(for: request.language)
        let (lesson, usage) = try await api.send(
            Lesson.self,
            cachedSystem: Self.expandSystem(pack),
            user: """
            Subject: \(request.seed.subject)
            Kind: \(request.kind.rawValue)
            The learner wrote: \(request.seed.context)
            Grammar point: \(request.seed.pointID ?? "none")
            Times the learner has opened this before: \(request.priorVisits)
            """,
            schema: Schemas.lesson(for: request.language)
        )

        lessons[request.cacheKey] = lesson
        return (lesson, usage)
    }

    // MARK: Assessment

    func assess(turn: Turn, level: Int) async throws -> (Review, Anthropic.Usage) {
        let pack = LanguagePacks.pack(for: turn.language)
        return try await api.send(
            Review.self,
            cachedSystem: Self.assessSystem(pack),
            user: """
            Mode: \(turn.mode.rawValue)
            Level: \(pack.level(level))
            Asked (English): \(turn.prompt.english ?? "—")
            Asked (\(pack.language.name)): \(turn.prompt.target ?? "—")
            The learner said: \(turn.attempt.confirmed)
            """,
            schema: Schemas.review(for: turn.language)
        )
    }

    // MARK: Drills and questions

    struct DrillVerdict: Codable { var correct: Bool; var note: String; var oneGoodAnswer: String }

    func grade(answer: String, to rung: Rung, in language: Language)
    async throws -> (DrillVerdict, Anthropic.Usage) {
        try await api.send(
            DrillVerdict.self,
            cachedSystem: Self.gradeSystem(LanguagePacks.pack(for: language)),
            user: """
            Task: \(rung.prompt)
            Model answers: \(rung.accept.joined(separator: " / "))
            The learner wrote: \(answer)
            """,
            schema: Schemas.drillResult,
            effort: .low
        )
    }

    func answer(question: String, about seed: Atom.Seed, in language: Language)
    async throws -> (AskItem, Anthropic.Usage) {
        let pack = LanguagePacks.pack(for: language)
        return try await api.send(
            AskItem.self,
            cachedSystem: Self.askSystem(pack),
            user: """
            Topic: \(seed.subject)
            The learner wrote: \(seed.context)
            Their question: \(question)
            """,
            schema: Schemas.askItem(for: language)
        )
    }

    // MARK: Prompts
    //
    // Byte-identical per language so the cache prefix holds. Everything that
    // varies per call goes in the user message.

    private static func voice(_ pack: LanguagePack) -> String {
        """
        You are a \(pack.language.name) tutor: warm, exacting, and brief.
        Write the way a good teacher talks, not the way a textbook reads. Never
        pad. If one clause will do, use one clause.
        """
    }

    private static func atomRules(_ pack: LanguagePack) -> String {
        """
        Every observation you make is an atom, and every atom must be openable —
        its `seed.subject` is what a whole lesson about it would be about, so it
        must be a real teachable point, never a restatement of the sentence.

        Ids are stable: the same point in the same language always gets the same
        id. Use kind-slug/anchor, e.g. word-order/已经.

        The three stages are a reveal, in order:
        - locate says where, and must not give away what. The learner should be
          able to try repairing the sentence from this alone.
        - name says what is wrong, still without the corrected text.
        - fix is the corrected text.
        Never let locate leak the answer; that is the whole point of the split.

        Report what the learner got right as well, with verdict "kept". Praise
        that names a real choice teaches; praise that is generic does not.

        Available kinds for \(pack.language.name): \(pack.kinds.map(\.rawValue).joined(separator: ", ")).
        \(pack.assessmentNotes)
        """
    }

    private static func expandSystem(_ pack: LanguagePack) -> String {
        """
        \(voice(pack))

        You write one lesson about one point, built from blocks.

        Use `rule` for the explanation — a short paragraph, not an essay.
        Use `contrast` for the confusable neighbour, which is usually what the
        learner needs next; give each side a seed so it opens.
        Use `examples` for the pattern in use; give each a seed.
        Use `drills` for production. Every drill needs at least two rungs,
        ordered hardest first: rung 0 is unaided production, and each later rung
        removes something the learner has to build — a frame with a gap, then a
        choice between two. A learner who fails drops a rung, so the lower rungs
        must test the same point with less to construct.

        `ask` holds two questions the learner plausibly has after reading this,
        in their own words, each answered in one or two sentences, each carrying
        atoms so the answer is a way further in rather than a full stop.

        `patterns` is shown instead of the rule when the learner has been here
        three times. Pattern only, no explanation — if explaining twice failed,
        a third explanation will fail too.

        \(atomRules(pack))
        """
    }

    private static func assessSystem(_ pack: LanguagePack) -> String {
        """
        \(voice(pack))

        You assess one attempt and return every finding.

        Rank them: exactly one atom has weight "start" — the one that most
        stops the learner being understood. Every other finding is still
        returned. Never omit a real error because it is minor; silence reads as
        approval.

        `fixed` is the minimal correction. `natural` is what a speaker would
        actually say, which is often different — give both when they differ.

        `respeaks` ask the learner to say their own sentence again with one
        thing deliberately changed: a different subject, a different tense, an
        added detail. Never a plain repeat — the point is transfer, not recall
        of the correction. Two or three, each with the forms you would accept.

        `readOfScore` is one clause on what the score means. Not a breakdown,
        not a pep talk.

        \(atomRules(pack))
        """
    }

    private static func gradeSystem(_ pack: LanguagePack) -> String {
        """
        You grade one short \(pack.language.name) answer. Accept any form a
        speaker would accept, not only the model answers. Reply in one or two
        sentences, naming what was wrong when it is wrong.
        """
    }

    private static func askSystem(_ pack: LanguagePack) -> String {
        """
        \(voice(pack))

        Answer the learner's question about one point in one or two sentences,
        then attach atoms for anything in your answer worth opening.

        \(atomRules(pack))
        """
    }
}
