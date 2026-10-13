import SwiftUI

/// The ALL LANGUAGES deck: one meaning, a side per language on plus English. Tap to show the next
/// side; once all are up, ✗ or ✓ on each language, and the card moves on.
/// No end: STOP shows the tally. Holding a word retypes it, for
/// when the list paired the wrong one.
struct AllLanguagesScreen: View {
    let store: Store

    @Environment(\.dismiss) private var dismiss
    @State private var cards: [Concept] = []
    @State private var index = 0
    /// Where the front rotation starts, so each sitting doesn't open on DE.
    @State private var turnBase = Int.random(in: 0..<16)
    @State private var shown = 1
    @State private var marks: [Language: Bool] = [:]
    @State private var finished = false
    /// Per language: right, marked.
    @State private var tally: [Language: (right: Int, total: Int)] = [:]
    /// The side being retyped, and what is typed so far.
    @State private var editing: Language?
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        Group {
            // Past the last card only when the deck ran dry.
            if finished || (index >= cards.count && !cards.isEmpty) {
                summary
            } else if cards.isEmpty {
                VStack(spacing: Theme.M.gap) {
                    Text("No words.").font(Theme.F.body).foregroundStyle(Theme.C.ink2)
                    TinyButton(title: "Done") { dismiss() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                runner
            }
        }
        .paper()
        .onAppear { if cards.isEmpty { cards = store.nextConcepts(asked: [], count: 12) } }
    }

    private var concept: Concept { cards[index] }
    private var ring: [Language] { store.conceptRing }
    private var faces: [ConceptDeck.Face] { ConceptDeck.faces(turn: turnBase + index, ring: ring) }
    private var allShown: Bool { shown >= faces.count }

    // MARK: Runner

    private var runner: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { stop() } label: {
                    Text("STOP").font(Theme.F.mono(12, bold: true))
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressDim())
                .accessibilityLabel("Stop")
                Spacer()
                Text("\(index)").font(Theme.F.mono(13))
                Spacer()
                // Balances STOP so the count sits centred.
                Color.clear.frame(width: 44, height: 44)
            }
            .foregroundStyle(Theme.C.ink)
            card
            Spacer(minLength: 0)
            Text(editing != nil ? "RETURN TO KEEP · EMPTY PUTS IT BACK"
                 : allShown ? "MARK EACH · HOLD A WORD TO RETYPE" : "TAP · SAY IT FIRST")
                .font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, Theme.M.gap)
        .padding(.top, 4)
        // Anywhere on the screen shows the next side; the keys keep their taps.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { reveal() }
    }

    private func reveal() {
        if editing != nil { commit(); return }
        guard !allShown else { return }
        withAnimation(.easeOut(duration: 0.12)) { shown += 1 }
    }

    private var card: some View {
        VStack(spacing: 0) {
            ForEach(Array(faces.enumerated()), id: \.offset) { i, face in
                row(face, visible: i < shown)
                if i < faces.count - 1 {
                    Rectangle().fill(Theme.C.rule.opacity(0.45)).frame(height: Theme.M.hair)
                }
            }
        }
        .hardCard(fill: Theme.C.stock, drop: CGSize(width: 3, height: 3))
        .id(concept.id)
        .accessibilityAction(named: "Show next") { reveal() }
    }

    private func row(_ face: ConceptDeck.Face, visible: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label(face)).font(Theme.F.mono(11)).foregroundStyle(Theme.C.ink3)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if !visible {
                    Text("?").font(Theme.F.serif(20)).foregroundStyle(Theme.C.ink3)
                } else {
                    switch face {
                    case .en:
                        Text(concept.en).font(Theme.F.serif(20, italic: true)).foregroundStyle(Theme.C.ink2)
                    case .language(let language) where editing == language:
                        TextField("", text: $draft)
                            .font(Theme.F.target(size: 24, bold: true, for: language))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($typing)
                            .onSubmit { commit() }
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Theme.C.accent).frame(height: 1.5).offset(y: 4)
                            }
                    case .language(let language):
                        let word = store.vocabWord(concept.word(language), in: language)
                        Text(word?.shown(language) ?? concept.word(language))
                            .font(Theme.F.target(size: 24, bold: true, for: language))
                            .minimumScaleFactor(0.5).lineLimit(2)
                            .onLongPressGesture { retype(language) }
                            .accessibilityAction(named: "Retype") { retype(language) }
                        if let py = word?.py {
                            Text(py).font(Theme.F.mono(12)).foregroundStyle(Theme.C.carbon)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if visible, case .language(let language) = face {
                if allShown { markKeys(language) } else { hear(language) }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 76)
    }

    private func retype(_ language: Language) {
        draft = concept.word(language)
        editing = language
        typing = true
    }

    private func commit() {
        guard let language = editing else { return }
        cards[index] = store.retype(concept, language, draft)
        editing = nil
        typing = false
    }

    private func label(_ face: ConceptDeck.Face) -> String {
        switch face {
        case .en: return "EN"
        case .language(let l): return l.short
        }
    }

    private func hear(_ language: Language) -> some View {
        Button { store.speak(concept.word(language), in: language) } label: {
            Text("▶").font(Theme.F.mono(13)).foregroundStyle(Theme.C.ink2)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .accessibilityLabel("Hear it")
    }

    private func markKeys(_ language: Language) -> some View {
        HStack(spacing: 6) {
            markKey(language, false)
            markKey(language, true)
        }
    }

    private func markKey(_ language: Language, _ right: Bool) -> some View {
        let chosen = marks[language] == right
        let colour = right ? Theme.C.good : Theme.C.bad
        return Button { mark(language, right) } label: {
            Text(right ? "✓" : "✗").font(Theme.F.mono(16, bold: true))
                .foregroundStyle(chosen ? Theme.C.surface : colour)
                .frame(width: 44, height: 44)
                .background(chosen ? colour : Theme.C.surface)
                .overlay(Rectangle().strokeBorder(colour, lineWidth: Theme.M.hair))
        }
        .buttonStyle(PressDim())
        .disabled(marks.count == ring.count)
        .accessibilityLabel("\(language.name): \(right ? "knew it" : "didn't")")
    }

    // MARK: Flow

    private func mark(_ language: Language, _ right: Bool) {
        // Recorded already, and moving on: a late tap would count it twice.
        guard marks.count < ring.count else { return }
        commit()
        marks[language] = right
        guard marks.count == ring.count else { return }
        let done = concept
        store.markConcept(done, marks)
        for (l, r) in marks {
            let t = tally[l] ?? (0, 0)
            tally[l] = (t.right + (r ? 1 : 0), t.total + 1)
        }
        let at = index
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard index == at else { return }
            advance()
        }
    }

    private func advance() {
        marks = [:]
        shown = 1
        if index + 3 >= cards.count {
            cards += store.nextConcepts(asked: Set(cards.map(\.id)), count: 10)
        }
        index += 1
    }

    private func stop() {
        if tally.isEmpty { dismiss() } else { finished = true }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            let n = tally.values.map(\.total).max() ?? 0
            Text(n == 1 ? "1 card" : "\(n) cards")
                .font(Theme.F.display).foregroundStyle(Theme.C.ink)
            LedgerSheet {
                ForEach(ring, id: \.self) { language in
                    let t = tally[language] ?? (0, 0)
                    HStack {
                        Text(language.name.uppercased()).font(Theme.F.label)
                        Spacer()
                        Text("\(t.right)/\(t.total)").font(Theme.F.number)
                    }
                    .padding(Theme.M.pad)
                }
            }
            Spacer()
            HStack(spacing: Theme.M.gapTight) {
                TinyButton(title: "Again") { again() }
                Spacer()
                MainButton(title: "Done") { dismiss() }
            }
        }
        .padding(Theme.M.gap)
    }

    private func again() {
        cards = store.nextConcepts(asked: [], count: 12)
        index = 0
        shown = 1
        marks = [:]
        tally = [:]
        finished = false
        turnBase = Int.random(in: 0..<16)
    }
}
