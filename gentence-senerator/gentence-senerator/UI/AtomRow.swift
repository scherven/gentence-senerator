import SwiftUI

/// A way onward that opens straight away. Used inside lessons, drill results
/// and answers — anywhere the three-beat reveal would be ceremony.
struct AtomRow: View {
    let link: AtomLink
    /// The leading edge. Seam by default: a link is not a consequence.
    var tint: Color = Theme.C.seam2
    var last = false
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            LedgerRow(account: link.kind.label, colour: Theme.C.ink2, edge: tint, ruled: !last) {
                Text(link.headline)
                    .font(Theme.F.bodyTight)
                    .foregroundStyle(Theme.C.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                Text("›").font(Theme.F.label).foregroundStyle(Theme.C.ink3)
                    .padding(.top, 12).padding(.trailing, 10)
            }
            .background(Theme.C.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
    }
}

/// A finding revealed in two beats: where, then what it is and the fix.
///
/// Closed, the row says only where the trouble is, which is the learner's
/// chance to repair it themselves. Opening it is them saying they want the
/// answer, so the answer arrives — there is nothing left to confirm. After it
/// they say whether they knew it, which decides whether this is scheduled.
///
/// Every stage arrives with the review; the staging is only in what is shown.
struct StagedAtomRow: View {
    let atom: Atom
    /// Shared with the underline in the sentence.
    var number: Int? = nil
    /// Where it is in the sentence, if it could be found.
    var span: Store.Span? = nil
    var last = false
    @Binding var open: Bool
    let knowledge: Progress.Encounter.Knowledge
    let onClassify: (Progress.Encounter.Knowledge) -> Void
    let onOpen: () -> Void

    /// Reviews from before grading moved to a batch can be missing everything
    /// after `locate`; those stay on it.
    private var headline: String {
        open && atom.isDeep ? atom.stages.name : atom.stages.locate
    }

    private var colour: Color { Theme.colour(for: atom.verdict) }

    var body: some View {
        LedgerRow(account: atom.verdict.rawValue, colour: colour, number: number,
                  edge: colour, ruled: !last) {
            VStack(alignment: .leading, spacing: 4) {
                if atom.weight == .start && !open {
                    Text("START HERE").monoCaps().foregroundStyle(Theme.C.ink2)
                }
                Text(atom.kind.label).monoCaps(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                Text(headline)
                    .font(Theme.F.bodyTight)
                    .foregroundStyle(Theme.C.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if open { opened }
            }
        } trailing: {
            // Open, the entry takes the width; LESSON › sits under the fix.
            if !open {
                Text("FIX +")
                    .font(Theme.F.label)
                    .tracking(Theme.M.caps)
                    .foregroundStyle(Theme.C.ink3)
                    .fixedSize()
                    .padding(.top, 12)
                    .padding(.trailing, 10)
            }
        }
        .background(Theme.C.surface)
        .contentShape(Rectangle())
        .onTapGesture(perform: advance)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var opened: some View {
        if !atom.isDeep {
            Text("No fix.")
                .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
        } else {
            FixLine(span: span, fix: atom.stages.fix).padding(.top, 4)

            Text(atom.stages.note)
                .font(Theme.F.note)
                .foregroundStyle(Theme.C.ink2)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) { classify; Spacer(minLength: Theme.M.gapTight); lesson }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) { classify }
                    lesson
                }
            }
            .padding(.top, 4)
        }
    }

    private var lesson: some View {
        Text("LESSON ›")
            .font(Theme.F.label)
            .tracking(Theme.M.caps)
            .foregroundStyle(Theme.C.accent)
            .fixedSize()
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private var classify: some View {
        TinyButton(title: "I knew that",
                   selected: knowledge == .slip) { onClassify(.slip) }
            .fixedSize()
        TinyButton(title: "New to me",
                   selected: knowledge == .gap) { onClassify(.gap) }
            .fixedSize()
    }

    private func advance() {
        if !open { open = true } else if atom.isDeep { onOpen() }
    }
}

/// `wrong → right`, the right half in the good colour. Without a located
/// span, only the fix.
struct FixLine: View {
    let span: Store.Span?
    let fix: String

    var body: some View {
        let target = Theme.F.target(size: 15)
        let right = Text(span?.right.map { $0.isEmpty ? "—" : $0 } ?? fix)
            .font(Theme.F.target(size: 15, bold: true))
            .foregroundColor(Theme.C.good)
        Group {
            if let span {
                Text(span.wrong).font(target).foregroundColor(Theme.C.ink)
                    + Text("  →  ").font(Theme.F.meta).foregroundColor(Theme.C.ink3)
                    + right
            } else {
                Text("→  ").font(Theme.F.meta).foregroundColor(Theme.C.ink3) + right
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Something that worked: what, and the words. Opens its lesson.
struct KeptRow: View {
    let atom: Atom
    var last = false
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            LedgerRow(account: atom.verdict.rawValue, colour: Theme.C.good,
                      edge: Theme.C.good, ruled: !last) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(atom.stages.name.isEmpty ? atom.kind.label : atom.stages.name)
                        .font(Theme.F.bodyTight)
                        .foregroundStyle(Theme.C.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !atom.stages.fix.isEmpty {
                        Text(atom.stages.fix)
                            .font(Theme.F.target(size: 13))
                            .foregroundStyle(Theme.C.ink3)
                    }
                }
            } trailing: {
                Text("›").font(Theme.F.label).foregroundStyle(Theme.C.ink3)
                    .padding(.top, 12).padding(.trailing, 10)
            }
            .background(Theme.C.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
    }
}
