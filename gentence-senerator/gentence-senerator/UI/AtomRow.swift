import SwiftUI

/// A way onward that opens straight away. Used inside lessons, drill results
/// and answers — anywhere the three-beat reveal would be ceremony.
struct AtomRow: View {
    let link: AtomLink
    var tint: Color = Theme.C.accent
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Text(link.kind.label.uppercased())
                    .font(Theme.F.label)
                    .tracking(1)
                    .foregroundStyle(tint)
                    .frame(width: 84, alignment: .leading)
                    .padding(.top, 2)

                Text(link.headline)
                    .font(Theme.F.bodyTight)
                    .foregroundStyle(Theme.C.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("+")
                    .font(Theme.F.meta)
                    .foregroundStyle(Theme.C.ink3)
            }
            .padding(Theme.M.padTight)
            .background(Theme.C.surface)
            .overlay(alignment: .leading) {
                Rectangle().fill(tint).frame(width: Theme.M.edge)
            }
            .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
        }
        .buttonStyle(.plain)
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
    @Binding var open: Bool
    let knowledge: Progress.Encounter.Knowledge
    let onClassify: (Progress.Encounter.Knowledge) -> Void
    let onOpen: () -> Void

    /// Reviews from before grading moved to a batch can be missing everything
    /// after `locate`; those stay on it.
    private var headline: String {
        open && atom.isDeep ? atom.stages.name : atom.stages.locate
    }

    private var affordance: String { open ? "LESSON →" : "FIX +" }

    var body: some View {
        VStack(spacing: 0) {
            if atom.weight == .start && !open {
                Text("START HERE")
                    .font(Theme.F.label)
                    .tracking(1.2)
                    .foregroundStyle(Theme.C.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 3)
            }

            Button { advance() } label: {
                HStack(alignment: .top, spacing: 10) {
                    Text(atom.kind.label.uppercased())
                        .font(Theme.F.label)
                        .tracking(1)
                        .foregroundStyle(Theme.colour(for: atom.verdict))
                        .frame(width: 84, alignment: .leading)
                        .padding(.top, 2)

                    Text(headline)
                        .font(Theme.F.bodyTight)
                        .foregroundStyle(Theme.C.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(affordance)
                        .font(Theme.F.label)
                        .foregroundStyle(Theme.C.ink3)
                        .padding(.top, 3)
                }
                .padding(Theme.M.padTight)
                .background(Theme.C.surface)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.colour(for: atom.verdict))
                        .frame(width: Theme.M.edge)
                }
                .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
            }
            .buttonStyle(.plain)

            if open { opened }
        }
    }

    @ViewBuilder
    private var opened: some View {
        VStack(alignment: .leading, spacing: Theme.M.gapTight) {
            if !atom.isDeep {
                Text("No fix.")
                    .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
            } else {
                Text(atom.stages.fix)
                    .font(Theme.F.targetSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.M.padTight)
                    .background(Theme.C.surface)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.C.good).frame(width: Theme.M.edge)
                    }
                    .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))

                Text(atom.stages.note)
                    .font(Theme.F.bodyTight)
                    .foregroundStyle(Theme.C.ink)

                HStack(spacing: 0) {
                    TinyButton(title: "I knew that",
                               selected: knowledge == .slip) { onClassify(.slip) }
                    TinyButton(title: "New to me",
                               selected: knowledge == .gap) { onClassify(.gap) }
                    TinyButton(title: "Lesson", action: onOpen)
                }
            }
        }
        .padding(Theme.M.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.C.sunk)
        .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
    }

    private func advance() {
        if !open { open = true } else if atom.isDeep { onOpen() }
    }
}
