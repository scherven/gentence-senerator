import SwiftUI

/// The whole app. One stack, one destination type: every screen below the root
/// is a lesson, and a lesson is reached by expanding an atom.
struct AppShell: View {
    @State var store: Store

    var body: some View {
        NavigationStack(path: $store.path) {
            ModeScreen(store: store)
                .navigationDestination(for: LessonRequest.self) { request in
                    LessonHost(store: store, request: request)
                }
        }
        .tint(Theme.C.accent)
    }
}

/// One screen for all three modes. The mode changes what is asked, not how the
/// attempt is made or how the review is read.
struct ModeScreen: View {
    @Bindable var store: Store
    @State private var typing = ""
    @State private var showingSettings = false
    @State private var showingHistory = false
    /// The English is a fallback, not the prompt. Reading it first turns
    /// producing into translating.
    @State private var showGloss = false

    var body: some View {
        Group {
            switch store.phase {
            case .idle:
                if store.dayComplete { DayScreen(store: store) } else { start }
            case .preparing:
                Busy(text: "Writing something for you…")
            case .passage:
                PassageScreen(store: store)
            case .ready, .recording:
                attempt
            case .confirming:
                confirm
            case .transcribing:
                Busy(text: "Writing down what you said…")
            case .assessing:
                Busy(text: "Looking at what you said…")
            case .reference:
                reference
            case .reviewing:
                review
            case .complete:
                done
            case .failed(let why):
                Trouble(message: why) { Task { await store.nextPrompt() } }
            }
        }
        .background(Theme.C.surface)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .idle = store.phase {
                ToolbarItem(placement: .topBarLeading) {
                    TinyButton(title: "History") { showingHistory = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    TinyButton(title: store.settings.language.flag) { showingSettings = true }
                }
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    if store.phase == .passage {
                        TinyButton(title: "Leave") { store.leavePassage() }
                    } else {
                        TinyButton(title: "End") { store.endSession() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(progressLabel)
                        .font(Theme.F.label)
                        .foregroundStyle(Theme.C.ink3)
                }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsScreen(store: store) }
        .sheet(isPresented: $showingHistory) { HistoryScreen(store: store) }
    }

    /// Before a mode is picked there is no mode to name, so the title carries
    /// the language instead.
    private var title: String {
        if case .idle = store.phase { return store.settings.language.name }
        // While reading, what is on screen may be another mode's review.
        return (store.current?.mode ?? store.settings.mode).name
    }

    private var progressLabel: String {
        if store.phase == .passage {
            let tally = store.tally(.listen)
            return "\(tally.done)/\(tally.goal)"
        }
        guard let session = store.session else { return "" }
        return "\(session.completedCount)/\(session.goal)"
    }

    // MARK: Phases

    private var start: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                GradingPanel(store: store)
                ModuleLabel(text: "Practice · \(store.pack.level(store.settings.level))")
                ForEach(Mode.allCases) { mode in
                    let tally = store.tally(mode)
                    let spent = store.isDone(mode)
                    Button { Task { await store.begin(mode) } } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(mode.name).font(Theme.F.title)
                                    .foregroundStyle(spent ? Theme.C.ink3 : Theme.C.ink)
                                Spacer()
                                if tally.done > 0 {
                                    Text("\(tally.done)/\(tally.goal)")
                                        .font(Theme.F.label)
                                        .foregroundStyle(spent ? Theme.C.ink3 : Theme.C.accent)
                                }
                            }
                            Text(blurb(mode, spent: spent, started: tally.done > 0))
                                .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.M.pad)
                        .background(spent ? Theme.C.raised : Theme.C.surface)
                        .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
                    }
                    .buttonStyle(.plain)
                    .disabled(spent)
                }
                PlanView(plan: store.plan)
            }
            .padding(Theme.M.gap)
        }
    }

    private func blurb(_ mode: Mode, spent: Bool, started: Bool) -> String {
        if spent { return "Spent. Back tomorrow." }
        if mode == .listen, let held = store.heldPassage {
            return held.run.stage == .gist
                ? "A dialogue: \(held.passage.title). Heard once, then questions."
                : "Carry on with \(held.passage.title)."
        }
        if started { return "Carry on where you left off." }
        return mode.blurb
    }

    private var attempt: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                if let stretch = store.stretch, store.settings.mode == .produce,
                   store.current?.prompt.pointID == stretch.id {
                    Panel(fill: Theme.C.sunk, edge: Theme.C.accent) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TRY TO USE").font(Theme.F.label).tracking(1.1)
                                .foregroundStyle(Theme.C.accent)
                            Text(stretch.name).font(Theme.F.body)
                            Text(stretch.instruction).font(Theme.F.note)
                                .foregroundStyle(Theme.C.ink2)
                        }
                    }
                }

                prompt

                if store.phase == .recording {
                    VStack(alignment: .leading, spacing: Theme.M.gapTight) {
                        ModuleLabel(text: "Listening")
                        Panel { Text(store.draft.isEmpty ? "…" : store.draft).font(Theme.F.target) }
                        MainButton(title: "Done") { store.stopRecording() }
                    }
                } else if store.settings.prefersTyping || store.speechTrouble != nil {
                    VStack(alignment: .leading, spacing: Theme.M.gapTight) {
                        if let trouble = store.speechTrouble {
                            Text(trouble + " Type it instead.")
                                .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                        }
                        TextField("Type it…", text: $typing, axis: .vertical)
                            .font(Theme.F.target)
                            .textFieldStyle(.plain)
                            .targetLanguageInput()
                            .lineLimit(2...5)
                            .padding(Theme.M.pad)
                            .background(Theme.C.sunk)
                            .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
                        MainButton(title: "Continue", enabled: !typing.isEmpty) {
                            store.typed(typing); typing = ""
                        }
                    }
                } else {
                    MainButton(title: "Speak") { store.startRecording() }
                    TinyButton(title: "Type instead") { store.settings.prefersTyping = true }
                }
            }
            .padding(Theme.M.gap)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: store.current?.id) { showGloss = false }
    }

    @ViewBuilder
    private var prompt: some View {
        if let turn = store.current {
            VStack(alignment: .leading, spacing: 6) {
                ModuleLabel(text: label(for: turn))
                Panel(fill: Theme.C.sunk, edge: Theme.C.accent) {
                    VStack(alignment: .leading, spacing: 6) {
                        if store.settings.mode == .translate {
                            Text(turn.prompt.english ?? "").font(Theme.F.target)
                        } else {
                            if let target = turn.prompt.target {
                                HStack(alignment: .firstTextBaseline, spacing: Theme.M.pad) {
                                    if store.settings.mode == .listen {
                                        Text("Play it, then write what you heard.")
                                            .font(Theme.F.body)
                                    } else {
                                        Text(target).font(Theme.F.target)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    TinyButton(title: "Hear") { store.say(target) }
                                }
                            }
                            if let english = turn.prompt.english, turn.mode != .listen {
                                if showGloss {
                                    Text(english).font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                                    TinyButton(title: "Hide translation") { showGloss = false }
                                } else {
                                    TinyButton(title: "Show translation") { showGloss = true }
                                }
                            }
                            if turn.mode == .listen {
                                Text(store.hearingRealVoice ? "A real recording" : "Synthesised")
                                    .font(Theme.F.label).foregroundStyle(Theme.C.ink3)
                            }
                        }
                    }
                }
            }
        }
    }

    private func label(for turn: Turn) -> String {
        switch turn.mode {
        case .translate: return "Say this in \(store.settings.language.name)"
        case .listen:    return "What was said?"
        case .produce:   return "Answer this"
        }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            ModuleLabel(text: store.current?.attempt.wasTyped == true
                        ? "Ready?" : "Is this what you said?")
            TextField("", text: $store.draft, axis: .vertical)
                .font(Theme.F.target)
                .textFieldStyle(.plain)
                .targetLanguageInput()
                .lineLimit(2...6)
                .padding(Theme.M.pad)
                .background(Theme.C.sunk)
                .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
            Text(store.current?.attempt.wasTyped == true
                 ? "Only this is marked."
                 : "Fix anything the microphone got wrong. Only this is marked.")
                .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
            MainButton(title: "Submit", enabled: !store.draft.isEmpty) {
                Task { await store.submit() }
            }
            TinyButton(title: store.current?.attempt.wasTyped == true
                       ? "Change it" : "Say it again") { store.reRecord() }
            Spacer()
        }
        .padding(Theme.M.gap)
    }

    @ViewBuilder
    private var review: some View {
        if let turn = store.current {
            VStack(spacing: 0) {
                ReviewScreen(
                    turn: turn,
                    exchange: store.exchange(endingAt: turn),
                    knowledge: store.knowledge,
                    onOpenAtom: { store.open($0) },
                    onOpenLink: { store.open($0, context: turn.attempt.confirmed) },
                    onClassify: { store.classify($0, as: $1) },
                    onAsk: { question in
                        Task {
                            await store.ask(question,
                                            about: .init(subject: turn.attempt.confirmed,
                                                         context: turn.attempt.confirmed,
                                                         pointID: turn.prompt.pointID),
                                            context: turn.id.uuidString)
                        }
                    },
                    answers: store.asked[turn.id.uuidString] ?? [],
                    isAsking: store.asking.contains(turn.id.uuidString)
                )
                MainButton(title: store.reading.count == 1 ? "Done" : "Next") {
                    Task { await store.advance() }
                }
            }
        }
    }

    /// A translate answer, and one good way to say it. Not a grade: the
    /// review comes with the batch.
    private var reference: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            if let turn = store.current {
                ModuleLabel(text: "Asked")
                Text(turn.prompt.english ?? "").font(Theme.F.body)
                ModuleLabel(text: "You said")
                Text(turn.attempt.confirmed).font(Theme.F.target)
                if let reference = turn.prompt.reference {
                    ModuleLabel(text: "One way to say it")
                    Panel(fill: Theme.C.sunk, edge: Theme.C.seam2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(reference).font(Theme.F.target)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            TinyButton(title: "Hear") { store.say(reference) }
                        }
                    }
                    Text("A reference, not a mark. Graded with the rest.")
                        .font(Theme.F.note).foregroundStyle(Theme.C.ink3)
                }
            }
            MainButton(title: "Next") { Task { await store.advance() } }
            Spacer()
        }
        .padding(Theme.M.gap)
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            ModuleLabel(text: "\(store.settings.mode.name) done")
            if let session = store.session {
                if session.mode == .listen {
                    Text("\(session.completedCount) attempts · average \(session.averageScore)")
                        .font(Theme.F.body)
                } else {
                    Text(store.notificationsOn
                         ? "\(session.completedCount) answers sent for grading. You'll get a notification."
                         : "\(session.completedCount) answers sent for grading. Notifications are off, so check back here.")
                        .font(Theme.F.body)
                }
            }
            MainButton(title: store.dayComplete ? "See the day" : "Back") {
                store.endSession()
            }
            Spacer()
        }
        .padding(Theme.M.gap)
    }
}

/// A lesson, loaded on demand and cached.
struct LessonHost: View {
    @Bindable var store: Store
    let request: LessonRequest

    var body: some View {
        Group {
            if let lesson = store.lesson(for: request) {
                LessonScreen(
                    lesson: lesson,
                    priorVisits: request.priorVisits,
                    onOpenLink: { store.open($0, context: request.seed.context) },
                    onOpenSeed: { store.open(seed: $0, kind: $1) },
                    onDrillOutcome: { store.recordDrill(correct: $0, at: $1) },
                    onAsk: { question in
                        Task {
                            await store.ask(question, about: request.seed,
                                            context: request.cacheKey)
                        }
                    },
                    grade: { await store.grade($0, against: $1) },
                    answers: store.asked[request.cacheKey] ?? [],
                    isAsking: store.asking.contains(request.cacheKey)
                )
            } else if let error = store.lessonError {
                Trouble(message: error) { }
            } else {
                Busy(text: "Working it out…")
            }
        }
        .navigationTitle(store.lesson(for: request)?.title ?? request.seed.subject)
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.C.surface)
    }
}

// MARK: - Small shared states

struct Busy: View {
    let text: String
    var body: some View {
        VStack(spacing: Theme.M.pad) {
            ProgressView().tint(Theme.C.accent)
            Text(text).font(Theme.F.note).foregroundStyle(Theme.C.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Trouble: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            ModuleLabel(text: "Stuck")
            Text(message).font(Theme.F.body).foregroundStyle(Theme.C.ink)
            MainButton(title: "Try again", action: retry)
            Spacer()
        }
        .padding(Theme.M.gap)
    }
}

/// Sessions out for grading, and the ones that have come back.
struct GradingPanel: View {
    @Bindable var store: Store

    var body: some View {
        if !store.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ModuleLabel(text: "Feedback")
                VStack(spacing: 0) {
                    ForEach(store.jobs.reversed()) { job in
                        row(job)
                    }
                }
            }
        }
    }

    /// The language only once there is more than one out.
    private func status(_ job: GradingJob) -> String {
        let mixed = Set(store.jobs.map(\.language)).count > 1
        return (mixed ? "\(job.language.flag) " : "") + store.status(of: job)
    }

    private func row(_ job: GradingJob) -> some View {
        let ready = store.canRead(job) && job.state == .done
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(job.mode.name.uppercased())
                .font(Theme.F.label).tracking(1)
                .foregroundStyle(ready ? Theme.C.accent : Theme.C.ink3)
                .frame(width: 84, alignment: .leading)
            Text(status(job))
                .font(Theme.F.bodyTight)
                .foregroundStyle(Theme.C.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if store.hasFailures(job) {
                TinyButton(title: "Retry") { store.regrade(job) }
            }
            if job.batchID == nil, !store.sendingNow.contains(job.id) {
                TinyButton(title: "Send now") { Task { await store.sendNow(job) } }
            }
            if ready {
                TinyButton(title: "Read") { store.read(job) }
            } else if job.state == .grading {
                ProgressView(value: Double(job.graded), total: Double(max(job.total, 1)))
                    .tint(Theme.C.accent)
                    .frame(width: 60)
            }
        }
        .padding(Theme.M.padTight)
        .background(Theme.C.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(ready ? Theme.C.accent : Theme.C.seam2).frame(width: Theme.M.edge)
        }
        .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
    }
}
