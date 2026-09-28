import SwiftUI

/// Production with a support ladder. A wrong answer drops a rung rather than
/// repeating the same task with more explanation attached.
struct DrillView: View {
    let drill: Drill
    let onOpenLink: (AtomLink) -> Void
    let onOutcome: (Bool, Rung.Support) -> Void
    /// Exact match first, model second — so an answer a speaker would accept
    /// is not marked wrong for being absent from the list.
    let grade: (String, Rung) async -> Tutor.DrillVerdict

    @State private var rungIndex = 0
    @State private var input = ""
    @State private var result: Bool?
    @State private var extra: String?
    @State private var checking = false
    @State private var steppedDown = false

    private var rung: Rung { drill.rungs[min(rungIndex, drill.rungs.count - 1)] }
    private var canStepDown: Bool { rungIndex < drill.rungs.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.M.gapTight) {
            support
            if steppedDown && result == nil {
                Text("Easier version.")
                    .font(Theme.F.note)
                    .foregroundStyle(Theme.C.warn)
                    .padding(.leading, Theme.M.gapTight)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.C.warn).frame(width: Theme.M.edge)
                    }
            }

            Text(rung.prompt)
                .font(Theme.F.body)
                .foregroundStyle(Theme.C.ink)

            if rung.support == .choice, let options = rung.options {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        Button { Task { await check(choice: index) } } label: {
                            Text(option)
                                .font(Theme.F.targetSmall)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Theme.M.padTight)
                                .background(Theme.C.sunk)
                                .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    TextField("Type it…", text: $input)
                        .font(Theme.F.targetSmall)
                        .textFieldStyle(.plain)
                        .targetLanguageInput()
                        .padding(Theme.M.padTight)
                        .background(Theme.C.sunk)
                        .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
                        .submitLabel(.done)
                        .onSubmit { Task { await check(choice: nil) } }
                        .disabled(checking)
                    TinyButton(title: checking ? "…" : "Check") {
                        Task { await check(choice: nil) }
                    }
                }
            }

            if let result { outcome(correct: result) }
        }
        .padding(Theme.M.pad)
        .background(Theme.C.surface)
        .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
    }

    private var support: some View {
        HStack(spacing: 7) {
            Text(rung.support.label.uppercased())
                .font(Theme.F.label)
                .tracking(1.1)
                .foregroundStyle(Theme.C.ink3)
            HStack(spacing: 3) {
                ForEach(Array(drill.rungs.enumerated()), id: \.offset) { index, _ in
                    Rectangle()
                        .fill(index <= rungIndex ? Theme.C.accent : Theme.C.seam2)
                        .frame(width: 13, height: 3)
                }
            }
        }
    }

    @ViewBuilder
    private func outcome(correct: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.M.gapTight) {
            Text(correct ? "GOT IT" : "NOT YET")
                .font(Theme.F.label)
                .tracking(1.2)
                .foregroundStyle(correct ? Theme.C.good : Theme.C.bad)

            Text(extra ?? (correct ? drill.correct : drill.incorrect))
                .font(Theme.F.bodyTight)
                .foregroundStyle(Theme.C.ink)

            if correct && rungIndex > 0 {
                TinyButton(title: "Harder version") {
                    rungIndex -= 1
                    reset()
                }
            }

            ForEach(drill.atoms) { link in
                AtomRow(link: link) { onOpenLink(link) }
            }
        }
        .padding(.leading, Theme.M.gapTight)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(correct ? Theme.C.good : Theme.C.bad)
                .frame(width: Theme.M.edge)
        }
    }

    private func check(choice: Int?) async {
        let correct: Bool
        var note: String?

        if let choice {
            correct = choice == rung.answerIndex
        } else {
            guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            checking = true
            let verdict = await grade(input, rung)
            checking = false
            correct = verdict.correct
            if !verdict.note.isEmpty { note = verdict.note }
        }

        extra = note
        onOutcome(correct, rung.support)

        if correct {
            result = true
            steppedDown = false
        } else if canStepDown {
            rungIndex += 1
            steppedDown = true
            reset()
        } else {
            result = false
        }
    }

    private func reset() {
        input = ""
        result = nil
        extra = nil
    }
}
