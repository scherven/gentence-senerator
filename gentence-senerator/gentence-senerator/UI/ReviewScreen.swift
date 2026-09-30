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
            ModuleLabel(text: "Sounds", trailing: "\(result.overall)")
            LedgerSheet {
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
                        LedgerRow(account: "\(unit.score)", colour: Theme.C.warn, edge: Theme.C.warn,
                                  accountWidth: 48, ruled: unit.id != weak.last?.id) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(unit.name ?? unit.gloss ?? "—")
                                    .font(Theme.F.targetSmall)
                                    .foregroundStyle(Theme.C.ink)
                                Text(unit.name == nil ? "sound \(unit.index + 1)" : (unit.gloss ?? ""))
                                    .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
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
        Panel {
            Text(item.instruction)
                .font(Theme.F.body)
                .foregroundStyle(Theme.C.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.M.gapTight) {
                TextField("Say it…", text: $input)
                    .font(Theme.F.targetSmall)
                    .foregroundStyle(Theme.C.ink)
                    .textFieldStyle(.plain)
                    .targetLanguageInput()
                    .submitLabel(.done)
                    .onSubmit(check)
                    .inset(padding: Theme.M.padTight)
                TinyButton(title: "Check", action: check)
            }

            if let result {
                Panel(fill: Theme.C.sunk, edge: result ? Theme.C.good : Theme.C.bad,
                      padding: Theme.M.padTight) {
                    Text(result ? "GOT IT" : "NOT YET")
                        .monoCaps()
                        .foregroundStyle(result ? Theme.C.good : Theme.C.bad)
                    Text(result ? item.correct : item.incorrect)
                        .font(Theme.F.bodyTight)
                        .foregroundStyle(Theme.C.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TinyButton(title: "Another change") {
                index += 1
                input = ""
                result = nil
            }
        }
    }

    private func check() {
        result = item.accept.contains { Rung.normalise($0) == Rung.normalise(input) }
    }
}

/// Reading reviews: the header, the review, the key onward. After the last
/// review of a batch, its summary, then Today.
struct ReviewReader: View {
    @Bindable var store: Store
    /// The batch as it was opened. `store.reading` shrinks as it is read.
    @State private var batch: [UUID] = []
    @State private var summary = false

    private var title: String { (store.current?.mode ?? store.settings.mode).name }

    private var position: String {
        if !batch.isEmpty {
            let at = summary ? batch.count : batch.count - store.reading.count + 1
            return "\(min(max(at, 1), batch.count))/\(batch.count)"
        }
        guard let session = store.session else { return "" }
        return "\(session.completedCount)/\(session.goal)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if summary {
                BatchSummary(turns: store.reviewed(batch))
            } else if let turn = store.current {
                screen(turn)
            }
            footer
        }
        .background(Theme.C.ground)
        .toolbar(.hidden, for: .navigationBar)
        .pageHeader(PageHeader(lead: .end(), title: title, onLead: { store.endSession() }) {
            Text(position)
        })
        .onAppear { if batch.isEmpty { batch = store.reading } }
    }

    private func screen(_ turn: Turn) -> some View {
        ReviewScreen(
            turn: turn,
            exchange: store.exchange(endingAt: turn),
            knowledge: store.knowledge,
            onOpenAtom: { store.open($0) },
            onOpenLink: { store.open($0, context: turn.attempt.confirmed) },
            onClassify: { store.classify($0, as: $1) },
            onAsk: { question in
                Task {
                    await store.ask(question,
                                    about: .init(subject: turn.attempt.confirmed,
                                                 context: turn.attempt.confirmed,
                                                 pointID: turn.prompt.pointID),
                                    context: turn.id.uuidString)
                }
            },
            answers: store.asked[turn.id.uuidString] ?? [],
            isAsking: store.asking.contains(turn.id.uuidString)
        )
        .id(turn.id)
    }

    private var footer: some View {
        let lastOfBatch = !batch.isEmpty && store.reading.count == 1
        return ActionKey(summary || lastOfBatch ? "Done" : "Next ›") {
            if lastOfBatch && !summary {
                summary = true
            } else {
                Task { await store.advance() }
            }
        }
        .padding(.horizontal, Theme.M.gap)
        .padding(.vertical, Theme.M.gapTight)
        .background(Theme.C.ground)
        .overlay(alignment: .top) { Rectangle().fill(Theme.C.ink).frame(height: Theme.M.hair) }
    }
}

/// A batch, read: each sentence's score as a tick, and what there was to fix.
struct BatchSummary: View {
    let turns: [Turn]

    private var scores: [Int] { turns.compactMap { $0.review?.score } }
    private var toFix: Int { turns.reduce(0) { $0 + ($1.review?.problems.count ?? 0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(scores.enumerated()), id: \.offset) { _, score in
                        VStack(spacing: 4) {
                            Rectangle().fill(Theme.band(score))
                                .frame(width: 14, height: 8 + CGFloat(score) * 0.32)
                            Text("\(score)").font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                        }
                    }
                    Spacer(minLength: 0)
                    if !scores.isEmpty {
                        Stamp(score: scores.reduce(0, +) / scores.count)
                    }
                }
                ModuleLabel(text: "\(turns.count) sentence\(turns.count == 1 ? "" : "s")",
                            trailing: "\(toFix) to fix")
                LedgerSheet {
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        let score = turn.review?.score ?? 0
                        LedgerRow(account: "\(index + 1)", colour: Theme.C.ink2,
                                  edge: Theme.band(score), accountWidth: 40,
                                  ruled: index < turns.count - 1) {
                            Text(turn.attempt.confirmed)
                                .font(Theme.F.targetSmall(for: turn.language))
                                .foregroundStyle(Theme.C.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        } trailing: {
                            Text("\(score)")
                                .font(Theme.F.label)
                                .foregroundStyle(Theme.band(score))
                                .padding(.top, 12).padding(.trailing, 10)
                        }
                    }
                }
            }
            .padding(Theme.M.gap)
        }
    }
}
