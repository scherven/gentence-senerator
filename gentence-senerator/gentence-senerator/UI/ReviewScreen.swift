import SwiftUI

/// What the learner sees after an attempt, in every mode.
struct ReviewScreen: View {
    let turn: Turn
    /// Every turn this review covers, in order, ending with `turn`. One,
    /// except a produce exchange graded whole before answers were graded alone.
    let exchange: [Turn]
    let knowledge: [String: Progress.Encounter.Knowledge]
    let onOpenAtom: (Atom) -> Void
    let onOpenLink: (AtomLink) -> Void
    let onClassify: (Atom, Progress.Encounter.Knowledge) -> Void
    let onAsk: (String) -> Void
    let answers: [AskItem]
    let isAsking: Bool

    /// Findings the learner has opened. Per screen, not persisted: reopening a
    /// review is asking to read it again.
    @State private var opened: Set<String> = []

    private var review: Review? { turn.review }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                specimen

                if let sounds = turn.attempt.pronunciation, !sounds.units.isEmpty {
                    pronunciation(sounds)
                }

                if let review {
                    findings(review)
                    if !review.respeaks.isEmpty {
                        RespeakView(items: review.respeaks)
                    }
                }

                AskView(answers: answers, isAsking: isAsking,
                        onOpenLink: onOpenLink, onAsk: onAsk)
            }
            .padding(Theme.M.gap)
            .padding(.bottom, Theme.M.gap)
        }
        .background(Theme.C.ground)
    }

    // MARK: Pieces

    /// Problems, numbered in order. The number ties the underline to the row.
    private func number(of atom: Atom) -> Int? {
        review?.problems.firstIndex { $0.id == atom.id }.map { $0 + 1 }
    }

    /// Each problem found in an answer on screen: which answer, and where.
    private var located: [String: (answer: Int, span: Store.Span)] {
        var out: [String: (answer: Int, span: Store.Span)] = [:]
        let said = exchange.count > 1 ? exchange.map(\.attempt.confirmed) : [turn.attempt.confirmed]
        for atom in review?.problems ?? [] {
            for (i, text) in said.enumerated() {
                if let span = Store.span(of: atom, in: text) { out[atom.id] = (i, span); break }
            }
        }
        return out
    }

    private func marks(for answer: Int) -> [SpanMark.Mark] {
        (review?.problems ?? []).compactMap { atom in
            guard let hit = located[atom.id], hit.answer == answer else { return nil }
            return SpanMark.Mark(hit.span.range, colour: Theme.colour(for: atom.verdict),
                                 number: number(of: atom))
        }
    }

    private var specimen: some View {
        IndexCard(headRule: nil, pitch: nil) {
            if exchange.count > 1 {
                // A finding can point at any answer here, so all of them are on
                // screen and numbered to match.
                ForEach(Array(exchange.enumerated()), id: \.element.id) { index, past in
                    specimenRow("\(index + 1)", first: index == 0) {
                        Text(past.prompt.target ?? past.prompt.english ?? "")
                            .font(Theme.F.gloss)
                            .foregroundStyle(Theme.C.ink2)
                        SpanMark(past.attempt.confirmed, marks: marks(for: index),
                                 font: Theme.F.target(size: 19, for: past.language))
                    }
                }
            } else {
                if let target = turn.prompt.target {
                    specimenRow(turn.mode == .listen ? "Played" : "Asked", first: true) {
                        Text(target).font(Theme.F.target(size: 19, for: turn.language))
                        if let english = turn.prompt.english {
                            Text(english).font(Theme.F.gloss).foregroundStyle(Theme.C.ink2)
                        }
                    }
                } else if let english = turn.prompt.english {
                    specimenRow("Asked", first: true) {
                        Text(english).font(Theme.F.gloss).foregroundStyle(Theme.C.ink2)
                    }
                }
                specimenRow("You said") {
                    SpanMark(turn.attempt.confirmed, marks: marks(for: 0),
                             font: Theme.F.target(size: 19, for: turn.language))
                }
                if let reference = turn.prompt.reference {
                    specimenRow("Ref") {
                        Text(reference).font(Theme.F.targetSmall(for: turn.language))
                            .foregroundStyle(Theme.C.carbon)
                    }
                }
            }
            if let natural = review?.natural {
                specimenRow("Natural") {
                    Text(natural).font(Theme.F.targetSmall(for: turn.language))
                        .foregroundStyle(Theme.C.carbon)
                }
            }
            if let review, !review.readOfScore.isEmpty {
                specimenRow("Score", last: true) {
                    Text(review.readOfScore).font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                }
            }
        }
        .padding(.top, review == nil ? 0 : 10)
        .overlay(alignment: .topTrailing) {
            if let review {
                Stamp(score: review.score).offset(x: 6, y: -4)
            }
        }
    }

    /// Account | double red margin | entry. Rows abut, so the margin runs the
    /// height of the card.
    private func specimenRow<Content: View>(_ tag: String, first: Bool = false, last: Bool = false,
                                            @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(tag.uppercased())
                .font(Theme.F.label)
                .tracking(0.6)
                .foregroundStyle(Theme.C.ink2)
                .frame(width: 62, alignment: .leading)
                .padding(.top, 6)
            HStack(spacing: 2.5) {
                Rectangle().fill(Theme.C.margin).frame(width: 0.75)
                Rectangle().fill(Theme.C.margin).frame(width: 0.75)
            }
            VStack(alignment: .leading, spacing: 3) { content() }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                // Clear of the stamp.
                .padding(.trailing, first && review != nil ? 64 : 0)
                .padding(.bottom, last ? 0 : 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Problems and praise are listed apart, so the count in the header names
    /// what is under it. Both are shown; only problems stage their reveal.
    private func findings(_ review: Review) -> some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            if !review.problems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ModuleLabel(text: "\(review.problems.count) to fix")
                    LedgerSheet {
                        ForEach(review.problems) { atom in
                            StagedAtomRow(
                                atom: atom,
                                number: number(of: atom),
                                span: located[atom.id]?.span,
                                last: atom.id == review.problems.last?.id,
                                open: binding(for: atom),
                                knowledge: knowledge[atom.id] ?? .unclassified,
                                onClassify: { onClassify(atom, $0) },
                                onOpen: { onOpenAtom(atom) }
                            )
                        }
                    }
                }
            }
            if !review.kept.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ModuleLabel(text: "Got right")
                    LedgerSheet {
                        ForEach(review.kept) { atom in
                            KeptRow(atom: atom, last: atom.id == review.kept.last?.id) {
                                onOpenAtom(atom)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The weakest sounds, worst first, each openable. Names are absent outside
    /// English and Mandarin, so a unit falls back to the word it sat in.
    private func pronunciation(_ result: PronunciationResult) -> some View {
        let weak = result.units.filter { $0.score < 70 }.sorted { $0.score < $1.score }.prefix(4)
        return VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: "Sounds · \(result.overall)")
            VStack(spacing: 0) {
                ForEach(Array(weak)) { unit in
                    Button {
                        onOpenAtom(Atom(
                            id: "pronunciation/\(unit.name ?? unit.gloss ?? "\(unit.index)")",
                            kind: .pronunciation, verdict: .weakens,
                            stages: .init(
                                locate: "Scored \(unit.score).",
                                name: unit.name.map { "Sound \($0)." }
                                    ?? "A sound in \(unit.gloss ?? "this word").",
                                fix: unit.gloss ?? "",
                                note: ""
                            ),
                            seed: .init(subject: unit.name ?? unit.gloss ?? "",
                                        context: turn.attempt.confirmed, pointID: nil)
                        ))
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(unit.name ?? unit.gloss ?? "—")
                                .font(Theme.F.targetSmall)
                            Text(unit.name == nil ? "sound \(unit.index + 1)" : (unit.gloss ?? ""))
                                .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(unit.score)")
                                .font(Theme.F.meta).foregroundStyle(Theme.C.warn)
                            Text("+").font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                        }
                        .padding(Theme.M.padTight)
                        .background(Theme.C.surface)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Theme.C.warn).frame(width: Theme.M.edge)
                        }
                        .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func binding(for atom: Atom) -> Binding<Bool> {
        Binding(
            get: { opened.contains(atom.id) },
            set: { if $0 { opened.insert(atom.id) } else { opened.remove(atom.id) } }
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
                    .targetLanguageInput()
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

            TinyButton(title: "Another change") {
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
