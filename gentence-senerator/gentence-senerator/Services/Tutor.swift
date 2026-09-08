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
            var kind: AtomKind; var verdict: Atom.Verdict
            var weight: Atom.Weight; var locate: String; var subject: String
        }
        var score: Int
        var readOfScore: String
        var findings: [Finding]
    }

    struct Depth: Codable {
        struct Filled: Codable { var id: String; var name: String; var fix: String; var note: String }
        struct Say: Codable { var instruction: String; var accept: [String]; var correct: String; var incorrect: String }
        var natural: String?
        var findings: [Filled]
        var respeaks: [Say]
        /// Grammar points the attempt used. Tagged here and not on the opening
        /// call, which the learner is waiting on.
        var used: [String] = []
    }

    /// The opening review as it is written. `score` and `readOfScore` land
    /// about halfway through the call; the findings follow one at a time, so
    /// the learner reads a real score while the rest is still arriving.
    ///
    /// Each element is the review so far. The last one carries the usage.
    func streamOpening(turn: Turn, history: [Turn] = [], level: Int)
    -> AsyncThrowingStream<(Review, Anthropic.Usage?), Error> {
        let pack = LanguagePacks.pack(for: turn.language)
        let said = (history + [turn]).map(\.attempt.confirmed).joined(separator: " ")
        let pointID = turn.prompt.pointID
        let events = api.stream(
            cachedSystem: Self.openingSystem(pack),
            user: Self.attemptFacts(turn: turn, history: history, level: level, pack: pack),
            schema: Schemas.reviewOpening(for: turn.language),
            effort: .medium
        )

        return AsyncThrowingStream { continuation in
            let work = Task {
                var buffer = ""
                var sent = Review(score: 0, readOfScore: "", atoms: [])
                var published = 0
                let decoder = JSONDecoder()
                do {
                    for try await event in events {
                        switch event {
                        case .refused(let why):
                            throw Anthropic.Failure.refused(why)

                        case .finished(let usage):
                            // The streamed values are a preview. What lands on
                            // screen for good is a strict parse of the whole
                            // document, so a scanning artifact can never be
                            // what gets kept or written to history.
                            if let whole = try? decoder.decode(Opening.self,
                                                               from: Data(buffer.utf8)) {
                                continuation.yield((Review(
                                    score: whole.score,
                                    readOfScore: whole.readOfScore,
                                    atoms: whole.findings.map {
                                        Self.atom(from: $0, said: said, pointID: pointID)
                                    },
                                    natural: nil
                                ), usage))
                            } else {
                                continuation.yield((sent, usage))
                            }
                            continuation.finish()
                            return

                        case .text(let chunk):
                            buffer += chunk
                            var changed = false
                            if sent.score == 0,
                               let score = PartialJSON.integer(at: "score", in: buffer) {
                                sent.score = score
                                changed = true
                            }
                            if sent.readOfScore.isEmpty,
                               let read = PartialJSON.string(at: "readOfScore", in: buffer) {
                                sent.readOfScore = read
                                changed = true
                            }
                            let elements = PartialJSON.elements(ofArrayAt: "findings", in: buffer)
                            if elements.count > published {
                                for element in elements[published...] {
                                    guard let finding = try? decoder.decode(
                                        Opening.Finding.self, from: element) else { continue }
                                    sent.atoms.append(Self.atom(from: finding, said: said,
                                                                pointID: pointID))
                                }
                                published = elements.count
                                changed = true
                            }
                            // Nothing goes out until the score does, so the
                            // screen never opens on an empty review.
                            if changed, sent.score != 0 {
                                continuation.yield((sent, nil))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func atom(from finding: Opening.Finding,
                             said: String, pointID: String?) -> Atom {
        Atom(id: Atom.identify(finding.kind, finding.subject),
             kind: finding.kind, verdict: finding.verdict,
             stages: .init(locate: finding.locate),
             seed: .init(subject: finding.subject, context: said, pointID: pointID),
             weight: finding.weight)
    }

    /// What the learner sees at once. Kept for the non-streaming path.
    func assessOpening(turn: Turn, history: [Turn] = [], level: Int)
    async throws -> (Review, Anthropic.Usage) {
        let pack = LanguagePacks.pack(for: turn.language)
        // A finding can sit in any answer of a held exchange, so the seed
        // carries all of them rather than only the last.
        let said = (history + [turn]).map(\.attempt.confirmed).joined(separator: " ")
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
                Atom(id: Atom.identify($0.kind, $0.subject),
                     kind: $0.kind, verdict: $0.verdict,
                     stages: .init(locate: $0.locate),
                     seed: .init(subject: $0.subject, context: said,
                                 pointID: turn.prompt.pointID),
                     weight: $0.weight)
            },
            natural: nil
        )
        return (review, usage)
    }

    /// Fetched while the learner is still looking at where the problem is.
    /// Kept for the non-streaming path; `streamDepth` is what the app uses.
    func assessDepth(turn: Turn, opening: Review, history: [Turn] = [], level: Int)
    async throws -> (Review, Anthropic.Usage) {
        let pack = LanguagePacks.pack(for: turn.language)
        let listed = opening.atoms.enumerated()
            .map { "\($0.offset): \($0.element.stages.locate)" }
            .joined(separator: "\n")

        let (depth, usage) = try await api.send(
            Depth.self,
            cachedSystem: Self.depthSystem(pack),
            user: Self.attemptFacts(turn: turn, history: history, level: level, pack: pack)
                + "\n\nFindings to fill in, by number:\n" + listed,
            schema: Schemas.reviewDepth(for: turn.language),
            effort: .medium
        )

        return (Self.merge(depth, into: opening, known: pack.pointIDs), usage)
    }

    /// `known` throws away ids the model invented. Anything that gets past here
    /// is written into `Progress` under that id and stays there.
    private static func merge(_ depth: Depth, into opening: Review,
                              known: Set<String>) -> Review {
        var merged = opening
        let byIndex = Dictionary(
            depth.findings.compactMap { finding in Int(finding.id).map { ($0, finding) } },
            uniquingKeysWith: { first, _ in first }
        )
        merged.atoms = opening.atoms.enumerated().map { index, atom in
            guard let filled = byIndex[index] else { return atom }
            var copy = atom
            copy.stages.name = filled.name
            copy.stages.fix = filled.fix
            copy.stages.note = filled.note
            return copy
        }
        merged.natural = depth.natural
        merged.respeaks = depth.respeaks.enumerated().map { index, say in
            Respeak(id: "r\(index)", instruction: say.instruction, accept: say.accept,
                    correct: say.correct, incorrect: say.incorrect)
        }
        merged.usedPoints = Array(Set(depth.used).intersection(known)).sorted()
        merged.isDeep = true
        return merged
    }

    /// The same call, published one finding at a time. Half the wall-clock is
    /// thinking before any text exists, and the findings are then written in
    /// the order they were listed — so the row carrying `.start`, which is the
    /// one the learner reaches for first, is filled in at roughly half the
    /// wait, without the others holding it up.
    ///
    /// Each element is the review so far. The last one carries the usage.
    func streamDepth(turn: Turn, opening: Review, history: [Turn] = [], level: Int)
    -> AsyncThrowingStream<(Review, Anthropic.Usage?), Error> {
        let pack = LanguagePacks.pack(for: turn.language)
        let listed = opening.atoms.enumerated()
            .map { "\($0.offset): \($0.element.stages.locate)" }
            .joined(separator: "\n")
        let events = api.stream(
            cachedSystem: Self.depthSystem(pack),
            user: Self.attemptFacts(turn: turn, history: history, level: level, pack: pack)
                + "\n\nFindings to fill in, by number:\n" + listed,
            schema: Schemas.reviewDepth(for: turn.language),
            effort: .medium
        )

        return AsyncThrowingStream { continuation in
            let work = Task {
                var buffer = ""
                var sent = opening
                var published = 0
                let decoder = JSONDecoder()
                do {
                    for try await event in events {
                        switch event {
                        case .refused(let why):
                            throw Anthropic.Failure.refused(why)

                        case .finished(let usage):
                            // As in the opening: what is kept is a strict parse
                            // of the whole document, so a scanning artifact can
                            // only ever appear in the preview.
                            if let whole = try? decoder.decode(Depth.self,
                                                               from: Data(buffer.utf8)) {
                                continuation.yield((Self.merge(whole, into: opening,
                                                               known: pack.pointIDs), usage))
                            } else {
                                sent.isDeep = true
                                continuation.yield((sent, usage))
                            }
                            continuation.finish()
                            return

                        case .text(let chunk):
                            buffer += chunk
                            var changed = false
                            if sent.natural == nil,
                               let natural = PartialJSON.string(at: "natural", in: buffer) {
                                sent.natural = natural
                                changed = true
                            }
                            let elements = PartialJSON.elements(ofArrayAt: "findings", in: buffer)
                            if elements.count > published {
                                for element in elements[published...] {
                                    guard let filled = try? decoder.decode(
                                            Depth.Filled.self, from: element),
                                          let index = Int(filled.id),
                                          sent.atoms.indices.contains(index) else { continue }
                                    sent.atoms[index].stages.name = filled.name
                                    sent.atoms[index].stages.fix = filled.fix
                                    sent.atoms[index].stages.note = filled.note
                                }
                                published = elements.count
                                changed = true
                            }
                            // `respeaks` and the natural version are still to
                            // come, so `isDeep` stays false until `.finished`.
                            if changed { continuation.yield((sent, nil)) }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func attemptFacts(turn: Turn, history: [Turn], level: Int, pack: LanguagePack) -> String {
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
    private static func heardFacts(turn: Turn, level: Int, pack: LanguagePack) -> String {
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

        `patterns` replaces the rule on a third visit: examples only, no
        explanation. If explaining twice did not work, a third will not either.

        Every `links` entry is a way onward: `subject` is what a lesson about it
        would be about — a real teachable point, never a restatement — and
        `headline` is one line on what opening it would teach.
        Kinds: \(pack.kinds.map(\.rawValue).joined(separator: ", ")).
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

        Rank them: exactly one finding has weight "start", the one that costs
        the learner most: being understood in translate and produce, catching
        what was actually said in listen. Return every other finding too.
        Never omit a real error because it is minor — silence reads as approval.
        The opposite failure is worse. Report nothing you cannot point at. A
        choice you would not have made is not an error, and an attempt with
        nothing wrong in it is an ordinary outcome — return no problems at all
        and say what carried it. Being corrected for something they got right is
        what stops a learner trusting any of it.

        In produce the corrections are held back and the exchange is reviewed
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
        character does. The score is how much of the sentence arrived. "breaks"
        is a miss that changed what the sentence meant; a syllable lost with the
        meaning intact is "weakens". Praise something hard that landed, not the
        easy syllables. `subject` is what would catch it next time — the sound,
        or the pair of characters, not the sentence.

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
        """
    }

    private static func depthSystem(_ pack: LanguagePack) -> String {
        """
        \(voice(pack))

        You fill in findings that have already been located. For each number
        you are given, say what is wrong (`name`, still without the corrected
        text), then the correction (`fix`), then one or two sentences on why
        (`note`). Return every number you are given, as `id`, copied exactly.
        Invent no others.

        `natural` is what a speaker would actually say when that differs from
        the minimal correction. Null when it does not.

        `respeaks` ask the learner to say their own sentence again with one
        thing deliberately changed — a different subject, a different tense, an
        added detail. Never a plain repeat: the point is transfer, not recall of
        the correction. Two or three, each with the forms you would accept.

        In listen the learner was writing down someone else's sentence. `name`
        says which of the three it was — misheard, heard and written wrong, or
        not known — and `note` says what makes that sound easy to lose, or, when
        they heard it, that the ear was right and only the writing was not.
        `natural` is null there: the played sentence is already what a speaker
        said. Build the respeaks from the played sentence.

        Every `links` entry is a way onward: `subject` is what a lesson about it
        would be about — a real teachable point, never a restatement of the
        sentence — and `headline` is one line on what opening it would teach.
        Kinds: \(pack.kinds.map(\.rawValue).joined(separator: ", ")).

        `used` is the other half of the job, and it is not about the errors.
        List the points below that the learner's own words actually used,
        whether they used them well or badly and whether or not anyone asked
        for them. A point you cannot put a finger on in their sentence is not
        used, and an empty list is an ordinary answer. Ids only, copied exactly;
        invent none.

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

/// `used` was added after the rest of the deep review existed, and the reply is
/// still whole without it — the synthesised decoder would throw all of it away
/// over one absent array, and the deep call has no second chance.
extension Tutor.Depth {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        natural = try container.decodeIfPresent(String.self, forKey: .natural)
        findings = try container.decode([Filled].self, forKey: .findings)
        respeaks = try container.decode([Say].self, forKey: .respeaks)
        used = try container.decodeIfPresent([String].self, forKey: .used) ?? []
    }
}
