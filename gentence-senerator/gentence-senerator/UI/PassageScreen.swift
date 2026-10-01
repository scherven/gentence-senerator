import SwiftUI

/// A dialogue in three passes: by ear, reading along, by ear again. The gist
/// questions come after the first listen, never before it, so they measure
/// what was caught rather than what was hunted for. How much the learner
/// followed is asked after both blind passes; the difference is what reading
/// bought.
///
/// Nothing here calls the model. Every answer is a choice, graded on the
/// device, so the whole screen works offline.
struct PassageScreen: View {
    @Bindable var store: Store
    /// The word whose gloss is showing.
    @State private var glossed: Passage.Word?
    /// Lines with their English open.
    @State private var english: Set<Int> = []

    var body: some View {
        if let passage = store.passage, let run = store.run {
            VStack(spacing: 0) {
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.M.gap) {
                            TypedLink("All dialogues", colour: Theme.C.ink3, chevron: false) {
                                glossed = nil
                                store.backToPicker()
                            }
                            .id("top")
                            stages(run)
                            switch run.stage {
                            case .first:  first(passage, run)
                            case .read:   reading(passage, run, scroller: scroller)
                            case .second: second(passage, run)
                            case .done:   done(passage, run)
                            }
                        }
                        .padding(Theme.M.gap)
                    }
                    // Each pass starts at its top, not wherever the last one was left.
                    .onChange(of: run.stage) { _, _ in scroller.scrollTo("top", anchor: .top) }
                }
                if run.stage == .read, let glossed { gloss(glossed) }
            }
            .onDisappear { store.stopDialogue() }
        } else {
            DialoguePicker(store: store)
        }
    }

    // MARK: Rail

    private static let rail: [(PassageRun.Stage, String)] =
        [(.first, "Listen"), (.read, "Read"), (.second, "Listen"), (.done, "Done")]

    private func stages(_ run: PassageRun) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(PassageScreen.rail.enumerated()), id: \.offset) { index, step in
                let here = step.0 == run.stage
                let past = PassageScreen.rail.firstIndex { $0.0 == run.stage }.map { index < $0 } ?? false
                Text(step.1.uppercased())
                    .font(Theme.F.label)
                    .tracking(Theme.M.caps)
                    .foregroundStyle(here ? Theme.C.onAccent : (past ? Theme.C.ink2 : Theme.C.ink3))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(here ? Theme.C.accent : Theme.C.sunk)
                    .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
            }
        }
    }

    // MARK: Pass 1

    @ViewBuilder
    private func first(_ passage: Passage, _ run: PassageRun) -> some View {
        Panel(fill: Theme.C.sunk, edge: Theme.C.accent) {
            Text(passage.title).font(Theme.F.cardTitle)
            Text(passage.setup).font(Theme.F.body)
            Text(meta(passage)).font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
        }
        timeline(passage)

        if !run.heardFirst {
            playKey(title: "Listen · no text")
            HStack {
                Spacer()
                TypedLink("Skip to questions", colour: Theme.C.ink3) { store.skipToQuestions() }
            }
        } else {
            HStack {
                TinyButton(title: store.dialogue.isPlaying ? "Stop" : "Again") { toggleBlind() }
                Spacer()
            }
            ModuleLabel(text: "What did you catch?")
            ForEach(passage.gist.indices, id: \.self) { i in question(passage, run, i) }
            followed(run.followedFirst)
            ActionKey("Read along", enabled: run.canRead(passage)) { store.toReading() }
        }
    }

    private func meta(_ passage: Passage) -> String {
        let seconds = passage.span.map { Int(($0.upperBound - $0.lowerBound).rounded()) } ?? 0
        return "\(seconds)s · \(passage.lines.count) lines · "
            + passage.speakers.map(\.name).joined(separator: ", ")
    }

    private func question(_ passage: Passage, _ run: PassageRun, _ i: Int) -> some View {
        let choices = passage.choices(for: i)
        let picked = run.answers[i].map(choices.slot(of:))
        return VStack(alignment: .leading, spacing: Theme.M.gapTight) {
            Text(passage.gist[i].question).font(Theme.F.body)
            ForEach(Array(choices.options.enumerated()), id: \.offset) { slot, option in
                Button { if picked == nil { store.answerGist(i, option: choices.order[slot]) } } label: {
                    HStack(spacing: 10) {
                        Text(String(UnicodeScalar(65 + slot)!)).font(Theme.F.meta).opacity(0.7)
                        Text(option).font(Theme.F.bodyTight)
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.M.padTight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(KeyStyle(variant(slot, picked, choices.answer), dimsWhenDisabled: false))
                .disabled(picked != nil)
            }
        }
    }

    /// Once picked: the right one marked right, a wrong pick struck, the rest spent.
    private func variant(_ slot: Int, _ picked: Int?, _ answer: Int) -> KeyStyle.Variant {
        guard let picked else { return .neutral }
        if slot == answer { return .right }
        if slot == picked { return .wrong }
        return .spent
    }

    private func followed(_ now: PassageRun.Followed?) -> some View {
        VStack(alignment: .leading, spacing: Theme.M.gapTight) {
            ModuleLabel(text: "How much followed")
            HStack(spacing: 6) {
                ForEach(PassageRun.Followed.allCases, id: \.self) { f in
                    TinyButton(title: f.word, selected: now == f) { store.rateFollowed(f) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Pass 2

    @ViewBuilder
    private func reading(_ passage: Passage, _ run: PassageRun, scroller: ScrollViewProxy) -> some View {
        let now = store.dialogue.now
        let playing = now.flatMap(passage.line(at:))?.n
        LedgerSheet {
            ForEach(passage.lines) { line in
                spoken(passage, line, run: run, now: now, current: line.n == playing,
                       ruled: line.n != passage.lines.last?.n)
                    .id(line.n)
            }
        }
        .onChange(of: playing) { _, n in
            guard let n else { return }
            withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(n, anchor: .center) }
        }
        HStack(spacing: 6) {
            TinyButton(title: store.dialogue.isPlaying ? "Stop" : "Play all") {
                if store.dialogue.isPlaying { store.stopDialogue() }
                else { store.playLines(from: 1, through: passage.lines.count) }
            }
            TinyButton(title: "0.8×") { store.playLines(from: 1, through: passage.lines.count, rate: 0.8) }
            Spacer()
        }
        ActionKey("Listen again") { glossed = nil; store.toSecondListen() }
    }

    private func spoken(_ passage: Passage, _ line: Passage.Line, run: PassageRun,
                        now: Double?, current: Bool, ruled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Tag(passage.name(of: line.speaker), .tinted(colour(passage.voice(of: line.speaker))))
                TypedLink("Line", chevron: false) { store.playLines(from: line.n) }
                TypedLink("EN", colour: english.contains(line.n) ? Theme.C.accent : Theme.C.ink3,
                          chevron: false) {
                    if english.contains(line.n) { english.remove(line.n) } else { english.insert(line.n) }
                }
                Spacer()
            }
            Flow(spacing: 2, lineSpacing: 6) {
                ForEach(Array(line.words.enumerated()), id: \.offset) { _, word in
                    token(word, lit: lit(word, now), tapped: run.tapped.contains(word.w))
                }
            }
            if english.contains(line.n) {
                Text(line.english).font(Theme.F.gloss).foregroundStyle(Theme.C.ink2)
            }
        }
        .padding(Theme.M.padTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(current ? Theme.C.accent.opacity(0.08) : .clear)
        .overlay(alignment: .bottom) {
            if ruled { Rectangle().fill(Theme.C.seam).frame(height: Theme.M.hair) }
        }
    }

    private func lit(_ word: Passage.Word, _ now: Double?) -> Bool {
        guard let now, let start = word.start, let end = word.end else { return false }
        return now >= start && now < end + 0.04
    }

    /// Pinyin over the characters. Punctuation keeps an empty pinyin row so
    /// everything on a line shares a baseline.
    private func token(_ word: Passage.Word, lit: Bool, tapped: Bool) -> some View {
        let body = VStack(spacing: 0) {
            Text(word.py ?? " ")
                .font(Theme.F.mono(10))
                .foregroundStyle(lit ? Theme.C.onAccent : Theme.C.ink3)
                .lineLimit(1)
                .fixedSize()
            Text(word.w)
                .font(Theme.F.target(size: 20))
                .foregroundStyle(lit ? Theme.C.onAccent : Theme.C.ink)
                .underline(tapped, color: Theme.C.warn)
                .fixedSize()
        }
        .padding(.horizontal, 1)
        .background(lit ? Theme.C.accent : .clear)
        return Group {
            if word.isPunctuation {
                body
            } else {
                Button { glossed = word; store.hearWord(word) } label: { body }
                    .buttonStyle(PressDim())
            }
        }
    }

    private func gloss(_ word: Passage.Word) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(word.w).font(Theme.F.target(size: 20)).foregroundStyle(Theme.C.onInverse)
            Text(word.py ?? "").font(Theme.F.meta).foregroundStyle(Theme.C.accentOnInverse)
            Text(word.g ?? "").font(Theme.F.bodyTight).foregroundStyle(Theme.C.onInverse)
            Spacer(minLength: 0)
            Button { glossed = nil } label: {
                Text("×").font(Theme.F.mono(16)).foregroundStyle(Theme.C.onInverse)
            }
            .buttonStyle(PressDim())
        }
        .padding(.horizontal, Theme.M.gap)
        .padding(.vertical, 10)
        .background(Theme.C.inverse)
    }

    // MARK: Pass 3

    @ViewBuilder
    private func second(_ passage: Passage, _ run: PassageRun) -> some View {
        Panel(fill: Theme.C.sunk, edge: Theme.C.accent) {
            Text(passage.title).font(Theme.F.cardTitle)
            Text(meta(passage)).font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
        }
        timeline(passage)
        playKey(title: "Listen · no text")
        followed(run.followedSecond)
        ActionKey("Finish", enabled: run.followedSecond != nil) { store.finishListening() }
    }

    // MARK: Done

    @ViewBuilder
    private func done(_ passage: Passage, _ run: PassageRun) -> some View {
        Panel(fill: Theme.C.sunk) {
            Text("\(run.right(in: passage)) of \(passage.gist.count)").font(Theme.F.number)
            Text("by ear, first listen").font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
        }
        VStack(spacing: 6) {
            meter("Pass 1", run.followedFirst, colour: Theme.C.ink2)
            meter("Pass 3", run.followedSecond, colour: Theme.C.accent)
        }

        if let review = store.current?.review, !review.atoms.isEmpty {
            LedgerSheet {
                ForEach(review.atoms) { atom in
                    let colour = Theme.colour(for: atom.verdict)
                    Button { store.open(atom) } label: {
                        LedgerRow(account: atom.kind.label, colour: colour, edge: colour,
                                  ruled: atom.id != review.atoms.last?.id) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(atom.stages.name).font(Theme.F.bodyTight)
                                    .foregroundStyle(Theme.C.ink)
                                Text(atom.stages.fix.isEmpty ? atom.stages.locate : atom.stages.fix)
                                    .font(Theme.F.meta)
                                    .foregroundStyle(Theme.C.ink3)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressDim())
                }
            }
        }

        MainButton(title: "Done") { store.backToPicker() }
    }

    private func meter(_ label: String, _ value: PassageRun.Followed?, colour: Color) -> some View {
        let fraction = CGFloat((value?.rawValue ?? -1) + 1) / 4
        return HStack(spacing: 10) {
            Text(label.uppercased()).font(Theme.F.label).tracking(Theme.M.caps)
                .foregroundStyle(Theme.C.ink2).frame(width: 56, alignment: .leading)
            GeometryReader { g in
                Rectangle().fill(colour).frame(width: g.size.width * fraction)
            }
            .frame(height: 10)
            .background(Theme.C.sunk)
            .overlay(Rectangle().strokeBorder(Theme.C.seam2, lineWidth: Theme.M.hair))
            Text(value?.word ?? "—").font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                .frame(width: 44, alignment: .leading)
        }
    }

    // MARK: Shared

    private func playKey(title: String) -> some View {
        ActionKey(store.dialogue.isPlaying ? "Stop" : title,
                  variant: store.dialogue.isPlaying ? .neutral : .primary) { toggleBlind() }
    }

    private func toggleBlind() {
        if store.dialogue.isPlaying { store.stopDialogue() } else { store.playBlind() }
    }

    /// Who speaks when, with a playhead. The only thing on screen while
    /// listening blind: turn-taking is information the ear gets anyway.
    private func timeline(_ passage: Passage) -> some View {
        let span = passage.span ?? 0...1
        let length = span.upperBound - span.lowerBound
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    ForEach(passage.lines) { line in
                        if let s = passage.span(of: line) {
                            Rectangle()
                                .fill(colour(passage.voice(of: line.speaker)).opacity(0.75))
                                .frame(width: max(2, g.size.width * (s.upperBound - s.lowerBound) / length - 1.5),
                                       height: 18)
                                .offset(x: g.size.width * (s.lowerBound - span.lowerBound) / length)
                        }
                    }
                    if let now = store.dialogue.now {
                        Rectangle().fill(Theme.C.accent).frame(width: 2, height: 34)
                            .offset(x: g.size.width * min(1, max(0, (now - span.lowerBound) / length)))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 34)
            .background(Theme.C.stock)
            .overlay(Rectangle().strokeBorder(Theme.C.seam2, lineWidth: Theme.M.hair))

            HStack(spacing: 12) {
                ForEach(passage.speakers, id: \.id) { s in
                    HStack(spacing: 4) {
                        Rectangle().fill(colour(passage.voice(of: s.id))).frame(width: 9, height: 9)
                        Text(s.name).font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                    }
                }
            }
        }
    }

    private func colour(_ voice: Int) -> Color {
        [Theme.C.ink2, Theme.C.carbon, Theme.C.good, Theme.C.warn][voice % 4]
    }
}
