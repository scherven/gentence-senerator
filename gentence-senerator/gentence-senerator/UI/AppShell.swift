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
            QuizScreen(store: store, plan: plan)
        }
        // Reading a review, from a tapped push or History, happens on Today.
        .onChange(of: store.reading.isEmpty) { _, idle in
            guard !idle else { return }
            // The tab left behind keeps its lessons; an open quiz stays up.
            if tab != .today {
                if let before = store.pathBeforeTap { paths[tab] = before }
                tab = .today
            }
            store.pathBeforeTap = nil
        }
        .onChange(of: quiz?.id) { _, open in store.quizOpen = open != nil }
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
                ModeScreen(store: store, openEntry: openEntry)
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

    /// A book entry, opened from Today: Today's lessons are set aside and the
    /// Book tab opens on the entry, its chapter underneath.
    private func openEntry(chapter: String, entry: String) {
        paths[tab] = store.path
        store.path = []
        bookRoutes = [.chapter(chapter), .entry(chapter: chapter, entry: entry)]
        tab = .book
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
    /// Opens a book entry on the Book tab: chapter id, entry id.
    var openEntry: (String, String) -> Void = { _, _ in }
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
                    } else if store.phase != .complete {
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
        if store.phase == .complete { return "\(session.completedCount)/\(session.goal)" }
        return "\(Store.turnNumber(session: session, current: store.current))/\(session.goal)"
    }

    // MARK: Phases

    private var start: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                produceKey
                HStack(alignment: .top, spacing: 10) {
                    modeKey(.translate)
                    modeKey(.listen)
                }
                WrittenToday(store: store)
                GradingPanel(store: store)
                RecommendedRound(store: store)
                PlanView(plan: store.plan)
            }
            .padding(Theme.M.gap)
        }
    }

    /// Next undone: accent. Done: flush. Otherwise a plain key.
    private func variant(_ mode: Mode) -> KeyStyle.Variant {
        store.isDone(mode) ? .spent : store.nextMode == mode ? .primary : .neutral
    }

    private func spentStamp(_ mode: Mode) -> some View {
        Stamp(mode == .listen ? "Done" : "Sent", colour: Theme.C.good, size: 10)
    }

    /// Produce carries the day: first, larger, with what it is made of.
    private var produceKey: some View {
        let tally = store.tally(.produce)
        let spent = store.isDone(.produce)
        let words = store.plan.words.have + store.plan.words.new
        return Button { Task { await store.begin(.produce) } } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Mode.produce.name).font(Theme.F.serif(22, bold: true))
                    Spacer()
                    if spent { spentStamp(.produce) }
                    else { Text("\(tally.done)/\(tally.goal) ›").font(Theme.F.meta) }
                }
                if !spent, store.plan.stretch != nil || !words.isEmpty {
                    Flow(spacing: 6, lineSpacing: 6) {
                        if let stretch = store.plan.stretch {
                            Ingredient(text: stretch.name, caps: true)
                                .onTapGesture { openStretch(stretch) }
                                .accessibilityAddTraits(.isButton)
                        }
                        ForEach(words, id: \.self) { Ingredient(text: $0) }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(KeyStyle(variant(.produce)))
        .disabled(spent)
    }

    private func modeKey(_ mode: Mode) -> some View {
        let tally = store.tally(mode)
        let spent = store.isDone(mode)
        return Button { Task { await store.begin(mode) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center) {
                    Text(mode.name).font(Theme.F.cardTitle).lineLimit(1)
                    Spacer(minLength: 4)
                    if spent { spentStamp(mode) }
                    else { Text("\(tally.done)/\(tally.goal)").font(Theme.F.meta).opacity(0.75) }
                }
                if mode == .listen, !spent, let held = store.heldPassage {
                    Text(held.passage.title).font(Theme.F.note).opacity(0.75).lineLimit(1)
                }
            }
            .padding(Theme.M.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(KeyStyle(variant(mode)))
        .disabled(spent)
    }

    /// The stretch's book entry; its lesson if the book has none.
    private func openStretch(_ point: GrammarPoint) {
        if let at = store.bookEntry(for: point.id) {
            openEntry(at.chapter, at.entry)
        } else {
            store.openLesson(for: point)
        }
    }

    /// What this produce answer can be made of, each ticked once the answer
    /// uses it. The stretch only on the prompt written for it.
    @ViewBuilder
    private var chips: some View {
        let answer = store.phase == .recording ? store.draft : typing
        let language = store.current?.language ?? store.settings.language
        let stretch = store.stretch.flatMap { $0.id == store.current?.prompt.pointID ? $0 : nil }
        let words = store.plan.words.have + store.plan.words.new
        if stretch != nil || !words.isEmpty {
            Flow(spacing: 6, lineSpacing: 6) {
                if let stretch {
                    Ingredient(text: stretch.name, caps: true,
                               used: store.markers(of: stretch).contains {
                                   Store.uses($0, in: answer, language: language)
                               })
                }
                ForEach(words, id: \.self) { word in
                    Ingredient(text: word, used: Store.uses(word, in: answer, language: language))
                }
            }
            .foregroundStyle(Theme.C.ink2)
        }
    }

    private var attempt: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                prompt

                if store.settings.mode == .produce { chips }

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
                            .lineLimit(store.settings.mode == .produce ? 5...12 : 2...5)
                            .frame(minHeight: store.settings.mode == .produce ? 140 : nil,
                                   alignment: .topLeading)
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

    /// The prompt, set back, above an answer being checked.
    @ViewBuilder
    private var dimmedPrompt: some View {
        if let turn = store.current {
            let english = turn.mode == .translate || turn.prompt.target == nil
            if let text = english ? turn.prompt.english : turn.prompt.target {
                Panel(fill: Theme.C.raised) {
                    Text(text)
                        .font(english ? Theme.F.body : Theme.F.targetSmall)
                        .foregroundStyle(Theme.C.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            dimmedPrompt
            TextField("", text: $store.draft, axis: .vertical)
                .font(Theme.F.target)
                .textFieldStyle(.plain)
                .targetLanguageInput()
                .lineLimit(store.current?.mode == .produce ? 4...10 : 2...6)
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
                let said = turn.attempt.confirmed
                let reference = turn.prompt.reference ?? ""
                // Where the two part ways. Not a verdict.
                let apart = Store.divergence(said, reference, language: turn.language)
                Text(turn.prompt.english ?? "").font(Theme.F.body)
                ModuleLabel(text: "You said")
                SpanMark(said, marks: apart.said.map { .init($0, colour: Theme.C.ink3) })
                if !reference.isEmpty {
                    ModuleLabel(text: "Ref")
                    Panel(fill: Theme.C.sunk, edge: Theme.C.seam2) {
                        HStack(alignment: .firstTextBaseline) {
                            SpanMark(reference, marks: apart.ref.map { .init($0, colour: Theme.C.carbon) },
                                     colour: Theme.C.carbon)
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
                    // Only what this session just sent.
                    let sent = store.justSent(session)
                    VStack(alignment: .leading, spacing: 6) {
                        ModuleLabel(text: "Sent",
                                    trailing: store.notificationsOn ? "\(sent.count)"
                                        : "\(sent.count) · notifications off")
                        WrittenRows(rows: sent.enumerated().map {
                            Store.Written(turn: $0.element, mode: session.mode, number: $0.offset + 1)
                        })
                    }
                }
            }
            HStack(spacing: 10) {
                ActionKey("Back", variant: .neutral) { store.endSession() }
                if let next = store.nextMode {
                    ActionKey("\(next.name) ›") {
                        store.endSession()
                        Task { await store.begin(next) }
                    }
                } else if store.dayComplete {
                    ActionKey("See the day ›") { store.endSession() }
                }
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
                let jobs = Array(store.todaysJobs.reversed())
                LedgerSheet {
                    ForEach(jobs) { job in
                        row(job, ruled: job.id != jobs.last?.id)
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

    private func row(_ job: GradingJob, ruled: Bool) -> some View {
        let ready = store.canRead(job) && job.state == .done
        return LedgerRow(account: job.mode.name, colour: ready ? Theme.C.accent : Theme.C.ink3,
                         edge: ready ? Theme.C.accent : nil, accountWidth: 84, ruled: ruled) {
            Text(status(job))
                .font(Theme.F.bodyTight)
                .foregroundStyle(Theme.C.ink)
        } trailing: {
            HStack(spacing: 6) {
                if store.hasFailures(job) {
                    TinyButton(title: "Retry") { store.regrade(job) }
                }
                if Store.showsSendNow(job, sending: store.sendingNow.contains(job.id)) {
                    TinyButton(title: "Send now") { Task { await store.sendNow(job) } }
                }
                if ready {
                    TypedLink("Read") { store.read(job) }
                } else if job.state == .grading {
                    SquareProgress(value: Double(job.graded), total: Double(max(job.total, 1)))
                        .frame(width: 60)
                }
            }
            .padding(.trailing, 10)
            .frame(maxHeight: .infinity)
        }
    }
}

/// One thing a produce answer is made of: the stretch (CAPS mono) or a word
/// in the language (target face, its own case, which `Tag` would lose). Ticked
/// once used. Takes the ink of the key it sits on.
struct Ingredient: View {
    let text: String
    var caps = false
    var used = false

    var body: some View {
        HStack(spacing: 4) {
            if used {
                Text("✓").font(Theme.F.mono(11, bold: true)).foregroundStyle(Theme.C.good)
            }
            Text(caps ? text.uppercased() : text)
                .font(caps ? Theme.F.label : Theme.F.target(size: 14))
                .tracking(caps ? Theme.M.caps : 0)
                .lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .overlay {
            Rectangle().strokeBorder(used ? AnyShapeStyle(Theme.C.good)
                                          : AnyShapeStyle(.foreground.opacity(0.6)),
                                     lineWidth: Theme.M.hair)
        }
    }
}

/// The learner's own sentences today, one ledger row each.
struct WrittenToday: View {
    let store: Store

    var body: some View {
        let rows = store.writtenToday
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ModuleLabel(text: "Written today")
                WrittenRows(rows: rows)
            }
        }
    }
}

/// Sentences as ledger rows: mode and number, the sentence, the time and, once
/// graded, the score.
struct WrittenRows: View {
    let rows: [Store.Written]

    var body: some View {
        LedgerSheet {
            ForEach(rows) { row in
                LedgerRow(account: "\(row.mode == .produce ? "Prod" : "Trans") \(row.number)",
                          accountWidth: 76, ruled: row.id != rows.last?.id) {
                    Text(row.turn.attempt.confirmed)
                        .font(Theme.F.target(size: 15, for: row.turn.language))
                        .foregroundStyle(Theme.C.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } trailing: {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(row.turn.createdAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted))
                            .minute(.twoDigits)))
                            .font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                        if let score = row.turn.review?.score {
                            Text("\(score)").font(Theme.F.label).foregroundStyle(Theme.band(score))
                        }
                    }
                    .padding(.trailing, 10).padding(.vertical, 12)
                }
            }
        }
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
