import SwiftUI

/// Full-screen runner for one plan, then its result. Present as a
/// `fullScreenCover`. `openEntry` makes each miss link to its entry page; the
/// screen dismisses itself first.
struct QuizScreen: View {
    let store: Store
    let plan: QuizPlan
    /// Chapter id, entry id.
    var openEntry: ((String, String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var round: QuizRound
    @State private var index = 0
    @State private var shownAt = Date.now
    @State private var finished = false
    /// Chapter id → entries holding or better, when the round began.
    @State private var before: [String: Int]

    init(store: Store, plan: QuizPlan, openEntry: ((String, String) -> Void)? = nil) {
        self.store = store
        self.plan = plan
        self.openEntry = openEntry
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
                               openEntry: openEntry.map { open in
                                   { chapter, entry in dismiss(); open(chapter, entry) }
                               })
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
        .paper()
    }

    // MARK: Runner

    private var item: QuizItem { round.items[index] }
    private var revealed: QuizRound.Answer? { round.answers[index] }

    private var runner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { quit() } label: {
                    Text("✕").font(Theme.F.mono(16)).foregroundStyle(Theme.C.ink)
                        .frame(width: 44, height: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressDim())
                .accessibilityLabel("Quit")
                Spacer()
                Text("\(index + 1) / \(round.items.count)").font(Theme.F.mono(13))
                Spacer()
                Text("×\(round.streak)").font(Theme.F.mono(13))
                    .foregroundStyle(Theme.C.accent)
                    .frame(width: 44, alignment: .trailing)
            }
            .foregroundStyle(Theme.C.ink)
            QuizRibbon(answers: round.answers.map { $0?.right }, current: index)
            timer
            QuizFormatView(context: QuizFormatContext(
                item: item, revealed: revealed,
                answer: { answer($0) },
                speak: { store.speakQuiz($0) },
                entryGloss: store.book.chapter(of: item.entry)?
                    .entries.first { $0.id == item.entry }?.gloss))
                .id(item.id)
                .padding(.top, 36)
                .frame(maxHeight: .infinity, alignment: .top)
            // Holds its height before the answer too, so nothing jumps.
            ZStack { Color.clear; footer }.frame(height: 44)
        }
        .padding(.horizontal, Theme.M.gap)
        .padding(.top, 4)
    }

    /// A 1pt ink line under the ribbon, shortening over the format's par.
    /// Pressure only; running out scores nothing.
    private var timer: some View {
        TimelineView(.animation(paused: revealed != nil)) { t in
            let left = max(0, 1 - t.date.timeIntervalSince(shownAt) / Self.par(item.format))
            GeometryReader { g in
                Rectangle().fill(Theme.C.ink)
                    .frame(width: g.size.width * left, height: 1)
            }
            .frame(height: 1)
        }
        .accessibilityHidden(true)
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
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
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

/// The round as a ribbon of slugs: done ones filled good or bad, the I-beam
/// after the last one answered.
struct QuizRibbon: View {
    /// Nil until answered.
    let answers: [Bool?]
    let current: Int

    var body: some View {
        let caret = answers.lastIndex { $0 != nil }.map { $0 + 1 } ?? 0
        HStack(spacing: 2) {
            ForEach(answers.indices, id: \.self) { i in
                if i == caret { IBeam().padding(.horizontal, 1) }
                Rectangle()
                    .fill(answers[i].map { $0 ? Theme.C.good : Theme.C.bad } ?? Theme.C.raised)
                    .frame(height: 6)
            }
            if caret == answers.count { IBeam().padding(.horizontal, 1) }
        }
        .frame(height: 11)
        .accessibilityElement()
        .accessibilityLabel("\(answers.compactMap { $0 }.count) of \(answers.count) answered")
    }
}
