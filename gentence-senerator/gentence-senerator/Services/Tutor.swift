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
    //
    // Two calls. The rule and its examples come back first because that is what
    // the learner reads; the drills follow while they are reading.

    struct Core: Codable {
        struct Ex: Codable { var target: String; var gloss: String; var subject: String? }
        var title: String
        var rule: String
        var contrastTerm: String?
        var contrastNote: String?
        var contrastSubject: String?
        var examples: [Ex]
    }

    struct Practice: Codable {
        struct R: Codable {
            var support: Rung.Support; var prompt: String; var accept: [String]
            var options: [String]?; var answerIndex: Int?
        }
        struct D: Codable { var rungs: [R]; var correct: String; var incorrect: String; var links: [AtomLink] }
        struct A: Codable { var question: String; var answer: String; var links: [AtomLink] }
        struct P: Codable { var target: String; var gloss: String }
        var drills: [D]
        var ask: [A]
        var patterns: [P]
    }

    /// First stage. Enough to put a lesson on screen.
    func expand(_ request: LessonRequest) async throws -> (Lesson, Anthropic.Usage?) {
        if let cached = lessons[request.cacheKey] { return (cached, nil) }

        let pack = LanguagePacks.pack(for: request.language)
        let (core, usage) = try await api.send(
            Core.self,
            cachedSystem: Self.coreSystem(pack),
            user: Self.lessonFacts(request, pack),
            schema: Schemas.lessonCore(for: request.language),
            effort: .medium
        )

        var blocks: [Block] = [
            Block(id: "rule", kind: .rule, label: nil, text: core.rule)
        ]
        if let term = core.contrastTerm, let note = core.contrastNote {
            blocks.append(Block(
                id: "contrast", kind: .contrast, label: "Not to be confused with",
                sides: [
                    Side(id: "a", term: request.seed.subject, note: "What you were doing.", seed: nil),
                    Side(id: "b", term: term, note: note,
                         seed: core.contrastSubject.map {
                             Atom.Seed(subject: $0, context: request.seed.context, pointID: nil)
                         })
                ]
            ))
        }
        blocks.append(Block(
            id: "examples", kind: .examples, label: "In the wild",
            examples: core.examples.enumerated().map { index, example in
                Example(id: "ex\(index)", target: example.target, gloss: example.gloss,
                        seed: example.subject.map {
                            Atom.Seed(subject: $0, context: request.seed.context, pointID: nil)
                        })
            }
        ))

        let lesson = Lesson(id: request.cacheKey, title: core.title,
                            blocks: blocks, ask: [], patterns: [])
        lessons[request.cacheKey] = lesson
        return (lesson, usage)
    }

    /// Second stage. Merged into the lesson already on screen.
    func practice(for request: LessonRequest) async throws -> (Lesson, Anthropic.Usage)? {
        guard var lesson = lessons[request.cacheKey], lesson.ask.isEmpty else { return nil }

        let pack = LanguagePacks.pack(for: request.language)
        let (practice, usage) = try await api.send(
            Practice.self,
            cachedSystem: Self.practiceSystem(pack),
            user: Self.lessonFacts(request, pack) + "\nThe rule as written: \(lesson.blocks.first?.text ?? "")",
            schema: Schemas.lessonPractice(for: request.language)
        )

        lesson.blocks.append(Block(
            id: "drills", kind: .drills, label: "Your turn",
            drills: practice.drills.enumerated().map { index, drill in
                Drill(id: "d\(index)",
                      rungs: drill.rungs.enumerated().map { rungIndex, rung in
                          Rung(id: "d\(index)r\(rungIndex)", support: rung.support,
                               prompt: rung.prompt, accept: rung.accept,
                               options: rung.options, answerIndex: rung.answerIndex)
                      },
                      correct: drill.correct, incorrect: drill.incorrect, atoms: drill.links)
            }
        ))
        lesson.ask = practice.ask.enumerated().map { index, item in
            AskItem(id: "a\(index)", question: item.question, answer: item.answer, atoms: item.links)
        }
        lesson.patterns = practice.patterns.enumerated().map { index, pattern in
            Example(id: "p\(index)", target: pattern.target, gloss: pattern.gloss, seed: nil)
        }

        lessons[request.cacheKey] = lesson
        return (lesson, usage)
    }

    private static func lessonFacts(_ request: LessonRequest, _ pack: LanguagePack) -> String {
        """
        Subject: \(request.seed.subject)
        Kind: \(request.kind.rawValue)
        The learner wrote: \(request.seed.context)
        Grammar point: \(request.seed.pointID ?? "none")
        Times opened before: \(request.priorVisits)
        """
    }

    // MARK: Assessment — two stages

    struct Opening: Codable {
        struct Finding: Codable {
            var id: String; var kind: AtomKind; var verdict: Atom.Verdict
            var weight: Atom.Weight; var anchor: String?; var locate: String; var subject: String
        }
        var score: Int
        var readOfScore: String
        var fixed: String?
        var findings: [Finding]
    }

    struct Depth: Codable {
        struct Filled: Codable { var id: String; var name: String; var fix: String; var note: String }
        struct Say: Codable { var instruction: String; var accept: [String]; var correct: String; var incorrect: String }
        struct A: Codable { var question: String; var answer: String; var links: [AtomLink] }
        var natural: String?
        var understood: String?
        var findings: [Filled]
        var respeaks: [Say]
        var ask: [A]
    }

    /// What the learner sees at once.
    func assessOpening(turn: Turn, history: [Turn] = [], level: Int)
    async throws -> (Review, Anthropic.Usage) {
        let pack = LanguagePacks.pack(for: turn.language)
        let (opening, usage) = try await api.send(
            Opening.self,
            cachedSystem: Self.openingSystem(pack),
            user: Self.attemptFacts(turn: turn, history: history, level: level, pack: pack),
            schema: Schemas.reviewOpening(for: turn.language),
            effort: .medium
        )

        let review = Review(
            score: opening.score,
            readOfScore: opening.readOfScore,
            atoms: opening.findings.map {
                Atom(id: $0.id, kind: $0.kind, verdict: $0.verdict, anchor: $0.anchor,
                     stages: .init(locate: $0.locate),
                     seed: .init(subject: $0.subject, context: turn.attempt.confirmed,
                                 pointID: turn.prompt.pointID),
                     weight: $0.weight)
            },
            fixed: opening.fixed, natural: nil, understood: nil
        )
        return (review, usage)
    }

    /// Fetched while the learner is still looking at where the problem is.
    func assessDepth(turn: Turn, opening: Review, history: [Turn] = [], level: Int)
    async throws -> (Review, Anthropic.Usage) {
        let pack = LanguagePacks.pack(for: turn.language)
        let listed = opening.atoms
            .map { "\($0.id): \($0.stages.locate)" }
            .joined(separator: "\n")

        let (depth, usage) = try await api.send(
            Depth.self,
            cachedSystem: Self.depthSystem(pack),
            user: Self.attemptFacts(turn: turn, history: history, level: level, pack: pack)
                + "\n\nFindings to fill in, by id:\n" + listed,
            schema: Schemas.reviewDepth(for: turn.language),
            effort: .medium
        )

        var merged = opening
        let byID = Dictionary(uniqueKeysWithValues: depth.findings.map { ($0.id, $0) })
        merged.atoms = opening.atoms.map { atom in
            guard let filled = byID[atom.id] else { return atom }
            var copy = atom
            copy.stages.name = filled.name
            copy.stages.fix = filled.fix
            copy.stages.note = filled.note
            return copy
        }
        merged.natural = depth.natural
        merged.understood = depth.understood
        merged.respeaks = depth.respeaks.enumerated().map { index, say in
            Respeak(id: "r\(index)", instruction: say.instruction, accept: say.accept,
                    correct: say.correct, incorrect: say.incorrect)
        }
        merged.ask = depth.ask.enumerated().map { index, item in
            AskItem(id: "q\(index)", question: item.question, answer: item.answer, atoms: item.links)
        }
        merged.isDeep = true
        return (merged, usage)
    }

    private static func attemptFacts(turn: Turn, history: [Turn], level: Int, pack: LanguagePack) -> String {
        var facts = """
        Mode: \(turn.mode.rawValue)
        Level: \(pack.level(level))
        Spoken: \(turn.attempt.wasTyped ? "no, typed" : "yes")
        """
        if !history.isEmpty {
            facts += "\n\nThe exchange so far:\n"
            for past in history {
                facts += "Q: \(past.prompt.target ?? past.prompt.english ?? "—")\n"
                facts += "A: \(past.attempt.confirmed)\n"
            }
        }
        facts += """

        Asked (English): \(turn.prompt.english ?? "—")
        Asked (\(pack.language.name)): \(turn.prompt.target ?? "—")
        The learner said: \(turn.attempt.confirmed)
        """
        return facts
    }

    // MARK: Generation

    struct Generated: Codable { var english: String; var target: String?; var pointID: String? }

    /// `revisit` are points due for retrieval — woven into an ordinary sentence
    /// rather than served as a card. `stretch` is a point the learner has never
    /// reached for, when we are deliberately pushing range.
    func nextPrompt(mode: Mode,
                    language: Language,
                    level: Int,
                    revisit: [String],
                    stretch: GrammarPoint?,
                    avoid: [String]) async throws -> (Generated, Anthropic.Usage) {

        let pack = LanguagePacks.pack(for: language)
        var facts = """
        Mode: \(mode.rawValue)
        Level: \(pack.level(level))
        """
        if !revisit.isEmpty {
            facts += "\nWork these in without drawing attention to them: \(revisit.joined(separator: ", "))"
        }
        if let stretch {
            facts += """

            Build this so the learner has to reach for \(stretch.name).
            \(stretch.instruction)
            """
        }
        if !avoid.isEmpty {
            facts += "\nAlready used today, do not repeat: \(avoid.suffix(20).joined(separator: " | "))"
        }

        return try await api.send(
            Generated.self,
            cachedSystem: Self.generateSystem(pack),
            user: facts,
            schema: Schemas.prompt,
            effort: .medium
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
            schema: Schemas.freeAnswer(for: language)
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
        When the attempt was spoken, never use \(pack.kinds.filter(\.isWrittenOnly).map(\.rawValue).joined(separator: ", ").isEmpty ? "any written-only kind" : pack.kinds.filter(\.isWrittenOnly).map(\.rawValue).joined(separator: ", ")) — silent orthography is not something a speaker got wrong.

        Routing. missing-piece, extra-piece, word-order and word-choice are
        catch-alls: almost any error can be described as one of them, so reach
        for a specific kind first and fall back only when nothing fits.
        \(pack.routing)

        \(pack.assessmentNotes)
        """
    }

    private static func generateSystem(_ pack: LanguagePack) -> String {
        """
        \(voice(pack))

        You write one thing for the learner to attempt.

        translate — `english` is a sentence to render in \(pack.language.name);
        leave `target` null. Write it so a natural rendering needs the target
        structure, rather than naming the structure.

        listen — `target` is the sentence to be played, written first and in
        \(pack.language.name); `english` is its meaning.

        produce — `target` is a question to answer in \(pack.language.name),
        written first and in \(pack.language.name); `english` is its meaning.
        Ask about the learner's own life, and make it answerable in two or three
        sentences.

        Sentences are things a person would actually say. No textbook filler, no
        sentences that exist only to contain a grammar point.
        \(pack.generationNotes)
        """
    }

    private static func coreSystem(_ pack: LanguagePack) -> String {
        """
        \(voice(pack))

        You explain one point, and only explain it — the practice is written
        separately, so do not include drills or questions here.

        `rule` is the explanation: a short paragraph. Say what governs the
        choice, not what the learner did.
        The contrast is the confusable neighbour, which is usually what they
        need next; give it a subject so it opens. Null it only when there
        genuinely is no near neighbour.
        `examples` are the pattern in use — three or four, each something a
        person would say. Give an example a subject when opening it would
        teach something further.
        """
    }

    private static func practiceSystem(_ pack: LanguagePack) -> String {
        """
        \(voice(pack))

        You write the practice for a rule that has already been explained.

        Every drill needs at least two rungs, hardest first. Rung 0 is unaided
        production. Each later rung removes something the learner has to build
        — a frame with a gap, then a choice between two. A learner who fails
        drops a rung, so the lower rungs must test the same point with less to
        construct, never a different point.

        `accept` lists every form a speaker would accept, not just the neatest.

        `ask` is two questions the learner plausibly has after reading the rule,
        in their own words, each answered in a sentence or two and carrying
        links so the answer opens further.

        `patterns` replaces the rule on a third visit: examples only, no
        explanation. If explaining twice did not work, a third will not either.

        \(atomRules(pack))
        """
    }

    private static func openingSystem(_ pack: LanguagePack) -> String {
        """
        \(voice(pack))

        You return a score and where each problem is — nothing more. Naming and
        fixing happen in a second pass, so `locate` must not give the answer
        away: the learner reads it and tries to repair the sentence themselves.
        "Something is in the wrong place in the second half" is right.
        "已经 should come before the verb" is not.

        Rank them: exactly one finding has weight "start", the one that most
        stops the learner being understood. Return every other finding too.
        Never omit a real error because it is minor — silence reads as approval.

        Report what they got right as well, with verdict "kept". Praise that
        names a real choice teaches; generic praise does not.

        `readOfScore` is one clause on what the score means. Not a breakdown,
        not a pep talk.

        Severity follows the level. Below B1 or HSK 4, being understood matters
        more than being formally correct: a morphological slip that leaves the
        meaning intact is "weakens", not "breaks". Reserve "breaks" for what
        actually stops a listener.

        \(atomRules(pack))
        """
    }

    private static func depthSystem(_ pack: LanguagePack) -> String {
        """
        \(voice(pack))

        You fill in findings that have already been located. For each id you are
        given, say what is wrong (`name`, still without the corrected text),
        then the correction (`fix`), then one or two sentences on why (`note`).
        Return every id you are given and invent no others.

        `natural` is what a speaker would actually say when that differs from
        the minimal correction. Null when it does not.

        `respeaks` ask the learner to say their own sentence again with one
        thing deliberately changed — a different subject, a different tense, an
        added detail. Never a plain repeat: the point is transfer, not recall of
        the correction. Two or three, each with the forms you would accept.

        `ask` is two questions the learner plausibly has about this attempt.

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
