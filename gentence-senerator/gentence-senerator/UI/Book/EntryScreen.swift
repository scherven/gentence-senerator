import SwiftUI

/// One entry: the head, where it stands, the saved rule, and the learner's own
/// record with it.
struct EntryScreen: View {
    @Bindable var store: Store
    let chapterID: String
    let entryID: String
    @Environment(\.startQuiz) private var startQuiz
    @State private var loading = false

    var body: some View {
        let index = store.bookIndex
        Group {
            if let chapter = index.chapter(chapterID),
               let entry = chapter.entries.first(where: { $0.id == entryID }) {
                page(entry, chapter, index)
            } else {
                Busy(text: "")
            }
        }
        .background(Theme.C.ground)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func page(_ entry: Chapter.Entry, _ chapter: Chapter, _ index: Store.BookIndex) -> some View {
        let state = store.bookState(of: entry, in: index)
        let source = index.noted[entry.id]
        let point = store.point(entry.point)
        let noted = entry.point.map { store.noted(point: $0) } ?? []
        let asked = entry.point.map { store.asked(point: $0) } ?? []
        let uses = entry.point.map { store.uses(point: $0) } ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                head(entry, chapter, state, point: point, source: source, asked: asked, noted: noted)
                if let point { rule(point) }
                own(uses: uses, source: source)
                if let question = asked.first?.question ?? source?.question, !question.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ModuleLabel(text: "Asked")
                        Panel {
                            Text(question).font(Theme.F.bodyTight)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                actions(entry, chapter, point: point, source: source)
            }
            .padding(.horizontal, Theme.M.gap)
            .padding(.top, 14)
            .padding(.bottom, Theme.M.gap)
        }
        .pageHeader(.back(chapter.name))
    }

    // MARK: Head

    @ViewBuilder
    private func head(_ entry: Chapter.Entry, _ chapter: Chapter, _ state: EntryState,
                      point: GrammarPoint?, source: Textbook.Entry?,
                      asked: [Textbook.Suggestion], noted: [Textbook.Noted]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if chapter.layout == .formulas {
                let filled = entry.example.flatMap { Formula.filled(entry.head, with: $0) }
                FormulaView(parts: filled ?? Formula.parse(entry.head), size: 34)
                if filled == nil, let example = entry.example {
                    Text(example).font(Theme.F.targetSmall)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    let head = chapter.fullHead(entry)
                    Text(head).font(Theme.F.target(size: head.count > 10 ? 24 : 34, bold: true))
                        .fixedSize(horizontal: false, vertical: true)
                    if let tag = entry.tag {
                        BookTag(text: tag, colour: BookColour.tag(tag, among: BookColour.order(chapter.entries.map(\.tag))))
                    }
                }
                if let reading = entry.reading {
                    Text(reading).font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                }
                if let example = entry.example, source == nil {
                    Text(example).font(Theme.F.targetSmall)
                }
            }
            if let gloss = entry.gloss {
                Text(gloss).font(Theme.F.gloss).foregroundStyle(Theme.C.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Flow(spacing: 8, lineSpacing: 6) {
                if source == nil || point != nil { BookTag(text: store.pack.level(store.level(of: entry))) }
                BookTag(text: state.label, colour: state.slipping ? Theme.C.bad : Theme.C.ink)
                if let at = asked.first?.at ?? source?.suggestedAt {
                    BookTag(text: "FROM ASK · \(day(at))", colour: Theme.C.accent)
                }
                let times = max(noted.count, source?.noted ?? 0)
                if times > 0 { BookTag(text: "NOTED ×\(times)", colour: Theme.C.accent) }
            }
        }
    }

    // MARK: Rule

    /// The saved rule on an index card. The rule block carries its own label.
    private func rule(_ point: GrammarPoint) -> some View {
        let request = store.ruleRequest(for: point)
        let lesson = store.lesson(for: request)
        return IndexCard {
            Text(point.name).font(Theme.F.cardTitle).foregroundStyle(Theme.C.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(height: 24, alignment: .leading)
                .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 10) {
                if let lesson {
                    ForEach(lesson.blocks.filter { $0.kind == .rule || $0.kind == .contrast }) { block in
                        BlockView(block: block,
                                  onOpenLink: { store.open($0, context: request.seed.context) },
                                  onOpenSeed: { store.open(seed: $0, kind: $1) },
                                  onDrillOutcome: { _, _ in },
                                  grade: { await store.grade($0, against: $1) })
                    }
                    HStack {
                        TypedLink("Lesson") { store.open(seed: request.seed, kind: request.kind) }
                        Spacer()
                        Text(store.ruleSaved[request.cacheKey].map { "SAVED \(day($0))" } ?? "SAVED")
                            .font(Theme.F.label).foregroundStyle(Theme.C.ink3)
                    }
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

    // MARK: The learner's own

    /// The last three sentences that used the point, by verdict. A Noted
    /// entry without a point shows the sentence it came from.
    @ViewBuilder
    private func own(uses: [Textbook.Use], source: Textbook.Entry?) -> some View {
        let lines: [(sentence: String, clean: Bool, fix: String)] = uses.isEmpty
            ? (source?.sentence).map { [($0, false, source?.atom?.stages.fix ?? "")] } ?? []
            : uses.prefix(3).map { ($0.sentence, $0.clean, $0.fix) }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ModuleLabel(text: "Yours")
                LedgerSheet {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        let colour = line.clean ? Theme.C.good : Theme.C.bad
                        LedgerRow(account: line.clean ? "Clean" : "Broke", colour: colour,
                                  edge: colour, accountWidth: 64, ruled: i < lines.count - 1) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.sentence).font(Theme.F.target(size: 15))
                                    .foregroundStyle(Theme.C.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !line.clean, !line.fix.isEmpty {
                                    Text("→ " + line.fix).font(Theme.F.target(size: 15))
                                        .foregroundStyle(Theme.C.good)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ entry: Chapter.Entry, _ chapter: Chapter,
                         point: GrammarPoint?, source: Textbook.Entry?) -> some View {
        HStack(spacing: 8) {
            if !chapter.formats.isEmpty {
                ActionKey("Practice") { startQuiz(Store.speedRound(for: chapter)) }
            } else if let source {
                // Noted: nothing to quiz, so the lesson it came from.
                ActionKey("Lesson") { store.open(source) }
            }
            if let point {
                let asked = store.isRequested(point: point.id)
                ActionKey(asked ? "Tomorrow ✓" : "Ask for it tomorrow", variant: .neutral,
                          enabled: !asked) { store.requestTomorrow(point: point.id) }
            }
        }
    }

    private func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated)).uppercased()
    }
}
