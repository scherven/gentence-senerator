import SwiftUI

/// Production with a support ladder. A wrong answer drops a rung rather than
/// repeating the same task with more explanation attached.
struct DrillView: View {
    let drill: Drill
    let onOpenAtom: (Atom) -> Void
    let onOutcome: (Bool, Rung.Support) -> Void

    @State private var rungIndex = 0
    @State private var input = ""
    @State private var result: Bool?
    @State private var steppedDown = false

    private var rung: Rung { drill.rungs[min(rungIndex, drill.rungs.count - 1)] }
    private var canStepDown: Bool { rungIndex < drill.rungs.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.M.gapTight) {
            support
            if steppedDown && result == nil {
                Text("Less to build.")
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
                        Button { check(choice: index) } label: {
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
                        .padding(Theme.M.padTight)
                        .background(Theme.C.sunk)
                        .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
                        .submitLabel(.done)
                        .onSubmit { check(choice: nil) }
                    TinyButton(title: "Check") { check(choice: nil) }
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

            Text(correct ? drill.correct : drill.incorrect)
                .font(Theme.F.bodyTight)
                .foregroundStyle(Theme.C.ink)

            if correct && rungIndex > 0 {
                TinyButton(title: "Back up to the full version") {
                    rungIndex -= 1
                    reset()
                }
            }

            ForEach(drill.atoms) { atom in
                AtomRow(atom: atom) { onOpenAtom(atom) }
            }
        }
        .padding(.leading, Theme.M.gapTight)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(correct ? Theme.C.good : Theme.C.bad)
                .frame(width: Theme.M.edge)
        }
    }

    private func check(choice: Int?) {
        let correct: Bool
        if let choice { correct = choice == rung.answerIndex }
        else { correct = rung.accepts(input) }

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
    }
}
