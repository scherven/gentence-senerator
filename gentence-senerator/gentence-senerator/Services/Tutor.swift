import Foundation

/// Everything the app asks the model, in one place.
///
/// The important property is that `expand` takes a `LessonRequest` and nothing
/// else. Depth 0 and depth 7 are the same call — the request is built from the
/// atom that was tapped, not from the screen it was tapped on, so a new kind of
/// feedback never needs a new prompt or a new view.
actor Tutor {

    let api: Anthropic
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
                            blocks: blocks, patterns: [])
        lessons[request.cacheKey] = lesson
        return (lesson, usage)
    }

    /// Second stage. Merged into the lesson already on screen.
    func practice(for request: LessonRequest) async throws -> (Lesson, Anthropic.Usage)? {
        guard var lesson = lessons[request.cacheKey], !lesson.hasPractice else { return nil }

        let pack = LanguagePacks.pack(for: request.language)
        let (practice, usage) = try await api.send(
            Practice.self,
            cachedSystem: Self.practiceSystem(pack),
            user: Self.lessonFacts(request, pack) + "\nThe rule as written: \(lesson.blocks.first?.text ?? "")",
            schema: Schemas.lessonPractice(for: request.language),
            // The largest structured reply in the app, and the rungs have to
            // ladder down testing the same point. Nobody waits on it — it is
            // fetched while the rule is being read — so this is the one call
            // where raising effort would cost only money.
            effort: .medium
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

    // MARK: Assessment
    //
    // One call per exchange. It used to be two — a score and `locate` first,
    // the rest streamed in behind — because the learner was waiting. Graded in
    // a batch, nobody is, so every stage and a lesson per problem come back
    // together and the model reasons about the exchange once.

    struct Graded: Codable {
        struct Finding: Codable {
            var kind: AtomKind; var verdict: Atom.Verdict; var weight: Atom.Weight
            var locate: String; var name: String; var fix: String; var note: String
            var subject: String
        }
        struct Say: Codable { var instruction: String; var accept: [String]; var correct: String; var incorrect: String }
        struct Pair: Codable { var target: String; var gloss: String }
        struct Drill: Codable { var rungs: [Practice.R]; var correct: String; var incorrect: String }
        struct Taught: Codable {
            var finding: Int
            var title: String
            var rule: String
            var contrastTerm: String?
            var contrastNote: String?
            var contrastSubject: String?
            var examples: [Pair]
            var drills: [Drill]
            var patterns: [Pair]
        }
        var score: Int
        var readOfScore: String
        var findings: [Finding]
        var natural: String?
        var respeaks: [Say]
        var lessons: [Taught]
        var used: [String]
    }

    /// The whole request for one exchange, for a batch.
    nonisolated func reviewParams(turn: Turn, history: [Turn], level: Int) -> [String: Any] {
        let pack = LanguagePacks.pack(for: turn.language)
        return api.params(
            cachedSystem: Self.reviewSystem(pack),
            user: Self.attemptFacts(turn: turn, history: history, level: level, pack: pack),
            schema: Schemas.review(for: turn.language),
            effort: Self.reviewEffort,
            maxTokens: 32000,
            batched: true
        )
    }

    /// The one lever on quality left once latency stopped mattering.
    nonisolated static let reviewEffort: Anthropic.Effort = .high

    /// Graded on the spot. Listen still works this way until it is rebuilt.
    func review(turn: Turn, history: [Turn] = [], level: Int)
    async throws -> (Review, [Lesson], Anthropic.Usage) {
        let pack = LanguagePacks.pack(for: turn.language)
        let reply = try await api.send(
            cachedSystem: Self.reviewSystem(pack),
            user: Self.attemptFacts(turn: turn, history: history, level: level, pack: pack),
            schema: Schemas.review(for: turn.language),
            effort: Self.reviewEffort,
            maxTokens: 32000
        )
        let (review, lessons) = try Self.read(reply, turn: turn, history: history)
        return (review, lessons, reply.usage)
    }

    /// A finished reply, as a review and the lessons behind its problems.
    /// `known` drops point ids the model invented: anything that gets past
    /// here is written into `Progress` under that id and stays there.
    nonisolated static func read(_ reply: Anthropic.Reply, turn: Turn, history: [Turn])
    throws -> (Review, [Lesson]) {
        let graded = try Anthropic.decode(Graded.self, from: reply)
        let pack = LanguagePacks.pack(for: turn.language)
        // A finding can sit in any answer of a held exchange, so the seed
        // carries all of them rather than only the last.
        let said = (history + [turn]).map(\.attempt.confirmed).joined(separator: " ")

        let atoms = graded.findings.map { f in
            Atom(id: Atom.identify(f.kind, f.subject),
                 kind: f.kind, verdict: f.verdict,
                 stages: .init(locate: f.locate, name: f.name, fix: f.fix, note: f.note),
                 seed: .init(subject: f.subject, context: said, pointID: turn.prompt.pointID),
                 weight: f.weight)
        }
        let review = Review(
            score: graded.score,
            readOfScore: graded.readOfScore,
            atoms: atoms,
            natural: graded.natural,
            respeaks: graded.respeaks.enumerated().map { index, say in
                Respeak(id: "r\(index)", instruction: say.instruction, accept: say.accept,
                        correct: say.correct, incorrect: say.incorrect)
            },
            usedPoints: Array(Set(graded.used).intersection(pack.pointIDs)).sorted(),
            isDeep: true
        )

        let lessons = graded.lessons.compactMap { taught -> Lesson? in
            guard atoms.indices.contains(taught.finding) else { return nil }
            let atom = atoms[taught.finding]
            let request = LessonRequest(seed: atom.seed, kind: atom.kind, language: turn.language)
            return lesson(from: taught, request: request)
        }
        return (review, lessons)
    }

    private nonisolated static func lesson(from taught: Graded.Taught, request: LessonRequest) -> Lesson {
        var blocks: [Block] = [Block(id: "rule", kind: .rule, label: nil, text: taught.rule)]
        if let term = taught.contrastTerm, let note = taught.contrastNote {
            blocks.append(Block(
                id: "contrast", kind: .contrast, label: "Not to be confused with",
                sides: [
                    Side(id: "a", term: request.seed.subject, note: "What you were doing.", seed: nil),
                    Side(id: "b", term: term, note: note,
                         seed: taught.contrastSubject.map {
                             Atom.Seed(subject: $0, context: request.seed.context, pointID: nil)
                         })
                ]
            ))
        }
        blocks.append(Block(
            id: "examples", kind: .examples, label: "In the wild",
            examples: taught.examples.enumerated().map { index, pair in
                Example(id: "ex\(index)", target: pair.target, gloss: pair.gloss, seed: nil)
            }
        ))
        blocks.append(Block(
            id: "drills", kind: .drills, label: "Your turn",
            drills: taught.drills.enumerated().map { index, drill in
                Drill(id: "d\(index)",
                      rungs: drill.rungs.enumerated().map { rungIndex, rung in
                          Rung(id: "d\(index)r\(rungIndex)", support: rung.support,
                               prompt: rung.prompt, accept: rung.accept,
                               options: rung.options, answerIndex: rung.answerIndex)
                      },
                      correct: drill.correct, incorrect: drill.incorrect, atoms: [])
            }
        ))
        return Lesson(
            id: request.cacheKey, title: taught.title, blocks: blocks,
            patterns: taught.patterns.enumerated().map { index, pair in
                Example(id: "p\(index)", target: pair.target, gloss: pair.gloss, seed: nil)
            }
        )
    }

    nonisolated private static func attemptFacts(turn: Turn, history: [Turn], level: Int, pack: LanguagePack) -> String {
        // Listen is dictation. Labelling the played sentence "Asked" and the
        // transcript "The learner said" got it graded as production: a dropped
        // 吧 came back as a weak sentence rather than as an unstressed
        // syllable that never arrived.
        if turn.mode == .listen { return heardFacts(turn: turn, level: level, pack: pack) }

        var facts = """
        Mode: \(turn.mode.rawValue)
        Level: \(pack.level(level))
        Spoken: \(turn.attempt.wasTyped ? "no, typed" : "yes")
        """
        // A held produce exchange is assessed whole. Framing the earlier turns
        // as background and only the last as the attempt got them read as
        // context, and their errors went unreported — two thirds of a produce
        // session came back unmarked.
        if !history.isEmpty {
            facts += "\n\nThe exchange, all of which you are assessing:\n"
            for (index, past) in (history + [turn]).enumerated() {
                let asked = past.prompt.target ?? past.prompt.english ?? "—"
                let gloss = past.prompt.target == nil ? "" : "  (\(past.prompt.english ?? ""))"
                facts += "\(index + 1). Asked: \(asked)\(gloss)\n"
                facts += "   Said:  \(past.attempt.confirmed)\n"
            }
            return facts
        }

        facts += """

        Asked (English): \(turn.prompt.english ?? "—")
        Asked (\(pack.language.name)): \(turn.prompt.target ?? "—")
        The learner said: \(turn.attempt.confirmed)
        """
        return facts
    }

    /// One listen turn as it actually happened. A real recording carries
    /// reduction and an accent that synthesis does not, so which one played
    /// changes what a miss means. `wasTyped` decides whether the characters are
    /// the learner's at all: spoken back, recognition wrote them, and no
    /// orthography finding is attributable.
    nonisolated private static func heardFacts(turn: Turn, level: Int, pack: LanguagePack) -> String {
        let played = turn.prompt.audioSource?.kind == .recording
            ? "a recording of a speaker" : "synthesised speech"
        var facts = """
        Mode: listen
        Level: \(pack.level(level))

        Played (\(pack.language.name), \(played)): \(turn.prompt.target ?? "—")
        """
        if let english = turn.prompt.english { facts += "\nMeans: \(english)" }
        if turn.attempt.wasTyped {
            facts += "\nWrote: \(turn.attempt.confirmed)"
        } else {
            facts += "\nSaid back: \(turn.attempt.confirmed)"
            facts += "\nRecognition transcribed that, not the learner — how it is written is not theirs."
        }
        return facts
    }

    // MARK: Generation

    /// No `pointID`: the caller already knows which point it asked for, and the
    /// model has no vocabulary of ids to return one from.
    struct Generated: Codable { var english: String; var target: String? }

    /// `revisit` are points due for retrieval — woven into an ordinary sentence
    /// rather than served as a card. `stretch` is a point the learner has never
    /// reached for, when we are deliberately pushing range. `seed` is one word
    /// to season the sentence with — at most one a turn, dropped when it does
    /// not fit, and never what the sentence is about: the weakest of the three
    /// and the one the model may ignore. `domain` is the corner of a life to
    /// set a translate sentence in, rotated so a day does not land in the same
    /// place every turn; produce sets its own from the system prompt, so it
    /// arrives nil.
    func nextPrompt(mode: Mode,
                    language: Language,
                    level: Int,
                    revisit: [String],
                    stretch: GrammarPoint?,
                    seed: String? = nil,
                    domain: String? = nil,
                    avoid: [String]) async throws -> (Generated, Anthropic.Usage) {

        let pack = LanguagePacks.pack(for: language)
        var facts = """
        Mode: \(mode.rawValue)
        Level: \(pack.level(level))
        """
        if !revisit.isEmpty {
            facts += "\nWork these in without drawing attention to them: \(revisit.joined(separator: ", "))"
        }
        // Two produce questions in a row came back about which floor a place is
        // on: told to build the sentence around 二 against 两, the model went
        // looking for a setting that would host the structure rather than for
        // something worth asking. The system prompt already forbids exactly
        // that, but it is the cached prefix and this is the later, more
        // specific instruction, so this one won. In produce it is now an
        // opportunity rather than a task. Whether to reach at all is the
        // caller's call — a nil stretch here means this turn does not — so the
        // decision and the `pointID` that records it cannot drift apart.
        if let stretch {
            if mode != .produce {
                // In translate and listen the sentence exists to be rendered or
                // heard, so building it around a structure is the job.
                facts += """

                Write this so a natural rendering needs \(stretch.name).
                \(stretch.instruction)
                """
            } else {
                facts += """

                If the answer happens to want \(stretch.name) — \
                \(stretch.instruction) — so much the better. Do not go looking \
                for a topic that would need it. Ask what you would have asked \
                anyway.
                """
            }
        }
        // The corner of a life to land in. Translate had no objective of its
        // own — no stretch, and for a new learner nothing to revisit — so a
        // day of it circled whatever the seed words happened to be. This is
        // what produce gets from its system prompt, handed to translate a turn
        // at a time.
        if let domain {
            facts += """

            Set this in one ordinary corner of a life — this time: \(domain). A \
            different corner each turn; two sentences about the same setting are \
            one sentence.
            """
        }
        // Never a task, so never an instruction the sentence has to obey: a
        // prompt built around a word is a vocabulary card with extra steps. One
        // word, offered where it fits and dropped where it does not — the whole
        // day's seeds forced into every sentence was what made translate one
        // note held for ten turns.
        if let seed {
            if mode == .produce {
                facts += "\nOne word may slip into the question unremarked, if it fits, or not at all: \(seed)"
            } else {
                facts += """

                A word to work in only where it fits, and to leave out entirely \
                where it does not — never what the sentence is about: \(seed)
                In translate the English has to call for it; do not name it.
                """
            }
        }
        // Repeating the sentence was never the failure worth guarding: two
        // different questions about which floor a restaurant is on are not two
        // questions. The setting has to move, not just the wording.
        if !avoid.isEmpty {
            facts += """

            Already asked today. Do not repeat one, and do not ask a different \
            question about the same setting either — go somewhere else in their \
            life: \(avoid.suffix(20).joined(separator: " | "))
            """
        }

        // Listen only now; translate and produce are written a session at a
        // time by `daySet`.
        return try await api.send(
            Generated.self,
            cachedSystem: Self.generateSystem(pack),
            user: facts,
            schema: Schemas.prompt,
            effort: .medium
        )
    }

    // MARK: The day's prompts

    struct DaySet: Codable {
        struct Item: Codable {
            var english: String
            var target: String?
            var reference: String?
            var revisited: [String]
        }
        var items: [Item]
    }

    /// One slot of a session: the corner of a life for translate, and at most
    /// one word to season it with. Decided by the caller, like the stretch.
    struct Slot { var domain: String?; var seed: String? }

    /// Everything a translate or produce session will ask, in one call. Written
    /// together so the model sees the whole spread and can keep it varied,
    /// rather than being told turn by turn what the earlier turns were.
    ///
    /// `stretch` goes on the first item only: a reach is one question, three
    /// is drilling. `revisit` subjects are spread across the set, and each item
    /// says which it actually called for, so a subject is only checked against
    /// a sentence that asked for it.
    func daySet(mode: Mode, language: Language, level: Int,
                slots: [Slot], revisit: [String], stretch: GrammarPoint?,
                avoid: [String]) async throws -> ([Turn.Prompt], Anthropic.Usage) {
        let pack = LanguagePacks.pack(for: language)
        var facts = """
        Mode: \(mode.rawValue)
        Level: \(pack.level(level))
        Items: \(slots.count)
        """
        if !revisit.isEmpty {
            facts += """

            Due for review — spread these across the set, each in at least one \
            item, woven in without drawing attention to them: \
            \(revisit.joined(separator: ", "))
            """
        }
        if let stretch {
            facts += mode == .produce
                ? """

                  Item 1 only: if the answer happens to want \(stretch.name) — \
                  \(stretch.instruction) — so much the better. Do not go looking \
                  for a topic that would need it.
                  """
                : """

                  Item 1 only: write it so a natural rendering needs \
                  \(stretch.name). \(stretch.instruction)
                  """
        }
        facts += "\n\nPer item:"
        for (index, slot) in slots.enumerated() {
            var line = "\n\(index + 1)."
            if let domain = slot.domain { line += " Set it in: \(domain)." }
            if let seed = slot.seed {
                line += " A word to work in only if it fits, never the point: \(seed)."
            }
            if slot.domain == nil && slot.seed == nil { line += " —" }
            facts += line
        }
        if !avoid.isEmpty {
            facts += """


            Already asked today — do not repeat one, or ask about the same \
            setting: \(avoid.suffix(20).joined(separator: " | "))
            """
        }

        let (set, usage) = try await api.send(
            DaySet.self,
            cachedSystem: Self.daySetSystem(pack),
            user: facts,
            schema: Schemas.daySet,
            effort: .high
        )
        let asked = Set(revisit.map { $0.lowercased() })
        let prompts = set.items.prefix(slots.count).enumerated().map { index, item in
            Turn.Prompt(
                english: item.english,
                target: mode == .translate ? nil : item.target,
                reference: mode == .translate ? item.reference : nil,
                audioSource: nil,
                pointID: index == 0 ? stretch?.id : nil,
                revisited: item.revisited.filter { asked.contains($0.lowercased()) }
            )
        }
        guard prompts.count == slots.count else {
            throw Anthropic.Failure.malformed("asked for \(slots.count) items, got \(prompts.count)")
        }
        return (prompts, usage)
    }

    // MARK: Drills and questions

    struct DrillVerdict: Codable { var correct: Bool; var note: String }

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
            schema: Schemas.freeAnswer(for: language),
            // The only call where the learner writes the question, so the input
            // is not constrained the way the others are, and a wrong
            // explanation is one they will take on trust.
            effort: .medium
        )
    }

    // MARK: Prompts
    //
    // Byte-identical per language so the cache prefix holds. Everything that
    // varies per call goes in the user message.

    nonisolated private static func voice(_ pack: LanguagePack) -> String {
        """
        You are a \(pack.language.name) tutor: warm, exacting, and brief.
        Write the way a good teacher talks, not the way a textbook reads. Never
        pad. If one clause will do, use one clause.
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
        Exactly one question about the learner's own life: one sentence, one
        question mark, under fifteen words. No preamble, no second question, no
        "and why?". Answerable in two or three sentences.
        Decide what is worth asking before you think about grammar at all. Pick
        a corner of their life — work, family, food, money, sleep, travel, a
        habit, someone they have not called — and ask what you would actually
        ask a person about it. A structure you are pointed at is at most
        something the answer may happen to need; it is never the reason for the
        question, and a question that exists to host one is the wrong question.
        Land somewhere new each time: two questions about the same place, or
        the same afternoon, are one question asked twice however different the
        words.

        Sentences are things a person would actually say. No textbook filler, no
        sentences that exist only to contain a grammar point.
        \(pack.generationNotes)
        """
    }

    private static func daySetSystem(_ pack: LanguagePack) -> String {
        """
        \(voice(pack))

        You write a whole practice session at once: one item per numbered slot,
        in order.

        translate — `english` is a sentence to render in \(pack.language.name).
        `target` is null. Write it so a natural rendering needs the target
        structure, rather than naming the structure. `reference` is one
        natural rendering a speaker would say — shown to the learner after they
        answer, as one good way to say it, not the only one.

        produce — `target` is a question to answer in \(pack.language.name),
        written first and in \(pack.language.name); `english` is its meaning;
        `reference` is null. Each is exactly one question about the learner's
        own life: one sentence, one question mark, under fifteen words. No
        preamble, no second question, no "and why?". Answerable in two or three
        sentences. The questions are asked in order as one conversation, so
        they may follow on from each other, but each must stand alone.
        Decide what is worth asking before you think about grammar at all. Ask
        what you would actually ask a person. A structure you are pointed at is
        at most something the answer may happen to need; it is never the reason
        for the question.

        Across the set, land somewhere different each time: two items about the
        same place, or the same afternoon, are one item asked twice however
        different the words. Sentences are things a person would actually say.
        No textbook filler, no sentences that exist only to contain a grammar
        point.

        `revisited` lists which of the due-for-review subjects that item
        actually calls for, copied exactly. Empty when it calls for none.
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

        `patterns` replaces the rule on a third visit: examples only, no
        explanation. If explaining twice did not work, a third will not either.

        Every `links` entry is a way onward: `subject` is what a lesson about it
        would be about — a real teachable point, never a restatement — and
        `headline` is one line on what opening it would teach.
        Kinds: \(pack.kinds.map(\.rawValue).joined(separator: ", ")).
        """
    }

    nonisolated private static func reviewSystem(_ pack: LanguagePack) -> String {
        """
        \(voice(pack))

        You review an attempt and return everything the learner will read: a
        score, every finding at every stage, and a short lesson behind each
        problem. The learner reads it later, not while waiting, so take the
        time to be right.

        Each finding is revealed in stages, so keep them apart. `locate` says
        where, and must not give the answer away: the learner reads it first
        and tries to repair the sentence themselves. "Something is in the
        wrong place in the second half" is right. "已经 should come before the
        verb" is not. `name` says what is wrong, still without the corrected
        text. `fix` is the correction. `note` is one or two sentences on why.

        Rank them: exactly one finding has weight "start", the one that costs
        the learner most: being understood in translate and produce, catching
        what was actually said in listen. Return every other finding too.
        Never omit a real error because it is minor — silence reads as approval.
        The opposite failure is worse. Report nothing you cannot point at. A
        choice you would not have made is not an error, and an attempt with
        nothing wrong in it is an ordinary outcome — return no problems at all
        and say what carried it. Being corrected for something they got right is
        what stops a learner trusting any of it. Before you finish, go back
        over each problem and drop any you could not defend to a native
        speaker.

        In produce the corrections were held back and the exchange is reviewed
        as one thing. Every answer in it is being assessed, not only the last:
        a problem in the first answer counts as much as one in the third, and
        `locate` must say which answer it is in. The same mistake in two
        answers is one finding and outranks two separate one-offs — say that it
        recurred. The score is for the exchange, not for the last sentence.

        In listen the sentence is the speaker's and the learner is writing down
        what reached them, so nothing in it is a production error. Every finding
        says which of three things happened, because each takes a different
        repair.
        Misheard — the sound never arrived, or arrived as a different one. This
        is the listening finding.
        Heard, written wrong — the sound arrived and the spelling of it is
        wrong. Orthography. Told they misheard something they heard perfectly, a
        learner stops trusting an ear that works.
        Not known — it arrived intact and they have no word for it.
        Which of the three belongs in `locate`, and it is still where and not
        what: "you caught every syllable, but one character in the first half is
        not the one that sound writes" gives nothing away, and naming the
        character does. `name` says which of the three it was; `note` says what
        makes that sound easy to lose, or, when they heard it, that the ear was
        right and only the writing was not. The score is how much of the
        sentence arrived. "breaks" is a miss that changed what the sentence
        meant; a syllable lost with the meaning intact is "weakens". Praise
        something hard that landed, not the easy syllables. `subject` is what
        would catch it next time — the sound, or the pair of characters, not
        the sentence. `natural` is null there: the played sentence is already
        what a speaker said. Build the respeaks from the played sentence.

        Report what they got right as well, with verdict "kept". Praise that
        names a real choice teaches; generic praise does not.

        `readOfScore` is one clause on what the score means. Not a breakdown,
        not a pep talk.

        Severity follows the level. Below B1 or HSK 4, being understood matters
        more than being formally correct: a morphological slip that leaves the
        meaning intact is "weakens", not "breaks". Reserve "breaks" for what
        actually stops a listener.

        `subject` is what a lesson about the finding would be about: a real
        teachable point, never a restatement of the sentence.

        Kinds: \(pack.kinds.map(\.rawValue).joined(separator: ", ")).
        When the attempt was spoken, never use a written-only kind — silent
        orthography is not something a speaker got wrong.

        Routing. missing-piece, extra-piece, word-order and word-choice are
        catch-alls: almost any error fits one, so reach for a specific kind
        first and fall back only when nothing else does.
        \(pack.routing)
        \(pack.assessmentNotes)

        `natural` is what a speaker would actually say when that differs from
        the minimal correction. Null when it does not.

        `respeaks` ask the learner to say their own sentence again with one
        thing deliberately changed — a different subject, a different tense, an
        added detail. Never a plain repeat: the point is transfer, not recall of
        the correction. Two or three, each with the forms you would accept.

        `lessons`: one for each finding whose verdict is breaks or weakens,
        pointing at it by its index in `findings`. None for kept. A lesson
        teaches the point, not the sentence. `rule` says what governs the
        choice, not what the learner did. The contrast is the confusable
        neighbour, which is usually what they need next; null it only when
        there genuinely is no near neighbour. `examples` are the pattern in
        use — three or four things a person would say. `drills`: two, each with
        at least two rungs, hardest first. Rung 0 is unaided production; each
        later rung removes something the learner has to build — a frame with a
        gap, then a choice between two — and must test the same point with less
        to construct, never a different point. `accept` lists every form a
        speaker would accept, not just the neatest. `patterns` replaces the
        rule on a third visit: examples only, no explanation.

        `used` is not about the errors. List the points below that the
        learner's own words actually used, whether they used them well or badly
        and whether or not anyone asked for them. A point you cannot put a
        finger on in their sentence is not used, and an empty list is an
        ordinary answer. Ids only, copied exactly; invent none.

        The points, by id:
        \(pack.points.map { "\($0.id) — \($0.name)" }.joined(separator: "\n"))
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
        then attach links for anything in your answer worth opening: `subject`
        is what a lesson about it would be about, `headline` one line on what it
        teaches.
        Kinds: \(pack.kinds.map(\.rawValue).joined(separator: ", ")).
        """
    }
}
