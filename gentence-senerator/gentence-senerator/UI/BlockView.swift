import SwiftUI

/// The one renderer. Reviews and lessons are both lists of blocks, so neither
/// owns a component the other cannot use.
struct BlockView: View {
    let block: Block
    let onOpenLink: (AtomLink) -> Void
    let onOpenSeed: (Atom.Seed, AtomKind) -> Void
    let onDrillOutcome: (Bool, Rung.Support) -> Void
    let grade: (String, Rung) async -> Tutor.DrillVerdict

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = block.label { ModuleLabel(text: label) }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .rule:
            IndexCard(headRule: nil, pitch: nil) {
                Text(block.text ?? "")
                    .font(Theme.F.body)
                    .foregroundStyle(Theme.C.ink)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .contrast:
            HStack(spacing: 0) {
                ForEach(Array((block.sides ?? []).enumerated()), id: \.element.id) { index, side in
                    if index > 0 { Rectangle().fill(Theme.C.seam).frame(width: Theme.M.hair) }
                    contrastSide(side)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .overlay(Rectangle().strokeBorder(Theme.C.seam, lineWidth: Theme.M.hair))

        case .examples:
            LedgerSheet {
                let examples = block.examples ?? []
                ForEach(Array(examples.enumerated()), id: \.element.id) { index, example in
                    exampleRow(example, number: index + 1, last: index == examples.count - 1)
                }
            }

        case .drills:
            VStack(spacing: Theme.M.gapTight) {
                ForEach(block.drills ?? []) { drill in
                    DrillView(drill: drill,
                              onOpenLink: onOpenLink,
                              onOutcome: onDrillOutcome,
                              grade: grade)
                }
            }

        case .atoms:
            LedgerSheet {
                let links = block.atoms ?? []
                ForEach(links) { link in
                    AtomRow(link: link, last: link.id == links.last?.id) { onOpenLink(link) }
                }
            }
        }
    }

    @ViewBuilder
    private func contrastSide(_ side: Side) -> some View {
        let inner = VStack(alignment: .leading, spacing: 3) {
            Text(side.term)
                .font(Theme.F.targetSmall)
                .foregroundStyle(side.seed == nil ? Theme.C.ink : Theme.C.accent)
            Text(side.seed == nil ? side.note : side.note + "  ›")
                .font(Theme.F.note)
                .foregroundStyle(Theme.C.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.M.pad)
        .background(Theme.C.surface)

        if let seed = side.seed {
            Button { onOpenSeed(seed, .wordChoice) } label: { inner }
                .buttonStyle(.plain)
        } else {
            inner
        }
    }

    @ViewBuilder
    private func exampleRow(_ example: Example, number: Int, last: Bool) -> some View {
        let inner = LedgerRow(account: "\(number)", colour: Theme.C.ink3,
                              accountWidth: 34, ruled: !last) {
            VStack(alignment: .leading, spacing: 2) {
                Text(example.target)
                    .font(Theme.F.targetSmall)
                    .foregroundStyle(Theme.C.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(example.gloss)
                    .font(Theme.F.gloss)
                    .foregroundStyle(Theme.C.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } trailing: {
            if example.seed != nil {
                Text("›").font(Theme.F.label).foregroundStyle(Theme.C.ink3)
                    .padding(.top, 12).padding(.trailing, 10)
            }
        }
        .background(Theme.C.surface)
        .contentShape(Rectangle())

        if let seed = example.seed {
            Button { onOpenSeed(seed, .wordChoice) } label: { inner }
                .buttonStyle(PressDim())
        } else {
            inner
        }
    }
}

/// A free field, and whatever the learner has already asked here. Answers are
/// themselves openable. Appears at the foot of every review and every lesson.
struct AskView: View {
    /// Answers to questions the learner typed here. Nothing is written until
    /// they ask — a guessed question costs more than it teaches.
    let answers: [AskItem]
    let isAsking: Bool
    let onOpenLink: (AtomLink) -> Void
    let onAsk: (String) -> Void

    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(answers) { item in
                Panel {
                    Text(item.question)
                        .font(Theme.F.gloss)
                        .foregroundStyle(Theme.C.ink2)
                    Text(item.answer)
                        .font(Theme.F.bodyTight)
                        .foregroundStyle(Theme.C.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.atoms.isEmpty {
                        LedgerSheet {
                            ForEach(item.atoms) { link in
                                AtomRow(link: link, last: link.id == item.atoms.last?.id) {
                                    onOpenLink(link)
                                }
                            }
                        }
                    }
                }
            }

            HStack(alignment: .center, spacing: Theme.M.gapTight) {
                TextField(isAsking ? "Thinking…" : "Ask a question…", text: $typed)
                    .font(Theme.F.bodyTight)
                    .foregroundStyle(Theme.C.ink)
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .disabled(isAsking)
                    .inset(padding: Theme.M.padTight)
                if isAsking {
                    Ticker()
                } else {
                    TinyButton(title: "Ask", action: send)
                }
            }
        }
    }

    private func send() {
        let question = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        onAsk(question)
        typed = ""
    }
}
