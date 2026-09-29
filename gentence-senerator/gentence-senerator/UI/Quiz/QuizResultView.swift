import SwiftUI

struct QuizResultView: View {
    let round: QuizRound
    /// Already includes this round.
    let record: QuizLog.PlanRecord
    let book: Book
    /// Holding-or-better entries before and after, per chapter.
    let chapters: [(chapter: Chapter, before: Int, after: Int)]
    let again: () -> Void
    let done: () -> Void
    /// Chapter id, entry id.
    var openEntry: ((String, String) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stub
                // A mixed drill touches many chapters: only the ones that moved.
                ForEach(chapters.filter { chapters.count == 1 || $0.before != $0.after },
                        id: \.chapter.id) { change($0) }
                strip

                if !round.misses.isEmpty {
                    LedgerSheet {
                        ForEach(Array(round.misses.enumerated()), id: \.element.item.id) { i, miss in
                            row(miss.item, miss.answer, last: i == round.misses.count - 1)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.M.gap)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        // Nothing scrolls under the status bar.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 0).background(Theme.C.ground.ignoresSafeArea(edges: .top))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 10) {
                ActionKey("Again", action: again)
                ActionKey("Done", variant: .neutral, action: done)
            }
            .padding(.horizontal, Theme.M.gap)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Theme.C.ground.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(Theme.C.ink).frame(height: Theme.M.hair) }
        }
    }

    /// Entry head | wrong → right | ›, opening the entry.
    @ViewBuilder
    private func row(_ item: QuizItem, _ answer: QuizRound.Answer, last: Bool) -> some View {
        let chapter = book.chapter(of: item.entry)
        let entry = chapter?.entries.first { $0.id == item.entry }
        let line = LedgerRow(account: entry.map { chapter!.fullHead($0) } ?? "", colour: Theme.C.bad,
                             ruled: !last) {
            VStack(alignment: .leading, spacing: 3) {
                Self.miss(item, answer).font(Theme.F.target(size: 17))
                    .fixedSize(horizontal: false, vertical: true)
                if let why = item.why {
                    Text(why).font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                }
            }
        } trailing: {
            if openEntry != nil, entry != nil {
                Text("›").font(Theme.F.mono(15)).foregroundStyle(Theme.C.accent)
                    .padding(.trailing, 12)
                    .frame(maxHeight: .infinity)
            }
        }
        if let openEntry, let chapter, entry != nil {
            Button { openEntry(chapter.id, item.entry) } label: { line.contentShape(Rectangle()) }
                .buttonStyle(PressDim())
        } else {
            line
        }
    }

    /// Ticket stub: what was run, the score, best and average; stamped.
    private var stub: some View {
        Panel(padding: 14) {
            HStack {
                Text(round.plan.name).monoCaps()
                Spacer()
                Text(Self.clock(round.seconds())).font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(round.right)").font(Theme.F.mono(64, bold: true))
                Text("/ \(round.items.count)").font(Theme.F.mono(20)).foregroundStyle(Theme.C.ink2)
                Spacer()
                if let best = record.best, let avg = record.average {
                    Text("BEST \(best)\nAVG \(avg)").font(Theme.F.meta)
                        .foregroundStyle(Theme.C.ink2).multilineTextAlignment(.trailing)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .foregroundStyle(Theme.C.ink)
        .overlay(alignment: .bottom) { Perforation(colour: Theme.C.ground).offset(y: 1) }
        .overlay(alignment: .bottomTrailing) {
            let band = Self.band(right: round.right, of: round.items.count)
            Stamp(band.word, colour: band.colour, size: 13)
                .background(Theme.C.surface.opacity(0.7))
                .offset(x: -14, y: 16)
        }
        .padding(.bottom, 10)
    }

    /// ≥85% CLEAN, ≥60% HOLDING, else AGAIN.
    static func band(right: Int, of total: Int) -> (word: String, colour: Color) {
        let share = total == 0 ? 0 : Double(right) / Double(total)
        if share >= 0.85 { return ("Clean", Theme.C.good) }
        if share >= 0.6 { return ("Holding", Theme.C.warn) }
        return ("Again", Theme.C.bad)
    }

    /// MEASURE WORDS   8 → 10 / 20
    private func change(_ c: (chapter: Chapter, before: Int, after: Int)) -> some View {
        Panel {
            HStack {
                Text(c.chapter.name.uppercased()).lineLimit(1)
                Spacer()
                Text("\(c.before) → ")
                    + Text("\(c.after)").bold()
                        .foregroundColor(c.after > c.before ? Theme.C.good
                                         : c.after < c.before ? Theme.C.bad : Theme.C.ink)
                    + Text(" / \(c.chapter.entries.count)")
            }
            .font(Theme.F.mono(12))
            .foregroundStyle(Theme.C.ink)
        }
    }

    /// The round, one cell per item, on a card with its corner clipped.
    private var strip: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 10), spacing: 2) {
            ForEach(round.answers.indices, id: \.self) { i in
                Rectangle()
                    .fill(round.answers[i].map { $0.right ? Theme.C.good : Theme.C.bad } ?? Theme.C.raised)
                    .frame(height: 20)
            }
        }
        .padding(6)
        .background(Theme.C.surface)
        .overlay(ClippedCorner().stroke(Theme.C.ink, lineWidth: Theme.M.hair))
        .clipShape(ClippedCorner())
    }

    /// Wrong → right, in place where the prompt has gaps.
    static func miss(_ item: QuizItem, _ a: QuizRound.Answer) -> Text {
        let expected = QuizRound.expected(item)
        func pair(_ given: String, _ right: String, _ ok: Bool) -> Text {
            ok ? Text(right).foregroundColor(Theme.C.ink)
                : Text(given).strikethrough().foregroundColor(Theme.C.bad)
                    + Text(" → ").foregroundColor(Theme.C.ink3)
                    + Text(right).bold().foregroundColor(Theme.C.good)
        }
        switch item.format {
        case .pickOne, .flip, .twoStep:
            return quizGapText(item.prompt ?? "", item.steps.indices.map { i in
                QuizGapFill(given: a.given[ifAny: i], correct: expected[ifAny: i],
                            right: a.steps[ifAny: i])
            }).foregroundColor(Theme.C.ink)
        case .spotIt:
            let tokens = item.steps[0].options
            let wrong = item.steps[0].answer
            var t = Text("")
            for (i, tok) in tokens.enumerated() {
                if i > 0 { t = t + Text(QuizRound.separator(tokens[i - 1], tok)) }
                t = t + (i == wrong ? pair(tok, expected[ifAny: 1] ?? "", false) : Text(tok))
            }
            return t
        case .sort, .toneTap:
            var t = Text("")
            var first = true
            for (i, step) in item.steps.enumerated() where a.steps[ifAny: i] == false {
                if !first { t = t + Text(" · ") }
                first = false
                t = t + Text((step.prompt ?? "") + " ") + pair(a.given[ifAny: i] ?? "", expected[ifAny: i] ?? "", false)
            }
            return t
        case .build, .transform:
            return Text(a.given.first ?? "").strikethrough().foregroundColor(Theme.C.bad)
                + Text(" → ") + Text(expected.first ?? "").foregroundColor(Theme.C.good)
        }
    }

    static func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}

/// A rectangle with its top-leading corner cut at 45°.
struct ClippedCorner: Shape {
    var cut: CGFloat = 10
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + cut, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + cut))
        p.closeSubpath()
        return p
    }
}
