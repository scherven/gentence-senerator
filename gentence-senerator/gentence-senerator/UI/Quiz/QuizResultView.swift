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
    var openChapter: ((Chapter) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(round.plan.name.uppercased()).tracking(1)
                    Spacer()
                    Text(Self.clock(round.seconds())).foregroundStyle(Theme.C.ink2)
                }
                .font(.system(size: 12, design: .monospaced))

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(round.right)").font(.system(size: 56, design: .monospaced))
                    Text("/ \(round.items.count)").font(.system(size: 18, design: .monospaced))
                        .foregroundStyle(Theme.C.ink2)
                    Spacer()
                    if let best = record.best, let avg = record.average {
                        Text("BEST \(best) · AVG \(avg)").font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.C.good)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 10),
                          spacing: 2) {
                    ForEach(round.answers.indices, id: \.self) { i in
                        Rectangle()
                            .fill(round.answers[i].map { $0.right ? Theme.C.good : Theme.C.bad } ?? Theme.C.raised)
                            .frame(height: 22)
                    }
                }

                if !round.misses.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(round.misses, id: \.item.id) { miss in row(miss.item, miss.answer) }
                    }
                    .overlay(alignment: .top) { Rectangle().fill(Theme.C.seam).frame(height: 1) }
                }

                ForEach(chapters, id: \.chapter.id) { c in
                    HStack {
                        Text(c.chapter.name.uppercased())
                        Spacer()
                        Text("\(c.before) → ")
                            + Text("\(c.after)").foregroundColor(c.after > c.before ? Theme.C.good
                                                                 : c.after < c.before ? Theme.C.bad : Theme.C.ink)
                            + Text(" / \(c.chapter.entries.count)")
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .background(Theme.C.surface)
                    .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
                }

                HStack(spacing: 8) {
                    Button(action: again) {
                        Text("AGAIN").frame(maxWidth: .infinity).frame(height: 48)
                            .foregroundStyle(Theme.C.surface).background(Theme.C.ink)
                            .background(Rectangle().fill(Color.black).offset(y: 3))
                    }
                    Button(action: done) { Text("DONE").frame(height: 48) }
                        .buttonStyle(QuizKey())
                        .frame(height: 48)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
            }
            .padding(.horizontal, Theme.M.gap)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
    }

    private func row(_ item: QuizItem, _ answer: QuizRound.Answer) -> some View {
        let chapter = book.chapter(of: item.entry)
        return HStack(alignment: .firstTextBaseline) {
            Self.miss(item, answer).font(.system(size: 17))
            Spacer(minLength: 8)
            if let chapter, let openChapter {
                Button { openChapter(chapter) } label: {
                    Text((item.why ?? chapter.name) + " ›")
                }
                .buttonStyle(.plain)
            } else if let why = item.why {
                Text(why)
            }
        }
        .font(Theme.F.meta)
        .foregroundStyle(Theme.C.ink2)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.C.seam).frame(height: 1) }
    }

    /// Wrong → right, in place where the prompt has gaps.
    static func miss(_ item: QuizItem, _ a: QuizRound.Answer) -> Text {
        let expected = QuizRound.expected(item)
        func pair(_ given: String, _ right: String, _ ok: Bool) -> Text {
            ok ? Text(right).foregroundColor(Theme.C.ink)
                : Text(given).strikethrough().foregroundColor(Theme.C.bad)
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
