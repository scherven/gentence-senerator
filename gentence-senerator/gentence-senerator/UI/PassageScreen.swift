import SwiftUI

/// A dialogue, heard once and then answered on. Four stages in a fixed order:
/// the quiz runs before the repair, because one uninterrupted listen is the
/// only honest measure of comprehension.
///
/// Nothing here calls the model. Every answer is a choice, so it is graded on
/// the device — which is also why the whole screen works offline.
struct PassageScreen: View {
    @Bindable var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                if let passage = store.passage, let run = store.run {
                    stages(run)
                    switch run.stage {
                    case .gist:      gist(passage, run)
                    case .quiz:      quiz(passage, run)
                    case .repairing: repairing(passage, run)
                    case .reask:     reask(passage, run)
                    case .done:      done(passage, run)
                    }
                }
            }
            .padding(Theme.M.gap)
        }
    }

    // MARK: Rail

    private static let rail: [(PassageRun.Stage, String)] =
        [(.gist, "Listen"), (.quiz, "Quiz"), (.repairing, "Repair"), (.done, "Done")]

    private func stages(_ run: PassageRun) -> some View {
        let here = PassageScreen.rail.firstIndex {
            $0.0 == (run.stage == .reask ? .repairing : run.stage)
        } ?? 0
        return HStack(spacing: 0) {
            ForEach(Array(PassageScreen.rail.enumerated()), id: \.offset) { index, step in
                Text(step.1.uppercased())
                    .font(Theme.F.label)
                    .tracking(0.8)
                    .foregroundStyle(index == here ? Theme.C.onAccent
                                     : (index < here ? Theme.C.ink2 : Theme.C.ink3))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(index == here ? Theme.C.accent : Theme.C.sunk)
                    .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
            }
        }
    }

    // MARK: One listen

    @ViewBuilder
    private func gist(_ passage: Passage, _ run: PassageRun) -> some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            VStack(alignment: .leading, spacing: 6) {
                ModuleLabel(text: "Listen once")
                Panel(fill: Theme.C.sunk, edge: Theme.C.accent) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(passage.title).font(Theme.F.target)
                        Text(heard(passage, run))
                            .font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                    }
                }
            }
            Text(run.played
                 ? "Questions next."
                 : "\(passage.quiz.count) questions after. One replay.")
                .font(Theme.F.note).foregroundStyle(Theme.C.ink2)

            MainButton(title: run.played ? "Play again" : "Play",
                       enabled: !run.played || run.canReplay) { store.playGist() }
            MainButton(title: "Go to the questions", enabled: run.played) { store.toQuiz() }
        }
    }

    private func heard(_ passage: Passage, _ run: PassageRun) -> String {
        let length = "\(Int(passage.length.rounded()))s"
        let voices = "\(passage.speakers.count) speakers"
        guard run.played else { return "\(length) · \(voices) · no text" }
        let left = PassageRun.replayLimit - run.replays
        return "\(length) · played · \(left) replay\(left == 1 ? "" : "s") left"
    }

    // MARK: Quiz

    @ViewBuilder
    private func quiz(_ passage: Passage, _ run: PassageRun) -> some View {
        let question = passage.quiz[min(run.quizAt, passage.quiz.count - 1)]
        let picked = run.answers[question.id]

        VStack(alignment: .leading, spacing: Theme.M.gap) {
            asked(question, index: run.quizAt, of: passage.quiz.count)
            options(question.options, picked: picked, answer: question.answer) {
                store.answerQuiz($0)
            }

            if let picked {
                // Every wrong option is true of some other line, so a wrong
                // pick says where the fact was misfiled rather than only that
                // it was.
                if picked != question.answer,
                   let from = question.optionLines[safe: picked],
                   let line = passage.line(from) {
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("True — of line \(from), not this question.")
                                .font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                            Text(line.text).font(Theme.F.targetSmall)
                        }
                    }
                } else {
                    Panel { Text("Right.").font(Theme.F.meta).foregroundStyle(Theme.C.good) }
                }
                MainButton(title: run.quizAt + 1 < passage.quiz.count
                           ? "Next question" : "What to go back to") { store.advanceQuiz() }
            }
        }
    }

    // MARK: Repair

    @ViewBuilder
    private func repairing(_ passage: Passage, _ run: PassageRun) -> some View {
        let n = run.repair[min(run.repairAt, run.repair.count - 1)]
        if let line = passage.line(n), let gap = line.gap {
            let picked = run.gaps[n]
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                VStack(alignment: .leading, spacing: 6) {
                    ModuleLabel(text: "Line \(n) of \(passage.lines.count)")
                    Panel(fill: Theme.C.sunk, edge: Theme.C.accent) {
                        VStack(alignment: .leading, spacing: 8) {
                            if let before = passage.line(n - 1) {
                                spoken(before, dim: true, gap: nil, picked: nil)
                            }
                            spoken(line, dim: false, gap: gap, picked: picked)
                        }
                    }
                }
                HStack {
                    TinyButton(title: "Hear this line") { store.hearLine(n) }
                    Spacer()
                }
                options(gap.options, picked: picked, answer: gap.answerIndex) {
                    store.answerGap($0)
                }
                if picked != nil {
                    Panel { Text(gap.why).font(Theme.F.note).foregroundStyle(Theme.C.ink2) }
                    MainButton(title: run.repairAt + 1 < run.repair.count
                               ? "Next line" : "Try those questions again") {
                        store.advanceRepair()
                    }
                }
            }
        }
    }

    /// One line of the dialogue, with the gap shown as a rule the answer drops
    /// into once it is picked.
    private func spoken(_ line: Passage.Line, dim: Bool,
                        gap: Passage.Gap?, picked: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(line.speaker)
                .font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
            if let gap {
                let parts = line.text.components(separatedBy: gap.answer)
                (Text(parts.first ?? "")
                 + Text(picked.map { gap.options[$0] } ?? "＿＿")
                    .foregroundColor(Theme.C.accent)
                 + Text(parts.count > 1 ? parts[1] : ""))
                    .font(Theme.F.targetSmall)
            } else {
                Text(line.text).font(Theme.F.targetSmall)
            }
            Spacer(minLength: 0)
        }
        .opacity(dim ? 0.45 : 1)
    }

    // MARK: Asked again

    @ViewBuilder
    private func reask(_ passage: Passage, _ run: PassageRun) -> some View {
        let id = run.reask[min(run.reaskAt, run.reask.count - 1)]
        if let question = passage.quiz.first(where: { $0.id == id }) {
            let picked = run.reanswers[id]
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                asked(question, index: run.reaskAt, of: run.reask.count, label: "Again")
                options(question.options, picked: picked, answer: question.answer) {
                    store.answerReask($0)
                }
                if picked != nil {
                    MainButton(title: run.reaskAt + 1 < run.reask.count ? "Next" : "Finish") {
                        store.advanceReask()
                    }
                }
            }
        }
    }

    // MARK: The read

    @ViewBuilder
    private func done(_ passage: Passage, _ run: PassageRun) -> some View {
        let tally = run.read(of: passage)
        let outcome = run.outcome(of: passage)
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            VStack(alignment: .leading, spacing: 6) {
                ModuleLabel(text: "Listening · day done")
                Panel(fill: Theme.C.sunk) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(tally.first) of \(tally.asked)").font(Theme.F.number)
                        Text("\(Int(passage.length.rounded()))s · \(run.replays) "
                             + "replay\(run.replays == 1 ? "" : "s") · "
                             + "\(tally.gapsRight)/\(tally.gaps) gaps")
                            .font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                    }
                }
                Panel(edge: colour(for: outcome)) {
                    Text(outcome.read).font(Theme.F.body)
                }
            }

            if let review = store.current?.review, !review.problems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ModuleLabel(text: "What you missed")
                    ForEach(review.problems) { atom in
                        Button { store.open(atom) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text(atom.stages.name).font(Theme.F.bodyTight)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(atom.stages.locate).font(Theme.F.meta)
                                    .foregroundStyle(Theme.C.ink3)
                                Text("+").font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                            }
                            .padding(Theme.M.padTight)
                            .background(Theme.C.surface)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Theme.colour(for: atom.verdict))
                                    .frame(width: Theme.M.edge)
                            }
                            .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("One dialogue is the whole listening day. Translate and produce are still open.")
                .font(Theme.F.note).foregroundStyle(Theme.C.ink3)
            MainButton(title: "Done") { store.leavePassage() }
        }
    }

    private func colour(for outcome: PassageRun.Outcome) -> Color {
        switch outcome {
        case .clean:            return Theme.C.good
        case .sound:            return Theme.C.bad
        case .context, .thread: return Theme.C.warn
        }
    }

    // MARK: Shared

    private func asked(_ question: Passage.Question, index: Int, of total: Int,
                       label: String = "Question") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: "\(label) \(index + 1) of \(total)")
            Panel(fill: Theme.C.sunk, edge: Theme.C.accent) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.question).font(Theme.F.target)
                    Text(question.english).font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                }
            }
        }
    }

    /// The whole answering surface. Once picked, the right one is marked
    /// whatever was chosen — being shown only that you were wrong teaches
    /// nothing.
    private func options(_ options: [String], picked: Int?, answer: Int,
                         choose: @escaping (Int) -> Void) -> some View {
        VStack(spacing: -Theme.M.hair) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button { if picked == nil { choose(index) } } label: {
                    HStack(spacing: 10) {
                        Text(String(UnicodeScalar(65 + index)!))
                            .font(Theme.F.meta)
                            .foregroundStyle(mark(index, picked, answer) ?? Theme.C.ink3)
                        Text(option)
                            .font(Theme.F.targetSmall)
                            .foregroundStyle(mark(index, picked, answer) ?? Theme.C.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.M.padTight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.C.surface)
                    .overlay(alignment: .leading) {
                        if let colour = mark(index, picked, answer) {
                            Rectangle().fill(colour).frame(width: Theme.M.edge)
                        }
                    }
                    .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
                }
                .buttonStyle(.plain)
                .disabled(picked != nil)
            }
        }
    }

    private func mark(_ index: Int, _ picked: Int?, _ answer: Int) -> Color? {
        guard let picked else { return nil }
        if index == answer { return Theme.C.good }
        if index == picked { return Theme.C.bad }
        return nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
