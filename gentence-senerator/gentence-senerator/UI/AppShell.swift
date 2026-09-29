import SwiftUI

/// The whole app: three tabs. Lessons ride on `store.path`, which belongs to
/// whichever tab is showing; each tab's is set aside while another is up.
struct AppShell: View {
    @State var store: Store
    @State private var tab: RootTab = .today
    @State private var paths: [RootTab: [LessonRequest]] = [:]
    @State private var bookRoutes: [BookRoute] = []
    @State private var quiz: QuizPlan?

    var body: some View {
        VStack(spacing: 0) {
            tabs
            // A sitting runs uninterrupted.
            if showsTabs { TabBar(tab: tabBinding) }
        }
        .tint(Theme.C.accent)
        .paper()
        // Scrolling content never shows through the status bar.
        .overlay(alignment: .top) {
            Theme.C.ground.frame(height: 0).ignoresSafeArea(edges: .top)
        }
        .environment(\.startQuiz) { quiz = $0 }
        .fullScreenCover(item: $quiz) { plan in
            QuizScreen(store: store, plan: plan) { chapter, entry in
                // A miss opens its entry on the Book tab, from wherever the round began.
                if tab != .book {
                    paths[tab] = store.path
                    tab = .book
                }
                store.path = []
                bookRoutes = [.chapter(chapter), .entry(chapter: chapter, entry: entry)]
            }
        }
        // Reading a review, from a tapped push or History, happens on Today.
        .onChange(of: store.reading.isEmpty) { _, idle in
            if !idle {
                quiz = nil
                if tab != .today { paths[tab] = nil; tab = .today }
            }
        }
        .onChange(of: store.settings.language) { bookRoutes = [] }
        .onChange(of: store.settings.language, initial: true) { _, language in
            ThemeState.shared.language = language
        }
    }

    @ViewBuilder
    private var tabs: some View {
        switch tab {
        case .today:
            NavigationStack(path: $store.path) {
                ModeScreen(store: store)
                    .navigationDestination(for: LessonRequest.self) { request in
                        LessonHost(store: store, request: request)
                    }
            }
        case .book:
            NavigationStack(path: bookPath) {
                BookScreen(store: store)
                    .navigationDestination(for: BookRoute.self) { route in
                        switch route {
                        case .chapter(let id):
                            ChapterScreen(store: store, chapterID: id)
                        case .entry(let chapter, let entry):
                            EntryScreen(store: store, chapterID: chapter, entryID: entry)
                        case .lesson(let request):
                            LessonHost(store: store, request: request)
                        }
                    }
            }
        case .history:
            NavigationStack {
                HistoryScreen(store: store)
            }
        }
    }

    private var showsTabs: Bool {
        if tab != .today { return true }
        if case .idle = store.phase { return true }
        return false
    }

    /// Switching sets the outgoing tab's lessons aside and brings back the
    /// incoming one's.
    private var tabBinding: Binding<RootTab> {
        Binding(get: { tab }, set: { next in
            guard next != tab else {
                // The tab you are on goes back to its top.
                store.path = []
                if next == .book { bookRoutes = [] }
                return
            }
            paths[tab] = store.path
            store.path = paths[next] ?? []
            tab = next
        })
    }

    /// Book pages below, lessons above.
    private var bookPath: Binding<[BookRoute]> {
        Binding(get: { bookRoutes + store.path.map(BookRoute.lesson) }, set: { routes in
            let cut = routes.firstIndex { if case .lesson = $0 { true } else { false } } ?? routes.count
            bookRoutes = Array(routes[..<cut])
            let lessons: [LessonRequest] = routes[cut...].compactMap {
                if case .lesson(let request) = $0 { request } else { nil }
            }
            if lessons != store.path { store.path = lessons }
        })
    }
}

enum RootTab: Hashable, CaseIterable {
    case today, book, history

    var title: String {
        switch self {
        case .today: return "TODAY"
        case .book: return "BOOK"
        case .history: return "HISTORY"
        }
    }
}

/// Three typed words. The active one is underlined in the accent with an
/// I-beam caret after it.
struct TabBar: View {
    @Binding var tab: RootTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(RootTab.allCases, id: \.self) { item in
                let on = item == tab
                Button { tab = item } label: {
                    HStack(spacing: 4) {
                        Text(item.title)
                            .font(Theme.F.mono(12, bold: on))
                            .tracking(1.2)
                            .foregroundStyle(on ? Theme.C.ink : Theme.C.ink3)
                            .overlay(alignment: .bottom) {
                                if on {
                                    Rectangle().fill(Theme.C.accent).frame(height: 2).offset(y: 5)
                                }
                            }
                        Rectangle().fill(on ? Theme.C.accent : .clear).frame(width: 3, height: 11)
                    }
                    .padding(.leading, 7)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .background(Theme.C.ground.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.C.ink).frame(height: Theme.M.hair) }
    }
}

/// One screen for all three modes. The mode changes what is asked, not how the
/// attempt is made or how the review is read.
struct ModeScreen: View {
    @Bindable var store: Store
    @State private var typing = ""
    @State private var showingSettings = false
    /// The English is a fallback, not the prompt. Reading it first turns
    /// producing into translating.
    @State private var showGloss = false

    var body: some View {
        Group {
            switch store.phase {
            case .idle:
                if store.dayComplete { DayScreen(store: store) } else { start }
            case .preparing:
                Busy(text: "Writing prompts…")
            case .passage:
                PassageScreen(store: store)
            case .ready, .recording:
                attempt
            case .confirming:
                confirm
            case .transcribing:
                Busy(text: "Transcribing…")
            case .assessing:
                Busy(text: "Checking…")
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
        .background(Theme.C.ground)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .idle = store.phase {
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
        // A tapped push can start reading under an open sheet.
        .onChange(of: store.reading.isEmpty) { _, idle in
            if !idle { showingSettings = false }
        }
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
                            if mode == .listen, !spent, let held = store.heldPassage {
                                Text(held.passage.title)
                                    .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.M.pad)
                    }
                    .buttonStyle(KeyStyle())
                    .disabled(spent)
                }
                RecommendedRound(store: store)
                PlanView(plan: store.plan)
            }
            .padding(Theme.M.gap)
        }
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
                        Panel { Text(store.draft.isEmpty ? "…" : store.draft).font(Theme.F.target) }
                        MainButton(title: "Done") { store.stopRecording() }
                    }
                } else if store.settings.prefersTyping || store.speechTrouble != nil {
                    VStack(alignment: .leading, spacing: Theme.M.gapTight) {
                        if let trouble = store.speechTrouble {
                            Text(trouble)
                                .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                        }
                        TextField("Type it…", text: $typing, axis: .vertical)
                            .font(Theme.F.target)
                            .textFieldStyle(.plain)
                            .targetLanguageInput()
                            .lineLimit(2...5)
                            .inset()
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
            Panel(fill: Theme.C.sunk, edge: Theme.C.accent) {
                VStack(alignment: .leading, spacing: 6) {
                    if store.settings.mode == .translate {
                        Text(turn.prompt.english ?? "").font(Theme.F.target)
                    } else {
                        if let target = turn.prompt.target {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.M.pad) {
                                if store.settings.mode != .listen {
                                    Text(target).font(Theme.F.target)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                }
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
                            Text(store.hearingRealVoice ? "Human recording" : "Synthesised")
                                .font(Theme.F.label).foregroundStyle(Theme.C.ink3)
                        }
                    }
                }
            }
        }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            TextField("", text: $store.draft, axis: .vertical)
                .font(Theme.F.target)
                .textFieldStyle(.plain)
                .targetLanguageInput()
                .lineLimit(2...6)
                .inset()
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
                .padding(.horizontal, Theme.M.gap)
                .padding(.vertical, Theme.M.gapTight)
                .background(Theme.C.ground)
                .overlay(alignment: .top) { Rectangle().fill(Theme.C.ink).frame(height: Theme.M.hair) }
            }
        }
    }

    /// A translate answer, and one good way to say it. Not a grade: the
    /// review comes with the batch.
    private var reference: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            if let turn = store.current {
                Text(turn.prompt.english ?? "").font(Theme.F.body)
                ModuleLabel(text: "You said")
                Text(turn.attempt.confirmed).font(Theme.F.target)
                if let reference = turn.prompt.reference {
                    ModuleLabel(text: "Ref")
                    Panel(fill: Theme.C.sunk, edge: Theme.C.seam2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(reference).font(Theme.F.target)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            TinyButton(title: "Hear") { store.say(reference) }
                        }
                    }
                }
            }
            MainButton(title: "Next") { Task { await store.advance() } }
            Spacer()
        }
        .padding(Theme.M.gap)
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            if let session = store.session {
                if session.mode == .listen {
                    Text("\(session.completedCount) attempts · average \(session.averageScore)")
                        .font(Theme.F.body)
                } else {
                    let sent = session.open.filter { !$0.attempt.confirmed.isEmpty }.count
                    let count = "\(sent) answer\(sent == 1 ? "" : "s") sent for grading."
                    Text(store.notificationsOn ? count : "\(count) Notifications off.")
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
                Busy(text: "Writing the lesson…")
            }
        }
        .navigationTitle(store.lesson(for: request)?.title ?? request.seed.subject)
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.C.ground)
    }
}

// MARK: - Small shared states

struct Busy: View {
    let text: String
    var body: some View {
        VStack(spacing: Theme.M.pad) {
            Ticker(text: text.trimmingCharacters(in: CharacterSet(charactersIn: "…")))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Trouble: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            Text(message).font(Theme.F.body).foregroundStyle(Theme.C.ink)
            MainButton(title: "Try again", action: retry)
            Spacer()
        }
        .padding(Theme.M.gap)
    }
}

/// Today's sessions out for grading, and what came back today.
struct GradingPanel: View {
    @Bindable var store: Store

    var body: some View {
        if !store.todaysJobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ModuleLabel(text: "Feedback")
                VStack(spacing: 0) {
                    ForEach(store.todaysJobs.reversed()) { job in
                        row(job)
                    }
                }
            }
        }
    }

    /// The language only once there is more than one out.
    private func status(_ job: GradingJob) -> String {
        let mixed = Set(store.todaysJobs.map(\.language)).count > 1
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
                SquareProgress(value: Double(job.graded), total: Double(max(job.total, 1)))
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

/// The round the record says to do next. Absent when there is none.
struct RecommendedRound: View {
    let store: Store
    @Environment(\.startQuiz) private var startQuiz

    var body: some View {
        if let pick = store.recommended() {
            Button { startQuiz(pick.plan) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("SPEED ROUND · \(pick.plan.name.uppercased())")
                            .lineLimit(1)
                        Spacer()
                        Text("\(pick.plan.count) ›").foregroundStyle(Theme.C.accentOnInverse)
                    }
                    .font(Theme.F.label).tracking(1)
                    Text(pick.reason).font(Theme.F.meta).opacity(0.7)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, Theme.M.pad).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(KeyStyle(.inverse, perforated: true))
        }
    }
}
