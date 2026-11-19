import Foundation

extension Store {

    // MARK: Redo

    /// Every sentence in the language that could be redone, archived ones
    /// only: a review has to have landed.
    func redoable(_ language: Language) -> [RedoItem] {
        past.filter { $0.language == language && $0.mode != .listen }
            .flatMap(\.turns)
            .compactMap(RedoItem.init(turn:))
    }

    /// Up to three of them, put in front of a translate session that has
    /// nothing answered yet. Nothing when none is due.
    func startRedo() {
        guard let live = session, live.mode == .translate, live.completedCount == 0 else {
            redo = nil
            return
        }
        let language = live.language
        // Today's round already dealt: carry on where it was left, or
        // nothing if it was finished or skipped.
        if let dealt = redoLog.round(language) {
            guard !dealt.closed else { redo = nil; return }
            let byID = Dictionary(redoable(language).map { ($0.turnID, $0) }, uniquingKeysWith: { a, _ in a })
            let items = dealt.ids.compactMap { byID[$0] }
            guard let next = items.firstIndex(where: { redoLog.isDue($0) }) else { redo = nil; return }
            redo = RedoRound(items: items, index: next)
            return
        }
        let picked = redoLog.pick(redoable(language))
        guard !picked.isEmpty else { redo = nil; return }
        redoLog.deal(picked, in: language)
        Vault.save(redoLog, Vault.redo)
        redo = RedoRound(items: picked)
    }

    func checkRedo() {
        guard var round = redo, let item = round.current, round.result == nil else { return }
        let answer = round.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        let result = item.check(answer)
        round.result = result
        redo = round
        redoLog.note(item.turnID, passed: result.passed)
        Vault.save(redoLog, Vault.redo)
        // Put right, a retrieval when the schedule was waiting on it; not
        // put right, a miss, for the changes that did not show up only.
        for atom in item.atoms {
            if result.missed.contains(atom.id) {
                progress.missed(subject: atom.seed.subject, language: item.language)
            } else if result.passed || item.changes.contains(where: { $0.atomID == atom.id }) {
                progress.retrieved(subject: atom.seed.subject, language: item.language)
            }
        }
        save()
    }

    /// On to the next, or out to the session.
    func nextRedo() {
        guard var round = redo else { return }
        round.index += 1
        round.answer = ""
        round.result = nil
        if round.current == nil, let language = round.items.first?.language {
            closeRound(language)
            redo = nil
        } else {
            redo = round
        }
    }

    /// Skipped: not offered again today.
    func skipRedo() {
        if let language = redo?.items.first?.language { closeRound(language) }
        redo = nil
    }

    private func closeRound(_ language: Language) {
        redoLog.close(language)
        Vault.save(redoLog, Vault.redo)
    }
}

extension Store {

    /// Simulator only, with `-dryRunSeed`: yesterday's translate answers in
    /// Mandarin, German and French, filed for grading so the dry run reviews
    /// them. Something to read and redo without a day's practice. Once.
    func seedDryRun() {
        guard DryRun.on else { return }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
        for language in [Language.mandarin, .german, .french] {
            let id = "\(Spend.key(yesterday))|\(language.rawValue)|translate|seed"
            guard !past.contains(where: { $0.id == id }) else { continue }
            let turns = DryRun.samples(language).enumerated().map { index, pair in
                Turn(id: UUID(), mode: .translate, language: language,
                     createdAt: yesterday.addingTimeInterval(Double(index) * 60),
                     prompt: .init(english: pair.english, target: nil, reference: pair.target,
                                   audioSource: nil, pointID: nil),
                     attempt: .init(heard: pair.target, confirmed: pair.target, wasTyped: true,
                                    audioFilename: nil, pronunciation: nil),
                     review: nil, exchangeID: UUID())
            }
            let session = Session(id: id, language: language, mode: .translate, startedAt: yesterday,
                                  turns: turns, goal: turns.count, level: settings.level)
            file(session)
            enqueue(session)
        }
    }
}
