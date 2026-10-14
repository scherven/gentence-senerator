import Foundation

extension Store {

    // MARK: Drilling down

    /// The language of what is on screen. Usually the setting; while reading
    /// a graded session it is that session's, which can be another language
    /// entirely — its lessons, its schedule, its voice.
    var language: Language { current?.language ?? settings.language }

    /// A finding's lesson, from the Book. Opening counts as a visit.
    func open(_ atom: Atom) {
        let request = LessonRequest(
            seed: atom.seed, kind: atom.kind, language: language,
            priorVisits: progress.visits(to: atom.id)
        )
        progress.opened(atom, language: language)
        save()
        path.append(request)
        Task { await load(request) }
    }

    /// A way onward from inside a lesson. The context comes from where it was
    /// tapped, which is why the link itself does not carry one.
    func open(_ link: AtomLink, context: String) {
        let request = link.request(in: language, context: context,
                                   priorVisits: progress.visits(to: link.id))
        path.append(request)
        Task { await load(request) }
    }

    /// Opening something that is not itself a finding — an example, half of a
    /// contrast — where there is no atom to record.
    func open(seed: Atom.Seed, kind: AtomKind) {
        let request = LessonRequest(seed: seed, kind: kind, language: language)
        path.append(request)
        Task { await load(request) }
    }

    func lesson(for request: LessonRequest) -> Lesson? { lessons[request.cacheKey] }

    func isLoading(_ request: LessonRequest) -> Bool {
        loadingLesson.contains(request.cacheKey)
    }

    /// A lesson the learner asked for: the rule, then the practice behind it.
    /// Try again, from the lesson's own error.
    func retryLesson(_ request: LessonRequest) {
        lessonErrors[request.cacheKey] = nil
        Task { await load(request) }
    }

    func load(_ request: LessonRequest) async {
        await loadCore(request)
        guard lessons[request.cacheKey] != nil else { return }
        await loadPractice(request)
    }

    /// The rule and its examples. The only part a tap waits on, so the only
    /// part worth writing ahead of time.
    func loadCore(_ request: LessonRequest) async {
        let key = request.cacheKey
        if lessons[key] != nil { return }
        if let running = coreLoads[key] {
            await running.value
            return
        }

        loadingLesson.insert(key)
        lessonErrors[key] = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let (lesson, usage) = try await self.tutor.expand(request)
                if let usage { self.note(usage) }
                self.shelve([lesson])
            } catch {
                self.lessonErrors[key] = Plain.message(error, "lesson")
            }
            self.loadingLesson.remove(key)
            self.coreLoads[key] = nil
        }
        coreLoads[key] = task
        await task.value
    }

    /// Drills and questions. The largest output of any call in the app, and
    /// most warmed lessons are never opened — so this is never written ahead,
    /// only for a lesson the learner actually asked for. It still lands while
    /// the rule is being read.
    private func loadPractice(_ request: LessonRequest) async {
        let key = request.cacheKey
        guard lessons[key]?.hasPractice == false else { return }
        if let running = practiceLoads[key] {
            await running.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                if let (full, usage) = try await self.tutor.practice(for: request) {
                    self.note(usage)
                    self.shelve([full])
                }
            } catch {
                self.lessonErrors[key] = Plain.message(error, "practice")
            }
            self.practiceLoads[key] = nil
        }
        practiceLoads[key] = task
        await task.value
    }

    // MARK: The day's summary

    /// Everything the tutor said today in this language — what broke, what
    /// weakened, and what held — one row per point, ranked by consequence and
    /// then by how often it came up. Nothing is dropped: silence on a finding
    /// reads as agreement.
    var todayFindings: [DayFinding] {
        var rows: [String: DayFinding] = [:]
        var order: [String] = []
        for mode in Mode.allCases {
            guard let session = today(mode) else { continue }
            for turn in session.turns {
                for atom in turn.review?.atoms ?? [] {
                    if var row = rows[atom.id] {
                        row.count += 1
                        // A finding whose second call never landed has only
                        // `locate` to show, so the deepest copy wins.
                        if !row.atom.isDeep, atom.isDeep { row.atom = atom }
                        rows[atom.id] = row
                    } else {
                        rows[atom.id] = DayFinding(atom: atom,
                                                   sentence: turn.attempt.confirmed, mode: mode)
                        order.append(atom.id)
                    }
                }
            }
        }
        // Sorting on the position it was first raised as the last key, since
        // `sorted` is not stable and the list must not shuffle under a tap.
        return order.enumerated()
            .compactMap { index, id in rows[id].map { (index, $0) } }
            .sorted { left, right in
                let l = DayFinding.rank(left.1.atom.verdict)
                let r = DayFinding.rank(right.1.atom.verdict)
                if l != r { return l < r }
                if left.1.count != right.1.count { return left.1.count > right.1.count }
                return left.0 < right.0
            }
            .map(\.1)
    }

    /// Attempts and average across all three modes today.
    var todayTally: (attempts: Int, average: Int) {
        let sessions = Mode.allCases.compactMap { today($0) }
        let scores = sessions.flatMap { $0.turns.compactMap { $0.review?.score } }
        return (sessions.reduce(0) { $0 + $1.completedCount },
                scores.isEmpty ? 0 : scores.reduce(0, +) / scores.count)
    }

    // MARK: Keeping things
    //
    // Keeping is pinning: the bank is the textbook's pinned section.

    func isKept(_ atomID: String) -> Bool { bank.contains { $0.atomID == atomID } }

    func keep(_ entry: Textbook.Entry) {
        bank.removeAll { $0.atomID == entry.id }
        bank.append(BankEntry(entry: entry, language: settings.language))
        Vault.save(bank, Vault.bank)
    }

    /// Keeping the same point twice replaces it — the newer wording is the one
    /// the learner just decided was worth holding onto.
    func keep(_ finding: DayFinding) {
        let entry = BankEntry(atom: finding.atom, language: settings.language,
                              sentence: finding.sentence)
        bank.removeAll { $0.atomID == entry.atomID }
        bank.append(entry)
        Vault.save(bank, Vault.bank)
    }

    func unkeep(_ atomID: String) {
        bank.removeAll { $0.atomID == atomID }
        Vault.save(bank, Vault.bank)
    }

    /// What the learner picked out of the day to see again. Opening a lesson
    /// schedules on its own; this is the other way in, and the only way back out.
    func setReturn(_ atom: Atom, wanted: Bool) {
        if wanted {
            progress.bringBack(atom, language: language)
        } else {
            progress.leaveOut(atom.id)
        }
        save()
    }


    /// Sends a finding the learner says is wrong, with what they said and why.
    /// Nil when sent, else the line to show.
    func dispute(_ atom: Atom, in turn: Turn, note: String) async -> String? {
        let body: [String: Any] = [
            "language": turn.language.rawValue,
            "mode": turn.mode.rawValue,
            "model": Tutor.reviewModel(turn.mode) ?? "claude-opus-5",
            "prompt": turn.prompt.english ?? turn.prompt.target ?? "",
            "attempt": turn.attempt.confirmed,
            "finding": [
                "kind": atom.kind.rawValue,
                "verdict": atom.verdict.rawValue,
                "text": [atom.stages.locate, atom.stages.name, atom.stages.fix]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                "note": atom.stages.note
            ],
            "note": note.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        do {
            try await Worker.dispute(body)
            disputed.insert(atom.id)
            Vault.save(Array(disputed), Vault.disputed)
            return nil
        } catch {
            return Plain.message(error, "dispute")
        }
    }

    func classify(_ atom: Atom, as verdict: Progress.Encounter.Knowledge) {
        knowledge[atom.id] = verdict
        progress.classify(atom, as: verdict, language: language)
        save()
    }

    /// A typed question about whatever is on screen. `context` scopes the
    /// answer so it appears under the thing it was asked about.
    func ask(_ question: String, about seed: Atom.Seed, context: String) async {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        asking.insert(context)
        do {
            let (reply, usage) = try await tutor.answer(
                question: question, about: seed, in: language
            )
            note(usage)
            asked[context, default: []].append(reply.item)
            file(reply.suggestions(language: language, validPoints: LanguagePacks.pack(for: language).pointIDs,
                                   question: question, context: seed.context))
        } catch {
            asked[context, default: []].append(
                AskItem(id: UUID().uuidString, question: question,
                        answer: Store.couldNotAnswer(Plain.message(error, "ask")),
                        atoms: [])
            )
        }
        asking.remove(context)
    }

    /// Exact match first — instant and free. Only when that fails does the
    /// model decide, so a right answer the author didn't list is not marked
    /// wrong.
    func grade(_ answer: String, against rung: Rung) async -> Tutor.DrillVerdict {
        if rung.accepts(answer) {
            return Tutor.DrillVerdict(correct: true, note: "")
        }
        do {
            let (verdict, usage) = try await tutor.grade(
                answer: answer, to: rung, in: language
            )
            note(usage)
            return verdict
        } catch {
            Plain.note(error, "drill check")
            return Tutor.DrillVerdict(correct: false, note: Store.uncheckable)
        }
    }

    /// Reach counts unaided production only — a multiple-choice hit is
    /// recognition, a different and easier skill. XP still lands on the lower
    /// rungs, at a lower rate, so climbing down to find the answer is not
    /// punished.
    func recordDrill(correct: Bool, at support: Rung.Support) {
        guard correct else { return }
        switch support {
        case .free:      progress.xp += 5
        case .transform: progress.xp += 3
        case .frame:     progress.xp += 2
        case .choice:    progress.xp += 1
        }
        save()
    }
}
