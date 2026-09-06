import SwiftUI

/// The one renderer. Reviews and lessons are both lists of blocks, so neither
/// owns a component the other cannot use.
struct BlockView: View {
    let block: Block
    let onOpenAtom: (Atom) -> Void
    let onOpenSeed: (Atom.Seed, AtomKind) -> Void
    let onDrillOutcome: (Bool, Rung.Support) -> Void

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
            Text(block.text ?? "")
                .font(Theme.F.body)
                .foregroundStyle(Theme.C.ink)
                .fixedSize(horizontal: false, vertical: true)

        case .contrast:
            HStack(spacing: 0) {
                ForEach(block.sides ?? []) { side in
                    contrastSide(side)
                }
            }
            .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))

        case .examples:
            VStack(spacing: 0) {
                ForEach(block.examples ?? []) { example in
                    exampleRow(example)
                }
            }

        case .drills:
            VStack(spacing: 0) {
                ForEach(block.drills ?? []) { drill in
                    DrillView(drill: drill,
                              onOpenAtom: onOpenAtom,
                              onOutcome: onDrillOutcome)
                }
            }

        case .atoms:
            VStack(spacing: 0) {
                ForEach(block.atoms ?? []) { atom in
                    AtomRow(atom: atom) { onOpenAtom(atom) }
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
            Text(side.seed == nil ? side.note : side.note + "  +")
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
    private func exampleRow(_ example: Example) -> some View {
        let inner = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(example.target)
                .font(Theme.F.targetSmall)
                .foregroundStyle(Theme.C.ink)
            Text(example.gloss)
                .font(Theme.F.note)
                .foregroundStyle(Theme.C.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if example.seed != nil {
                Text("+").font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
            }
        }
        .padding(Theme.M.padTight)
        .background(Theme.C.surface)
        .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))

        if let seed = example.seed {
            Button { onOpenSeed(seed, .wordChoice) } label: { inner }
                .buttonStyle(.plain)
        } else {
            inner
        }
    }
}

/// Suggested questions with answers that are themselves openable, plus a free
/// field. Appears at the foot of every review and every lesson.
struct AskView: View {
    let items: [AskItem]
    let onOpenAtom: (Atom) -> Void
    let onAsk: (String) -> Void

    @State private var expanded: Set<String> = []
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: "Ask about this")

            VStack(spacing: 0) {
                ForEach(items) { item in
                    let open = expanded.contains(item.id)

                    Button {
                        if open { expanded.remove(item.id) } else { expanded.insert(item.id) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(item.question)
                                .font(Theme.F.bodyTight)
                                .foregroundStyle(Theme.C.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(open ? "−" : "?")
                                .font(Theme.F.meta)
                                .foregroundStyle(Theme.C.ink3)
                        }
                        .padding(Theme.M.padTight)
                        .background(open ? Theme.C.sunk : Theme.C.surface)
                        .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
                    }
                    .buttonStyle(.plain)

                    if open {
                        VStack(alignment: .leading, spacing: Theme.M.gapTight) {
                            Text(item.answer)
                                .font(Theme.F.bodyTight)
                                .foregroundStyle(Theme.C.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(item.atoms) { atom in
                                AtomRow(atom: atom) { onOpenAtom(atom) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.M.pad)
                        .background(Theme.C.sunk)
                        .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
                    }
                }
            }

            HStack(spacing: 0) {
                TextField("Ask something else…", text: $typed)
                    .font(Theme.F.bodyTight)
                    .textFieldStyle(.plain)
                    .padding(Theme.M.padTight)
                    .background(Theme.C.sunk)
                    .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
                    .submitLabel(.send)
                    .onSubmit(send)
                TinyButton(title: "Ask", action: send)
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
