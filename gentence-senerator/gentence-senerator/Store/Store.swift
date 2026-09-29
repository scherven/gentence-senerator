import Foundation
import Network
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
    /// Lessons, in the order they were written, so the shelf can be capped.
    private var lessonOrder: [String] = []

    /// Finished sessions out for grading, oldest first, until their reviews
    /// are in the archive.
    private(set) var jobs: [GradingJob] = [] { didSet { noteLanded(since: oldValue) } }
    /// The day each job came back, by job id, for jobs seen to come back.
    private var landed: [String: String] = [:]
    /// Reviews being read, as the turns they landed on. Empty outside reading.
    private(set) var reading: [UUID] = []
    /// The day's prompt sets being written, by hold key, so starting a
    /// session joins the one already running.
    private var writing: [String: Task<Void, Never>] = [:]
    private var polling: Task<Void, Never>?
    private let sender = Sender()
    /// Jobs whose failed answers are being graded again right now, so the
    /// screen says so and Retry cannot start a second, paid-for copy.
    private(set) var regrading: Set<UUID> = []
    /// Jobs being sent by hand right now.
    private(set) var sendingNow: Set<UUID> = []
    /// Whether the phone has a route to the internet. Watched so a session
    /// waiting for signal is sent the moment it comes back, and so the screen
    /// can say which of the two it is waiting on.
    private(set) var online = true
    private let network = NWPathMonitor()
    /// Whether a finished session can promise a notification.
    private(set) var notificationsOn = true
    /// Recognition could not start — usually no signal, in a language this
    /// phone cannot recognise offline. The answer is typed instead, this once.
    private(set) var speechTrouble: String?

    /// Slip or gap, per atom, for the review on screen.
    private(set) var knowledge: [String: Progress.Encounter.Knowledge] = [:]

    /// Answers to questions the learner typed, keyed by what they were asking
    /// about. Answers carry atoms, so asking is another way down.
    private(set) var asked: [String: [AskItem]] = [:]
    private(set) var asking: Set<String> = []

    /// A structure the learner has never reached for, offered this session.
    private(set) var stretch: GrammarPoint?

    /// Today before it starts, and what the sentences will be written from.
    /// Rebuilt whenever the learner is back at the start, so what it says about
    /// the record keeps up with the day.
    private(set) var plan = DayPlan.empty

    /// The random half of it, drawn once a day and persisted. Rebuilding the
    /// plan reads this rather than drawing again: a stretch that changed every
    /// time the learner came back to the start screen was never the one the
    /// day's sentences had been written from. One slot per language, like
    /// `holds`, so switching away and back is not a new day either.
    private var draws: [String: DayDraw] = [:]

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

    /// Listen only: the turn after the one on screen, written while the
    /// learner is still working on it. Translate and produce are written a
    /// session at a time and have nothing to prefetch.
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
        draws = Vault.load([String: DayDraw].self, Vault.plan) ?? [:]
        jobs = Vault.load([GradingJob].self, Vault.grading) ?? []
        landed = Vault.load([String: String].self, Vault.landed) ?? [:]
        if let shelf = Vault.load(LessonShelf.self, Vault.lessons) {
            lessons = shelf.lessons
            lessonOrder = shelf.order
        }
        if let old = Vault.load(Unfinished.self, Vault.inProgress) {
            holds[Store.holdKey(old.session.language, old.session.mode)] = old
            UserDefaults.standard.removeObject(forKey: Vault.inProgress)
            Vault.save(holds, Vault.holds)
        }
        retireStaleHolds()
        refreshPlan()
        sender.onResult = { [weak self] id, result in self?.submitted(id, result) }
        sender.resume()
        network.pathUpdateHandler = { [weak self] update in
            let now = update.status == .satisfied
            Task { @MainActor in
                guard let self, now != self.online else { return }
                self.online = now
                if now { await self.pump() }
            }
        }
        network.start(queue: .global(qos: .utility))
    }

    /// A session belongs to the day it was started on — the day is capped, so
    /// yesterday's half-finished translate cannot eat today's three. Archive
    /// those rather than leaving them to be overwritten by the next hold.
    ///
    /// Earlier days only: tomorrow's set, written ahead, is held too.
    private func retireStaleHolds() {
        let today = Spend.key(.now)
        let stale = holds.filter { String($0.value.session.id.prefix(10)) < today }
        guard !stale.isEmpty else { return }
        let unfinished = stale.values.map(\.session).filter { $0.completedCount > 0 }
        for session in unfinished { file(session) }
        past.sort { $0.startedAt < $1.startedAt }
        for key in stale.keys { holds[key] = nil }
        Vault.save(Array(past.suffix(120)), Vault.sessions)
        Vault.save(holds, Vault.holds)
        // A session left part-way is still worth grading: those answers were
        // given, and nobody is going to finish them now.
        for session in unfinished where session.mode != .listen { enqueue(session) }
    }

    /// A session still on screen from an earlier day — the app was never
    /// closed overnight — is stepped out of and filed with the rest, before
    /// anything can write today over it.
    private func retireStale() {
        if let live = session, live.mode != .listen,
           String(live.id.prefix(10)) < Spend.key(.now) {
            hold()
            session = nil
            current = nil
            phase = .idle
            path = []
            knowledge = [:]
        }
        retireStaleHolds()
        refreshPlan()
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

    /// The turns one review covers. One, except in produce graded before each
    /// answer was graded alone: there the review landed on the last answer of
    /// a held exchange and stands for the unreviewed ones before it.
    func exchange(endingAt turn: Turn) -> [Turn] {
        let live = session?.turns ?? []
        let turns = live.contains { $0.id == turn.id }
            ? live
            : past.first { $0.turns.contains { $0.id == turn.id } }?.turns ?? []
        return Store.exchange(endingAt: turn, in: turns)
    }

    nonisolated static func exchange(endingAt turn: Turn, in turns: [Turn]) -> [Turn] {
        guard let end = turns.firstIndex(where: { $0.id == turn.id }) else { return [turn] }
        var start = end
        while start > 0, turns[start - 1].review == nil,
              turns[start - 1].exchangeID == turn.exchangeID { start -= 1 }
        return Array(turns[start...end])
    }

    /// What picking this mode would resume, if anything.
    func resumable(_ mode: Mode) -> Session? {
        guard let held = holds[Store.holdKey(settings.language, mode)]?.session,
              held.id == sessionID(for: mode), !held.isComplete else { return nil }
        return held
    }

    /// The stepper. Today's translate and produce in this language follow the
    /// goal: raised, a finished one is held again so the mode resumes and the
    /// rest of its set is written; what was already sent stays sent. Listen is
    /// left alone — a dialogue is not counted in turns.
    func setGoal(_ n: Int) {
        guard n != settings.dailyGoal else { return }
        settings.dailyGoal = n
        for mode in [Mode.translate, .produce] {
            let key = Store.holdKey(settings.language, mode)
            if var live = session, live.id == sessionID(for: mode), !live.isComplete {
                live.regoal(n)
                session = live
                hold()
                continue
            }
            // Tomorrow's set, written ahead: nothing answered, so it just
            // takes the goal.
            if var ahead = holds[key], ahead.session.id != sessionID(for: mode) {
                ahead.session.regoal(n)
                holds[key] = ahead
            }
            guard var today = today(mode), today.regoal(n) else { continue }
            let held = holds[key]?.session.id == today.id ? holds[key] : nil
            if today.isComplete {
                // Lowered back over a reopened one: it was already filed.
                if held != nil { holds[key] = nil }
                file(today)
            } else {
                // Over tomorrow's set, if one was written; that is written
                // again once this one is done.
                holds[key] = Unfinished(session: today, turn: held?.turn)
            }
        }
        Vault.save(holds, Vault.holds)
        refreshPlan()
        Task { await prepareDay() }
    }

    /// Into the archive, over any earlier copy of the same session — a
    /// reopened one is archived twice.
    private func file(_ finished: Session) {
        if let index = past.firstIndex(where: { $0.id == finished.id }) {
            past[index] = finished
        } else {
            past.append(finished)
        }
        Vault.save(Array(past.suffix(120)), Vault.sessions)
        if activity.add(finished) { Vault.save(activity, Vault.activity) }
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
        refreshPlan()
    }

    // MARK: Feedback by day

    /// Feedback belongs to the day. The main screen shows today's sessions'
    /// jobs, anything still out, and anything that came back today — a job
    /// from yesterday that lands today stays until tomorrow, read or not.
    var todaysJobs: [GradingJob] {
        let today = Spend.key(.now)
        return jobs.filter { Store.showsToday($0, landed: landed[$0.id.uuidString], today: today) }
    }

    nonisolated static func showsToday(_ job: GradingJob, landed: String?, today: String) -> Bool {
        job.state != .done || String(job.sessionID.prefix(10)) >= today || landed == today
    }

    private func noteLanded(since old: [GradingJob]) {
        let out = Set(old.filter { $0.state != .done }.map(\.id))
        let now = jobs.filter { $0.state == .done && out.contains($0.id) }
            .map(\.id.uuidString).filter { landed[$0] == nil }
        guard !now.isEmpty else { return }
        let ids = Set(jobs.map(\.id.uuidString))
        landed = landed.filter { ids.contains($0.key) }
        for id in now { landed[id] = Spend.key(.now) }
        Vault.save(landed, Vault.landed)
    }

    /// Everything off the main screen, by day, newest first.
    var archive: [ArchiveDay] {
        Store.archive(past, showing: Set(todaysJobs.map(\.sessionID)), today: Spend.key(.now))
    }

    nonisolated static func archive(_ past: [Session], showing: Set<String>,
                                    today: String) -> [ArchiveDay] {
        let old = past.filter { String($0.id.prefix(10)) < today && !showing.contains($0.id) }
        return Dictionary(grouping: old) { String($0.id.prefix(10)) }
            .map { ArchiveDay(day: $0.key, sessions: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }

    /// An archived session's reviews, read the way a job's are.
    func read(_ session: Session) {
        read(GradingJob(id: UUID(), sessionID: session.id, language: session.language,
                        mode: session.mode, createdAt: session.startedAt, level: session.level,
                        exchanges: GradingJob.exchanges(of: session)))
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
        refreshPlan()
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
        guard !isDone(mode) else { return }
        settings.mode = mode
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

        // Pick up where it was left, rather than throwing the turns away.
        if resumable(mode) != nil,
           let held = holds[Store.holdKey(settings.language, mode)] {
            session = held.session
            current = held.turn
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

        session = Session(
            id: sessionID(for: mode), language: settings.language, mode: mode,
            startedAt: .now, turns: [], goal: settings.dailyGoal, level: settings.level
        )
        stretch = nil
        await nextPrompt()
        if let session { stretch = stretch(of: session) }
    }

    /// The structure produce is reaching for this session, if any. Read off the
    /// written set, so it is the one the question was actually written for.
    private func stretch(of session: Session) -> GrammarPoint? {
        guard session.mode == .produce,
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
    /// Once a mode is done for today and its feedback is in, tomorrow's set is
    /// written too — so a first open on the train with no signal still has
    /// something to practise. Never over a held session: those are answers.
    func prepareDay() async {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        for mode in [Mode.translate, .produce] {
            let key = Store.holdKey(settings.language, mode)
            guard writing[key] == nil else { continue }
            if let held = holds[key]?.session {
                if held.id == sessionID(for: mode) { await writeRest(of: held, key: key) }
                continue
            }

            let day: Date
            let stretch: GrammarPoint?
            let words: WordSeeds
            if today(mode) == nil {
                day = .now
                (stretch, words) = (plan.stretch, plan.words)
            } else if isDone(mode), feedbackIsIn(for: sessionID(for: mode)) {
                day = tomorrow
                let draw = nextDraw(on: tomorrow)
                stretch = draw.stretchID.flatMap { id in pack.points.first { $0.id == id } }
                words = draw.words
            } else {
                continue
            }

            let draft = Session(id: sessionID(for: mode, on: day), language: settings.language,
                                mode: mode, startedAt: day, turns: [], goal: settings.dailyGoal,
                                level: settings.level)
            let task = Task { [weak self] in
                guard let self else { return }
                guard let prompts = try? await self.writeSet(for: draft, from: 0,
                                                             stretch: stretch, words: words)
                else { return }
                // Started by hand while this was being written: that one owns
                // the slot, and this set goes unused.
                guard self.holds[key] == nil, self.session?.id != draft.id else { return }
                var planned = draft
                planned.planned = prompts
                // The goal may have moved while this was being written.
                planned.goal = self.settings.dailyGoal
                self.holds[key] = Unfinished(session: planned, turn: nil)
                Vault.save(self.holds, Vault.holds)
            }
            writing[key] = task
            await task.value
            writing[key] = nil
        }
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

    /// Every job for that session has come back. No job — nothing was
    /// answered — counts as in.
    private func feedbackIsIn(for sessionID: String) -> Bool {
        jobs.filter { $0.sessionID == sessionID }.allSatisfy { $0.state == .done }
    }

    /// Tomorrow's draw, made now and kept in its own slot so today's plan is
    /// not redrawn under it. `refreshPlan` promotes it when tomorrow comes.
    private func nextDraw(on day: Date) -> DayDraw {
        let language = settings.language
        let level = settings.level
        let slot = language.rawValue + "|next"
        let drawn = DayDraw.forToday(draws[slot], day: Spend.key(day),
                                     language: language, level: level) {
            (requestedStretch(on: Spend.key(day)) { pickStretch()?.id },
             WordSeeds.read(band: lexicon.band(upTo: level, language: language),
                            above: lexicon.band(at: level + 1, language: language),
                            progress: progress, language: language))
        }
        if drawn != draws[slot] {
            draws[slot] = drawn
            Vault.save(draws, Vault.plan)
        }
        return drawn
    }

    /// Prompts for every turn from `index` to the end of the session. The
    /// per-turn choices — which corner of a life, which word — are the ones
    /// the turn-by-turn generation made, so a turn index still gets the same
    /// seasoning it always did. `stretch` and `words` are the draw of the day
    /// the session belongs to, which is not always today.
    private func writeSet(for session: Session, from index: Int,
                          stretch: GrammarPoint?, words: WordSeeds) async throws -> [Turn.Prompt] {
        guard session.goal > index else { return [] }
        let day = String(session.id.prefix(10))
        let slots = (index..<session.goal).map { turn in
            Tutor.Slot(
                domain: session.mode == .translate
                    ? DayPlan.domain(day: day, language: session.language, turn: turn) : nil,
                seed: DayPlan.seed(from: words, turn: turn)
            )
        }
        let reach = session.mode == .produce && index == 0 && settings.offerStretch
            ? stretch : nil
        let avoid = Mode.allCases.compactMap { today($0) }
            .flatMap { ($0.planned ?? []) + $0.turns.map(\.prompt) }
            .compactMap(\.english)
        let (prompts, usage) = try await tutor.daySet(
            mode: session.mode, language: session.language,
            level: session.level ?? settings.level,
            slots: slots,
            revisit: progress.seedsForGeneration(language: session.language),
            stretch: reach, avoid: avoid
        )
        note(usage)
        return prompts
    }

    /// A point at the learner's level that they have never once attempted.
    /// Absence is the signal — it produces no errors to schedule on. Produce
    /// only, but the plan names it before a mode has been picked, so the mode
    /// check sits at the use rather than here.
    private func pickStretch() -> GrammarPoint? {
        let use: GrammarPoint.Use = settings.prefersTyping ? .written : .spoken
        let candidates = pack.reachable(at: settings.level, use: use)
        return weightedToTheTop(of: progress.neverReached(among: candidates))
    }

    /// The plan, rebuilt off today's draw. Everything random about a day
    /// happens inside `DayDraw.forToday`, and only when the day, the language
    /// or the level has moved; `DayPlan.read` derives the rest, which is why
    /// finishing a session still refreshes the record without dealing a new
    /// day.
    private func refreshPlan() {
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
                            progress: progress, language: language))
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
            phase = .failed(error.localizedDescription)
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
        // rotating domain gives translate a spread of its own — produce sets its
        // own corner and takes none.
        let turn = used.count
        let seed = DayPlan.seed(from: plan.words, turn: turn)
        let domain = settings.mode == .translate
            ? DayPlan.domain(day: Spend.key(.now), language: settings.language, turn: turn)
            : nil
        let (made, usage) = try await tutor.nextPrompt(
            mode: settings.mode,
            language: settings.language,
            level: settings.level,
            revisit: revisit,
            stretch: offered,
            seed: seed,
            domain: domain,
            avoid: used
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
    private func dropPending() {
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
            speechTrouble = error.localizedDescription
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
            let (review, written, usage) = try await tutor.review(turn: turn, level: settings.level)
            note(usage)
            turn.review = review
            current = turn
            session?.turns.append(turn)
            record(for: turn, review: review)
            reached(review, in: turn)
            shelve(written)
            hold()
            phase = .reviewing
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// A change to one turn wherever it now lives: on screen, in the live
    /// session, or already archived.
    private func amend(_ id: UUID, _ change: (inout Turn) -> Void) {
        if current?.id == id, var live = current {
            change(&live)
            current = live
        }
        if let index = session?.turns.firstIndex(where: { $0.id == id }) {
            change(&session!.turns[index])
            hold()
        }
        for s in past.indices {
            if let t = past[s].turns.firstIndex(where: { $0.id == id }) {
                change(&past[s].turns[t])
                Vault.save(Array(past.suffix(120)), Vault.sessions)
            }
        }
        // A reopened session is held and archived at once.
        for key in holds.keys where session?.id != holds[key]?.session.id {
            if let t = holds[key]?.session.turns.firstIndex(where: { $0.id == id }) {
                change(&holds[key]!.session.turns[t])
                Vault.save(holds, Vault.holds)
            }
        }
    }

    private func archived(_ id: UUID) -> Turn? {
        for session in past.reversed() {
            if let turn = session.turns.first(where: { $0.id == id }) { return turn }
        }
        return nil
    }

    // MARK: Grading

    /// Files a finished session for grading. Nothing is sent here, so this is
    /// safe offline and at launch; `pump` does the sending.
    private func enqueue(_ session: Session) {
        let exchanges = Store.unfiled(session, jobs: jobs)
        guard !exchanges.isEmpty else { return }
        // A session from before sessions carried a level, retired after a
        // language switch, can only take the setting — which is shared.
        jobs.append(GradingJob(id: UUID(), sessionID: session.id, language: session.language,
                               mode: session.mode, createdAt: .now,
                               level: session.level ?? settings.level, exchanges: exchanges))
        saveJobs()
    }

    private var pumping = false

    /// Moves every job one step on: hands what is unsent to the background
    /// uploader, tells the push worker about anything it is not watching,
    /// counts what is graded, and reads in whatever has finished. Safe to call
    /// as often as liked; a failure in one job or one step is retried on the
    /// next call and never stops the others.
    func pump() async {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }

        for id in jobs.map(\.id) {
            guard var job = jobs.first(where: { $0.id == id }), job.state != .done else { continue }
            do {
                if job.batchID == nil {
                    if !job.uploading { try submit(&job) }
                    put(job)
                    continue
                }
                guard let batchID = job.batchID else { continue }

                if !job.watched, await watch(batchID, job: job.id, label: label(of: job)) {
                    job.watched = true
                }

                let batch = try await tutor.api.retrieveBatch(batchID)
                job.graded = batch.succeeded
                job.failed = batch.failed
                job.error = nil
                if batch.ended {
                    ingest(try await tutor.api.batchResults(batch), into: job)
                    job.state = .done
                }
            } catch {
                job.error = error.localizedDescription
            }
            put(job)
        }

        // A failed answer gets one second attempt on its own, outside the
        // batch — where the refusal fallback is allowed. After that it waits
        // for Retry.
        for id in jobs.map(\.id) {
            guard var job = jobs.first(where: { $0.id == id }),
                  job.state == .done, !job.retried, hasFailures(job) else { continue }
            job.retried = true
            put(job)
            await gradeMissing(of: job)
        }

        // Done jobs stay a day and a half, so the screen can still say what
        // came back.
        let cutoff = Date.now.addingTimeInterval(-36 * 3600)
        jobs.removeAll { $0.state == .done && $0.createdAt < cutoff }
        saveJobs()
    }

    private func label(of job: GradingJob) -> String {
        "\(job.language.name) \(job.mode.name.lowercased())"
    }

    /// Hands a job to the background uploader. From here iOS owns it: it goes
    /// when there is signal, with or without the app, and `submitted` hears
    /// back.
    private func submit(_ job: inout GradingJob) throws {
        guard let body = try body(of: job) else {
            job.state = .done
            return
        }
        let token = UserDefaults.standard.string(forKey: Vault.pushToken)
        try sender.send(job: job.id, body: body, token: token, label: label(of: job))
        job.uploading = true
        job.error = nil
    }

    /// The batch a job sends. Nil when none of its answers can be found.
    private func body(of job: GradingJob) throws -> Data? {
        let level = job.level ?? settings.level
        let requests: [[String: Any]] = job.exchanges.compactMap { exchange in
            let turns = exchange.turnIDs.compactMap(archived)
            guard let last = turns.last else { return nil }
            return ["custom_id": exchange.customID,
                    "params": tutor.reviewParams(turn: last, history: Array(turns.dropLast()),
                                                 level: level)]
        }
        guard !requests.isEmpty else { return nil }
        return try Schemas.data(["requests": requests])
    }

    /// Sends a job from the app, now, beside whatever iOS is holding for it.
    func sendNow(_ job: GradingJob) async {
        guard job.batchID == nil, sendingNow.insert(job.id).inserted else { return }
        defer { sendingNow.remove(job.id) }
        do {
            guard let body = try body(of: job) else { return }
            let batch = try await sender.sendNow(
                job: job.id, body: body,
                token: UserDefaults.standard.string(forKey: Vault.pushToken),
                label: label(of: job))
            submitted(job.id, .success(batch))
            await pump()
        } catch {
            if var now = jobs.first(where: { $0.id == job.id }) {
                now.error = online ? error.localizedDescription : "Still no connection."
                put(now)
            }
        }
    }

    /// The uploader's answer, possibly delivered with the app in the
    /// background. Saved before anything else: this is the only record of
    /// which batch the answers became.
    private func submitted(_ id: UUID, _ result: Result<String, Error>) {
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        job.uploading = false
        // Sent both ways: the second answer is the same batch, or a failure
        // that no longer matters.
        if job.batchID != nil {
            put(job)
            return
        }
        switch result {
        case .success(let batch):
            job.batchID = batch
            job.state = .grading
            job.watched = UserDefaults.standard.string(forKey: Vault.pushToken) != nil
            job.error = nil
        case .failure(let error):
            job.error = error.localizedDescription
        }
        put(job)
    }

    /// An upload iOS no longer holds — the app was reinstalled, or the
    /// system dropped it — is sent again. The worker returns the batch it
    /// already made if the first one did arrive.
    private func reconcileUploads() async {
        let flying = await sender.inFlight()
        for var job in jobs where job.uploading && !flying.contains(job.id) {
            job.uploading = false
            put(job)
        }
    }

    /// Answers the batch did not grade, graded one at a time on the spot.
    /// Each is saved as it lands, so being interrupted loses only the one in
    /// flight.
    private func gradeMissing(of job: GradingJob) async {
        guard regrading.insert(job.id).inserted else { return }
        defer { regrading.remove(job.id) }
        let level = job.level ?? settings.level
        for exchange in job.exchanges {
            let turns = exchange.turnIDs.compactMap(archived)
            guard let last = turns.last, last.review == nil else { continue }
            do {
                let (review, lessons, usage) = try await tutor.review(
                    turn: last, history: Array(turns.dropLast()), level: level)
                note(usage)
                land(review, lessons, on: last)
            } catch {
                if var now = jobs.first(where: { $0.id == job.id }) {
                    now.error = error.localizedDescription
                    put(now)
                }
            }
        }
        refreshPlan()
    }

    /// One review into the archive, and everything it is evidence of into
    /// `Progress`.
    private func land(_ review: Review, _ lessons: [Lesson], on turn: Turn) {
        amend(turn.id) { $0.review = review }
        var graded = turn
        graded.review = review
        record(for: graded, review: review)
        reached(review, in: graded)
        shelve(lessons)
    }

    /// Reviews into the archive, in the order the answers were given.
    /// Idempotent: an answer already reviewed is skipped, so a crash halfway
    /// through costs nothing on the next pass.
    private func ingest(_ results: [Anthropic.BatchResult], into job: GradingJob) {
        let byID = Dictionary(results.map { ($0.customID, $0) }, uniquingKeysWith: { a, _ in a })
        for exchange in job.exchanges {
            guard let result = byID[exchange.customID], let reply = result.reply else { continue }
            let turns = exchange.turnIDs.compactMap(archived)
            guard let last = turns.last, last.review == nil else { continue }
            note(reply.usage, batched: true)
            guard let (review, lessons) = try? Tutor.read(reply, turn: last,
                                                           history: Array(turns.dropLast()))
            else { continue }
            land(review, lessons, on: last)
        }
        // What the reviews put into `Progress` moves the record on screen.
        refreshPlan()
    }

    /// Tells the push worker to notify this device when the batch ends — for
    /// a job submitted before the device had a token. False when it could
    /// not, so the next pump tries again.
    private func watch(_ batchID: String, job: UUID, label: String) async -> Bool {
        guard let token = UserDefaults.standard.string(forKey: Vault.pushToken),
              let url = URL(string: Key.graderURL + "/watch") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(Key.watchSecret, forHTTPHeaderField: "x-watch-secret")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["batch": batchID, "job": job.uuidString, "token": token, "label": label,
                             "sandbox": Sender.sandbox])
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func saveJobs() { Vault.save(jobs, Vault.grading) }

    /// By id: the list can change under an await.
    private func put(_ job: GradingJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job
        saveJobs()
    }

    /// Anything not yet handed to the uploader or not yet watched, so going
    /// to the background can ask for time to finish it.
    var hasUnsent: Bool {
        jobs.contains { ($0.batchID == nil && !$0.uploading) || ($0.batchID != nil && !$0.watched) }
    }

    /// Everything the app does on coming to the front, in order: a session
    /// left open since yesterday is filed and graded before today can be
    /// written over it; lost uploads are resent; what finished is read in;
    /// then the day — and, once today's feedback is in, tomorrow — is written.
    /// Polls while anything is out, so the graded count moves on screen.
    func wake() async {
        backfillActivity()
        retireStale()
        await reconcileUploads()
        await pump()
        notificationsOn = await Push.allowed()
        await prepareDay()
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.jobs.contains(where: { $0.state != .done }) else { return }
                await self.pump()
            }
        }
    }

    func sleep() {
        polling?.cancel()
        polling = nil
    }

    /// Grades the answers a finished job is still missing, on the spot.
    func regrade(_ job: GradingJob) {
        Task { await gradeMissing(of: job) }
    }

    // MARK: Reading

    /// The graded reviews of one job, one screen per exchange.
    func read(_ job: GradingJob) {
        let ids = job.exchanges.compactMap(\.turnIDs.last)
            .filter { archived($0)?.review != nil }
        guard let first = ids.first, let turn = archived(first) else { return }
        session = nil
        knowledge = [:]
        path = []
        reading = ids
        current = turn
        phase = .reviewing
    }

    /// Where a job stands, in the learner's words.
    func status(of job: GradingJob) -> String {
        switch job.state {
        case .unsent:
            if sendingNow.contains(job.id) { return "Sending…" }
            if !online { return "Offline" }
            return job.uploading ? "Sending…" : "Not sent"
        case .grading:
            return "\(job.graded) of \(job.total) graded"
        case .done:
            let missing = job.exchanges.filter {
                $0.turnIDs.last.flatMap(archived)?.review == nil
            }.count
            if missing == 0 { return "Graded" }
            return regrading.contains(job.id) ? "Grading \(missing) again…" : "Graded, \(missing) failed"
        }
    }

    func canRead(_ job: GradingJob) -> Bool {
        job.exchanges.contains { $0.turnIDs.last.flatMap(archived)?.review != nil }
    }

    func hasFailures(_ job: GradingJob) -> Bool {
        job.state == .done && !regrading.contains(job.id) && job.exchanges.contains {
            $0.turnIDs.last.flatMap(archived)?.review == nil
        }
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
    private func hold() {
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
                    name: right ? "\(gap.answer), correct" : "\(gap.answer), not \(chose)",
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
    /// The language of what is on screen. Usually the setting; while reading
    /// a graded session it is that session's, which can be another language
    /// entirely — its lessons, its schedule, its voice.
    private var language: Language { current?.language ?? settings.language }

    func open(_ atom: Atom) {
        let request = LessonRequest(
            seed: atom.seed, kind: atom.kind, language: language,
            priorVisits: progress.visits(to: atom.id)
        )
        progress.opened(atom, language: language)
        save()
        path.append(request)
        Task { await load(request) }
    }

    /// A way onward from inside a lesson. The context comes from where it was
    /// tapped, which is why the link itself does not carry one.
    func open(_ link: AtomLink, context: String) {
        let request = link.request(in: language, context: context,
                                   priorVisits: progress.visits(to: link.id))
        path.append(request)
        Task { await load(request) }
    }

    /// Opening something that is not itself a finding — an example, half of a
    /// contrast — where there is no atom to record.
    func open(seed: Atom.Seed, kind: AtomKind) {
        let request = LessonRequest(seed: seed, kind: kind, language: language)
        path.append(request)
        Task { await load(request) }
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
                self.shelve([lesson])
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
                    self.shelve([full])
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
    //
    // Keeping is pinning: the bank is the textbook's pinned section.

    func isKept(_ atomID: String) -> Bool { bank.contains { $0.atomID == atomID } }

    func keep(_ entry: Textbook.Entry) {
        bank.removeAll { $0.atomID == entry.id }
        bank.append(BankEntry(entry: entry, language: settings.language))
        Vault.save(bank, Vault.bank)
    }

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
            progress.bringBack(atom, language: language)
        } else {
            progress.leaveOut(atom.id)
        }
        save()
    }

    func classify(_ atom: Atom, as verdict: Progress.Encounter.Knowledge) {
        knowledge[atom.id] = verdict
        progress.classify(atom, as: verdict, language: language)
        save()
    }

    /// A typed question about whatever is on screen. `context` scopes the
    /// answer so it appears under the thing it was asked about.
    func ask(_ question: String, about seed: Atom.Seed, context: String) async {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        asking.insert(context)
        do {
            let (reply, usage) = try await tutor.answer(
                question: question, about: seed, in: language
            )
            note(usage)
            asked[context, default: []].append(reply.item)
            file(reply.suggestions(language: language, validPoints: LanguagePacks.pack(for: language).pointIDs,
                                   question: question, context: seed.context))
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
                answer: answer, to: rung, in: language
            )
            note(usage)
            return verdict
        } catch {
            return Tutor.DrillVerdict(
                correct: false, note: "Couldn't check that."
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
            speech?.speak(text, locale: language.localeID)
        }
    }

    /// Whether the learner is hearing a person or a synthesiser.
    var hearingRealVoice: Bool {
        current?.prompt.audioSource?.kind == .recording
    }

    var clipCredits: [String] { clips.credits }

    // MARK: Bookkeeping

    private func note(_ usage: Anthropic.Usage, batched: Bool = false) {
        spend.add(usage, batched: batched)
        Vault.save(spend, Vault.spend)
    }

    /// Lessons are kept across launches, since the batch wrote them once and
    /// nothing will write them again. Capped, oldest out.
    private func shelve(_ written: [Lesson]) {
        guard !written.isEmpty else { return }
        for lesson in written {
            lessons[lesson.id] = lesson
            lessonOrder.removeAll { $0 == lesson.id }
            lessonOrder.append(lesson.id)
        }
        while lessonOrder.count > LessonShelf.cap {
            lessons[lessonOrder.removeFirst()] = nil
        }
        Vault.save(LessonShelf(order: lessonOrder, lessons: lessons), Vault.lessons)
    }

    private func save() {
        Vault.save(progress, Vault.progress)
    }

    var spentToday: Double { spend.today().dollars }

    // MARK: Opening from a notification

    /// What a tapped push names. The worker sends `job` and `batch`; pushes
    /// from before it kept job ids have only `batch`.
    struct Tap: Equatable, Sendable {
        var job: UUID?
        var batch: String?

        init(job: UUID? = nil, batch: String? = nil) {
            self.job = job
            self.batch = batch
        }

        init(_ userInfo: [AnyHashable: Any]) {
            job = (userInfo["job"] as? String).flatMap(UUID.init(uuidString:))
            batch = userInfo["batch"] as? String
        }
    }

    /// The job a tap is about. A tap naming nothing opens the newest graded
    /// job; one naming a job that cannot be read yet opens nothing.
    nonisolated static func target(of tap: Tap, in jobs: [GradingJob],
                                   readable: (GradingJob) -> Bool) -> GradingJob? {
        let named = jobs.first { job in
            tap.job == job.id || (tap.batch != nil && tap.batch == job.batchID)
        }
        if tap.job != nil || tap.batch != nil {
            return named.flatMap { $0.state == .done && readable($0) ? $0 : nil }
        }
        return jobs.last { $0.state == .done && readable($0) }
    }

    /// Reads the results in, then opens the review. Mid-attempt it only reads
    /// them in: the panel shows them when the learner steps out.
    func open(_ tap: Tap) async {
        // Launch's `wake` may be mid-pump; a second pump would return at once.
        while pumping { try? await Task.sleep(for: .milliseconds(200)) }
        await pump()
        let interruptible = phase == .idle || phase == .complete
            || (phase == .reviewing && !reading.isEmpty)
        guard interruptible,
              let job = Store.target(of: tap, in: jobs, readable: canRead) else { return }
        read(job)
    }

    // MARK: Textbook

    /// Links out of ask answers. The answers themselves live only for the
    /// launch; what they pointed at is kept.
    private(set) var suggestions: [Textbook.Suggestion] =
        Vault.load([Textbook.Suggestion].self, Vault.suggestions) ?? []

    private func file(_ new: [Textbook.Suggestion]) {
        guard !new.isEmpty else { return }
        suggestions = Textbook.Suggestion.adding(new, to: suggestions)
        Vault.save(suggestions, Vault.suggestions)
    }

    func textbook(scope: Textbook.Scope, search: String = "") -> [Textbook.Section] {
        let language = settings.language
        let pack = LanguagePacks.pack(for: language)
        let sessions = past + Mode.allCases.compactMap { today($0) }
        return Textbook.assemble(
            language: language, kinds: pack.kinds, points: pack.points,
            noted: Textbook.noted(in: sessions, language: language),
            progress: progress, suggestions: suggestions, bank: bank,
            scope: scope, search: search
        )
    }

    /// Onto the same lesson path as everything else. A finding counts as a
    /// visit; a point or a suggestion has no atom to record.
    func open(_ entry: Textbook.Entry) {
        if let atom = entry.atom {
            open(atom)
        } else {
            open(seed: entry.seed, kind: entry.kind)
        }
    }

    func togglePin(_ entry: Textbook.Entry) {
        if isKept(entry.id) { unkeep(entry.id) } else { keep(entry) }
    }

    // MARK: Quizzes

    private let books = BookLibrary()
    private(set) var quizLog: QuizLog = Vault.load(QuizLog.self, Vault.quizLog) ?? QuizLog()

    /// The current language's book.
    var book: Book { books.book(for: settings.language) }
    var quizItems: [QuizItem] { books.items(for: settings.language) }

    /// Quizzes take an entry to holding; solid is its point's production
    /// standing, as the day plan reads it.
    func state(of entry: Chapter.Entry) -> EntryState {
        let solid = entry.point.map { DayPlan.standing(of: $0, in: progress) == .solid } ?? false
        return quizLog.state(of: entry.id, pointSolid: solid)
    }

    /// Drill ids are not language-scoped, so the log key is.
    private func planKey(_ plan: QuizPlan) -> String { "\(settings.language.rawValue)|\(plan.id)" }

    func roundsDone(_ plan: QuizPlan) -> Int { quizLog.plans[planKey(plan)]?.rounds ?? 0 }

    func record(of plan: QuizPlan) -> QuizLog.PlanRecord { quizLog.plans[planKey(plan)] ?? .init() }

    /// The entry's level, falling back to its point's.
    func level(of entry: Chapter.Entry) -> Int {
        let points = pointLevels
        return entry.effectiveLevel { points[$0] }
    }

    private var pointLevels: [String: Int] {
        Dictionary(pack.points.map { ($0.id, $0.level) }, uniquingKeysWith: { a, _ in a })
    }

    /// The book cut to what the learner sees: up to their level + 1.
    var visibleBook: Book {
        let points = pointLevels
        return book.visible(at: settings.level) { $0.effectiveLevel { points[$0] } }
    }

    /// The level shown on entries a step above the learner's; nil otherwise.
    func stretchTag(_ entry: Chapter.Entry) -> String? {
        let n = level(of: entry)
        return n > settings.level ? pack.level(n) : nil
    }

    func round(for plan: QuizPlan) -> QuizRound {
        let book = book
        let points = pointLevels
        let entries = Dictionary(book.chapters.flatMap(\.entries).map { ($0.id, $0) },
                                 uniquingKeysWith: { a, _ in a })
        return QuizRound.assemble(
            plan: plan, book: book, bank: quizItems, maxLevel: settings.level + 1,
            levelOf: { id in entries[id]?.effectiveLevel { points[$0] } ?? 1 }
        ) { id in
            entries[id].map(self.state(of:)) ?? self.quizLog.state(of: id)
        }
    }


    /// Answered items move their entries; a finished round counts to its plan.
    func finish(_ round: QuizRound) {
        quizLog.record(round, planKey: planKey(round.plan))
        Vault.save(quizLog, Vault.quizLog)
        if round.answers.allSatisfy({ $0 != nil }),
           activity.add(.quiz, on: .now, settings.language) {
            Vault.save(activity, Vault.activity)
        }
    }

    /// Entries holding or better.
    func held(in chapter: Chapter) -> Int {
        chapter.entries.filter {
            let s = state(of: $0).standing
            return s == .holding || s == .solid
        }.count
    }

    func recommended() -> (plan: QuizPlan, reason: String)? {
        QuizLog.recommend(book: visibleBook, bank: quizItems, state: state(of:))
            .map { (Store.speedRound(for: $0.chapter), $0.reason) }
    }

    nonisolated static func speedRound(for chapter: Chapter) -> QuizPlan {
        QuizPlan(id: chapter.id, name: chapter.name, chapters: [chapter.id], formats: chapter.formats)
    }

    /// Synthesised, always: `say` would play the current turn's recording.
    func speakQuiz(_ text: String) {
        speech?.speak(text, locale: settings.language.localeID)
    }

    // MARK: Book

    /// The book as the tab shows it: the shipped chapters cut to the
    /// learner's level, then Noted, which is never cut.
    struct BookIndex {
        var book: Book
        var chapters: [Chapter]
        /// Noted chapter entries, back to the textbook entries they came from.
        var noted: [String: Textbook.Entry]

        func chapter(_ id: String) -> Chapter? { chapters.first { $0.id == id } }
    }

    var bookIndex: BookIndex {
        let shown = visibleBook
        let bank = quizItems
        var book = shown
        // A drill with nothing at this level goes with its chapters.
        book.drills = shown.drills.filter { !QuizRound.candidates(plan: $0, book: shown, bank: bank).isEmpty }
        var chapters = book.chapters
        var noted: [String: Textbook.Entry] = [:]
        if let extra = Textbook.notedChapter(
            language: settings.language, sections: textbook(scope: .mine),
            bookPoints: Set(chapters.flatMap(\.entries).compactMap(\.point)),
            known: Set(pack.points.map(\.id))) {
            chapters.append(extra.chapter)
            noted = extra.sources
        }
        return BookIndex(book: book, chapters: chapters, noted: noted)
    }

    func bookState(of entry: Chapter.Entry, in index: BookIndex) -> EntryState {
        if let source = index.noted[entry.id] { return Textbook.state(of: source) }
        return state(of: entry)
    }

    func point(_ id: String?) -> GrammarPoint? {
        id.flatMap { id in pack.points.first { $0.id == id } }
    }

    /// The learner's own sentences where this point was noted, newest first.
    func noted(point: String) -> [Textbook.Noted] {
        let sessions = past + Mode.allCases.compactMap { today($0) }
        return Textbook.noted(in: sessions, language: settings.language)
            .filter { $0.atom.seed.pointID == point }
            .sorted { $0.at > $1.at }
    }

    /// Questions whose answers pointed at this point, newest first.
    func asked(point: String) -> [Textbook.Suggestion] {
        suggestions.filter { $0.language == settings.language && $0.pointID == point }
            .sorted { $0.at > $1.at }
    }

    /// The same request the textbook's curriculum rows made, so the lesson is
    /// the one already on the shelf.
    func ruleRequest(for point: GrammarPoint) -> LessonRequest {
        LessonRequest(seed: Atom.Seed(subject: point.name, context: point.examples.first ?? "",
                                      pointID: point.id),
                      kind: point.kind, language: settings.language)
    }

    /// When a rule was first written from the book, by lesson cache key.
    private(set) var ruleSaved: [String: Date] =
        Vault.load([String: Date].self, Vault.bookRules) ?? [:]

    /// Writes the rule and shelves it. The practice half waits for the lesson
    /// to be opened.
    func loadRule(_ request: LessonRequest) async {
        let key = request.cacheKey
        let had = lessons[key] != nil
        await loadCore(request)
        if !had, lessons[key] != nil {
            ruleSaved[key] = .now
            Vault.save(ruleSaved, Vault.bookRules)
        }
    }

    /// Asked for from the book, by language. Spent by the next day drawn.
    private(set) var requests: [String: StretchRequest] =
        Vault.load([String: StretchRequest].self, Vault.requests) ?? [:]

    /// Makes `point` tomorrow's stretch.
    func requestTomorrow(point: String) {
        let language = settings.language
        guard pack.points.contains(where: { $0.id == point }) else { return }
        let request = StretchRequest(pointID: point, language: language, madeOn: Spend.key(.now))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        let slot = language.rawValue + "|next"
        if let drawn = request.replacing(draws[slot], tomorrow: Spend.key(tomorrow)) {
            // Tomorrow is already drawn: the request goes straight in.
            draws[slot] = drawn
            Vault.save(draws, Vault.plan)
            requests[language.rawValue] = nil
            // Its produce set was written for the old stretch. Unstarted, it
            // is written again.
            let key = Store.holdKey(language, .produce)
            if let held = holds[key], held.turn == nil, held.session.turns.isEmpty,
               held.session.id == sessionID(for: .produce, on: tomorrow) {
                holds[key] = nil
                Vault.save(holds, Vault.holds)
            }
        } else {
            requests[language.rawValue] = request
        }
        Vault.save(requests, Vault.requests)
    }

    func isRequested(point: String) -> Bool {
        let language = settings.language
        if requests[language.rawValue]?.pointID == point { return true }
        let tomorrow = Spend.key(Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now)
        guard let ahead = draws[language.rawValue + "|next"], ahead.day == tomorrow else { return false }
        return ahead.stretchID == point
    }

    /// The stretch for a draw on `day`, spending a request that applies.
    private func requestedStretch(on day: String, fallback: () -> String?) -> String? {
        let key = settings.language.rawValue
        let (id, spent) = StretchRequest.stretch(on: day, language: settings.language,
                                                 request: requests[key],
                                                 known: Set(pack.points.map(\.id)),
                                                 fallback: fallback)
        if spent {
            requests[key] = nil
            Vault.save(requests, Vault.requests)
        }
        return id
    }

    // MARK: Activity

    private(set) var activity: ActivityLog =
        Vault.load(ActivityLog.self, Vault.activity) ?? ActivityLog()

    /// Days from before the log existed, or from sessions filed some other
    /// way, read off what the archive and quiz scores still hold.
    private func backfillActivity() {
        var changed = false
        for s in past + holds.values.map(\.session) { changed = activity.add(s) || changed }
        for (key, plan) in quizLog.plans {
            guard let language = key.split(separator: "|").first
                .flatMap({ Language(rawValue: String($0)) }) else { continue }
            for score in plan.scores {
                changed = activity.add(.quiz, on: score.at, language) || changed
            }
        }
        if changed { Vault.save(activity, Vault.activity) }
    }

    func activity(on day: Date) -> Set<ActivityLog.Mark> {
        var marks = activity.marks(on: day, settings.language)
        // Today's sessions may not be filed yet.
        if Calendar.current.isDateInToday(day) {
            for mode in [Mode.translate, .produce] {
                if let s = today(mode), let m = ActivityLog.mark(for: s) { marks.insert(m) }
            }
        }
        return marks
    }

    // MARK: History

    /// The archive in the current language, with quiz rounds, by day.
    var history: [HistoryDay] {
        let names = Dictionary(book.chapters.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return HistoryDay.build(archive: archive, quizzes: quizLog.plans,
                                language: settings.language, today: Spend.key(.now)) {
            names[$0] ?? "Quiz"
        }
    }

    /// A recurring point's lesson. The latest finding it came from when one
    /// is still archived, so the lesson keeps its sentence; else its subject.
    func open(_ encounter: Progress.Encounter) {
        let sessions = past + Mode.allCases.compactMap { today($0) }
        let atom = sessions.sorted { $0.startedAt > $1.startedAt }.lazy
            .flatMap(\.turns)
            .compactMap { $0.review?.atoms.first { $0.id == encounter.atomID } }
            .first
        if let atom {
            open(atom)
        } else {
            open(seed: Atom.Seed(subject: encounter.subject, context: "", pointID: nil),
                 kind: encounter.kind)
        }
    }

    // MARK: Review

    /// Graded turns of a batch being read, in order. For the summary.
    func reviewed(_ ids: [UUID]) -> [Turn] {
        ids.compactMap { id in
            archived(id) ?? session?.turns.first { $0.id == id }
        }.filter { $0.review != nil }
    }

    /// The verdict `grade(_:against:)` returns when the model could not be reached.
    static let uncheckable = "Couldn't check that."

    /// Where a finding sits in what was said, and its fix as wrong → right.
    struct Span: Equatable {
        /// Character offsets into the sentence.
        var range: Range<Int>
        var wrong: String
        /// Nil when the fix is not a correction of these words (kept, or no fix).
        var right: String?
    }

    /// Finds a finding in the sentence from two sources: quoted fragments of
    /// its stages that occur verbatim, and where the fix places it (the part a
    /// whole-sentence fix changed, or the window a fragment fix rewrites).
    /// Nil when neither lands.
    nonisolated static func span(of atom: Atom, in said: String) -> Span? {
        let chars = Array(said)
        guard !chars.isEmpty else { return nil }
        let fix = atom.stages.fix.trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = atom.verdict.isProblem && !fix.isEmpty
        // Where the fix says it is, from the fix alone.
        let fromFix: Span? = !problem ? nil : rewrite(said, to: fix) ?? window(for: fix, in: chars)
            .map { Span(range: $0, wrong: String(chars[$0]), right: fix) }

        var quoted = [atom.stages.locate, atom.stages.name, atom.stages.note]
            .flatMap(quotes(in:))
        if !atom.verdict.isProblem, !fix.isEmpty { quoted.append(fix) }
        let near = { (r: Range<Int>) in fromFix.map { $0.range.overlaps(r) } ?? false }
        let hits = quoted.compactMap { q -> (range: Range<Int>, count: Int)? in
            let found = occurrences(of: q, in: chars)
            guard let first = found.first else { return nil }
            // A repeat is settled by the fix where it can be.
            return (found.first(where: near) ?? first, found.count)
        }
        // A quote the fix agrees with. Where the fix places it elsewhere, the
        // quote was context ("after „Gestern“"): the fix wins. With no fix,
        // a quote that occurs once, then any.
        let agreed = hits.first { near($0.range) }
        if agreed == nil, let fromFix { return fromFix }
        if let r = (agreed ?? hits.first { $0.count == 1 } ?? hits.first)?.range {
            let right: String? = !problem ? nil
                : (fromFix.flatMap { $0.range == r ? $0.right : nil } ?? fix)
            return Span(range: r, wrong: String(chars[r]), right: right)
        }
        return fromFix
    }

    /// Text between paired quotes, trimmed. Two or more characters, or one CJK.
    nonisolated static func quotes(in text: String) -> [String] {
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("“", "”"), ("„", "“"), ("«", "»"), ("‹", "›"),
            ("‘", "’"), ("「", "」"), ("『", "』"), ("*", "*"), ("'", "'")
        ]
        let chars = Array(text)
        var found: [String] = []
        var i = 0
        // One pass, so the closer of „…“ is never read as an opener.
        while i < chars.count {
            let c = chars[i]
            // An apostrophe inside a word is not a quote.
            let inWord = c == "'" && i > 0 && chars[i - 1].isLetter
            let ends = inWord ? [] : pairs.filter { $0.0 == c }.compactMap { pair in
                chars[(i + 1)...].firstIndex(of: pair.1)
            }
            guard let j = ends.min() else { i += 1; continue }
            let inner = String(chars[(i + 1)..<j]).trimmingCharacters(in: .whitespaces)
            if inner.count >= 2 || inner.contains(where: isCJK) { found.append(inner) }
            i = j + 1
        }
        return found
    }

    nonisolated private static func occurrences(of needle: String, in chars: [Character]) -> [Range<Int>] {
        let n = Array(needle)
        guard !n.isEmpty, n.count <= chars.count else { return [] }
        return (0...(chars.count - n.count)).compactMap { i in
            Array(chars[i..<(i + n.count)]) == n ? i..<(i + n.count) : nil
        }
    }

    nonisolated static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }

    nonisolated private static func isWord(_ c: Character) -> Bool {
        !isCJK(c) && (c.isLetter || c.isNumber || c == "-" || c == "'" || c == "’")
    }

    /// A fix that is the whole sentence rewritten: what changed, on word
    /// boundaries. An insertion takes the word before it.
    nonisolated private static func rewrite(_ said: String, to fix: String) -> Span? {
        let a = Array(said), b = Array(fix)
        guard !b.isEmpty, a != b else { return nil }
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        // Too little shared: a fragment, not a rewrite.
        guard p + s >= max(2, a.count / 3) else { return nil }
        var lo = p, hiA = a.count - s, hiB = b.count - s
        // Out to word boundaries; prefix and suffix are shared, so both move.
        while lo > 0, lo < a.count, isWord(a[lo - 1]), isWord(a[lo]) { lo -= 1 }
        while hiA > 0, hiA < a.count, isWord(a[hiA - 1]), isWord(a[hiA]) { hiA += 1; hiB += 1 }
        if lo == hiA {
            // Nothing of the learner's to mark: take the word before, or after.
            if lo > 0 {
                var w = lo - 1
                while w > 0, a[w] == " " { w -= 1 }
                var start = w
                while start > 0, isWord(a[start - 1]) { start -= 1 }
                if isCJK(a[w]) { start = w }
                lo = start
            } else if hiA < a.count {
                var end = hiA + 1
                while end < a.count, isWord(a[end - 1]), isWord(a[end]) { end += 1 }
                hiB += end - hiA
                hiA = end
            }
        }
        guard lo < hiA, hiB <= b.count, lo <= hiB else { return nil }
        let wrong = String(a[lo..<hiA]).trimmingCharacters(in: .whitespaces)
        let right = String(b[lo..<hiB]).trimmingCharacters(in: .whitespaces)
        guard !wrong.isEmpty else { return nil }
        // Trim what trimming took off the range.
        let lead = a[lo..<hiA].prefix { $0 == " " }.count
        let trail = a[lo..<hiA].reversed().prefix { $0 == " " }.count
        return Span(range: (lo + lead)..<(hiA - trail), wrong: wrong, right: right)
    }

    /// Words (or CJK characters) with their offsets.
    nonisolated private static func tokens(_ chars: [Character]) -> [(String, Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var i = 0
        while i < chars.count {
            if isCJK(chars[i]) { out.append((String(chars[i]), i..<(i + 1))); i += 1; continue }
            guard isWord(chars[i]) else { i += 1; continue }
            var j = i
            while j < chars.count, isWord(chars[j]) { j += 1 }
            out.append((String(chars[i..<j]).lowercased(), i..<j))
            i = j
        }
        return out
    }

    /// The run of words a fragment fix most plausibly replaces: the same
    /// length, give or take one, sharing at least half its words. Earliest wins a tie.
    nonisolated private static func window(for fix: String, in chars: [Character]) -> Range<Int>? {
        let said = tokens(chars)
        let want = tokens(Array(fix)).map(\.0)
        guard !want.isEmpty, !said.isEmpty else { return nil }
        var best: (score: Double, range: Range<Int>)?
        for len in [want.count, want.count - 1, want.count + 1] where len >= 1 && len <= said.count {
            for start in 0...(said.count - len) {
                var pool = want
                var shared = 0
                for t in said[start..<(start + len)] {
                    if let k = pool.firstIndex(of: t.0) { pool.remove(at: k); shared += 1 }
                }
                let overlap = Double(shared) / Double(max(len, want.count))
                guard shared > 0, overlap >= 0.5 else { continue }
                // Words in the same places break a tie.
                let aligned = zip(said[start..<(start + len)], want).filter { $0.0.0 == $0.1 }.count
                let score = overlap + 0.01 * Double(aligned)
                // A window identical to the fix is not wrong.
                if shared == want.count, len == want.count,
                   said[start..<(start + len)].map(\.0) == want { continue }
                let r = said[start].1.lowerBound..<said[start + len - 1].1.upperBound
                if best == nil || score > best!.score { best = (score, r) }
            }
        }
        return best?.range
    }
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
                reason: "Nothing broke in \(turns.count) sentences at \(here). "
                    + "Most of its points used."
            )
        }

        if level > 1, average <= LevelEvidence.demoteScore {
            return LevelOffer(
                level: level - 1,
                reason: "Your last \(turns.count) sentences at \(here) averaged "
                    + "\(average)."
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
