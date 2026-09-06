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
    private(set) var lessonError: String?

    /// Slip or gap, per atom, for the review on screen.
    private(set) var knowledge: [String: Progress.Encounter.Knowledge] = [:]

    /// A structure the learner has never reached for, offered this session.
    private(set) var stretch: GrammarPoint?

    private let tutor: Tutor
    private let speech: SpeechIO?

    init(tutor: Tutor, speech: SpeechIO? = nil) {
        self.tutor = tutor
        self.speech = speech
        settings = Vault.load(Settings.self, Vault.settings) ?? Settings()
        progress = Vault.load(Progress.self, Vault.progress) ?? Progress()
        spend = Vault.load(Spend.self, Vault.spend) ?? Spend()
        past = Vault.load([Session].self, Vault.sessions) ?? []
    }

    var pack: LanguagePack { LanguagePacks.pack(for: settings.language) }

    // MARK: Session

    func begin(_ mode: Mode) async {
        settings.mode = mode
        knowledge = [:]
        path = []
        stretch = settings.offerStretch ? pickStretch(for: mode) : nil

        session = Session(
            id: "\(Spend.key(.now))|\(settings.language.rawValue)|\(mode.rawValue)",
            language: settings.language, mode: mode, startedAt: .now,
            turns: [], goal: settings.dailyGoal, endless: false
        )
        await nextPrompt()
    }

    /// A point at the learner's level, in this mode, that they have never once
    /// attempted. Absence is the signal — it produces no errors to schedule on.
    private func pickStretch(for mode: Mode) -> GrammarPoint? {
        guard mode == .produce else { return nil }
        let use: GrammarPoint.Use = settings.prefersTyping ? .written : .spoken
        let candidates = pack.reachable(at: settings.level, use: use)
        return progress.neverReached(among: candidates).randomElement()
    }

    func nextPrompt() async {
        phase = .preparing
        draft = ""
        do {
            let used = (session?.turns ?? []).compactMap { $0.prompt.english }
            let (made, usage) = try await tutor.nextPrompt(
                mode: settings.mode,
                language: settings.language,
                level: settings.level,
                revisit: progress.seedsForGeneration(language: settings.language),
                stretch: stretch,
                avoid: used
            )
            note(usage)

            current = Turn(
                id: UUID(), mode: settings.mode, language: settings.language,
                createdAt: .now,
                prompt: .init(english: made.english, target: made.target,
                              audioSource: nil, pointID: made.pointID),
                attempt: .init(heard: "", confirmed: "", wasTyped: false,
                               audioFilename: nil, pronunciation: nil),
                review: nil
            )
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
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

        // Produce holds corrections until the exchange is done.
        if !settings.mode.reviewsEachAttempt,
           (session?.completedCount ?? 0) < settings.turnsBeforeReview - 1 {
            session?.turns.append(turn)
            await nextPrompt()
            return
        }

        phase = .assessing
        do {
            let history = settings.mode.reviewsEachAttempt ? [] : (session?.turns ?? [])
            let (review, usage) = try await tutor.assess(
                turn: turn, history: history, level: settings.level
            )
            note(usage)
            turn.review = review
            current = turn
            session?.turns.append(turn)
            recordReach(for: turn, review: review)
            phase = .reviewing
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// A point counts as attempted whether or not it worked — that is what
    /// separates reach from repetition.
    private func recordReach(for turn: Turn, review: Review) {
        guard let pointID = turn.prompt.pointID else { return }
        let clean = review.problems.isEmpty
        progress.attempted(pointID: pointID, language: turn.language, succeeded: clean)
        if pointID == stretch?.id { stretch = nil }
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
        } else {
            await nextPrompt()
        }
    }

    /// Past the daily goal, by choice.
    func keepGoing() async {
        session?.endless = true
        await nextPrompt()
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

    /// Opening something that is not itself a finding — an example, half of a
    /// contrast — where there is no atom to record.
    func open(seed: Atom.Seed, kind: AtomKind) {
        let request = LessonRequest(seed: seed, kind: kind, language: settings.language)
        path.append(request)
        Task { await load(request) }
    }

    func lesson(for request: LessonRequest) -> Lesson? { lessons[request.cacheKey] }

    func isLoading(_ request: LessonRequest) -> Bool {
        loadingLesson.contains(request.cacheKey)
    }

    private func load(_ request: LessonRequest) async {
        guard lessons[request.cacheKey] == nil else { return }
        loadingLesson.insert(request.cacheKey)
        lessonError = nil
        do {
            let (lesson, usage) = try await tutor.expand(request)
            if let usage { note(usage) }
            lessons[request.cacheKey] = lesson
        } catch {
            lessonError = error.localizedDescription
        }
        loadingLesson.remove(request.cacheKey)
    }

    func classify(_ atom: Atom, as verdict: Progress.Encounter.Knowledge) {
        knowledge[atom.id] = verdict
        progress.classify(atom, as: verdict, language: settings.language)
        save()
    }

    func recordDrill(correct: Bool, at support: Rung.Support) {
        // Only unaided production counts toward reach; a multiple-choice hit is
        // recognition, which is a different and easier skill.
        guard support == .free, correct else { return }
        progress.xp += 5
        save()
    }

    // MARK: Speaking

    func say(_ text: String) {
        speech?.speak(text, locale: settings.language.localeID)
    }

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
