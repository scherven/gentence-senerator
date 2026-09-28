import SwiftUI

/// Full-screen runner for one plan, then its result. Present as a
/// `fullScreenCover`. `openChapter` makes the misses link to their chapter;
/// the screen dismisses itself first.
struct QuizScreen: View {
    let store: Store
    let plan: QuizPlan
    var openChapter: ((Chapter) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var round: QuizRound
    @State private var index = 0
    @State private var shownAt = Date.now
    @State private var finished = false
    /// Chapter id → entries holding or better, when the round began.
    @State private var before: [String: Int]

    init(store: Store, plan: QuizPlan, openChapter: ((Chapter) -> Void)? = nil) {
        self.store = store
        self.plan = plan
        self.openChapter = openChapter
        let r = store.round(for: plan)
        _round = State(initialValue: r)
        _before = State(initialValue: Self.held(store, r))
    }

    var body: some View {
        Group {
            if finished {
                QuizResultView(round: round, record: store.record(of: plan), book: store.book,
                               chapters: chapters.map { ($0, before[$0.id] ?? 0, store.held(in: $0)) },
                               again: again, done: { dismiss() },
                               openChapter: openChapter.map { open in { ch in dismiss(); open(ch) } })
            } else if round.items.isEmpty {
                VStack(spacing: Theme.M.gap) {
                    Text("No items.").font(Theme.F.body).foregroundStyle(Theme.C.ink2)
                    TinyButton(title: "Done") { dismiss() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                runner
            }
        }
        .background(Theme.C.ground.ignoresSafeArea())
    }

    // MARK: Runner

    private var item: QuizItem { round.items[index] }
    private var revealed: QuizRound.Answer? { round.answers[index] }

    private var runner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { quit() } label: {
                    Text("✕").font(.system(size: 18, design: .monospaced)).foregroundStyle(Theme.C.ink)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quit")
                Spacer()
                Text("\(index + 1) / \(round.items.count)").font(.system(size: 13, design: .monospaced))
                Spacer()
                Text("×\(round.streak)").font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.C.accent)
            }
            ticks
            timer
            QuizFormatView(context: QuizFormatContext(
                item: item, revealed: revealed,
                answer: { answer($0) },
                speak: { store.speakQuiz($0) }))
                .id(item.id)
                .padding(.top, 36)
                .frame(maxHeight: .infinity, alignment: .top)
            footer.frame(height: 44)
        }
        .padding(.horizontal, Theme.M.gap)
        .padding(.top, 8)
    }

    private var ticks: some View {
        HStack(spacing: 2) {
            ForEach(round.answers.indices, id: \.self) { i in
                Rectangle()
                    .fill(round.answers[i].map { $0.right ? Theme.C.good : Theme.C.bad }
                          ?? (i == index ? Theme.C.seam2 : Theme.C.raised))
                    .frame(height: 6)
            }
        }
    }

    /// Runs down over the format's par. Pressure only; running out scores
    /// nothing.
    private var timer: some View {
        TimelineView(.animation(paused: revealed != nil)) { t in
            let left = max(0, 1 - t.date.timeIntervalSince(shownAt) / Self.par(item.format))
            GeometryReader { g in
                Rectangle().fill(Theme.C.raised)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(left < 0.2 ? Theme.C.bad : Theme.C.ink)
                            .frame(width: g.size.width * left)
                    }
            }
            .frame(height: 3)
        }
    }

    @ViewBuilder private var footer: some View {
        if let r = revealed {
            Button { next() } label: {
                HStack {
                    Text(r.right ? "" : (item.why ?? ""))
                    Spacer()
                    Text("NEXT ›")
                }
                .font(Theme.F.meta)
                .foregroundStyle(Theme.C.ink2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Flow

    private func answer(_ a: QuizRound.Answer) {
        guard round.answers[index] == nil else { return }
        round.answer(index, a)
        if item.format == .toneTap, let s = item.speak, !a.right { store.speakQuiz(s) }
        guard a.right else { return }
        let at = index
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            if index == at, !finished { next() }
        }
    }

    private func next() {
        guard revealed != nil else { return }
        if index + 1 < round.items.count {
            index += 1
            shownAt = .now
        } else {
            store.finish(round)
            finished = true
        }
    }

    private func quit() {
        if round.answered > 0, !finished { store.finish(round) }
        dismiss()
    }

    private func again() {
        round = store.round(for: plan)
        before = Self.held(store, round)
        index = 0
        shownAt = .now
        finished = false
    }

    // MARK: Chapters

    private var chapters: [Chapter] { Self.chapters(store.book, round) }

    private static func chapters(_ book: Book, _ round: QuizRound) -> [Chapter] {
        let ids = round.plan.chapters.isEmpty
            ? round.items.compactMap { book.chapter(of: $0.entry)?.id }
            : round.plan.chapters
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }.compactMap { book.chapter($0) }
    }

    private static func held(_ store: Store, _ round: QuizRound) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: chapters(store.book, round).map { ($0.id, store.held(in: $0)) })
    }

    static func par(_ f: QuizFormat) -> TimeInterval {
        switch f {
        case .flip:      return 4
        case .pickOne:   return 6
        case .twoStep, .toneTap: return 10
        case .spotIt:    return 12
        case .build:     return 25
        case .sort, .transform: return 30
        }
    }
}
