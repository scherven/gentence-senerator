import Foundation

extension Store {

    // MARK: Dialogues

    /// The dialogue opened last, if it isn't finished. Readable at idle, so
    /// the mode card can name it before the learner taps in.
    var heldPassage: (passage: Passage, run: PassageRun)? {
        guard let state = passageState[settings.language.rawValue],
              let id = state.open, let held = state.runs[id], held.stage != .done,
              let found = passages.passage(id) else { return nil }
        return (found, held)
    }

    var hasDialogues: Bool { !passages.playable(settings.language).isEmpty }

    /// Every playable dialogue, in the picker's order.
    var shelf: [ShelfEntry] {
        let state = passageState[settings.language.rawValue] ?? PassageState()
        return Shelf.entries(passages.playable(settings.language), runs: state.runs,
                             heard: state.heard, today: .now)
    }

    /// True when dialogues took the session: listen opens on the picker.
    func startPassage() -> Bool {
        guard hasDialogues else { return false }
        passage = nil
        run = nil
        current = nil
        phase = .passage
        return true
    }

    /// Into one dialogue, where it was left unless `fresh`.
    func choosePassage(_ id: String, fresh: Bool = false) {
        guard let found = passages.passage(id) else { return }
        dialogue.stop()
        let held = passageState[settings.language.rawValue]?.runs[id]
        passage = found
        run = !fresh && held?.stage != .done ? held : nil
        current = nil
        if run == nil {
            // Not saved until something happens in it, so opening one and
            // backing out doesn't leave it half done.
            run = PassageRun(passageID: id, language: settings.language,
                             startedOn: Spend.key(.now))
            if fresh { dropRun(id) }
        } else {
            savePassage()
        }
    }

    private func dropRun(_ id: String) {
        passageState[settings.language.rawValue]?.runs[id] = nil
        Vault.save(passageState, Vault.passages)
    }

    /// Back to the list, keeping the run where it is.
    func backToPicker() {
        dialogue.stop()
        passage = nil
        run = nil
        current = nil
        phase = .passage
    }

    private func savePassage() {
        guard let run else { return }
        var state = passageState[run.language.rawValue] ?? PassageState()
        state.runs[run.passageID] = run.stage == .done ? nil : run
        state.open = run.passageID
        passageState[run.language.rawValue] = state
        Vault.save(passageState, Vault.passages)
    }

    private func recordHeard(_ heard: Heard, for run: PassageRun) {
        var state = passageState[run.language.rawValue] ?? PassageState()
        state.heard[run.passageID, default: []].append(heard)
        passageState[run.language.rawValue] = state
        Vault.save(passageState, Vault.passages)
    }

    private func updateRun(_ change: (inout PassageRun) -> Void) {
        guard var live = run else { return }
        change(&live)
        run = live
        savePassage()
    }

    // MARK: Hearing it

    /// A blind pass: the whole dialogue, no text. The first one unlocks the
    /// questions only when it runs to the end.
    func playBlind() {
        guard let passage, let url = passage.url, let span = passage.span, let live = run
        else { return }
        savePassage()   // pressing play is what starts a dialogue
        let stage = live.stage
        dialogue.play(url, span) { [weak self] reachedEnd in
            guard let self, reachedEnd, stage == .first else { return }
            self.updateRun { $0.heardFirst = true; $0.firstPlays += 1 }
        }
    }

    /// Straight to the questions without finishing the first listen.
    func skipToQuestions() {
        dialogue.stop()
        updateRun { $0.heardFirst = true }
    }

    /// Read-along playback: one line, or from a line to the end.
    func playLines(from n: Int, through last: Int? = nil, rate: Float = 1) {
        guard let passage, let url = passage.url,
              let from = passage.line(n).flatMap(passage.span(of:)),
              let to = passage.line(last ?? n).flatMap(passage.span(of:))
        else { return }
        dialogue.play(url, from.lowerBound...to.upperBound, rate: rate)
    }

    /// One word, out of the recording, slowed a little. Tapping marks it.
    func hearWord(_ word: Passage.Word) {
        updateRun { $0.tap(word.w) }
        guard let passage, let url = passage.url, let span = passage.span(of: word) else { return }
        dialogue.play(url, span, rate: 0.85)
    }

    func stopDialogue() { dialogue.stop() }

    // MARK: Answering

    func answerGist(_ index: Int, option: Int) {
        guard let passage, passage.gist.indices.contains(index) else { return }
        updateRun { if $0.answers[index] == nil { $0.answers[index] = option } }
    }

    func rateFollowed(_ followed: PassageRun.Followed) {
        updateRun {
            if $0.stage == .first { $0.followedFirst = followed }
            if $0.stage == .second { $0.followedSecond = followed }
        }
    }

    func toReading() {
        guard let passage, let live = run, live.canRead(passage) else { return }
        dialogue.stop()
        updateRun { $0.stage = .read }
    }

    func toSecondListen() {
        dialogue.stop()
        updateRun { $0.stage = .second }
        playBlind()
    }

    /// A review that went well ends after the first pass.
    func finishReview() {
        guard isReview, let followed = run?.followedFirst else { return }
        dialogue.stop()
        updateRun { $0.followedSecond = followed; $0.stage = .done }
        finishPassage()
    }

    func finishListening() {
        guard run?.followedSecond != nil else { return }
        dialogue.stop()
        updateRun { $0.stage = .done }
        finishPassage()
    }

    // MARK: Finishing

    /// The dialogue becomes one ordinary turn with an ordinary review, so the
    /// day summary, the bank and spaced repetition pick it up without knowing
    /// passages exist. No model call: every answer was a choice, graded here.
    private func finishPassage() {
        guard let passage, let live = run else { return }
        var turn = Turn(
            id: UUID(), mode: .listen, language: settings.language, createdAt: .now,
            prompt: .init(english: nil, target: passage.title,
                          audioSource: passage.wholeSource, pointID: nil),
            attempt: .init(heard: "", confirmed: passage.title, wasTyped: true,
                           audioFilename: nil, pronunciation: nil),
            review: nil
        )
        let review = read(of: passage, run: live)
        turn.review = review
        // A missed gist question is a whole line, and only hearing it again
        // tests it — the shelf brings the dialogue back. Woven into a written
        // sentence it could never come back wrong. Tapped words schedule.
        var schedulable = review
        schedulable.atoms.removeAll { $0.kind == .comprehension }
        record(for: turn, review: schedulable)

        // A second dialogue the same day joins that day's listen session
        // rather than filing another under the same id.
        let id = sessionID(for: .listen)
        recordHeard(Heard(on: .now, right: live.right(in: passage), asked: passage.gist.count,
                          before: live.followedFirst, after: live.followedSecond), for: live)
        if let i = past.lastIndex(where: { $0.id == id }) {
            past[i].turns.append(turn)
        } else {
            past.append(Session(id: id, language: settings.language, mode: .listen,
                                startedAt: .now, turns: [turn], goal: 1))
            past.sort { $0.startedAt < $1.startedAt }
        }
        // Heard is recorded first, so the goal counts this one as done.
        if let i = past.lastIndex(where: { $0.id == id }) {
            past[i].goal = max(listenGoal, past[i].turns.count)
        }
        saveArchive()
        savePassage()
        session = nil
        current = turn
        phase = .passage
    }

    /// A missed question breaks: the meaning didn't land. A tapped word
    /// weakens: it was understood only once it was read. Both point at the
    /// line they came from, so opening one teaches it in its sentence.
    func read(of passage: Passage, run: PassageRun) -> Review {
        var atoms: [Atom] = []
        for (i, q) in passage.gist.enumerated() where !run.got(i, in: passage) {
            guard let line = passage.line(q.line) else { continue }
            let picked = run.answers[i].map { q.options[$0] } ?? "nothing"
            atoms.append(Atom(
                id: Atom.identify(.comprehension, "\(passage.id)/\(i)"),
                kind: .comprehension, verdict: .breaks,
                stages: .init(locate: "Line \(q.line) of \(passage.lines.count).",
                              name: "\(q.question) \(q.options[q.answer]), not \(picked).",
                              fix: line.text, note: line.english),
                seed: .init(subject: line.text, context: line.text, pointID: nil)))
        }
        for word in run.tapped {
            guard let line = passage.lines.first(where: { $0.words.contains { $0.w == word } }),
                  let entry = line.words.first(where: { $0.w == word }) else { continue }
            atoms.append(Atom(
                id: Atom.identify(.wordChoice, word),
                kind: .wordChoice, verdict: .weakens,
                stages: .init(locate: "Line \(line.n) of \(passage.lines.count).",
                              name: "\(word) \(entry.py ?? "")",
                              fix: entry.g ?? "", note: line.text),
                seed: .init(subject: word, context: line.text, pointID: nil)))
        }
        if !atoms.isEmpty { atoms[0].weight = .start }
        let right = run.right(in: passage)
        let before = run.followedFirst?.word ?? "?"
        let after = run.followedSecond?.word ?? "?"
        return Review(
            score: passage.gist.isEmpty ? 0 : right * 100 / passage.gist.count,
            readOfScore: "\(right) of \(passage.gist.count) by ear. Followed: \(before) → \(after).",
            atoms: atoms, natural: nil, respeaks: [], isDeep: true
        )
    }

    /// Off the dialogue screen. Nothing to archive — every answer was saved as
    /// it was given.
    func leavePassage() {
        dialogue.stop()
        passage = nil
        run = nil
        current = nil
        phase = .idle
        path = []
        knowledge = [:]
    }
}
