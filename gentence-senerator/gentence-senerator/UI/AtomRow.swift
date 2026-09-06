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

/// A finding revealed in three beats: where, then what, then the fix.
///
/// The learner gets a chance to self-repair at each step, and after the fix is
/// shown they say whether they knew it — which decides whether this is
/// scheduled at all.
struct StagedAtomRow: View {
    let atom: Atom
    @Binding var stage: Int
    let knowledge: Progress.Encounter.Knowledge
    let onClassify: (Progress.Encounter.Knowledge) -> Void
    let onOpen: () -> Void

    private var headline: String {
        stage == 0 ? atom.stages.locate : atom.stages.name
    }

    private var affordance: String {
        switch stage {
        case 0:  return "NAME IT +"
        case 1:  return "FIX +"
        default: return "LESSON →"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if atom.weight == .start && stage == 0 {
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

            if stage >= 1 { body(for: stage) }
        }
    }

    @ViewBuilder
    private func body(for stage: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.M.gapTight) {
            if stage == 1 {
                Text("Fix it yourself first.")
                    .font(Theme.F.note)
                    .foregroundStyle(Theme.C.ink2)
                HStack(spacing: 0) {
                    TinyButton(title: "I've got it") { self.stage = 2 }
                    TinyButton(title: "Show the fix") { self.stage = 2 }
                }
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
                    TinyButton(title: "Open the lesson", action: onOpen)
                }

                switch knowledge {
                case .slip:
                    Text("Slip. Speed round, not a lesson.")
                        .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                case .gap:
                    Text("Gap. Back in a sentence within days.")
                        .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                case .unclassified:
                    EmptyView()
                }
            }
        }
        .padding(Theme.M.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.C.sunk)
        .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
    }

    private func advance() {
        if stage >= 2 { onOpen() } else { stage += 1 }
    }
}
