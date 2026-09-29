import SwiftUI

// One view per `QuizFormat`, registered in `QuizFormatView`.

private var promptFont: Font { Theme.F.target(size: 26) }

private func gloss(_ s: String?) -> some View {
    Text(s ?? "")
        .font(Theme.F.serif(14.5, italic: true))
        .foregroundStyle(Theme.C.ink2)
        .opacity(s == nil ? 0 : 1)
}

// MARK: Pick one

struct PickOneQuiz: View {
    let c: QuizFormatContext
    @State private var picked: Int?

    private var step: QuizItem.Step { c.item.steps[0] }

    var body: some View {
        VStack(spacing: 10) {
            quizGapText(c.item.prompt ?? "", [fill])
                .font(Theme.F.target(size: 36))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
            gloss(c.item.gloss)
            Spacer()
            QuizOptions(options: step.options, picked: picked, answer: step.answer, done: c.done) { i in
                picked = i
                c.answer(QuizRound.score(c.item, picks: [i]))
            }
        }
    }

    private var fill: QuizGapFill? {
        guard let p = picked else { return nil }
        let right = c.done ? p == step.answer : nil
        return QuizGapFill(given: step.options[p], correct: step.options[step.answer], right: right)
    }
}

// MARK: Flip

struct FlipQuiz: View {
    let c: QuizFormatContext
    @State private var picked: Int?
    @State private var drag: CGFloat = 0

    private var step: QuizItem.Step { c.item.steps[0] }

    var body: some View {
        VStack(spacing: 0) {
            card
                .padding(.top, 32)
                .offset(x: drag)
                .rotationEffect(.degrees(-2 + Double(drag) / 30))
                .gesture(swipe)
            Spacer()
            HStack(spacing: 10) {
                half(0, label: "‹ " + step.options[0])
                half(1, label: step.options[1] + " ›")
            }
            .frame(height: 200)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            quizGapText(c.item.prompt ?? "", [fill]).font(Theme.F.target)
            if let g = c.item.gloss {
                Text(g).font(Theme.F.gloss).foregroundStyle(Theme.C.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 22).padding(.horizontal, 16)
        .background(Theme.C.surface)
        .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
        .background(Rectangle().fill(Theme.C.seam2).offset(y: 3))
    }

    private func half(_ i: Int, label: String) -> some View {
        let look = QuizKey.Look.of(i, picked: picked, answer: step.answer, done: c.done)
        // Left inverse, right accent, until marked.
        let variant: KeyStyle.Variant = switch look {
        case .right: .right
        case .wrong: .wrong
        case .dim:   .dim
        default:     i == 0 ? .inverse : .primary
        }
        return Button { choose(i) } label: {
            Text(label)
                .font(Theme.F.target(size: 30, bold: true))
                .minimumScaleFactor(0.4)
                .padding(.horizontal, 10)
        }
        .buttonStyle(KeyStyle(variant, expand: true, dimsWhenDisabled: false))
        .disabled(picked != nil)
    }

    private var swipe: some Gesture {
        DragGesture()
            .onChanged { if picked == nil { drag = $0.translation.width } }
            .onEnded { v in
                withAnimation(.snappy) { drag = 0 }
                guard picked == nil, abs(v.translation.width) > 70 else { return }
                choose(v.translation.width < 0 ? 0 : 1)
            }
    }

    private func choose(_ i: Int) {
        guard picked == nil else { return }
        picked = i
        c.answer(QuizRound.score(c.item, picks: [i]))
    }

    private var fill: QuizGapFill? {
        guard let p = picked else { return nil }
        return QuizGapFill(given: step.options[p], correct: step.options[step.answer],
                       right: c.done ? p == step.answer : nil)
    }
}

// MARK: Two-step

struct TwoStepQuiz: View {
    let c: QuizFormatContext
    @State private var picks: [Int] = []

    var body: some View {
        let steps = c.item.steps
        let at = min(picks.count, steps.count - 1)
        VStack(alignment: .leading, spacing: 18) {
            quizGapText(c.item.prompt ?? "", fills).font(Theme.F.target(size: 24))
            gloss(c.item.gloss ?? c.entryGloss)
            QuizStepLine(steps: steps, results: results)
            Spacer()
            QuizOptions(options: steps[at].options,
                       picked: c.done ? picks[ifAny: at] : nil,
                       answer: steps[at].answer, done: c.done) { i in
                picks.append(i)
                if picks.count == steps.count { c.answer(QuizRound.score(c.item, picks: picks)) }
            }
            .id(at)
        }
    }

    private var results: [Bool] {
        picks.enumerated().map { $0.element == c.item.steps[$0.offset].answer }
    }

    private var fills: [QuizGapFill?] {
        c.item.steps.enumerated().map { i, step in
            guard let p = picks[ifAny: i] else { return nil }
            return QuizGapFill(given: step.options[p], correct: step.options[step.answer],
                           right: p == step.answer)
        }
    }
}

// MARK: Spot it

struct SpotItQuiz: View {
    let c: QuizFormatContext
    @State private var picks: [Int] = []

    var body: some View {
        let tokens = c.item.steps[0]
        let fix = c.item.steps[1]
        VStack(alignment: .leading, spacing: 18) {
            gloss(c.item.gloss)
            QuizFlow(spacing: 6) {
                ForEach(Array(tokens.options.enumerated()), id: \.offset) { i, token in
                    Button {
                        guard picks.isEmpty else { return }
                        picks = [i]
                    } label: {
                        Text(token).font(Theme.F.target(size: 24)).padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    .buttonStyle(QuizKey(look: tokenLook(i, answer: tokens.answer)))
                    .fixedSize()
                    .disabled(!picks.isEmpty)
                }
            }
            StepTicks(count: c.item.steps.count, results: results)
            Spacer()
            if !picks.isEmpty {
                QuizOptions(options: fix.options, picked: c.done ? picks[ifAny: 1] : nil,
                           answer: fix.answer, done: c.done) { i in
                    picks.append(i)
                    c.answer(QuizRound.score(c.item, picks: picks))
                }
            }
        }
    }

    private func tokenLook(_ i: Int, answer: Int) -> QuizKey.Look {
        guard let p = picks.first else { return .plain }
        if i == answer { return p == answer || c.done ? .right : .plain }
        if i == p { return .wrong }
        return .plain
    }

    private var results: [Bool] {
        picks.enumerated().map { $0.element == c.item.steps[$0.offset].answer }
    }
}

// MARK: Tone tap

struct ToneTapQuiz: View {
    let c: QuizFormatContext
    @State private var picks: [Int?] = []

    var body: some View {
        VStack(spacing: 22) {
            Button { play() } label: {
                Text("▶ " + (c.item.prompt ?? "PLAY"))
                    .font(Theme.F.target(size: 30))
                    .padding(.vertical, 18)
            }
            .buttonStyle(QuizKey())
            .frame(height: 84)
            gloss(c.item.gloss)
            Spacer()
            ForEach(Array(c.item.steps.enumerated()), id: \.offset) { s, step in
                HStack(spacing: 8) {
                    Text(step.prompt ?? "")
                        .font(Theme.F.target(size: 26))
                        .frame(width: 44, alignment: .leading)
                    ForEach(Array(step.options.enumerated()), id: \.offset) { i, mark in
                        Button { pick(s, i) } label: { Text(mark).font(Theme.F.target(size: 22)) }
                            .buttonStyle(QuizKey(look: .of(i, picked: picks[ifAny: s] ?? nil,
                                                          answer: step.answer, done: c.done)))
                            .frame(height: 52)
                            .disabled(c.done)
                    }
                }
            }
        }
        .onAppear {
            picks = Array(repeating: nil, count: c.item.steps.count)
            play()
        }
    }

    private func play() { if let s = c.item.speak { c.speak(s) } }

    private func pick(_ s: Int, _ i: Int) {
        guard !c.done, picks.indices.contains(s) else { return }
        picks[s] = i
        let all = picks.compactMap { $0 }
        if all.count == c.item.steps.count { c.answer(QuizRound.score(c.item, picks: all)) }
    }
}

// MARK: Sort

struct SortQuiz: View {
    let c: QuizFormatContext
    @State private var picks: [Int] = []

    var body: some View {
        let steps = c.item.steps
        let buckets = steps[0].options
        VStack(spacing: 16) {
            gloss(c.item.prompt ?? c.item.gloss)
            HStack(spacing: 2) {
                ForEach(steps.indices, id: \.self) { i in
                    Rectangle().fill(i < picks.count
                                     ? (picks[i] == steps[i].answer ? Theme.C.good : Theme.C.bad)
                                     : Theme.C.raised)
                        .frame(height: 4)
                }
            }
            if c.done {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(steps.indices, id: \.self) { i in
                            let ok = picks[ifAny: i] == steps[i].answer
                            HStack {
                                Text(steps[i].prompt ?? "").font(Theme.F.targetSmall)
                                Spacer()
                                if !ok, let p = picks[ifAny: i] {
                                    Text(buckets[p]).strikethrough().foregroundStyle(Theme.C.bad)
                                }
                                Text(buckets[steps[i].answer])
                                    .foregroundStyle(ok ? Theme.C.ink2 : Theme.C.good)
                            }
                            .font(Theme.F.body)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.C.seam).frame(height: 1) }
                        }
                    }
                }
            } else {
                Spacer()
                Text(steps[min(picks.count, steps.count - 1)].prompt ?? "")
                    .font(Theme.F.target(size: 40))
                    .minimumScaleFactor(0.4)
                    .id(picks.count)
                    .transition(.push(from: .trailing))
                Text("\(picks.count + 1) / \(steps.count)")
                    .font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                Spacer()
                HStack(spacing: 10) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { i, b in
                        Button { pick(i) } label: { Text(b).font(Theme.F.target(size: 24)) }
                            .buttonStyle(QuizKey())
                            .frame(height: 96)
                    }
                }
            }
        }
    }

    private func pick(_ i: Int) {
        guard picks.count < c.item.steps.count else { return }
        withAnimation(.snappy(duration: 0.18)) { picks.append(i) }
        if picks.count == c.item.steps.count { c.answer(QuizRound.score(c.item, picks: picks)) }
    }
}

// MARK: Build

struct BuildQuiz: View {
    let c: QuizFormatContext
    /// Indices into `bank`.
    @State private var placed: [Int] = []

    private var bank: [String] { c.item.shuffled(c.item.tiles + c.item.decoys) }

    var body: some View {
        let bank = bank
        VStack(alignment: .leading, spacing: 22) {
            if let p = c.item.gloss ?? c.item.prompt {
                Text(p).font(Theme.F.target(size: 18))
            }
            QuizFlow(spacing: 8) {
                ForEach(placed, id: \.self) { i in
                    Button { if !c.done { placed.removeAll { $0 == i } } } label: { tile(bank[i]) }
                        .buttonStyle(QuizKey(look: slotLook))
                        .fixedSize()
                }
                if !c.done {
                    ForEach(0..<max(0, c.item.tiles.count - placed.count), id: \.self) { _ in
                        Rectangle().strokeBorder(Theme.C.seam2, style: StrokeStyle(lineWidth: 1, dash: [3]))
                            .frame(width: 44, height: 46)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(Theme.C.ink).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.C.ink).frame(height: 1) }

            if c.done, c.revealed?.right == false {
                Text(QuizRound.expected(c.item).first ?? "")
                    .font(Theme.F.target).foregroundStyle(Theme.C.good)
            }

            QuizFlow(spacing: 8) {
                ForEach(bank.indices, id: \.self) { i in
                    if placed.contains(i) {
                        tile(bank[i]).foregroundStyle(.clear)
                            .overlay(Rectangle().strokeBorder(Theme.C.seam2, style: StrokeStyle(lineWidth: 1, dash: [3])))
                    } else {
                        Button {
                            if !c.done, placed.count < c.item.tiles.count { placed.append(i) }
                        } label: { tile(bank[i]) }
                            .buttonStyle(QuizKey(look: c.done ? .dim : .plain))
                            .fixedSize()
                    }
                }
            }
            Spacer()
            if !c.done {
                QuizCheckButton(enabled: QuizRound.canCheck(c.item, placed: placed.count)) {
                    c.answer(QuizRound.score(c.item, tiles: placed.map { bank[$0] }))
                }
            }
        }
    }

    private var slotLook: QuizKey.Look {
        guard let r = c.revealed else { return .plain }
        return r.right ? .right : .wrong
    }

    private func tile(_ s: String) -> some View {
        Text(s).font(Theme.F.target(size: 20)).padding(.horizontal, 12).padding(.vertical, 10)
    }
}

// MARK: Transform

struct TransformQuiz: View {
    let c: QuizFormatContext
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let build = ChineseInput.fallback(for: c.item) {
            // No Chinese keyboard: the same answer as tiles.
            VStack(alignment: .leading, spacing: 14) {
                Text(c.item.prompt ?? "").font(Theme.F.target(size: 22))
                Text(c.item.task ?? "").font(Theme.F.label).foregroundStyle(Theme.C.accent)
                BuildQuiz(c: QuizFormatContext(item: build, revealed: c.revealed,
                                               answer: c.answer, speak: c.speak))
            }
        } else {
            typing
        }
    }

    private var typing: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(c.item.prompt ?? "").font(Theme.F.target(size: 24))
            gloss(c.item.gloss)
            Text(c.item.task ?? "").font(Theme.F.label).foregroundStyle(Theme.C.accent)
            field
                .padding(Theme.M.pad)
                .background(Theme.C.sunk)
                .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
            if c.revealed?.right == false {
                Text(QuizRound.expected(c.item).first ?? "")
                    .font(Theme.F.target).foregroundStyle(Theme.C.good)
            }
            Spacer()
            if !c.done {
                QuizCheckButton(enabled: !typed.trimmingCharacters(in: .whitespaces).isEmpty, action: check)
            }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder private var field: some View {
        let tint = c.revealed.map { $0.right ? Theme.C.good : Theme.C.bad } ?? Theme.C.ink
        if ChineseInput.isChinese(c.item) {
            ChineseField(text: $typed, enabled: !c.done, colour: UIColor(tint), onSubmit: check)
                .frame(height: 30)
        } else {
            TextField("", text: $typed, axis: .vertical)
                .font(Theme.F.target)
                .textFieldStyle(.plain)
                .targetLanguageInput()
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(check)
                .disabled(c.done)
                .strikethrough(c.revealed?.right == false, color: Theme.C.bad)
                .foregroundStyle(tint)
        }
    }

    private func check() {
        guard !c.done, !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        focused = false
        c.answer(QuizRound.score(c.item, typed: typed))
    }
}

// MARK: -

/// CHECK: `ActionKey` under the quiz's name.
struct QuizCheckButton: View {
    var enabled = true
    let action: () -> Void
    var body: some View {
        ActionKey("Check", enabled: enabled, action: action)
    }
}

extension Array {
    subscript(ifAny i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
