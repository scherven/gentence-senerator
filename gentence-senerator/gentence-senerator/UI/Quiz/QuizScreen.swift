import SwiftUI

/// Full-screen runner for one plan, then its result. Present as a
/// `fullScreenCover`. `openEntry` makes each miss link to its entry page; the
/// screen dismisses itself first.
struct QuizScreen: View {
    let store: Store
    /// What was started. ∞ on a words round swaps in an endless plan.
    @State private var plan: QuizPlan
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
        _plan = State(initialValue: plan)
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

    private func entry(of item: QuizItem) -> Chapter.Entry? {
        store.book.chapter(of: item.entry)?.entries.first { $0.id == item.entry }
    }

    private var item: QuizItem { round.items[index] }
    private var revealed: QuizRound.Answer? { round.answers[index] }

    private var runner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { quit() } label: {
                    Text(plan.endless ? "STOP" : "✕").font(Theme.F.mono(plan.endless ? 12 : 16, bold: plan.endless))
                        .foregroundStyle(Theme.C.ink)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressDim())
                .accessibilityLabel(plan.endless ? "Stop" : "Quit")
                Spacer()
                Text(counter).font(Theme.F.mono(13))
                Spacer()
                if VocabDrill.isVocab(plan) {
                    Button { goEndless() } label: {
                        Text("∞").font(Theme.F.mono(16, bold: true))
                            .frame(width: 44, height: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressDim())
                    .accessibilityLabel("Keep going without an end")
                } else {
                    Text("×\(round.streak)").font(Theme.F.mono(13))
                        .foregroundStyle(Theme.C.accent)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .foregroundStyle(Theme.C.ink)
            ribbon
            timer
            QuizFormatView(context: QuizFormatContext(
                item: item, revealed: revealed,
                answer: { answer($0) },
                speak: { store.speakQuiz($0) },
                entryGloss: entry(of: item)?.gloss,
                structure: QuizRound.structure(of: entry(of: item)?.head),
                rule: note(item)))
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
        HStack {
            // Words only, before the mark: away for months.
            if isWord(item), revealed == nil {
                TinyButton(title: "Knew it") { knewIt() }
            }
            if revealed != nil {
                Button { next() } label: {
                    HStack {
                        Spacer()
                        Text("NEXT ›").font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressDim())
            } else {
                Spacer()
            }
        }
    }

    /// Counts as right, keeps the word away for months, moves on.
    private func knewIt() {
        if round.answers[index] == nil {
            round.answer(index, QuizRound.Answer(steps: [true], given: ["knew it"]))
        }
        store.markKnown(item.entry)
        next()
    }

    /// The item's own `why`, else the entry it tests.
    private func note(_ item: QuizItem) -> String {
        item.why ?? entry(of: item)?.head ?? ""
    }

    // MARK: Flow

    private func isWord(_ item: QuizItem) -> Bool { item.entry.hasPrefix("vocab.") }

    /// `3 / 20`; endless: answered and the share right.
    private var counter: String {
        guard plan.endless else { return "\(index + 1) / \(round.items.count)" }
        let n = round.answered
        return n == 0 ? "0" : "\(n) · \(Int((Double(round.right) / Double(n) * 100).rounded()))%"
    }

    /// Endless shows the last twenty.
    private var ribbon: some View {
        let start = plan.endless ? max(0, index - 19) : 0
        let end = plan.endless ? min(round.items.count, start + 20) : round.items.count
        return QuizRibbon(answers: round.answers[start..<end].map { $0?.right }, current: index - start)
    }

    private func answer(_ a: QuizRound.Answer) {
        guard round.answers[index] == nil else { return }
        round.answer(index, a)
        if plan.endless {
            store.recordEndless(item, a)
            // A miss comes back a few items on.
            if !a.right { round.again(index, after: Int.random(in: 4...7)) }
        }
        if item.format == .toneTap, let s = item.speak, !a.right { store.speakQuiz(s) }
        // A card was just read and marked: nothing more to show.
        if item.format == .card { next(); return }
        guard a.right else { return }
        let at = index
        Task {
            // Long enough to read the rule.
            try? await Task.sleep(for: .milliseconds(note(item).isEmpty ? 650 : 1400))
            if index == at, !finished { next() }
        }
    }

    private func next() {
        guard revealed != nil else { return }
        if plan.endless, index + 4 >= round.items.count {
            round.append(store.more(for: plan, after: round))
        }
        if index + 1 < round.items.count {
            index += 1
            shownAt = .now
        } else {
            store.finish(round)
            finished = true
        }
    }

    private func quit() {
        if plan.endless, round.answered > 0 { finished = true; return }
        if round.answered > 0, !finished { store.finish(round) }
        dismiss()
    }

    /// ∞ on a words round: what's answered is recorded, the rest carries on
    /// with no end.
    private func goEndless() {
        guard !plan.endless else { return }
        for (item, answer) in zip(round.items, round.answers) {
            if let answer { store.recordEndless(item, answer) }
        }
        plan = store.endlessPlan(QuizPlan.Mix(words: true))
        let rest = min(revealed == nil ? index : index + 1, round.items.count)
        var next = QuizRound(plan: plan, items: Array(round.items[rest...]))
        next.append(store.more(for: plan, after: next))
        round = next
        index = 0
        shownAt = .now
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
        case .card:      return 6
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
