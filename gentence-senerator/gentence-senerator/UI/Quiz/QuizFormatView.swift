import SwiftUI

/// The one place a format meets its view.
///
/// New format: a `QuizFormat` case with its `rules` (mirror them in
/// `tools/check_book.py`), a view taking `QuizFormatContext`, and a line in
/// the switch below. New subject: data only — a chapter in `book-<lang>.json`
/// and items in `quiz-<lang>.json` using existing formats.
struct QuizFormatView: View {
    let context: QuizFormatContext

    var body: some View {
        switch context.item.format {
        case .pickOne:   PickOneQuiz(c: context)
        case .flip:      FlipQuiz(c: context)
        case .build:     BuildQuiz(c: context)
        case .twoStep:   TwoStepQuiz(c: context)
        case .spotIt:    SpotItQuiz(c: context)
        case .toneTap:   ToneTapQuiz(c: context)
        case .sort:      SortQuiz(c: context)
        case .transform: TransformQuiz(c: context)
        }
    }
}

/// What every format view gets. It calls `answer` once, when the item is
/// done; after that `revealed` is set and it shows right and wrong.
struct QuizFormatContext {
    let item: QuizItem
    let revealed: QuizRound.Answer?
    let answer: (QuizRound.Answer) -> Void
    let speak: (String) -> Void
    /// The entry's gloss, for items that carry none.
    var entryGloss: String? = nil
    /// The entry's fixed words (等…再… → 等, 再), highlighted in a correction.
    var structure: [String] = []

    var done: Bool { revealed != nil }
}

// MARK: - Shared pieces

/// A quiz option: `KeyStyle` filling its frame, keeping the quiz looks.
struct QuizKey: ButtonStyle {
    enum Look { case plain, right, wrong, chosen, dim }
    var look: Look = .plain

    func makeBody(configuration: Configuration) -> some View {
        let variant: KeyStyle.Variant = switch look {
        case .plain:  .neutral
        case .right:  .right
        case .wrong:  .wrong
        case .chosen: .chosen
        case .dim:    .dim
        }
        return KeyStyle(variant, expand: true, dimsWhenDisabled: false)
            .makeBody(configuration: configuration)
    }
}

extension QuizKey.Look {
    /// For option `index` of a step once it is answered.
    static func of(_ index: Int, picked: Int?, answer: Int, done: Bool) -> QuizKey.Look {
        guard done else { return index == picked ? .chosen : .plain }
        if index == answer { return .right }
        if index == picked { return .wrong }
        return .dim
    }
}

/// A grid of option keys for one step.
struct QuizOptions: View {
    let options: [String]
    var picked: Int?
    var answer: Int
    var done: Bool
    var height: CGFloat = 72
    let pick: (Int) -> Void

    var body: some View {
        let big = options.allSatisfy { $0.count <= 2 }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                  spacing: 13) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                Button { pick(i) } label: {
                    Text(option)
                        .font(Theme.F.target(size: big ? 38 : 22, bold: big))
                        .minimumScaleFactor(0.5)
                        .lineLimit(2)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(QuizKey(look: .of(i, picked: picked, answer: answer, done: done)))
                .frame(height: big ? height + 24 : height)
                .disabled(done || picked != nil)
            }
        }
    }
}

/// What goes in a gap.
struct QuizGapFill {
    var given: String?
    /// Shown after `given`, struck, when they differ.
    var correct: String?
    var right: Bool?
}

/// A prompt with its `＿` gaps drawn as underlined slots or filled.
func quizGapText(_ prompt: String, _ fills: [QuizGapFill?]) -> Text {
    let parts = prompt.split(separator: QuizItem.gap, omittingEmptySubsequences: false).map(String.init)
    var out = Text("")
    for (i, part) in parts.enumerated() {
        out = out + Text(part)
        guard i < parts.count - 1 else { break }
        let f = i < fills.count ? fills[i] : nil
        if let f, let given = f.given {
            if f.right == false, let correct = f.correct {
                out = out + Text(given).strikethrough().foregroundColor(Theme.C.bad)
                    + Text(" → ").foregroundColor(Theme.C.ink3)
                    + Text(correct).foregroundColor(Theme.C.good).underline()
            } else {
                out = out + Text(given).underline()
                    .foregroundColor(f.right == true ? Theme.C.good : Theme.C.accent)
            }
        } else {
            out = out + Text("\u{2009}") + Text(QuizBlank.image).foregroundColor(Theme.C.ink)
                + Text("\u{2009}")
        }
    }
    return out
}

/// An empty gap: a 1.5pt rule on the baseline, 44pt long.
enum QuizBlank {
    static let image: Image = {
        let size = CGSize(width: 44, height: 1.5)
        let ui = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return Image(uiImage: ui.withRenderingMode(.alwaysTemplate))
    }()
}

/// Wraps children onto lines. Tokens, tiles.
struct QuizFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? s.width : s.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += s.width + gap
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, s.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// Mono caption for a step: "1 ✓ AUXILIARY · 2 ENDING".
struct QuizStepLine: View {
    let steps: [QuizItem.Step]
    let results: [Bool]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                if i > 0 { Text("·").foregroundStyle(Theme.C.ink3) }
                let mark = i < results.count ? (results[i] ? " ✓" : " ✗") : ""
                Text("\(i + 1)\(mark)" + (step.prompt.map { " " + $0.uppercased() } ?? ""))
                    .foregroundStyle(i < results.count ? (results[i] ? Theme.C.good : Theme.C.bad)
                                     : i == results.count ? Theme.C.ink : Theme.C.ink3)
            }
        }
        .font(Theme.F.meta)
    }
}

/// One tick per step: marked when answered, outlined in ink when current.
struct StepTicks: View {
    let count: Int
    let results: [Bool]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                Group {
                    if let ok = results[ifAny: i] {
                        Rectangle().fill(ok ? Theme.C.good : Theme.C.bad)
                    } else {
                        Rectangle().strokeBorder(i == results.count ? Theme.C.ink : Theme.C.seam2,
                                                 lineWidth: Theme.M.hair)
                    }
                }
                .frame(width: 14, height: 6)
            }
        }
        .accessibilityLabel("Step \(min(results.count + 1, count)) of \(count)")
    }
}

extension QuizItem {
    /// Stable per item, so the tiles don't reshuffle on every redraw.
    func shuffled(_ values: [String]) -> [String] {
        var h: UInt64 = 1469598103934665603
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        var state = h == 0 ? 0x9E3779B97F4A7C15 : h
        var a = values
        var i = a.count - 1
        while i > 0 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            a.swapAt(i, Int(state % UInt64(i + 1)))
            i -= 1
        }
        return a
    }
}
