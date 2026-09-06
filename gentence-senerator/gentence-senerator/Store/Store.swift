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
    private(set) var reviewDepthError: String?

    /// Slip or gap, per atom, for the review on screen.
    private(set) var knowledge: [String: Progress.Encounter.Knowledge] = [:]

    /// Answers to questions the learner typed, keyed by what they were asking
    /// about. Answers carry atoms, so asking is another way down.
    private(set) var asked: [String: [AskItem]] = [:]
    private(set) var asking: Set<String> = []

    /// A structure the learner has never reached for, offered this session.
    private(set) var stretch: GrammarPoint?

    private let tutor: Tutor
    private let speech: SpeechIO?
    private let pronunciation: Pronunciation
    private let clips = ClipLibrary()
    private var usedClips: Set<String> = []

    init(tutor: Tutor, speech: SpeechIO? = nil,
         pronunciation: Pronunciation = Pronunciation(key: Key.azureKey, region: Key.azureRegion)) {
        self.pronunciation = pronunciation
        self.tutor = tutor
        self.speech = speech
        settings = Vault.load(Settings.self, Vault.settings) ?? Settings()
        progress = Vault.load(Progress.self, Vault.progress) ?? Progress()
        spend = Vault.load(Spend.self, Vault.spend) ?? Spend()
        past = Vault.load([Session].self, Vault.sessions) ?? []
    }

    var pack: LanguagePack { LanguagePacks.pack(for: settings.language) }

    /// Switching language abandons the current session rather than carrying it
    /// over — the sentences and the level mean something different.
    func switchLanguage(_ language: Language) {
        guard language != settings.language else { return }
        settings.language = language
        // HSK runs to 9, CEFR to 6.
        settings.level = min(settings.level, language == .mandarin ? 9 : 6)
        session = nil
        current = nil
        phase = .idle
        path = []
        knowledge = [:]
    }

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

        // Real speech where the library has it. Falls through to a generated
        // sentence and synthesis otherwise, which is the normal case for
        // Mandarin.
        if settings.mode == .listen,
           let clip = clips.pick(language: settings.language,
                                 level: settings.level, excluding: usedClips) {
            usedClips.insert(clip.id)
            current = Turn(
                id: UUID(), mode: .listen, language: settings.language, createdAt: .now,
                prompt: .init(english: clip.english, target: clip.text,
                              audioSource: clips.source(for: clip), pointID: nil),
                attempt: .init(heard: "", confirmed: "", wasTyped: false,
                               audioFilename: nil, pronunciation: nil),
                review: nil
            )
            phase = .ready
            return
        }

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

        // Produce holds corrections until the exchange is done. "Done" means
        // this many turns since the last review, not since the session began —
        // otherwise every turn after the first review would trigger one.
        let unreviewed = session?.turns.reversed().prefix { $0.review == nil }.count ?? 0
        if !settings.mode.reviewsEachAttempt, unreviewed < settings.turnsBeforeReview - 1 {
            session?.turns.append(turn)
            await nextPrompt()
            return
        }

        phase = .assessing

        // Scored against what they should have said: the played sentence in
        // listen mode, their own words otherwise.
        if !turn.attempt.wasTyped, let wav = speech?.lastRecording {
            let reference = turn.mode == .listen
                ? (turn.prompt.target ?? turn.attempt.confirmed)
                : turn.attempt.confirmed
            turn.attempt.pronunciation = try? await pronunciation.assess(
                wav: wav, reference: reference, locale: settings.language.localeID
            )
            current = turn
        }

        // Only the turns this review covers.
        let history = settings.mode.reviewsEachAttempt
            ? []
            : Array((session?.turns ?? []).suffix(unreviewed))
        do {
            let (opening, usage) = try await tutor.assessOpening(
                turn: turn, history: history, level: settings.level
            )
            note(usage)
            turn.review = opening
            current = turn
            session?.turns.append(turn)
            recordReach(for: turn, review: opening)
            phase = .reviewing

            // The rest lands while the learner is still reading where the
            // problems are and trying to fix them. By the time they ask for a
            // name, it is usually already here.
            Task { await deepen(turn: turn, opening: opening, history: history) }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func deepen(turn: Turn, opening: Review, history: [Turn]) async {
        do {
            let (full, usage) = try await tutor.assessDepth(
                turn: turn, opening: opening, history: history, level: settings.level
            )
            note(usage)
            guard current?.id == turn.id else { return }
            current?.review = full
            if let index = session?.turns.firstIndex(where: { $0.id == turn.id }) {
                session?.turns[index].review = full
            }
        } catch {
            // The opening still stands; the learner just waits on a tap.
            reviewDepthError = error.localizedDescription
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

    /// Leave a session unfinished. Whatever was completed is kept.
    func endSession() {
        if let live = session, live.completedCount > 0 {
            past.append(live)
            Vault.save(Array(past.suffix(120)), Vault.sessions)
        }
        session = nil
        current = nil
        phase = .idle
        path = []
        knowledge = [:]
        usedClips = []
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
            loadingLesson.remove(request.cacheKey)

            // Drills and questions arrive while the rule is being read.
            if let (full, practiceUsage) = try await tutor.practice(for: request) {
                note(practiceUsage)
                lessons[request.cacheKey] = full
            }
        } catch {
            lessonError = error.localizedDescription
            loadingLesson.remove(request.cacheKey)
        }
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
            return Tutor.DrillVerdict(correct: true, note: "", oneGoodAnswer: rung.accept.first ?? "")
        }
        do {
            let (verdict, usage) = try await tutor.grade(
                answer: answer, to: rung, in: settings.language
            )
            note(usage)
            return verdict
        } catch {
            return Tutor.DrillVerdict(
                correct: false,
                note: "Couldn't check that just now.",
                oneGoodAnswer: rung.accept.first ?? ""
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
