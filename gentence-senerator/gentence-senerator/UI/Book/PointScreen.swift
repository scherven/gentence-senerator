import SwiftUI

/// One grammar point: where it stands, the entries that teach it, the rule,
/// and every result on it from every mode, newest first.
struct PointScreen: View {
    @Bindable var store: Store
    let pointID: String
    var back = "Book"
    /// The entry it was opened from, marked among the entries.
    var focus: String? = nil
    @Environment(\.startQuiz) private var startQuiz
    @State private var loading = false
    @State private var all = false

    var body: some View {
        Group {
            if let point = store.point(pointID) { page(point) } else { Busy(text: "") }
        }
        .background(Theme.C.ground)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func page(_ point: GrammarPoint) -> some View {
        let state = store.pointState(point.id)
        let entries = store.entries(of: point.id)
        let record = store.learner.point(point.id, store.settings.language)
        let results = store.learner.results(point.id, store.settings.language)
        let asked = store.asked(point: point.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                head(point, state)
                tally(record, entries: entries)
                if !entries.isEmpty { chips(entries) }
                rule(point)
                if !results.isEmpty { feed(results) }
                if let question = asked.first?.question, !question.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ModuleLabel(text: "Asked")
                        Panel {
                            Text(question).font(Theme.F.bodyTight)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                actions(point, entries: entries)
            }
            .padding(.horizontal, Theme.M.gap)
            .padding(.top, 14)
            .padding(.bottom, Theme.M.gap)
        }
        .pageHeader(.back(back))
    }

    // MARK: Head

    private func head(_ point: GrammarPoint, _ state: EntryState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(point.name).font(Theme.F.title).foregroundStyle(Theme.C.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let example = point.examples.first {
                Text(example).font(Theme.F.targetSmall)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Flow(spacing: 8, lineSpacing: 6) {
                BookTag(text: store.pack.level(point.level))
                BookTag(text: state.label, colour: state.slipping ? Theme.C.bad : Theme.C.ink)
                if let back = store.pointReturns(point) {
                    BookTag(text: back == "held" ? "HELD" : "BACK \(back.uppercased())",
                            colour: Theme.C.accent)
                }
            }
        }
    }

    // MARK: Record

    /// Sentences, and the quiz ticks across its entries.
    @ViewBuilder
    private func tally(_ record: LearnerRecord.PointRecord,
                       entries: [(chapter: Chapter, entry: Chapter.Entry)]) -> some View {
        let said = record.uses
        let clean = said.filter { $0.verdict == .clean }.count
        let quiz = record.quiz.isEmpty
            ? entries.flatMap { store.quizLog.state(of: $0.entry.id).recent }
            : record.quiz.map(\.right)
        if !said.isEmpty || !quiz.isEmpty {
            LedgerSheet {
                LedgerRow(account: "Said", accountWidth: 64, ruled: true) {
                    Text(said.isEmpty ? "—" : "\(said.count) · \(clean) clean")
                        .font(Theme.F.meta).foregroundStyle(Theme.C.ink)
                }
                LedgerRow(account: "Quiz", accountWidth: 64, ruled: false) {
                    if quiz.isEmpty {
                        Text("—").font(Theme.F.meta).foregroundStyle(Theme.C.ink)
                    } else {
                        Ticks(recent: Array(quiz.suffix(8)))
                    }
                }
            }
        }
    }

    private func chips(_ entries: [(chapter: Chapter, entry: Chapter.Entry)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ModuleLabel(text: "Entries")
            Flow(spacing: 6, lineSpacing: 6) {
                ForEach(entries, id: \.entry.id) { pair in
                    let s = store.quizLog.state(of: pair.entry.id)
                    BookTag(text: pair.entry.head,
                            colour: s.slipping || s.recent.last == false ? Theme.C.bad
                                : pair.entry.id == focus ? Theme.C.accent : Theme.C.ink)
                }
            }
        }
    }

    // MARK: Rule

    private func rule(_ point: GrammarPoint) -> some View {
        let request = store.ruleRequest(for: point)
        let lesson = store.lesson(for: request)
        return IndexCard {
            VStack(alignment: .leading, spacing: 10) {
                if let lesson {
                    ForEach(lesson.blocks.filter { $0.kind == .rule || $0.kind == .contrast }) { block in
                        BlockView(block: block,
                                  onOpenLink: { store.open($0, context: request.seed.context) },
                                  onOpenSeed: { store.open(seed: $0, kind: $1) },
                                  onDrillOutcome: { _, _ in },
                                  grade: { await store.grade($0, against: $1) })
                    }
                    TypedLink("Lesson") { store.open(seed: request.seed, kind: request.kind) }
                } else if loading || store.isLoading(request) {
                    Ticker(text: "Writing")
                } else {
                    Text(point.instruction).font(Theme.F.bodyTight)
                        .fixedSize(horizontal: false, vertical: true)
                    TinyButton(title: "Write the rule") {
                        loading = true
                        Task {
                            await store.loadRule(request)
                            loading = false
                        }
                    }
                }
            }
        }
    }

    // MARK: Results

    private func feed(_ results: [LearnerRecord.Result]) -> some View {
        let shown = all ? results : Array(results.prefix(6))
        return VStack(alignment: .leading, spacing: 8) {
            ModuleLabel(text: "Results", trailing: "\(results.count)")
            LedgerSheet {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, result in
                    row(result, ruled: i < shown.count - 1)
                }
            }
            if results.count > shown.count {
                TypedLink("All \(results.count)") { all = true }
            }
        }
    }

    @ViewBuilder
    private func row(_ result: LearnerRecord.Result, ruled: Bool) -> some View {
        switch result {
        case .use(let u):
            let colour = colour(u.verdict)
            LedgerRow(account: u.verdict == .clean ? "Clean" : u.verdict == .weakens ? "Weak" : "Broke",
                      colour: colour, edge: colour, accountWidth: 64, ruled: ruled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(u.sentence).font(Theme.F.target(size: 15)).foregroundStyle(Theme.C.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if u.verdict != .clean, !u.fix.isEmpty {
                        Text("→ " + u.fix).font(Theme.F.target(size: 15)).foregroundStyle(Theme.C.good)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("\(u.mode.name) · \(day(u.at))").monoCaps(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                }
            }
        case .mark(let m):
            let colour = m.right ? Theme.C.good : Theme.C.bad
            LedgerRow(account: m.right ? "Quiz ✓" : "Quiz ✗", colour: colour, edge: colour,
                      accountWidth: 64, ruled: ruled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.prompt ?? m.answer).font(Theme.F.target(size: 15)).foregroundStyle(Theme.C.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !m.right {
                        Text("\(m.given.isEmpty ? "—" : m.given) → \(m.answer)")
                            .font(Theme.F.target(size: 15)).foregroundStyle(Theme.C.good)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(day(m.at)).monoCaps(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                }
            }
        }
    }

    private func colour(_ v: LearnerRecord.Verdict) -> Color {
        switch v {
        case .clean:   return Theme.C.good
        case .weakens: return Theme.C.warn
        case .breaks:  return Theme.C.bad
        }
    }

    // MARK: Actions

    private func actions(_ point: GrammarPoint,
                         entries: [(chapter: Chapter, entry: Chapter.Entry)]) -> some View {
        HStack(spacing: 8) {
            if let chapter = entries.first(where: { !$0.chapter.formats.isEmpty })?.chapter {
                ActionKey("Practice") { startQuiz(Store.speedRound(for: chapter)) }
            }
            let asked = store.isRequested(point: point.id)
            ActionKey(asked ? "Tomorrow ✓" : "Ask for it tomorrow", variant: .neutral,
                      enabled: !asked) { store.requestTomorrow(point: point.id) }
        }
    }

    private func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated)).uppercased()
    }
}
