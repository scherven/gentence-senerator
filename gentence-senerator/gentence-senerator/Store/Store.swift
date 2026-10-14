import Foundation
import Network
import Observation

/// All app state. Views read it and call methods; nothing mutates it directly.
@MainActor
@Observable
final class Store {

    // MARK: Persisted

    var settings = Settings() {
        didSet {
            Vault.save(settings, Vault.settings)
            if oldValue.prefersTyping != settings.prefersTyping
                || oldValue.offerStretch != settings.offerStretch { rewriteUnstarted() }
        }
    }
    var progress = Progress()
    var spend = Spend()
    var past: [Session] = []
    var bank: [BankEntry] = []

    // MARK: Current attempt

    var phase: Phase = .idle
    var session: Session?
    var current: Turn?
    /// The editable transcript, or what is being typed. Assessed only after the
    /// learner confirms it.
    var draft = ""

    // MARK: Drilling down

    /// The navigation stack. Each entry is the request that produced the screen.
    var path: [LessonRequest] = []
    private(set) var lessons: [String: Lesson] = [:]
    var loadingLesson: Set<String> = []
    /// In flight, per lesson, so a tap joins a prefetch already running
    /// instead of asking for the same thing twice.
    var coreLoads: [String: Task<Void, Never>] = [:]
    var practiceLoads: [String: Task<Void, Never>] = [:]
    /// Why a lesson did not load, by `LessonRequest.cacheKey`: one lesson's
    /// failure is not another's.
    var lessonErrors: [String: String] = [:]
    /// Lessons, in the order they were written, so the shelf can be capped.
    private var lessonOrder: [String] = []

    /// Finished sessions out for grading, oldest first, until their reviews
    /// are in the archive.
    var jobs: [GradingJob] = [] { didSet { noteLanded(since: oldValue) } }
    /// The day each job came back, by job id, for jobs seen to come back.
    var landed: [String: String] = [:]
    /// Reviews being read, as the turns they landed on. Empty outside reading.
    var reading: [UUID] = []
    /// The day's prompt sets being written, by hold key, so starting a
    /// session joins the one already running.
    var writing: [String: Task<Void, Never>] = [:]
    var polling: Task<Void, Never>?
    let sender = Sender()
    /// Jobs whose failed answers are being graded again right now, so the
    /// screen says so and Retry cannot start a second, paid-for copy.
    var regrading: Set<UUID> = []
    /// Jobs being sent by hand right now.
    var sendingNow: Set<UUID> = []
    /// Whether the phone has a route to the internet. Watched so a session
    /// waiting for signal is sent the moment it comes back, and so the screen
    /// can say which of the two it is waiting on.
    private(set) var online = true
    private let network = NWPathMonitor()
    /// Whether a finished session can promise a notification.
    var notificationsOn = true
    /// Recognition could not start — usually no signal, in a language this
    /// phone cannot recognise offline. The answer is typed instead, this once.
    var speechTrouble: String?

    /// Slip or gap, per atom, for the review on screen.
    var knowledge: [String: Progress.Encounter.Knowledge] = [:]

    /// Answers to questions the learner typed, keyed by what they were asking
    /// about. Answers carry atoms, so asking is another way down.
    var asked: [String: [AskItem]] = [:]
    var asking: Set<String> = []

    /// A structure the learner has never reached for, offered this session.
    var stretch: GrammarPoint?

    /// Today before it starts, and what the sentences will be written from.
    /// Rebuilt whenever the learner is back at the start, so what it says about
    /// the record keeps up with the day.
    var plan = DayPlan.empty

    /// The random half of it, drawn once a day and persisted. Rebuilding the
    /// plan reads this rather than drawing again: a stretch that changed every
    /// time the learner came back to the start screen was never the one the
    /// day's sentences had been written from. One slot per language, like
    /// `holds`, so switching away and back is not a new day either.
    var draws: [String: DayDraw] = [:]

    /// Sessions the learner stepped out of. Picking the same mode resumes it
    /// rather than starting over. One slot per language and mode: ending a
    /// produce session and then a translate session holds both.
    struct Unfinished: Codable {
        var session: Session
        var turn: Turn?
    }
    var holds: [String: Unfinished] = [:]

    static func holdKey(_ language: Language, _ mode: Mode) -> String {
        "\(language.rawValue)|\(mode.rawValue)"
    }

    /// Listen only: the turn after the one on screen, written while the
    /// learner is still working on it. Translate and produce are written a
    /// session at a time and have nothing to prefetch.
    var pending: Task<Turn?, Never>?

    let tutor: Tutor
    let speech: SpeechIO?
    let pronunciation: Pronunciation
    let clips = ClipLibrary()
    var usedClips: Set<String> = []
    /// The other half of reach. Words are counted here rather than asked for.
    let lexicon = Lexicon()

    // MARK: Dialogues

    let passages = PassageLibrary()

    /// Per language: a run per dialogue started and not finished, every
    /// finished listen, and the one opened last. Not in `holds` — those are
    /// retired at the end of the day and a passage is allowed to outlive one.
    struct PassageState: Codable {
        var runs: [String: PassageRun] = [:]
        var heard: [String: [Heard]] = [:]
        var open: String?
    }
    var passageState: [String: PassageState] = [:]

    /// What the passage screen is showing. Both nil on the picker, and when
    /// listen is on clips.
    var passage: Passage?
    var run: PassageRun?
    /// Playback for the passage screen, polled for the read-along.
    let dialogue = DialoguePlayer()

    // MARK: Stored for the extensions

    var pumping = false

    var gradingTimes: [TimeInterval] = Vault.load([TimeInterval].self, Vault.gradingTimes) ?? []

    /// Uploads turned down, by job: when the next may go, and how many in a
    /// row have failed. In memory — a relaunch tries again.
    var uploadHolds: [UUID: (next: Date, failures: Int)] = [:]

    /// Findings the learner has said are wrong, by atom id. Kept so the key
    /// stays marked on a review opened again.
    var disputed: Set<String> = Set(Vault.load([String].self, Vault.disputed) ?? [])

    /// Links out of ask answers. The answers themselves live only for the
    /// launch; what they pointed at is kept.
    var suggestions: [Textbook.Suggestion] =
        Vault.load([Textbook.Suggestion].self, Vault.suggestions) ?? []

    let books = BookLibrary()

    var quizLog: QuizLog = Vault.load(QuizLog.self, Vault.quizLog) ?? QuizLog()

    var endlessMixes: [String: QuizPlan.Mix] =
        Vault.load([String: QuizPlan.Mix].self, Vault.endlessMixes) ?? [:]

    var topUps: [String: [QuizItem]] =
        Vault.load([String: [QuizItem]].self, Vault.topUps) ?? [:]

    @ObservationIgnored var askedItems: [String: Set<String>] =
        Vault.load([String: Set<String>].self, Vault.askedItems) ?? [:]

    @ObservationIgnored var toppingUp: Set<String> = []

    @ObservationIgnored var topUpFailed: [String: Date] = [:]

    /// Concept id → language → the word the learner typed over the list's.
    var conceptEdits: [String: [String: String]] =
        Vault.load([String: [String: String]].self, Vault.conceptEdits) ?? [:]

    /// When a rule was first written from the book, by lesson cache key.
    var ruleSaved: [String: Date] =
        Vault.load([String: Date].self, Vault.bookRules) ?? [:]

    /// Asked for from the book, by language. Spent by the next day drawn.
    var requests: [String: StretchRequest] =
        Vault.load([String: StretchRequest].self, Vault.requests) ?? [:]

    var activity: ActivityLog =
        Vault.load(ActivityLog.self, Vault.activity) ?? ActivityLog()

    var scores: ScoreLog = Vault.load(ScoreLog.self, Vault.scores) ?? ScoreLog()

    /// A quiz is on screen. A tapped push reads its results in but leaves it up.
    var quizOpen = false

    /// The lessons on screen when a tapped push started reading, so the shell
    /// can hand them back to the tab they belonged to.
    var pathBeforeTap: [LessonRequest]?

    var rerolling = false

    init(tutor: Tutor, speech: SpeechIO? = nil,
         pronunciation: Pronunciation = Pronunciation()) {
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
        past = Vault.loadList(Session.self, Vault.sessions) ?? []
        bank = Vault.loadList(BankEntry.self, Vault.bank) ?? []
        holds = Vault.loadMap(Unfinished.self, Vault.holds) ?? [:]
        passageState = Vault.loadMap(PassageState.self, Vault.passages) ?? [:]
        draws = Vault.loadMap(DayDraw.self, Vault.plan) ?? [:]
        jobs = Vault.loadList(GradingJob.self, Vault.grading) ?? []
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
        saveArchive()
        Vault.save(holds, Vault.holds)
        // A session left part-way is still worth grading: those answers were
        // given, and nobody is going to finish them now.
        for session in unfinished where session.mode != .listen { enqueue(session) }
    }

    /// A session still on screen from an earlier day — the app was never
    /// closed overnight — is stepped out of and filed with the rest, before
    /// anything can write today over it.
    func retireStale() {
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

    func sessionID(for mode: Mode, on day: Date = .now) -> String {
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
        // the three passes is the only number worth showing while it is running.
        if mode == .listen, let held = heldPassage {
            let passes: Int = switch held.run.stage {
            case .first:  held.run.canRead(held.passage) ? 1 : 0
            case .read:   1
            case .second, .done: held.run.followedSecond == nil ? 2 : 3
            }
            return (passes, 3)
        }
        if mode == .listen, hasDialogues {
            return (today(.listen)?.completedCount ?? 0, listenGoal)
        }
        guard let session = today(mode) else { return (0, settings.dailyGoal) }
        return (session.completedCount, session.goal)
    }

    /// One new dialogue and one review a day, each while there is one to do.
    var listenGoal: Int {
        let state = passageState[settings.language.rawValue] ?? PassageState()
        let todayKey = Spend.key(.now)
        var newToday = 0, reviewsToday = 0
        for history in state.heard.values {
            let sorted = history.sorted { $0.on < $1.on }
            for (i, h) in sorted.enumerated() where Spend.key(h.on) == todayKey {
                if i == 0 { newToday += 1 } else { reviewsToday += 1 }
            }
        }
        let statuses = shelf.map(\.status)
        let wantsNew = newToday > 0 || statuses.contains { if case .new = $0 { true } else { false } }
        let wantsReview = reviewsToday > 0 || statuses.contains { if case .due = $0 { true } else { false } }
        let slots = max(1, (wantsNew ? 1 : 0) + (wantsReview ? 1 : 0))
        return max(slots, today(.listen)?.completedCount ?? 0)
    }

    /// Heard before: a review, which can skip the read-along.
    var isReview: Bool {
        guard let run else { return false }
        return !(passageState[run.language.rawValue]?.heard[run.passageID] ?? []).isEmpty
    }

    func isDone(_ mode: Mode) -> Bool { today(mode)?.isComplete ?? false }

    /// Three of each and the day is over. The main screen becomes the summary.
    var dayComplete: Bool { settings.language.modes.allSatisfy(isDone) }

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
    func file(_ finished: Session) {
        if let index = past.firstIndex(where: { $0.id == finished.id }) {
            past[index] = finished
        } else {
            past.append(finished)
        }
        saveArchive()
        if activity.add(finished) { Vault.save(activity, Vault.activity) }
    }

    /// The archive as it is on disk: trimmed here too, so History does not
    /// show more than the next launch will.
    func saveArchive() {
        if past.count > Store.archiveLimit { past.removeFirst(past.count - Store.archiveLimit) }
        Vault.save(past, Vault.sessions)
    }

    private static let archiveLimit = 120

    /// The archive plus today's live and held sessions, each once. Today's
    /// can also be archived; the live or held copy is the newer.
    var everySession: [Session] {
        var sessions = past
        for live in Mode.allCases.compactMap({ today($0) }) {
            if let i = sessions.firstIndex(where: { $0.id == live.id }) {
                sessions[i] = live
            } else {
                sessions.append(live)
            }
        }
        return sessions
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

    /// Turns a language on or off. The one in use stays on.
    func setOffered(_ language: Language, _ on: Bool) {
        guard on || language != settings.language else { return }
        var set = Set(settings.languages)
        if on { set.insert(language) } else { set.remove(language) }
        settings.languages = Language.allCases.filter(set.contains)
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
        rewriteUnstarted()
    }

    /// Sets written ahead for a level, stretch or way of answering the learner
    /// has just changed. Unstarted only — anything begun holds answers.
    private func rewriteUnstarted() {
        var dropped = false
        for mode in [Mode.translate, .produce] {
            let key = Store.holdKey(settings.language, mode)
            if let held = holds[key], held.turn == nil, held.session.turns.isEmpty,
               held.session.id != session?.id {
                holds[key] = nil
                dropped = true
            }
        }
        if dropped { Vault.save(holds, Vault.holds) }
        Task { await prepareDay() }
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
        let turns = everySession
            .filter { $0.language == settings.language }
            .flatMap(\.turns)
            .filter { $0.mode.isScored && $0.review != nil && $0.createdAt >= since
                && seen.insert($0.id).inserted }
            .sorted { $0.createdAt < $1.createdAt }
        return Array(turns.suffix(n))
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

    func note(_ usage: Anthropic.Usage, batched: Bool = false, model: String? = nil) {
        if model == Anthropic.reviewModel {
            spend.addSonnet(usage, batched: batched)
        } else {
            spend.add(usage, batched: batched)
        }
        Vault.save(spend, Vault.spend)
    }

    /// Lessons are kept across launches, since the batch wrote them once and
    /// nothing will write them again. Capped, oldest out.
    func shelve(_ written: [Lesson]) {
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

    func save() {
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
        // An open quiz is not interrupted: its round would be lost.
        let interruptible = !quizOpen && (phase == .idle || phase == .complete
            || (phase == .reviewing && !reading.isEmpty))
        guard interruptible,
              let job = Store.target(of: tap, in: jobs, readable: canRead) else { return }
        pathBeforeTap = path
        read(job)
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
