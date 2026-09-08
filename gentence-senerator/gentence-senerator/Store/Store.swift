import Foundation
import Observation

/// All app state. Views read it and call methods; nothing mutates it directly.
@MainActor
@Observable
final class Store {

    // MARK: Persisted

    var settings = Settings() { didSet { Vault.save(settings, Vault.settings) } }
    private(set) var progress = Progress()
    private(set) var spend = Spend()
    private(set) var past: [Session] = []
    private(set) var bank: [BankEntry] = []

    // MARK: Current attempt

    private(set) var phase: Phase = .idle
    private(set) var session: Session?
    private(set) var current: Turn?
    /// The editable transcript, or what is being typed. Assessed only after the
    /// learner confirms it.
    var draft = ""

    // MARK: Drilling down

    /// The navigation stack. Each entry is the request that produced the screen.
    var path: [LessonRequest] = []
    private(set) var lessons: [String: Lesson] = [:]
    private(set) var loadingLesson: Set<String> = []
    /// In flight, per lesson, so a tap joins a prefetch already running
    /// instead of asking for the same thing twice.
    private var coreLoads: [String: Task<Void, Never>] = [:]
    private var practiceLoads: [String: Task<Void, Never>] = [:]
    private(set) var lessonError: String?
    private(set) var reviewDepthError: String?
    private(set) var deepening = false
    /// True while the review is still being written onto the screen.
    private(set) var streamingReview = false

    /// Slip or gap, per atom, for the review on screen.
    private(set) var knowledge: [String: Progress.Encounter.Knowledge] = [:]

    /// Answers to questions the learner typed, keyed by what they were asking
    /// about. Answers carry atoms, so asking is another way down.
    private(set) var asked: [String: [AskItem]] = [:]
    private(set) var asking: Set<String> = []

    /// A structure the learner has never reached for, offered this session.
    private(set) var stretch: GrammarPoint?

    /// Sessions the learner stepped out of. Picking the same mode resumes it
    /// rather than starting over. One slot per language and mode: ending a
    /// produce session and then a translate session holds both.
    private struct Unfinished: Codable {
        var session: Session
        var turn: Turn?
    }
    private var holds: [String: Unfinished] = [:]

    private static func holdKey(_ language: Language, _ mode: Mode) -> String {
        "\(language.rawValue)|\(mode.rawValue)"
    }

    /// The turn after the one on screen, written while the learner is still
    /// working on it. The first prompt of a session is not prefetched — there
    /// is nothing to hide it behind — so only that one is ever waited for.
    private var pending: Task<Turn?, Never>?

    private let tutor: Tutor
    private let speech: SpeechIO?
    private let pronunciation: Pronunciation
    private let clips = ClipLibrary()
    private var usedClips: Set<String> = []
    /// The other half of reach. Words are counted here rather than asked for.
    private let lexicon = Lexicon()

    // MARK: Dialogues

    private let passages = PassageLibrary()

    /// Per language: the dialogue in progress, and the ones already finished.
    /// Not in `holds` — those are retired at the end of the day and a passage
    /// is deliberately allowed to outlive one.
    private struct PassageState: Codable {
        var run: PassageRun?
        var finished: Set<String> = []
    }
    private var passageState: [String: PassageState] = [:]

    /// What the passage screen is showing. Both nil when listen is on clips.
    private(set) var passage: Passage?
    private(set) var run: PassageRun?

    init(tutor: Tutor, speech: SpeechIO? = nil,
         pronunciation: Pronunciation = Pronunciation(key: Key.azureKey, region: Key.azureRegion)) {
        self.pronunciation = pronunciation
        self.tutor = tutor
        self.speech = speech
        if let stored = Vault.load(Settings.self, Vault.settings) {
            settings = stored
        } else if var old = Vault.load(Settings.self, Vault.oldSettings) {
            // Everything but the goal carries over: under the old key the goal
            // was a whole sitting, so it takes the new per-mode default.
            old.dailyGoal = Settings().dailyGoal
            settings = old
            UserDefaults.standard.removeObject(forKey: Vault.oldSettings)
            Vault.save(settings, Vault.settings)
        }
        progress = Vault.load(Progress.self, Vault.progress) ?? Progress()
        spend = Vault.load(Spend.self, Vault.spend) ?? Spend()
        past = Vault.load([Session].self, Vault.sessions) ?? []
        bank = Vault.load([BankEntry].self, Vault.bank) ?? []
        holds = Vault.load([String: Unfinished].self, Vault.holds) ?? [:]
        passageState = Vault.load([String: PassageState].self, Vault.passages) ?? [:]
        if let old = Vault.load(Unfinished.self, Vault.inProgress) {
            holds[Store.holdKey(old.session.language, old.session.mode)] = old
            UserDefaults.standard.removeObject(forKey: Vault.inProgress)
            Vault.save(holds, Vault.holds)
        }
        retireStaleHolds()
    }

    /// A session belongs to the day it was started on — the day is capped, so
    /// yesterday's half-finished translate cannot eat today's three. Archive
    /// those rather than leaving them to be overwritten by the next hold.
    private func retireStaleHolds() {
        let today = Spend.key(.now)
        let stale = holds.filter { !$0.value.session.id.hasPrefix(today) }
        guard !stale.isEmpty else { return }
        past.append(contentsOf: stale.values.map(\.session).filter { !$0.turns.isEmpty })
        past.sort { $0.startedAt < $1.startedAt }
        for key in stale.keys { holds[key] = nil }
        Vault.save(Array(past.suffix(120)), Vault.sessions)
        Vault.save(holds, Vault.holds)
    }

    // MARK: The day

    private func sessionID(for mode: Mode, on day: Date = .now) -> String {
        "\(Spend.key(day))|\(settings.language.rawValue)|\(mode.rawValue)"
    }

    /// The one session that owns today's attempts in this mode — live, held
    /// part-way, or already archived. Never two of the three: the id carries
    /// the date, so yesterday's is a different session.
    func today(_ mode: Mode) -> Session? {
        let id = sessionID(for: mode)
        if let live = session, live.id == id { return live }
        if let held = holds[Store.holdKey(settings.language, mode)]?.session,
           held.id == id { return held }
        return past.last { $0.id == id }
    }

    /// Attempts done and the cap, for one mode. The session carries its own
    /// goal, so changing the setting mid-day cannot retroactively unfinish one.
    func tally(_ mode: Mode) -> (done: Int, goal: Int) {
        // A dialogue is the whole listening day, so its own progress through
        // the questions is the only number worth showing while it is running.
        if mode == .listen, let held = heldPassage {
            return (held.run.answers.count, held.passage.quiz.count)
        }
        guard let session = today(mode) else { return (0, settings.dailyGoal) }
        return (session.completedCount, session.goal)
    }

    func isDone(_ mode: Mode) -> Bool { today(mode)?.isComplete ?? false }

    /// Three of each and the day is over. The main screen becomes the summary.
    var dayComplete: Bool { Mode.allCases.allSatisfy(isDone) }

    /// The turns one review covers. In produce the review is held until the
    /// end of an exchange, so a reviewed turn stands for several, not one.
    func exchange(endingAt turn: Turn) -> [Turn] {
        let live = session?.turns ?? []
        let turns = live.contains { $0.id == turn.id }
            ? live
            : past.first { $0.turns.contains { $0.id == turn.id } }?.turns ?? []
        guard let end = turns.firstIndex(where: { $0.id == turn.id }) else { return [turn] }
        var start = end
        while start > 0, turns[start - 1].review == nil { start -= 1 }
        return Array(turns[start...end])
    }

    /// What picking this mode would resume, if anything.
    func resumable(_ mode: Mode) -> Session? {
        guard let held = holds[Store.holdKey(settings.language, mode)]?.session,
              held.id == sessionID(for: mode), !held.isComplete else { return nil }
        return held
    }

    var pack: LanguagePack { LanguagePacks.pack(for: settings.language) }

    /// The session does not carry over — the sentences and the level mean
    /// something different. It is held under the old language, so switching
    /// back and picking the same mode carries on from here.
    func switchLanguage(_ language: Language) {
        guard language != settings.language else { return }
        hold()
        dropPending()
        settings.language = language
        settings.level = min(settings.level, pack.levels)
        session = nil
        current = nil
        phase = .idle
        path = []
        knowledge = [:]
    }

    // MARK: Level

    /// Every deliberate move comes through here — the stepper and the offer
    /// both — and the date is why: what was scored at a level the learner has
    /// left is not evidence about the one they are on.
    func setLevel(_ n: Int) {
        var next = settings
        next.level = min(max(n, 1), pack.levels)
        next.levelChangedAt = .now
        settings = next
    }

    /// What the evidence says about the level. Nil is stay — most of the time,
    /// and the screen shows nothing rather than a verdict nobody asked for.
    ///
    /// On `Store` rather than `Progress`: the evidence is scores across
    /// sessions and points out of the pack, and `Progress` holds neither.
    var levelOffer: LevelOffer? {
        LevelOffer.read(level: settings.level, in: pack,
                        turns: recentTurns(LevelEvidence.window),
                        holding: holdingShare)
    }

    /// How much of this level the learner has got working. This level only —
    /// `reachable` is everything up to it, and asking for three quarters of a
    /// whole curriculum is asking for a promotion that never comes.
    private var holdingShare: Double {
        let use: GrammarPoint.Use = settings.prefersTyping ? .written : .spoken
        let points = pack.reachable(at: settings.level, use: use)
            .filter { $0.level == settings.level }
        guard !points.isEmpty else { return 0 }
        return Double(points.filter { progress.state(of: $0.id) == .holding }.count)
            / Double(points.count)
    }

    /// Reviewed turns in this language since the level last moved, oldest
    /// first. Every session they could be in: archived, held, and the live one.
    private func recentTurns(_ n: Int) -> [Turn] {
        var seen: Set<UUID> = []
        let since = settings.levelChangedAt ?? .distantPast
        let sessions = past + Mode.allCases.compactMap { today($0) }
        let turns = sessions
            .filter { $0.language == settings.language }
            .flatMap(\.turns)
            .filter { $0.review != nil && $0.createdAt >= since && seen.insert($0.id).inserted }
            .sorted { $0.createdAt < $1.createdAt }
        return Array(turns.suffix(n))
    }

    // MARK: Session

    func begin(_ mode: Mode) async {
        guard !isDone(mode) else { return }
        settings.mode = mode
        knowledge = [:]
        path = []
        dropPending()

        // Pick up where it was left, rather than throwing the turns away.
        if resumable(mode) != nil,
           let held = holds[Store.holdKey(settings.language, mode)] {
            session = held.session
            current = held.turn
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

        stretch = settings.offerStretch ? pickStretch(for: mode) : nil

        session = Session(
            id: sessionID(for: mode), language: settings.language, mode: mode,
            startedAt: .now, turns: [], goal: settings.dailyGoal
        )
        await nextPrompt()
    }

    /// A point at the learner's level, in this mode, that they have never once
    /// attempted. Absence is the signal — it produces no errors to schedule on.
    private func pickStretch(for mode: Mode) -> GrammarPoint? {
        guard mode == .produce else { return nil }
        let use: GrammarPoint.Use = settings.prefersTyping ? .written : .spoken
        let candidates = pack.reachable(at: settings.level, use: use)
        return weightedToTheTop(of: progress.neverReached(among: candidates))
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
            phase = .failed(error.localizedDescription)
        }
    }

    /// Produces a turn without touching what is on screen, so it is safe to run
    /// ahead of time.
    private func makeTurn() async throws -> Turn {
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
        let (made, usage) = try await tutor.nextPrompt(
            mode: settings.mode,
            language: settings.language,
            level: settings.level,
            revisit: revisit,
            stretch: stretch,
            avoid: used
        )
        note(usage)

        // What was asked for, not what came back: the point and the subjects are
        // both chosen here, so the reply has nothing to add about either.
        return Turn(
            id: UUID(), mode: settings.mode, language: settings.language,
            createdAt: .now,
            prompt: .init(english: made.english, target: made.target,
                          audioSource: nil, pointID: stretch?.id,
                          revisited: revisit),
            attempt: .init(heard: "", confirmed: "", wasTyped: false,
                           audioFilename: nil, pronunciation: nil),
            review: nil
        )
    }

    private func install(_ turn: Turn) {
        current = turn
        phase = .ready
        hold()
        prefetchNext()
    }

    /// Started as soon as a prompt is on screen. The learner spends far longer
    /// answering than the call takes, so the next turn costs nothing to wait
    /// for.
    private func prefetchNext() {
        guard pending == nil, session != nil else { return }
        pending = Task { [weak self] in
            guard let self else { return nil }
            return try? await self.makeTurn()
        }
    }

    /// Anything held for a different mode or language is wrong for this one.
    private func dropPending() {
        pending?.cancel()
        pending = nil
    }

    // MARK: Attempting

    func startRecording() {
        guard let speech else { return }
        do {
            try speech.startListening(locale: settings.language.localeID)
            phase = .recording
        } catch {
            phase = .failed(error.localizedDescription)
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
    func submit() async {
        guard var turn = current else { return }
        turn.attempt.confirmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !turn.attempt.confirmed.isEmpty else { return }
        current = turn

        // Produce holds corrections until the exchange is done. "Done" means
        // this many turns since the last review, not since the session began —
        // otherwise every turn after the first review would trigger one. The
        // last turn of a session reviews regardless: an exchange held past the
        // cap is one the learner never gets back.
        let unreviewed = session?.turns.reversed().prefix { $0.review == nil }.count ?? 0
        let lastOfSession = session.map { $0.completedCount + 1 >= $0.goal } ?? false
        if !settings.mode.reviewsEachAttempt, !lastOfSession,
           unreviewed < settings.turnsBeforeReview - 1 {
            session?.turns.append(turn)
            hold()
            await nextPrompt()
            return
        }

        phase = .assessing
        streamingReview = true

        // Scored against what they should have said: the played sentence in
        // listen mode, their own words otherwise.
        //
        // Started, not awaited: the review prompt never reads the pronunciation
        // result, so running Azure before the model call only added its latency
        // to a wait the learner is already sitting through.
        let scoring: Task<PronunciationResult?, Never>? = {
            guard !turn.attempt.wasTyped, let wav = speech?.lastRecording else { return nil }
            let reference = turn.mode == .listen
                ? (turn.prompt.target ?? turn.attempt.confirmed)
                : turn.attempt.confirmed
            let service = pronunciation
            let locale = settings.language.localeID
            return Task { try? await service.assess(wav: wav, reference: reference, locale: locale) }
        }()

        // Only the turns this review covers.
        let history = settings.mode.reviewsEachAttempt
            ? []
            : Array((session?.turns ?? []).suffix(unreviewed))
        do {
            // Shown as it is written: the score arrives about halfway through
            // the call and the findings one at a time after it, so the screen
            // opens on a real score instead of a spinner.
            var opening: Review?
            var usage: Anthropic.Usage?
            let updates = await tutor.streamOpening(
                turn: turn, history: history, level: settings.level
            )
            for try await (partial, final) in updates {
                opening = partial
                usage = final ?? usage
                turn.review = partial
                current = turn
                if phase != .reviewing { phase = .reviewing }
            }
            guard let opening else { throw Anthropic.Failure.malformed("no review arrived") }

            if let usage { note(usage) }
            turn.review = opening
            current = turn
            session?.turns.append(turn)
            record(for: turn, review: opening)
            streamingReview = false
            hold()

            // The rest lands while the learner is still reading where the
            // problems are and trying to fix them. Started before the
            // pronunciation result is waited on — the two are independent, and
            // anything in front of this is time the learner can spend looking
            // at "Working it out…".
            Task { await deepen(turn: turn, opening: opening, history: history) }
            prefetchLessons(for: opening)

            // Merged in when it arrives, against whatever is on screen by then
            // rather than the copy above, which the depth call may already
            // have filled in.
            if let sounds = await scoring?.value {
                if var live = current, live.id == turn.id {
                    live.attempt.pronunciation = sounds
                    current = live
                }
                if let index = session?.turns.firstIndex(where: { $0.id == turn.id }) {
                    session?.turns[index].attempt.pronunciation = sounds
                }
                hold()
            }
        } catch {
            streamingReview = false
            phase = .failed(error.localizedDescription)
        }
    }

    private func deepen(turn: Turn, opening: Review, history: [Turn]) async {
        deepening = true
        reviewDepthError = nil
        defer { deepening = false }
        do {
            // Written onto the screen as it arrives, so a row stops saying
            // "Working it out…" the moment its own name exists rather than
            // when the last one does.
            let updates = await tutor.streamDepth(
                turn: turn, opening: opening, history: history, level: settings.level
            )
            for try await (partial, usage) in updates {
                if let usage { note(usage) }
                // Before the guard below: what the sentence used is true
                // whether or not the learner is still looking at the review of
                // it. Only the last element is deep, so this fires once.
                if partial.isDeep { reached(partial, in: turn) }
                guard var live = current, live.id == turn.id else { return }
                live.review = partial
                current = live
                if let index = session?.turns.firstIndex(where: { $0.id == turn.id }) {
                    session?.turns[index].review = partial
                }
            }
            hold()
        } catch {
            // The opening still stands. Say so rather than leaving half a
            // review on screen with no explanation.
            reviewDepthError = error.localizedDescription
        }
    }

    /// Ask for the rest again after a failure.
    func retryDepth() async {
        guard let turn = current, let opening = turn.review, !opening.isDeep else { return }
        let history = settings.mode.reviewsEachAttempt
            ? []
            : Array((session?.turns ?? []).dropLast().suffix(settings.turnsBeforeReview))
        await deepen(turn: turn, opening: opening, history: history)
    }

    /// Structures the deep review says the sentence actually used, asked for or
    /// not. One tag is not proof — the model over-tags — so each is filed as an
    /// attempt and `neverReached` decides how many make a habit. The point the
    /// prompt asked for is skipped: `record` already counted it, and counting
    /// it twice would retire it off a single turn.
    private func reached(_ review: Review, in turn: Turn) {
        for pointID in review.usedPoints where pointID != turn.prompt.pointID {
            progress.attempted(pointID: pointID, language: turn.language,
                               succeeded: review.problems.isEmpty)
        }
        if !review.usedPoints.isEmpty { save() }
    }

    /// Everything a landed review is evidence of. Nothing here waits for a tap:
    /// a finding the learner reads and moves past is still something they got
    /// wrong.
    private func record(for turn: Turn, review: Review) {
        // Reach. A point counts as attempted whether or not it worked — that is
        // what separates reach from repetition.
        if let pointID = turn.prompt.pointID {
            progress.attempted(pointID: pointID, language: turn.language,
                               succeeded: review.problems.isEmpty)
            if pointID == stretch?.id { stretch = nil }
        }

        // Reach, again, and the half that needs no call. Only where the words
        // are the learner's own: in listen they are writing down someone
        // else's sentence, and a word transcribed is not a word produced.
        if turn.mode != .listen {
            progress.produced(lexicon.words(in: turn.attempt.confirmed,
                                            language: turn.language),
                              language: turn.language)
        }

        // Repetition. A due subject was woven into the sentence; whether it came
        // back clean is the retrieval check the schedule was waiting on.
        for subject in turn.prompt.revisited {
            let wrong = review.problems.contains {
                $0.seed.subject.lowercased() == subject.lowercased()
            }
            if wrong {
                progress.missed(subject: subject, language: turn.language)
            } else {
                progress.retrieved(subject: subject, language: turn.language)
            }
        }

        for atom in review.problems {
            progress.saw(atom, language: turn.language)
        }
        save()
    }

    func advance() async {
        guard let live = session else { return }
        knowledge = [:]
        path = []
        if live.isComplete {
            phase = .complete
            past.append(live)
            Vault.save(Array(past.suffix(120)), Vault.sessions)
            holds[Store.holdKey(live.language, live.mode)] = nil
            Vault.save(holds, Vault.holds)
            dropPending()
            usedClips = []
        } else {
            await nextPrompt()
        }
    }

    /// Held after every turn, not only when the learner steps out, so a crash
    /// or a force-quit does not cost them the session either.
    private func hold() {
        guard let live = session, !live.isComplete else { return }
        holds[Store.holdKey(live.language, live.mode)] =
            Unfinished(session: live, turn: phase == .reviewing ? nil : current)
        Vault.save(holds, Vault.holds)
    }

    /// Step out of a session. An unfinished one is held rather than archived,
    /// so picking the same mode again carries on from here; a finished one was
    /// already archived by `advance`, and this just clears the screen.
    func endSession() {
        hold()
        dropPending()
        session = nil
        current = nil
        phase = .idle
        path = []
        knowledge = [:]
    }


    // MARK: Dialogues

    /// The dialogue in progress, if there is one. Readable at idle, so the
    /// mode card can name it before the learner taps in.
    var heldPassage: (passage: Passage, run: PassageRun)? {
        guard let held = passageState[settings.language.rawValue]?.run,
              held.stage != .done,
              let found = passages.passage(held.passageID) else { return nil }
        return (found, held)
    }

    /// True when a dialogue took the session. An unfinished one outranks a new
    /// one, whatever day it was started on.
    private func startPassage() -> Bool {
        if let held = heldPassage {
            passage = held.passage
            run = held.run
            phase = .passage
            return true
        }
        let done = passageState[settings.language.rawValue]?.finished ?? []
        guard let next = passages.pick(language: settings.language,
                                       level: settings.level, excluding: done)
        else { return false }
        passage = next
        run = PassageRun(passageID: next.id, language: settings.language,
                         startedOn: Spend.key(.now))
        phase = .passage
        savePassage()
        return true
    }

    private func savePassage() {
        guard let run else { return }
        var state = passageState[run.language.rawValue] ?? PassageState()
        state.run = run.stage == .done ? nil : run
        if run.stage == .done { state.finished.insert(run.passageID) }
        passageState[run.language.rawValue] = state
        Vault.save(passageState, Vault.passages)
    }

    // MARK: Hearing it

    func hearPassage() {
        guard let passage else { return }
        if let source = passage.wholeSource {
            Task { try? await speech?.play(source) }
        } else {
            speech?.speak(passage.lines.map(\.text).joined(separator: " "),
                          locale: settings.language.localeID)
        }
    }

    func hearLine(_ n: Int) {
        guard let passage, let line = passage.line(n) else { return }
        if let source = passage.source(for: line) {
            Task { try? await speech?.play(source) }
        } else {
            speech?.speak(line.text, locale: settings.language.localeID)
        }
    }

    /// The first listen, and the one replay. Counted: how many times it took is
    /// the measure, so it is never silently free.
    func playGist() {
        guard var live = run else { return }
        if live.played {
            guard live.canReplay else { return }
            live.replays += 1
        } else {
            live.played = true
        }
        run = live
        savePassage()
        hearPassage()
    }

    func toQuiz() {
        guard var live = run, live.played else { return }
        live.stage = .quiz
        run = live
        savePassage()
    }

    // MARK: Answering

    func answerQuiz(_ index: Int) {
        guard var live = run, let passage,
              live.quizAt < passage.quiz.count else { return }
        let question = passage.quiz[live.quizAt]
        guard live.answers[question.id] == nil else { return }
        live.answers[question.id] = index
        run = live
        savePassage()
    }

    /// Onto the next question, or into the repair — which covers only the
    /// lines whose question was missed, and only those carrying a gap.
    func advanceQuiz() {
        guard var live = run, let passage else { return }
        if live.quizAt + 1 < passage.quiz.count {
            live.quizAt += 1
        } else {
            let missed = passage.quiz.filter { !live.got($0) }
            live.repair = missed.map(\.line).filter { passage.line($0)?.gap != nil }
            live.reask = missed.map(\.id)
            live.stage = live.repair.isEmpty ? .done : .repairing
        }
        run = live
        savePassage()
        if live.stage == .done { finishPassage() }
    }

    func answerGap(_ index: Int) {
        guard var live = run, live.repairAt < live.repair.count else { return }
        let n = live.repair[live.repairAt]
        guard live.gaps[n] == nil else { return }
        live.gaps[n] = index
        run = live
        savePassage()
    }

    func advanceRepair() {
        guard var live = run else { return }
        if live.repairAt + 1 < live.repair.count {
            live.repairAt += 1
        } else {
            live.stage = .reask
        }
        run = live
        savePassage()
    }

    func answerReask(_ index: Int) {
        guard var live = run, let passage, live.reaskAt < live.reask.count else { return }
        let id = live.reask[live.reaskAt]
        guard passage.quiz.contains(where: { $0.id == id }), live.reanswers[id] == nil
        else { return }
        live.reanswers[id] = index
        run = live
        savePassage()
    }

    func advanceReask() {
        guard var live = run else { return }
        if live.reaskAt + 1 < live.reask.count {
            live.reaskAt += 1
            run = live
            savePassage()
        } else {
            live.stage = .done
            run = live
            finishPassage()
        }
    }

    // MARK: Finishing

    /// The dialogue becomes one ordinary turn with an ordinary review, so the
    /// day summary, the bank and spaced repetition pick it up without knowing
    /// passages exist. No model call: every answer was a choice, graded here.
    private func finishPassage() {
        guard let passage, let live = run else { return }
        var turn = Turn(
            id: UUID(), mode: .listen, language: settings.language, createdAt: .now,
            prompt: .init(english: nil, target: passage.title,
                          audioSource: passage.wholeSource, pointID: nil),
            attempt: .init(heard: "", confirmed: passage.title, wasTyped: true,
                           audioFilename: nil, pronunciation: nil),
            review: nil
        )
        let review = read(of: passage, run: live)
        turn.review = review
        record(for: turn, review: review)

        var finished = Session(id: sessionID(for: .listen), language: settings.language,
                               mode: .listen, startedAt: .now, turns: [turn], goal: 1)
        finished.turns = [turn]
        past.append(finished)
        past.sort { $0.startedAt < $1.startedAt }
        Vault.save(Array(past.suffix(120)), Vault.sessions)

        savePassage()
        session = nil
        current = turn
        phase = .passage
    }

    /// One atom per gap the repair covered, right or wrong. A gap whose
    /// question was also missed changed what the learner understood, so it
    /// breaks; one they answered around only marked them.
    private func read(of passage: Passage, run: PassageRun) -> Review {
        let tally = run.read(of: passage)
        var atoms: [Atom] = []
        for n in run.repair {
            guard let line = passage.line(n), let gap = line.gap,
                  let picked = run.gaps[n], picked < gap.options.count else { continue }
            let chose = gap.options[picked]
            let right = picked == gap.answerIndex
            let brokeMeaning = passage.quiz.contains { $0.line == n && !run.got($0) }
            let subject = right ? gap.answer : "\(gap.answer) against \(chose)"
            atoms.append(Atom(
                id: Atom.identify(.pronunciation, subject),
                kind: .pronunciation,
                verdict: right ? .kept : (brokeMeaning ? .breaks : .weakens),
                stages: .init(
                    locate: "Line \(n) of \(passage.lines.count).",
                    name: right ? "\(gap.answer) landed" : "\(gap.answer), not \(chose)",
                    fix: gap.answer,
                    note: gap.why
                ),
                seed: .init(subject: subject, context: line.text, pointID: nil)
            ))
        }
        if let first = atoms.firstIndex(where: { $0.verdict.isProblem }) {
            atoms[first].weight = .start
        } else if !atoms.isEmpty {
            atoms[0].weight = .start
        }
        return Review(
            score: tally.asked == 0 ? 0 : tally.first * 100 / tally.asked,
            readOfScore: run.outcome(of: passage).read,
            atoms: atoms, natural: nil, respeaks: [], isDeep: true
        )
    }

    /// Off the dialogue screen. Nothing to archive — every answer was saved as
    /// it was given.
    func leavePassage() {
        passage = nil
        run = nil
        current = nil
        phase = .idle
        path = []
        knowledge = [:]
    }

    // MARK: Drilling down

    /// The one entry point. Every openable thing in the app ends up here, at
    /// any depth, with a request built from the atom rather than the screen.
    func open(_ atom: Atom) {
        let request = LessonRequest(
            seed: atom.seed, kind: atom.kind, language: settings.language,
            priorVisits: progress.visits(to: atom.id)
        )
        progress.opened(atom, language: settings.language)
        save()
        path.append(request)
        Task { await load(request) }
    }

    /// A way onward from inside a lesson. The context comes from where it was
    /// tapped, which is why the link itself does not carry one.
    func open(_ link: AtomLink, context: String) {
        let request = link.request(in: settings.language, context: context,
                                   priorVisits: progress.visits(to: link.id))
        path.append(request)
        Task { await load(request) }
    }

    /// Opening something that is not itself a finding — an example, half of a
    /// contrast — where there is no atom to record.
    func open(seed: Atom.Seed, kind: AtomKind) {
        let request = LessonRequest(seed: seed, kind: kind, language: settings.language)
        path.append(request)
        Task { await load(request) }
    }

    /// The rules behind the findings on screen, written before any of them is
    /// tapped. Ranked order, so the start finding — the one most often opened —
    /// is warm first, and the rest follow without competing with it. Rules
    /// only: the drills cost more than everything else in a turn put together
    /// and most of these are never opened.
    private func prefetchLessons(for review: Review) {
        let requests = review.problems.map { atom in
            LessonRequest(seed: atom.seed, kind: atom.kind, language: settings.language,
                          priorVisits: progress.visits(to: atom.id))
        }
        guard !requests.isEmpty else { return }
        Task {
            for request in requests {
                guard !Task.isCancelled else { return }
                await loadCore(request)
            }
        }
    }

    func lesson(for request: LessonRequest) -> Lesson? { lessons[request.cacheKey] }

    func isLoading(_ request: LessonRequest) -> Bool {
        loadingLesson.contains(request.cacheKey)
    }

    /// A lesson the learner asked for: the rule, then the practice behind it.
    private func load(_ request: LessonRequest) async {
        await loadCore(request)
        guard lessons[request.cacheKey] != nil else { return }
        await loadPractice(request)
    }

    /// The rule and its examples. The only part a tap waits on, so the only
    /// part worth writing ahead of time.
    private func loadCore(_ request: LessonRequest) async {
        let key = request.cacheKey
        if lessons[key] != nil { return }
        if let running = coreLoads[key] {
            await running.value
            return
        }

        loadingLesson.insert(key)
        lessonError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let (lesson, usage) = try await self.tutor.expand(request)
                if let usage { self.note(usage) }
                self.lessons[key] = lesson
            } catch {
                self.lessonError = error.localizedDescription
            }
            self.loadingLesson.remove(key)
            self.coreLoads[key] = nil
        }
        coreLoads[key] = task
        await task.value
    }

    /// Drills and questions. The largest output of any call in the app, and
    /// most warmed lessons are never opened — so this is never written ahead,
    /// only for a lesson the learner actually asked for. It still lands while
    /// the rule is being read.
    private func loadPractice(_ request: LessonRequest) async {
        let key = request.cacheKey
        guard lessons[key]?.hasPractice == false else { return }
        if let running = practiceLoads[key] {
            await running.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                if let (full, usage) = try await self.tutor.practice(for: request) {
                    self.note(usage)
                    self.lessons[key] = full
                }
            } catch {
                self.lessonError = error.localizedDescription
            }
            self.practiceLoads[key] = nil
        }
        practiceLoads[key] = task
        await task.value
    }

    // MARK: The day's summary

    /// Everything the tutor said today in this language — what broke, what
    /// weakened, and what held — one row per point, ranked by consequence and
    /// then by how often it came up. Nothing is dropped: silence on a finding
    /// reads as agreement.
    var todayFindings: [DayFinding] {
        var rows: [String: DayFinding] = [:]
        var order: [String] = []
        for mode in Mode.allCases {
            guard let session = today(mode) else { continue }
            for turn in session.turns {
                for atom in turn.review?.atoms ?? [] {
                    if var row = rows[atom.id] {
                        row.count += 1
                        // A finding whose second call never landed has only
                        // `locate` to show, so the deepest copy wins.
                        if !row.atom.isDeep, atom.isDeep { row.atom = atom }
                        rows[atom.id] = row
                    } else {
                        rows[atom.id] = DayFinding(atom: atom,
                                                   sentence: turn.attempt.confirmed, mode: mode)
                        order.append(atom.id)
                    }
                }
            }
        }
        // Sorting on the position it was first raised as the last key, since
        // `sorted` is not stable and the list must not shuffle under a tap.
        return order.enumerated()
            .compactMap { index, id in rows[id].map { (index, $0) } }
            .sorted { left, right in
                let l = DayFinding.rank(left.1.atom.verdict)
                let r = DayFinding.rank(right.1.atom.verdict)
                if l != r { return l < r }
                if left.1.count != right.1.count { return left.1.count > right.1.count }
                return left.0 < right.0
            }
            .map(\.1)
    }

    /// Attempts and average across all three modes today.
    var todayTally: (attempts: Int, average: Int) {
        let sessions = Mode.allCases.compactMap { today($0) }
        let scores = sessions.flatMap { $0.turns.compactMap { $0.review?.score } }
        return (sessions.reduce(0) { $0 + $1.completedCount },
                scores.isEmpty ? 0 : scores.reduce(0, +) / scores.count)
    }

    // MARK: Keeping things

    func isKept(_ atomID: String) -> Bool { bank.contains { $0.atomID == atomID } }

    /// Keeping the same point twice replaces it — the newer wording is the one
    /// the learner just decided was worth holding onto.
    func keep(_ finding: DayFinding) {
        let entry = BankEntry(atom: finding.atom, language: settings.language,
                              sentence: finding.sentence)
        bank.removeAll { $0.atomID == entry.atomID }
        bank.append(entry)
        Vault.save(bank, Vault.bank)
    }

    func unkeep(_ atomID: String) {
        bank.removeAll { $0.atomID == atomID }
        Vault.save(bank, Vault.bank)
    }

    /// What the learner picked out of the day to see again. Opening a lesson
    /// schedules on its own; this is the other way in, and the only way back out.
    func setReturn(_ atom: Atom, wanted: Bool) {
        if wanted {
            progress.bringBack(atom, language: settings.language)
        } else {
            progress.leaveOut(atom.id)
        }
        save()
    }

    func classify(_ atom: Atom, as verdict: Progress.Encounter.Knowledge) {
        knowledge[atom.id] = verdict
        progress.classify(atom, as: verdict, language: settings.language)
        save()
    }

    /// A typed question about whatever is on screen. `context` scopes the
    /// answer so it appears under the thing it was asked about.
    func ask(_ question: String, about seed: Atom.Seed, context: String) async {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        asking.insert(context)
        do {
            let (item, usage) = try await tutor.answer(
                question: question, about: seed, in: settings.language
            )
            note(usage)
            asked[context, default: []].append(item)
        } catch {
            asked[context, default: []].append(
                AskItem(id: UUID().uuidString, question: question,
                        answer: "Couldn't answer that: \(error.localizedDescription)",
                        atoms: [])
            )
        }
        asking.remove(context)
    }

    /// Exact match first — instant and free. Only when that fails does the
    /// model decide, so a right answer the author didn't list is not marked
    /// wrong.
    func grade(_ answer: String, against rung: Rung) async -> Tutor.DrillVerdict {
        if rung.accepts(answer) {
            return Tutor.DrillVerdict(correct: true, note: "")
        }
        do {
            let (verdict, usage) = try await tutor.grade(
                answer: answer, to: rung, in: settings.language
            )
            note(usage)
            return verdict
        } catch {
            return Tutor.DrillVerdict(
                correct: false, note: "Couldn't check that just now."
            )
        }
    }

    /// Reach counts unaided production only — a multiple-choice hit is
    /// recognition, a different and easier skill. XP still lands on the lower
    /// rungs, at a lower rate, so climbing down to find the answer is not
    /// punished.
    func recordDrill(correct: Bool, at support: Rung.Support) {
        guard correct else { return }
        switch support {
        case .free:      progress.xp += 5
        case .transform: progress.xp += 3
        case .frame:     progress.xp += 2
        case .choice:    progress.xp += 1
        }
        save()
    }

    // MARK: Speaking

    /// Plays the recording where there is one, synthesises otherwise.
    func say(_ text: String) {
        if let source = current?.prompt.audioSource, source.kind == .recording {
            Task { try? await speech?.play(source) }
        } else {
            speech?.speak(text, locale: settings.language.localeID)
        }
    }

    /// Whether the learner is hearing a person or a synthesiser.
    var hearingRealVoice: Bool {
        current?.prompt.audioSource?.kind == .recording
    }

    var clipCredits: [String] { clips.credits }

    // MARK: Bookkeeping

    private func note(_ usage: Anthropic.Usage) {
        spend.add(usage)
        Vault.save(spend, Vault.spend)
    }

    private func save() {
        Vault.save(progress, Vault.progress)
    }

    var spentToday: Double { spend.today().dollars }
}

// MARK: - Moving the level

/// Where the level would go, and why, in words the learner can check against
/// what they remember. Never acted on without them.
struct LevelOffer: Hashable {
    let level: Int
    let reason: String

    /// The decision, kept apart from the gathering: the thresholds are the part
    /// worth pinning down, and they need no sessions to check. `turns` is the
    /// recent window, oldest first; `holding` is the share of the level's
    /// points the learner has got working.
    static func read(level: Int, in pack: LanguagePack,
                     turns: [Turn], holding: Double) -> LevelOffer? {
        guard turns.count >= LevelEvidence.window else { return nil }
        let scores = turns.compactMap { $0.review?.score }
        guard !scores.isEmpty else { return nil }
        let average = scores.reduce(0, +) / scores.count
        let broke = turns.contains {
            $0.review?.atoms.contains { $0.verdict == .breaks } == true
        }
        let here = pack.level(level)

        if level < pack.levels, average >= LevelEvidence.promoteScore,
           !broke, holding >= LevelEvidence.promoteHolding {
            return LevelOffer(
                level: level + 1,
                reason: "Nothing broke in \(turns.count) sentences at \(here), "
                    + "and you've used most of what it has. Move up?"
            )
        }

        if level > 1, average <= LevelEvidence.demoteScore {
            return LevelOffer(
                level: level - 1,
                reason: "Your last \(turns.count) sentences at \(here) averaged "
                    + "\(average). Try \(pack.level(level - 1)) for a while?"
            )
        }

        return nil
    }
}

/// What it takes to move. Every number the level turns on is here.
enum LevelEvidence {
    /// Nine attempts is a full day, so twenty is a bit over two — long enough
    /// that one good afternoon cannot move the level, short enough that a
    /// fortnight of them does.
    static let window = 20
    /// 85 is where findings stop being about grammar and start being about
    /// phrasing; below 60 the sentences are not landing at all.
    static let promoteScore = 85
    static let demoteScore = 60
    /// Three in four. A level always keeps a point or two the learner will not
    /// meet by chance, and waiting on those waits forever.
    static let promoteHolding = 0.75
}
