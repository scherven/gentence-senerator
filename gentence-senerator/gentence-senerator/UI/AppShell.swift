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

    var body: some View {
        Group {
            switch store.phase {
            case .idle:
                start
            case .preparing:
                Busy(text: "Writing something for you…")
            case .ready, .recording:
                attempt
            case .confirming:
                confirm
            case .transcribing:
                Busy(text: "Writing down what you said…")
            case .assessing:
                Busy(text: store.settings.mode == .produce
                     ? "Reading the whole exchange…"
                     : "Looking at what you said…")
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
                    TinyButton(title: "End") { store.endSession() }
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
        return store.settings.mode.name
    }

    private var progressLabel: String {
        guard let session = store.session else { return "" }
        return session.endless
            ? "\(session.completedCount)"
            : "\(session.completedCount)/\(session.goal)"
    }

    // MARK: Phases

    private var start: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            ModuleLabel(text: "Practice · \(store.pack.level(store.settings.level))")
            ForEach(Mode.allCases) { mode in
                Button { Task { await store.begin(mode) } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mode.name).font(Theme.F.title)
                        Text(mode.blurb).font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.M.pad)
                    .background(Theme.C.surface)
                    .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(Theme.M.gap)
    }

    private var attempt: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            if let stretch = store.stretch, store.settings.mode == .produce {
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
            } else if store.settings.prefersTyping {
                VStack(alignment: .leading, spacing: Theme.M.gapTight) {
                    TextField("Type it…", text: $typing, axis: .vertical)
                        .font(Theme.F.target)
                        .textFieldStyle(.plain)
                        .targetLanguageInput()
                        .lineLimit(2...5)
                        .padding(Theme.M.pad)
                        .background(Theme.C.sunk)
                        .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
                    MainButton(title: "Review", enabled: !typing.isEmpty) {
                        store.typed(typing); typing = ""
                    }
                }
            } else {
                MainButton(title: "Speak") { store.startRecording() }
                TinyButton(title: "Type instead") { store.settings.prefersTyping = true }
            }
            Spacer()
        }
        .padding(Theme.M.gap)
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
                                    }
                                    Spacer()
                                    TinyButton(title: "Hear") { store.say(target) }
                                }
                            }
                            if let english = turn.prompt.english, store.settings.mode != .listen {
                                Text(english).font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                            }
                            if store.settings.mode == .listen {
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
                    knowledge: store.knowledge,
                    onOpenAtom: { store.open($0) },
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
                    ask: turn.review?.ask ?? [],
                    answers: store.asked[turn.id.uuidString] ?? [],
                    isAsking: store.asking.contains(turn.id.uuidString)
                )
                MainButton(title: "Next") { Task { await store.advance() } }
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            ModuleLabel(text: "Done for today")
            if let session = store.session {
                Text("\(session.completedCount) attempts · average \(session.averageScore)")
                    .font(Theme.F.body)
            }
            MainButton(title: "Keep going") { Task { await store.keepGoing() } }
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
                    onOpenAtom: { store.open($0) },
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
