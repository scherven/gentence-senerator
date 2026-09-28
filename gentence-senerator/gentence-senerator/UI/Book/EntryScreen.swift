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
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BookPageHeader(back: chapter.name, title: "")
                head(entry, chapter, state, point: point, source: source, asked: asked, noted: noted)
                if let point { rule(point) }
                own(noted: noted, source: source)
                if let question = asked.first?.question ?? source?.question, !question.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        GroupLabel(text: "Asked")
                        Text(question).font(Theme.F.bodyTight)
                            .padding(.horizontal, Theme.M.pad).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(Rectangle().strokeBorder(Theme.C.seam2,
                                                              style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }
                }
                actions(entry, chapter, point: point, source: source)
            }
            .padding(.horizontal, Theme.M.gap)
            .padding(.top, Theme.M.gapTight)
            .padding(.bottom, Theme.M.gap)
        }
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
                    Text(entry.head).font(.system(size: entry.head.count > 10 ? 24 : 34, weight: .medium))
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
                Text(gloss).font(.system(size: 14)).foregroundStyle(Theme.C.ink2)
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

    private func rule(_ point: GrammarPoint) -> some View {
        let request = store.ruleRequest(for: point)
        let lesson = store.lesson(for: request)
        return VStack(alignment: .leading, spacing: 8) {
            GroupLabel(text: "Rule")
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
                        Button { store.open(seed: request.seed, kind: request.kind) } label: {
                            Text("LESSON ›").font(Theme.F.meta).foregroundStyle(Theme.C.accent)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text(store.ruleSaved[request.cacheKey].map { "SAVED \(day($0))" } ?? "SAVED")
                            .font(Theme.F.label).foregroundStyle(Theme.C.ink3)
                    }
                    .padding(.top, 8)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.C.seam).frame(height: Theme.M.hair) }
                } else if loading || store.isLoading(request) {
                    HStack(spacing: Theme.M.gapTight) {
                        ProgressView().tint(Theme.C.accent)
                        Text("Writing…").font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                    }
                } else {
                    Text(point.instruction).font(.system(size: 14))
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
            .padding(Theme.M.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.C.surface)
            .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
        }
    }

    // MARK: The learner's own

    @ViewBuilder
    private func own(noted: [Textbook.Noted], source: Textbook.Entry?) -> some View {
        let lines: [(you: String, fix: String)] = noted.isEmpty
            ? (source?.sentence).map { [($0, source?.atom?.stages.fix ?? "")] } ?? []
            : noted.prefix(5).map { ($0.sentence, $0.atom.stages.fix) }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                GroupLabel(text: "Yours")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 3) {
                            mark("YOU", line.you, Theme.C.bad)
                            if !line.fix.isEmpty { mark("FIX", line.fix, Theme.C.good) }
                        }
                    }
                }
                .padding(Theme.M.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.C.surface)
                .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
            }
        }
    }

    private func mark(_ label: String, _ text: String, _ colour: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(Theme.F.label).foregroundStyle(colour).frame(width: 26, alignment: .leading)
            Text(text).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ entry: Chapter.Entry, _ chapter: Chapter,
                         point: GrammarPoint?, source: Textbook.Entry?) -> some View {
        HStack(spacing: 8) {
            if !chapter.formats.isEmpty {
                Button { startQuiz(Store.speedRound(for: chapter)) } label: {
                    label("PRACTICE", fill: true)
                }
                .buttonStyle(BookKeyStyle(edge: Theme.C.ink, fill: Theme.C.accent))
            } else if let source {
                // Noted: nothing to quiz, so the lesson it came from.
                Button { store.open(source) } label: { label("LESSON", fill: true) }
                    .buttonStyle(BookKeyStyle(edge: Theme.C.ink, fill: Theme.C.accent))
            }
            if let point {
                let asked = store.isRequested(point: point.id)
                Button { store.requestTomorrow(point: point.id) } label: {
                    label(asked ? "TOMORROW ✓" : "ASK FOR IT TOMORROW", fill: false)
                }
                .buttonStyle(BookKeyStyle(unseen: false, edge: Theme.C.ink, fill: Theme.C.ground))
                .disabled(asked)
            }
        }
    }

    private func label(_ text: String, fill: Bool) -> some View {
        Text(text)
            .font(Theme.F.meta.weight(.medium)).tracking(1)
            .foregroundStyle(fill ? Theme.C.onAccent : Theme.C.ink)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity).frame(height: 48)
    }

    private func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated)).uppercased()
    }
}
