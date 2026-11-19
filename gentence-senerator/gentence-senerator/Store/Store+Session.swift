import Foundation

extension Store {

    // MARK: Session

    /// A session's exchanges no job holds yet: after what was filed when it
    /// first ended, and not already sent.
    nonisolated static func unfiled(_ session: Session, jobs: [GradingJob]) -> [GradingJob.Exchange] {
        let sent = Set(jobs.filter { $0.sessionID == session.id }
            .flatMap { $0.exchanges.flatMap(\.turnIDs) })
        var rest = session
        rest.turns = session.open.filter { !sent.contains($0.id) }
        return GradingJob.exchanges(of: rest)
    }

    func begin(_ mode: Mode) async {
        // Listen stays open past the day's one: the picker is how another
        // dialogue gets chosen.
        guard settings.language.modes.contains(mode),
              !isDone(mode) || (mode == .listen && hasDialogues) else { return }
        settings.mode = mode
        redo = nil
        knowledge = [:]
        path = []
        reading = []
        dropPending()

        // The day's set may be being written already; join it rather than
        // writing a second one.
        if let running = writing[Store.holdKey(settings.language, mode)] {
            phase = .preparing
            await running.value
        }

        if mode != .listen { takePackDay() }

        // Pick up where it was left, rather than throwing the turns away.
        if resumable(mode) != nil,
           let held = holds[Store.holdKey(settings.language, mode)] {
            session = held.session
            current = held.turn
            if mode == .translate { startRedo() }
            stretch = stretch(of: held.session)
            draft = ""
            if current == nil {
                await nextPrompt()
            } else {
                phase = .ready
                prefetchNext()
            }
            return
        }

        // A dialogue replaces the whole listen session. Falls through to
        // single clips when the library has nothing at this level.
        if mode == .listen, startPassage() { return }

        session = freshSession(mode)
        if mode == .translate { startRedo() }
        stretch = nil
        await nextPrompt()
        if let session { stretch = stretch(of: session) }
    }

    /// The structure produce is reaching for this session, if any. Read off the
    /// written set, so it is the one the question was actually written for.
    func stretch(of session: Session) -> GrammarPoint? {
        guard session.mode == .produce || session.mode == .reply,
              let id = session.planned?.first?.pointID else { return nil }
        return pack.points.first { $0.id == id }
    }

    // MARK: Writing the day

    /// Writes today's translate and produce sets ahead of time, so starting
    /// either on a train with no signal still works. Each is held as an
    /// unstarted session, which `begin` resumes.
    ///
    /// Run after the grading pump, so what yesterday's reviews put on the
    /// schedule is in `Progress` before today's sentences are written from it.
    ///
    /// Today comes from the offline queue when it has a day; then the queue is
    /// kept one day ahead, so a first open with no signal still has a day.
    /// Never over a held session: those are answers.
    func prepareDay() async {
        takePackDay()
        for mode in Mode.ahead {
            let key = Store.holdKey(settings.language, mode)
            guard writing[key] == nil else { continue }
            if let held = holds[key]?.session {
                if held.id == sessionID(for: mode) { await writeRest(of: held, key: key) }
                continue
            }
            guard today(mode) == nil else { continue }

            let draft = freshSession(mode)
            let (stretch, words) = (plan.stretch, plan.words)
            let task = Task { [weak self] in
                guard let self else { return }
                guard let prompts = try? await self.writeSet(for: draft, from: 0,
                                                             stretch: stretch, words: words)
                else { return }
                // Started by hand while this was being written: that one owns
                // the slot, and this set goes unused.
                guard self.holds[key] == nil, self.session?.id != draft.id,
                      draft.level == self.settings.level else { return }
                var planned = draft
                planned.planned = prompts
                // The goal may have moved while this was being written.
                if planned.scene != true { planned.goal = self.settings.dailyGoal }
                self.holds[key] = Unfinished(session: planned, turn: nil)
                Vault.save(self.holds, Vault.holds)
            }
            writing[key] = task
            await task.value
            writing[key] = nil
        }
        keepPackStocked()
    }

    /// Today's held session asks more than its set holds — the goal was
    /// raised — so the rest is written now, while there is signal. `begin`
    /// joins it; `plannedTurn` would otherwise write it on the spot.
    private func writeRest(of held: Session, key: String) async {
        let have = held.planned ?? held.turns.map(\.prompt)
        guard have.count < held.goal else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            guard let written = try? await self.writeSet(for: held, from: have.count,
                                                         stretch: self.plan.stretch,
                                                         words: self.plan.words)
            else { return }
            let full = have + written
            if var now = self.holds[key], now.session.id == held.id,
               (now.session.planned ?? []).count <= have.count {
                now.session.planned = full
                self.holds[key] = now
                Vault.save(self.holds, Vault.holds)
            }
            if self.session?.id == held.id, (self.session?.planned ?? []).count <= have.count {
                self.session?.planned = full
            }
        }
        writing[key] = task
        await task.value
        writing[key] = nil
    }

    /// Prompts for every turn from `index` to the end of the session. The
    /// per-turn choices — which corner of a life, which word — are the ones
    /// the turn-by-turn generation made, so a turn index still gets the same
    /// seasoning it always did. `stretch` and `words` are the draw of the day
    /// the session belongs to, which is not always today.
    func writeSet(for session: Session, from index: Int,
                  stretch: GrammarPoint?, words: WordSeeds,
                  avoiding also: [String] = []) async throws -> [Turn.Prompt] {
        guard session.goal > index else { return [] }
        let day = String(session.id.prefix(10))
        let scene = session.scene == true
        let slots = (index..<session.goal).map { turn in
            Tutor.Slot(
                domain: DayPlan.domain(day: day, language: session.language, turn: turn),
                kind: session.mode == .produce && !scene
                    ? DayPlan.kind(day: day, language: session.language, turn: turn) : nil,
                seed: DayPlan.seed(from: words, turn: turn)
            )
        }
        // Item 1 of produce, or of reply now that produce is not owed: a
        // requested point has to land somewhere every day.
        let reach = (session.mode == .produce || session.mode == .reply) && index == 0
            && settings.offerStretch ? stretch : nil
        let avoid = recentlyAsked(session.mode) + Mode.allCases.compactMap { today($0) }
            .flatMap { ($0.planned ?? []) + $0.turns.map(\.prompt) }
            .compactMap(\.english) + also
        let (prompts, usage) = try await tutor.daySet(
            mode: session.mode, language: session.language,
            level: session.level ?? settings.level,
            slots: slots,
            revisit: progress.seedsForGeneration(language: session.language,
                                                 on: max(Spend.date(day) ?? .now, .now)),
            stretch: reach, scene: scene, avoid: avoid
        )
        costs.noteSet(note(usage))
        Vault.save(costs, Vault.costs)
        return prompts
    }

    /// Today's session for `mode`, unstarted. Produce on the language's scene
    /// day is the one scene.
    func freshSession(_ mode: Mode) -> Session {
        let scene = mode == .produce && sceneToday
        var fresh = Session(id: sessionID(for: mode), language: settings.language, mode: mode,
                            startedAt: .now, turns: [], goal: scene ? 1 : settings.dailyGoal,
                            level: settings.level)
        if scene { fresh.scene = true }
        return fresh
    }

    var sceneToday: Bool { DayPlan.isSceneDay(.now, language: settings.language) }

    /// Every `mode` question of the last week, every language, oldest first.
    /// Compared by English meaning, so one asked in French counts in Mandarin.
    func recentlyAsked(_ mode: Mode, days: Int = 7) -> [String] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
        let sessions = (past + holds.values.map(\.session))
            .filter { $0.mode == mode && $0.startedAt >= cutoff }
            .sorted { $0.startedAt < $1.startedAt }
        var seen = Set<String>()
        return sessions
            .flatMap { $0.turns.map(\.prompt) + ($0.planned ?? []) }
            .compactMap(\.english)
            .filter { seen.insert($0).inserted }
    }

    /// A point at the learner's level that they have never once attempted.
    /// Absence is the signal — it produces no errors to schedule on. Produce
    /// only, but the plan names it before a mode has been picked, so the mode
    /// check sits at the use rather than here.
    func pickStretch(excluding taken: Set<String> = []) -> GrammarPoint? {
        let use: GrammarPoint.Use = settings.prefersTyping ? .written : .spoken
        let candidates = pack.reachable(at: settings.level, use: use)
        let fresh = progress.neverReached(among: candidates).filter { !taken.contains($0.id) }
        return weightedToTheTop(of: fresh)
    }

    /// The plan, rebuilt off today's draw. Everything random about a day
    /// happens inside `DayDraw.forToday`, and only when the day, the language
    /// or the level has moved; `DayPlan.read` derives the rest, which is why
    /// finishing a session still refreshes the record without dealing a new
    /// day.
    func refreshPlan() {
        let language = settings.language
        let level = settings.level
        // Tomorrow's draw, made the evening before with its set, becomes
        // today's rather than being drawn again.
        let next = language.rawValue + "|next"
        if draws[language.rawValue]?.day != Spend.key(.now),
           let ahead = draws[next], ahead.day == Spend.key(.now) {
            draws[language.rawValue] = ahead
            draws[next] = nil
            Vault.save(draws, Vault.plan)
        }
        let drawn = DayDraw.forToday(draws[language.rawValue], day: Spend.key(.now),
                                     language: language, level: level) {
            (requestedStretch(on: Spend.key(.now)) { pickStretch()?.id },
             WordSeeds.read(band: lexicon.band(upTo: level, language: language),
                            above: lexicon.band(at: level + 1, language: language),
                            progress: progress, language: language,
                            missed: missedWords))
        }
        if drawn != draws[language.rawValue] {
            draws[language.rawValue] = drawn
            Vault.save(draws, Vault.plan)
        }
        plan = DayPlan.read(
            pack: pack, level: level,
            use: settings.prefersTyping ? .written : .spoken,
            progress: progress,
            stretch: drawn.stretchID.flatMap { id in pack.points.first { $0.id == id } },
            words: drawn.words
        )
    }

    /// One draw, weighted 1/(1 + levels down), so a point at the learner's own
    /// level is five times likelier than one four levels below it. Uniform, a
    /// full curriculum makes the stretch a beginner's lucky dip.
    private func weightedToTheTop(of points: [GrammarPoint]) -> GrammarPoint? {
        let weights = points.map { 1.0 / Double(1 + settings.level - $0.level) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }
        var roll = Double.random(in: 0..<total)
        for (point, weight) in zip(points, weights) {
            roll -= weight
            if roll < 0 { return point }
        }
        return points.last
    }

    func nextPrompt() async {
        draft = ""

        // Written during the last attempt, so there is usually nothing to wait
        // for here. A prefetch that failed falls through and asks again.
        if let ready = pending {
            pending = nil
            if let turn = await ready.value {
                install(turn)
                return
            }
        }

        phase = .preparing
        do {
            install(try await makeTurn())
        } catch {
            phase = .failed(Plain.message(error, "next prompt"))
        }
    }

    /// Produces a turn without touching what is on screen, so it is safe to run
    /// ahead of time.
    private func makeTurn() async throws -> Turn {
        if settings.mode != .listen { return try await plannedTurn() }

        // Real speech where the library has it. Falls through to a generated
        // sentence and synthesis otherwise, which is the normal case for
        // Mandarin.
        if settings.mode == .listen,
           let clip = clips.pick(language: settings.language,
                                 level: settings.level, excluding: usedClips) {
            usedClips.insert(clip.id)
            return Turn(
                id: UUID(), mode: .listen, language: settings.language, createdAt: .now,
                prompt: .init(english: clip.english, target: clip.text,
                              audioSource: clips.source(for: clip), pointID: nil),
                attempt: .init(heard: "", confirmed: "", wasTyped: false,
                               audioFilename: nil, pronunciation: nil),
                review: nil
            )
        }

        // The turn on screen is not in `session.turns` until it is submitted,
        // so without it here a prefetch can repeat the prompt being answered.
        var used = (session?.turns ?? []).compactMap { $0.prompt.english }
        if let live = current?.prompt.english { used.append(live) }

        let revisit = progress.seedsForGeneration(language: settings.language)
        // Produce reaches once a session — `used` is empty only on the opening
        // question. A reach is one question; three is drilling. Resolved here
        // rather than inside the prompt, so the point recorded below is always
        // the point the learner was actually invited to use.
        let offered = (settings.mode != .produce || used.isEmpty) ? stretch : nil
        // One turn's worth of seasoning, rotated by how many prompts are already
        // out this session. The day fixes the pool; the turn picks from it, so a
        // sitting no longer forces the same two words into every sentence. The
        // rotating domain and kind keep the set from landing in one place.
        let turn = used.count
        let seed = DayPlan.seed(from: plan.words, turn: turn)
        let day = Spend.key(.now)
        let domain = settings.mode == .listen
            ? nil : DayPlan.domain(day: day, language: settings.language, turn: turn)
        let kind = settings.mode == .produce
            ? DayPlan.kind(day: day, language: settings.language, turn: turn) : nil
        let (made, usage) = try await tutor.nextPrompt(
            mode: settings.mode,
            language: settings.language,
            level: settings.level,
            revisit: revisit,
            stretch: offered,
            seed: seed,
            domain: domain,
            kind: kind,
            avoid: recentlyAsked(settings.mode) + used
        )
        note(usage)

        // What was asked for, not what came back: the point and the subjects are
        // both chosen here, so the reply has nothing to add about either.
        return Turn(
            id: UUID(), mode: settings.mode, language: settings.language,
            createdAt: .now,
            prompt: .init(english: made.english, target: made.target,
                          audioSource: nil, pointID: offered?.id,
                          revisited: revisit),
            attempt: .init(heard: "", confirmed: "", wasTyped: false,
                           audioFilename: nil, pronunciation: nil),
            review: nil
        )
    }

    /// The next prompt off the session's written set, writing the rest of the
    /// set first if it is missing — a session held from before sets existed,
    /// or one whose set failed to write while offline.
    private func plannedTurn() async throws -> Turn {
        guard let live = session else { throw Anthropic.Failure.malformed("no session") }
        let index = live.turns.count
        var planned = live.planned ?? []
        if planned.count <= index {
            let written = try await writeSet(for: live, from: index,
                                             stretch: plan.stretch, words: plan.words)
            planned = Array(live.turns.map(\.prompt).prefix(index)) + written
            session?.planned = planned
        }
        guard planned.indices.contains(index) else {
            throw Anthropic.Failure.malformed("nothing left to ask")
        }
        return Turn(
            id: UUID(), mode: live.mode, language: live.language, createdAt: .now,
            prompt: planned[index],
            attempt: .init(heard: "", confirmed: "", wasTyped: false,
                           audioFilename: nil, pronunciation: nil),
            review: nil
        )
    }

    private func install(_ turn: Turn) {
        speechTrouble = nil
        current = turn
        phase = .ready
        hold()
        prefetchNext()
    }

    /// Started as soon as a prompt is on screen. The learner spends far longer
    /// answering than the call takes, so the next turn costs nothing to wait
    /// for.
    private func prefetchNext() {
        guard pending == nil, session != nil, settings.mode == .listen else { return }
        pending = Task { [weak self] in
            guard let self else { return nil }
            return try? await self.makeTurn()
        }
    }

    /// Anything held for a different mode or language is wrong for this one.
    func dropPending() {
        pending?.cancel()
        pending = nil
    }

    // MARK: Attempting

    func startRecording() {
        guard let speech else { return }
        do {
            try speech.startListening(locale: settings.language.localeID)
            speechTrouble = nil
            phase = .recording
        } catch {
            // Not a dead end: the answer can still be typed, and the session
            // goes on.
            speechTrouble = Plain.message(error, "start recording")
            phase = .ready
        }
    }

    func stopRecording() {
        guard let speech else { return }
        let heard = speech.stopListening()
        draft = heard
        current?.attempt.heard = heard
        current?.attempt.wasTyped = false
        phase = .confirming
    }

    /// Typed instead of spoken. Goes straight to confirmation — there is
    /// nothing to correct in a transcript that was never transcribed.
    func typed(_ text: String) {
        draft = text
        current?.attempt.heard = text
        current?.attempt.wasTyped = true
        phase = .confirming
    }

    func reRecord() {
        draft = ""
        phase = .ready
    }

    /// Only the confirmed text is assessed, so a recognition error is never
    /// scored as a language error.
    ///
    /// Translate and produce are not graded here. The answer is filed, and the
    /// whole session goes to a batch when it ends; the learner hears back by
    /// notification. Listen is still graded on the spot until it is rebuilt.
    func submit() async {
        guard var turn = current, let live = session else { return }
        turn.attempt.confirmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !turn.attempt.confirmed.isEmpty else { return }

        // Every answer is its own review, produce included.
        turn.exchangeID = UUID()
        current = turn

        // Scored against what they should have said: the played sentence in
        // listen, their own words otherwise. Attached whenever it lands — the
        // review never reads it.
        if !turn.attempt.wasTyped, let wav = speech?.lastRecording {
            let reference = turn.mode == .listen
                ? (turn.prompt.target ?? turn.attempt.confirmed)
                : turn.attempt.confirmed
            let service = pronunciation
            let locale = settings.language.localeID
            let id = turn.id
            Task {
                guard let sounds = try? await service.assess(wav: wav, reference: reference,
                                                             locale: locale) else { return }
                self.amend(id) { $0.attempt.pronunciation = sounds }
            }
        }

        if live.mode == .listen {
            await gradeNow(turn)
            return
        }

        session?.turns.append(turn)
        hold()
        if turn.prompt.reference != nil {
            phase = .reference
        } else {
            await advance()
        }
    }

    /// Listen's path: one call, waited on.
    private func gradeNow(_ turn: Turn) async {
        var turn = turn
        phase = .assessing
        do {
            let (review, usage) = try await tutor.review(turn: turn, level: settings.level)
            note(usage, model: Tutor.reviewModel(turn.mode))
            turn.review = review
            current = turn
            session?.turns.append(turn)
            record(for: turn, review: review)
            reached(review, in: turn)
            hold()
            phase = .reviewing
        } catch {
            phase = .failed(Plain.message(error, "review"))
        }
    }

    /// A change to one turn wherever it now lives: on screen, in the live
    /// session, or already archived.
    func amend(_ id: UUID, _ change: (inout Turn) -> Void) {
        if current?.id == id, var live = current {
            change(&live)
            current = live
        }
        if let index = session?.turns.firstIndex(where: { $0.id == id }) {
            change(&session!.turns[index])
            hold()
        }
        var archived = false
        for s in past.indices {
            if let t = past[s].turns.firstIndex(where: { $0.id == id }) {
                change(&past[s].turns[t])
                archived = true
            }
        }
        if archived { saveArchive() }
        // A reopened session is held and archived at once.
        for key in holds.keys where session?.id != holds[key]?.session.id {
            if let t = holds[key]?.session.turns.firstIndex(where: { $0.id == id }) {
                change(&holds[key]!.session.turns[t])
                Vault.save(holds, Vault.holds)
            }
        }
    }

    func archived(_ id: UUID) -> Turn? {
        for session in past.reversed() {
            if let turn = session.turns.first(where: { $0.id == id }) { return turn }
        }
        return nil
    }

    func advance() async {
        knowledge = [:]
        path = []

        // Reading a graded session: on to its next review, or back out.
        if !reading.isEmpty {
            reading.removeFirst()
            if let next = reading.first, let turn = archived(next) {
                current = turn
            } else {
                reading = []
                current = nil
                phase = .idle
            }
            return
        }

        guard let live = session else { return }
        if live.isComplete {
            phase = .complete
            file(live)
            holds[Store.holdKey(live.language, live.mode)] = nil
            Vault.save(holds, Vault.holds)
            dropPending()
            usedClips = []
            if live.mode != .listen {
                enqueue(live)
                Task { await pump() }
            }
        } else {
            await nextPrompt()
        }
    }

    /// Held after every turn, not only when the learner steps out, so a crash
    /// or a force-quit does not cost them the session either.
    func hold() {
        guard let live = session, !live.isComplete else { return }
        // The turn on screen is only held while it is unanswered; once
        // submitted it is already in the session's turns.
        let open = current.flatMap { turn in
            live.turns.contains { $0.id == turn.id } ? nil : turn
        }
        holds[Store.holdKey(live.language, live.mode)] = Unfinished(session: live, turn: open)
        Vault.save(holds, Vault.holds)
    }

    /// Step out of a session. An unfinished one is held rather than archived,
    /// so picking the same mode again carries on from here; a finished one was
    /// already archived by `advance`, and this just clears the screen.
    func endSession() {
        redo = nil
        hold()
        dropPending()
        session = nil
        current = nil
        reading = []
        phase = .idle
        path = []
        knowledge = [:]
        refreshPlan()
    }

    // MARK: Reroll


    /// A different produce question in place of the one on screen, before any
    /// answer. Keeps the point it was asked to reach for, if it had one.
    func reroll() async {
        guard var turn = current, turn.mode == .produce, session?.scene != true,
              draft.isEmpty, !rerolling else { return }
        rerolling = true
        defer { rerolling = false }
        let point = turn.prompt.pointID.flatMap { id in pack.points.first { $0.id == id } }
        let asked = (session?.planned ?? []) + (session?.turns.map(\.prompt) ?? []) + [turn.prompt]
        let avoid = recentlyAsked(.produce) + asked.compactMap { $0.english ?? $0.target }
        // Past the end of the day's slots, so the corner and kind are ones the
        // set has not used.
        let spare = (session?.goal ?? 0) + rerolls
        rerolls += 1
        let day = Spend.key(.now)
        do {
            let (made, usage) = try await tutor.nextPrompt(
                mode: .produce, language: settings.language, level: settings.level,
                revisit: turn.prompt.revisited, stretch: point,
                seed: DayPlan.seed(from: plan.words, turn: session?.turns.count ?? 0),
                domain: DayPlan.domain(day: day, language: settings.language, turn: spare),
                kind: DayPlan.kind(day: day, language: settings.language, turn: spare),
                avoid: avoid)
            note(usage)
            turn.prompt.english = made.english
            turn.prompt.target = made.target
            guard current?.id == turn.id else { return }
            current = turn
            if let index = session?.turns.count, session?.planned?.indices.contains(index) == true {
                session?.planned?[index] = turn.prompt
            }
            hold()
        } catch {
            Plain.note(error, "another question")
            speechTrouble = "No new question."
        }
    }
}
