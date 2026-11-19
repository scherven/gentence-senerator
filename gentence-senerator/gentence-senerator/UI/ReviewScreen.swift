import SwiftUI

/// What the learner sees after an attempt, in every mode.
struct ReviewScreen: View {
    let turn: Turn
    /// Every turn this review covers, in order, ending with `turn`. One,
    /// except a produce exchange graded whole before answers were graded alone.
    let exchange: [Turn]
    let knowledge: [String: Progress.Encounter.Knowledge]
    let onOpenLink: (AtomLink) -> Void
    let onClassify: (Atom, Progress.Encounter.Knowledge) -> Void
    /// When each finding comes back.
    let back: (String) -> String?
    /// Nil when the dispute was sent, else the line to show.
    let onDispute: (Atom, String) async -> String?
    let disputed: Set<String>
    let onAsk: (String) -> Void
    let answers: [AskItem]
    let isAsking: Bool
    /// A point id's name, for the link under a finding.
    var pointName: (String) -> String? = { _ in nil }
    @Environment(\.openPoint) private var openPoint

    /// Findings the learner has opened. Per screen, not persisted: reopening a
    /// review is asking to read it again.
    @State private var opened: Set<String> = []
    @State private var showKept = false
    @State private var showRespeak = false

    private var review: Review? { turn.review }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                asked
                specimen

                if let review {
                    findings(review)
                    native(review)
                }

                if let sounds = turn.attempt.pronunciation, !sounds.units.isEmpty {
                    pronunciation(sounds)
                }

                if let review {
                    kept(review)
                    if !review.respeaks.isEmpty {
                        if showRespeak {
                            RespeakView(items: review.respeaks)
                        } else {
                            TinyButton(title: "Say it with a change") { showRespeak = true }
                                .fixedSize()
                        }
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

    /// What was asked, set back, with the score stamped beside it.
    private var asked: some View {
        HStack(alignment: .top, spacing: Theme.M.gapTight) {
            VStack(alignment: .leading, spacing: 3) {
                if turn.mode == .reply, let from = turn.prompt.context {
                    Text(from.uppercased()).font(Theme.F.meta).tracking(Theme.M.caps)
                        .foregroundStyle(Theme.C.ink2)
                }
                if exchange.count > 1 {
                    EmptyView()
                } else if turn.mode == .translate {
                    Text(turn.prompt.english ?? "").font(Theme.F.gloss).foregroundStyle(Theme.C.ink2)
                } else if turn.mode != .listen, let target = turn.prompt.target {
                    Text(target).font(Theme.F.targetSmall(for: turn.language))
                        .foregroundStyle(Theme.C.ink2)
                    if let english = turn.prompt.english {
                        Text(english).font(Theme.F.note).foregroundStyle(Theme.C.ink3)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let review { Stamp(score: review.score) }
        }
    }

    /// The fixed sentence, its changes marked against what was said.
    private var fixLine: (text: String, marks: [SpanMark.Mark], tag: String)? {
        if turn.mode == .listen, let played = turn.prompt.target {
            let apart = Store.divergence(turn.attempt.confirmed, played, language: turn.language)
            return (played, apart.ref.map { .init($0, colour: Theme.C.good) }, "Played")
        }
        guard let fixed = review?.fixed, !(review?.problems.isEmpty ?? true),
              fixed != turn.attempt.confirmed else { return nil }
        let apart = Store.divergence(turn.attempt.confirmed, fixed, language: turn.language)
        return (fixed, apart.ref.map { .init($0, colour: Theme.C.good) }, "Fix")
    }

    private var specimen: some View {
        let font = Theme.F.target(size: 19, for: turn.language)
        return LedgerSheet {
            if exchange.count > 1 {
                // A legacy held exchange: a finding can point at any answer,
                // so all of them are on screen and numbered to match.
                ForEach(Array(exchange.enumerated()), id: \.element.id) { index, past in
                    specimenRow("\(index + 1)", last: index == exchange.count - 1) {
                        Text(past.prompt.target ?? past.prompt.english ?? "")
                            .font(Theme.F.gloss)
                            .foregroundStyle(Theme.C.ink2)
                        SpanMark(past.attempt.confirmed, marks: marks(for: index), font: font)
                    }
                }
            } else {
                specimenRow("You", last: fixLine == nil) {
                    SpanMark(turn.attempt.confirmed, marks: marks(for: 0), font: font)
                }
                if let fix = fixLine {
                    specimenRow(fix.tag, last: true) {
                        SpanMark(fix.text, marks: fix.marks, font: font)
                    }
                }
            }
        }
    }

    private func specimenRow<Content: View>(_ tag: String, last: Bool,
                                            @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(tag.uppercased())
                .font(Theme.F.account)
                .tracking(0.6)
                .foregroundStyle(Theme.C.ink2)
                .frame(width: 44 * Theme.F.growth(11, mono: true, upTo: Theme.F.accountCap),
                       alignment: .leading)
            VStack(alignment: .leading, spacing: 3) { content() }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.C.rule.opacity(0.45)).frame(height: Theme.M.hair) }
        }
    }

    /// One row per problem, in order of cost.
    @ViewBuilder
    private func findings(_ review: Review) -> some View {
        if !review.problems.isEmpty {
            LedgerSheet {
                ForEach(review.problems) { atom in
                    FindingRow(
                        atom: atom,
                        number: number(of: atom),
                        span: located[atom.id]?.span,
                        last: atom.id == review.problems.last?.id,
                        open: binding(for: atom),
                        knowledge: knowledge[atom.id] ?? .unclassified,
                        onClassify: { onClassify(atom, $0) },
                        back: back(atom.id),
                        disputed: disputed.contains(atom.id),
                        onDispute: { await onDispute(atom, $0) },
                        point: atom.seed.pointID.flatMap { id in
                            pointName(id).map { (name: $0, open: { openPoint(id) }) }
                        }
                    )
                }
            }
        }
    }

    /// What a speaker would say, when it is not the fix. In translate with
    /// no such line, the reference the learner saw.
    @ViewBuilder
    private func native(_ review: Review) -> some View {
        let shown = [review.fixed, turn.attempt.confirmed].compactMap { $0 }
        let line = review.natural ?? (turn.mode == .translate ? turn.prompt.reference : nil)
        if turn.mode != .listen, let line, !shown.contains(line) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("NATIVE").font(Theme.F.account).tracking(0.6).foregroundStyle(Theme.C.ink2)
                Text(line).font(Theme.F.targetSmall(for: turn.language))
                    .foregroundStyle(Theme.C.carbon)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)
        }
    }

    /// What held, as a count until asked for.
    @ViewBuilder
    private func kept(_ review: Review) -> some View {
        if !review.kept.isEmpty {
            if showKept {
                LedgerSheet {
                    ForEach(review.kept) { atom in
                        KeptRow(atom: atom, last: atom.id == review.kept.last?.id)
                    }
                }
            } else {
                Button { showKept = true } label: {
                    Text("+\(review.kept.count) right ›")
                        .font(Theme.F.label).tracking(Theme.M.caps)
                        .foregroundStyle(Theme.C.good)
                        .frame(minHeight: 32)
                }
                .buttonStyle(PressDim())
            }
        }
    }

    /// The weakest sounds, worst first. Names are absent outside
    /// English and Mandarin, so a unit falls back to the word it sat in.
    private func pronunciation(_ result: PronunciationResult) -> some View {
        let weak = result.units.filter { $0.score < 70 }.sorted { $0.score < $1.score }.prefix(4)
        return VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: "Sounds", trailing: "\(result.overall)")
            LedgerSheet {
                ForEach(Array(weak)) { unit in
                    LedgerRow(account: "\(unit.score)", colour: Theme.C.warn, edge: Theme.C.warn,
                              accountWidth: 48, ruled: unit.id != weak.last?.id) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(unit.name ?? unit.gloss ?? "—")
                                .font(Theme.F.targetSmall)
                                .foregroundStyle(Theme.C.ink)
                            Text(unit.name == nil ? "sound \(unit.index + 1)" : (unit.gloss ?? ""))
                                .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                        }
                    }
                    .background(Theme.C.surface)
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
            onOpenLink: { store.open($0, context: turn.attempt.confirmed) },
            onClassify: { store.classify($0, as: $1) },
            back: { store.progress.backLabel($0) },
            onDispute: { await store.dispute($0, in: turn, note: $1) },
            disputed: store.disputed,
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
            isAsking: store.asking.contains(turn.id.uuidString),
            pointName: { store.point($0)?.name }
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

    /// The three problems most worth keeping: most often first, then the
    /// costlier, then the one marked to start with.
    private var takeAway: [(atom: Atom, count: Int)] {
        Store.takeAway(turns.compactMap(\.review))
    }

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
                if !takeAway.isEmpty {
                    ModuleLabel(text: "Take away")
                    LedgerSheet {
                        ForEach(Array(takeAway.enumerated()), id: \.element.atom.id) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                NumberTag(number: index + 1, colour: Theme.colour(for: item.atom.verdict))
                                VStack(alignment: .leading, spacing: 2) {
                                    FixLine(span: item.atom.stages.wrong.map {
                                        Store.Span(range: 0..<0, wrong: $0, right: item.atom.stages.fix)
                                    }, fix: item.atom.stages.fix)
                                    Text(item.atom.stages.name).font(Theme.F.note)
                                        .foregroundStyle(Theme.C.ink2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if item.count > 1 {
                                    Text("×\(item.count)").font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                if index < takeAway.count - 1 {
                                    Rectangle().fill(Theme.C.rule.opacity(0.45)).frame(height: Theme.M.hair)
                                }
                            }
                        }
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
