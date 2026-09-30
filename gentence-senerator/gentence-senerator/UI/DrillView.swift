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
                    .foregroundStyle(Theme.C.ink2)
            }

            Text(rung.prompt)
                .font(Theme.F.body)
                .foregroundStyle(Theme.C.ink)
                .fixedSize(horizontal: false, vertical: true)

            if rung.support == .choice, let options = rung.options {
                VStack(spacing: Theme.M.gapTight) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        Button { Task { await check(choice: index) } } label: {
                            Text(option)
                                .font(Theme.F.targetSmall)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.M.pad)
                                .padding(.vertical, 11)
                        }
                        .buttonStyle(KeyStyle(key(for: index)))
                    }
                }
            } else {
                HStack(spacing: Theme.M.gapTight) {
                    TextField("Type it…", text: $input)
                        .font(Theme.F.targetSmall)
                        .foregroundStyle(Theme.C.ink)
                        .textFieldStyle(.plain)
                        .targetLanguageInput()
                        .submitLabel(.done)
                        .onSubmit { Task { await check(choice: nil) } }
                        .disabled(checking)
                        .inset(padding: Theme.M.padTight)
                    if checking {
                        Ticker()
                    } else {
                        TinyButton(title: "Check") { Task { await check(choice: nil) } }
                    }
                }
            }

            if let result { outcome(correct: result) }
        }
        .padding(Theme.M.pad)
        .background(Theme.C.surface)
        .overlay(Rectangle().strokeBorder(Theme.C.seam, lineWidth: Theme.M.hair))
    }

    /// Quiz keys: the answer turns right once it is known.
    private func key(for index: Int) -> KeyStyle.Variant {
        guard result == true, index == rung.answerIndex else { return .neutral }
        return .right
    }

    private var support: some View {
        HStack(spacing: 3) {
            ForEach(Array(drill.rungs.enumerated()), id: \.offset) { index, _ in
                Rectangle()
                    .fill(index <= rungIndex ? Theme.C.ink2 : Theme.C.seam2)
                    .frame(width: 13, height: 3)
            }
        }
    }

    @ViewBuilder
    private func outcome(correct: Bool) -> some View {
        if extra == Store.uncheckable {
            Panel(fill: Theme.C.sunk, edge: Theme.C.warn, padding: Theme.M.padTight) {
                Text(Store.uncheckable)
                    .font(Theme.F.bodyTight)
                    .foregroundStyle(Theme.C.ink)
            }
        } else {
            Panel(fill: Theme.C.sunk, edge: correct ? Theme.C.good : Theme.C.bad,
                  padding: Theme.M.padTight) {
                Text(correct ? "GOT IT" : "NOT YET")
                    .monoCaps()
                    .foregroundStyle(correct ? Theme.C.good : Theme.C.bad)
                Text(extra ?? (correct ? drill.correct : drill.incorrect))
                    .font(Theme.F.bodyTight)
                    .foregroundStyle(Theme.C.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if correct {
            // The lesson's related rows are already on the page.
            if rungIndex > 0 {
                TinyButton(title: "Harder version") {
                    rungIndex -= 1
                    reset()
                }
            }
        } else if !drill.atoms.isEmpty {
            LedgerSheet {
                ForEach(drill.atoms) { link in
                    AtomRow(link: link, last: link.id == drill.atoms.last?.id) { onOpenLink(link) }
                }
            }
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
