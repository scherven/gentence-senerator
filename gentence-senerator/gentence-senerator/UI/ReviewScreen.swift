import SwiftUI

/// What the learner sees after an attempt, in every mode.
struct ReviewScreen: View {
    let turn: Turn
    let knowledge: [String: Progress.Encounter.Knowledge]
    let onOpenAtom: (Atom) -> Void
    let onClassify: (Atom, Progress.Encounter.Knowledge) -> Void
    let onAsk: (String) -> Void
    let ask: [AskItem]

    @State private var stages: [String: Int] = [:]

    private var review: Review? { turn.review }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                specimen

                if let review {
                    findings(review)
                    if let natural = review.natural {
                        sentence(natural, label: "What a speaker would say", edge: Theme.C.accent)
                    }
                    if !review.respeaks.isEmpty {
                        respeak(review.respeaks)
                    }
                }

                if !ask.isEmpty {
                    AskView(items: ask, onOpenAtom: onOpenAtom, onAsk: onAsk)
                }
            }
            .padding(Theme.M.gap)
        }
        .background(Theme.C.surface)
    }

    // MARK: Pieces

    private var specimen: some View {
        VStack(spacing: 0) {
            if let english = turn.prompt.english {
                specimenRow("Asked") {
                    Text(english).font(Theme.F.body).foregroundStyle(Theme.C.ink)
                }
            }
            if let target = turn.prompt.target {
                specimenRow(turn.mode == .listen ? "Played" : "Asked") {
                    Text(target).font(Theme.F.target).foregroundStyle(Theme.C.ink)
                }
            }
            specimenRow("You said") {
                Text(turn.attempt.confirmed)
                    .font(Theme.F.target)
                    .foregroundStyle(review.map { $0.problems.isEmpty ? Theme.C.ink : Theme.C.bad } ?? Theme.C.ink)
            }
            if let review {
                specimenRow("Score") {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(review.score)")
                            .font(Theme.F.number)
                            .foregroundStyle(Theme.C.ink)
                        Text(review.readOfScore)
                            .font(Theme.F.note)
                            .foregroundStyle(Theme.C.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .background(Theme.C.sunk)
        .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
    }

    private func specimenRow<Content: View>(_ tag: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Theme.M.pad) {
            Text(tag.uppercased())
                .font(Theme.F.label)
                .tracking(1)
                .foregroundStyle(Theme.C.ink3)
                .frame(width: 58, alignment: .leading)
                .padding(.top, 4)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.M.padTight)
    }

    private func findings(_ review: Review) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: label(for: review.problems.count))
            VStack(spacing: 0) {
                ForEach(review.atoms) { atom in
                    if atom.verdict.isProblem {
                        StagedAtomRow(
                            atom: atom,
                            stage: binding(for: atom),
                            knowledge: knowledge[atom.id] ?? .unclassified,
                            onClassify: { onClassify(atom, $0) },
                            onOpen: { onOpenAtom(atom) }
                        )
                    } else {
                        AtomRow(atom: atom) { onOpenAtom(atom) }
                    }
                }
            }
        }
    }

    private func label(for count: Int) -> String {
        switch count {
        case 0:  return "Nothing to fix"
        case 1:  return "One thing to look at"
        default: return "\(count) things to look at"
        }
    }

    private func sentence(_ text: String, label: String, edge: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: label)
            Text(text)
                .font(Theme.F.target)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.M.pad)
                .background(Theme.C.surface)
                .overlay(alignment: .leading) {
                    Rectangle().fill(edge).frame(width: Theme.M.edge)
                }
                .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
        }
    }

    private func respeak(_ items: [Respeak]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: "Say it again, changed")
            RespeakView(items: items)
        }
    }

    private func binding(for atom: Atom) -> Binding<Int> {
        Binding(
            get: { stages[atom.id] ?? 0 },
            set: { stages[atom.id] = $0 }
        )
    }
}

/// The learner's own sentence with one thing moved. Cycling the change stops it
/// becoming recall of the correction.
struct RespeakView: View {
    let items: [Respeak]

    @State private var index = 0
    @State private var input = ""
    @State private var result: Bool?

    private var item: Respeak { items[index % items.count] }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.M.gapTight) {
            Text(item.instruction)
                .font(Theme.F.body)
                .foregroundStyle(Theme.C.ink)

            HStack(spacing: 0) {
                TextField("Say it…", text: $input)
                    .font(Theme.F.targetSmall)
                    .textFieldStyle(.plain)
                    .padding(Theme.M.padTight)
                    .background(Theme.C.sunk)
                    .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
                    .submitLabel(.done)
                    .onSubmit(check)
                TinyButton(title: "Check", action: check)
            }

            if let result {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result ? "GOT IT" : "NOT YET")
                        .font(Theme.F.label)
                        .tracking(1.2)
                        .foregroundStyle(result ? Theme.C.good : Theme.C.bad)
                    Text(result ? item.correct : item.incorrect)
                        .font(Theme.F.bodyTight)
                        .foregroundStyle(Theme.C.ink)
                }
                .padding(.leading, Theme.M.gapTight)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(result ? Theme.C.good : Theme.C.bad)
                        .frame(width: Theme.M.edge)
                }
            }

            TinyButton(title: "A different change") {
                index += 1
                input = ""
                result = nil
            }
        }
        .padding(Theme.M.pad)
        .background(Theme.C.surface)
        .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
    }

    private func check() {
        result = item.accept.contains { Rung.normalise($0) == Rung.normalise(input) }
    }
}
