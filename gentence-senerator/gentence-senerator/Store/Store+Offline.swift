import Foundation

extension Store {

    // MARK: Offline pack

    /// Days queued for the language and level in use.
    var packReady: Int { packDays.filter(fitsNow).count }

    func fitsNow(_ day: PackDay) -> Bool {
        day.language == settings.language && day.level == settings.level
    }

    func packEstimate(days: Int) -> (now: Double, later: Double) {
        costs.estimate(days: days, goal: settings.dailyGoal)
    }

    func noteGraded(_ dollars: Double, answers: Int) {
        costs.noteAnswers(dollars, count: answers)
        Vault.save(costs, Vault.costs)
    }

    /// One day always queued, written as soon as there is none. Fails
    /// quietly without signal; the next wake or reconnect tries again.
    func keepPackStocked() {
        guard packReady == 0, packTask == nil,
              settings.language.modes.contains(.translate),
              settings.language.modes.contains(.produce) else { return }
        downloadPack(days: 1, quiet: true)
    }

    /// Writes `days` more days after the ones already queued. Each day is
    /// saved as it lands, so stopping or losing signal keeps what was written.
    /// `quiet`: the automatic top-up, which reports nothing on Settings.
    func downloadPack(days: Int, quiet: Bool = false) {
        guard packTask == nil, days > 0 else { return }
        let language = settings.language, level = settings.level, goal = settings.dailyGoal
        if !quiet {
            packTrouble = nil
            packSpent = nil
        }
        packing = (0, days)
        packTask = Task { [weak self] in
            guard let self else { return }
            let before = self.spend.today().dollars
            for done in 0..<days {
                guard !Task.isCancelled, self.settings.language == language,
                      self.settings.level == level else { break }
                do {
                    try await self.writePackDay(language: language, level: level, goal: goal)
                    self.packing = (done + 1, days)
                } catch {
                    let why = Plain.message(error, "download")
                    if !quiet, !Task.isCancelled { self.packTrouble = why }
                    break
                }
            }
            if !quiet { self.packSpent = self.spend.today().dollars - before }
            self.packing = nil
            self.packTask = nil
        }
    }

    func stopPack() { packTask?.cancel() }

    /// One day: its own stretch, not one already queued, and its own words.
    private func writePackDay(language: Language, level: Int, goal: Int) async throws {
        let queued = packDays.filter { $0.language == language && $0.level == level }
        let day = Calendar.current.date(byAdding: .day, value: queued.count + 1, to: .now) ?? .now
        let taken = Set(queued.compactMap(\.stretchID) + [plan.stretch?.id].compactMap { $0 })
        // A point asked for from the book goes to the first day written after.
        let stretchID = requestedStretch(on: Spend.key(day)) { pickStretch(excluding: taken)?.id }
        let stretch = stretchID.flatMap { id in pack.points.first { $0.id == id } }
        let words = WordSeeds.read(band: lexicon.band(upTo: level, language: language),
                                   above: lexicon.band(at: level + 1, language: language),
                                   progress: progress, language: language, missed: missedWords)
        var avoid = queued.suffix(3).flatMap(\.asked)
        var sets: [Mode: [Turn.Prompt]] = [:]
        for mode in [Mode.translate, .produce] {
            let draft = Session(id: "\(Spend.key(day))|\(language.rawValue)|\(mode.rawValue)",
                                language: language, mode: mode, startedAt: day, turns: [],
                                goal: goal, level: level)
            let written = try await writeSet(for: draft, from: 0, stretch: stretch, words: words,
                                             avoiding: avoid)
            sets[mode] = written
            avoid += written.compactMap(\.english)
        }
        packDays.append(PackDay(id: UUID(), language: language, level: level,
                                stretchID: stretch?.id, words: words,
                                translate: sets[.translate] ?? [], produce: sets[.produce] ?? [],
                                writtenAt: .now))
        Vault.save(packDays, Vault.pack)
    }

    /// The front of the queue becomes today's sets, when today has neither yet.
    /// Both modes at once, so one pack day is one day. Taken online too: it is
    /// already paid for.
    @discardableResult
    func takePackDay() -> Bool {
        let language = settings.language
        // Pack days are written without knowing the day they land on, so a
        // scene day takes translate from the pack and writes its scene live.
        let modes: [Mode] = sceneToday ? [.translate] : [.translate, .produce]
        guard let at = packDays.firstIndex(where: fitsNow),
              modes.allSatisfy({ today($0) == nil
                  && holds[Store.holdKey(language, $0)] == nil
                  && writing[Store.holdKey(language, $0)] == nil })
        else { return false }

        let day = packDays.remove(at: at)
        // A day retargeted by a request may still be waiting on its produce
        // set; `prepareDay` writes what is missing.
        for mode in modes where !day.prompts(mode).isEmpty {
            var session = Session(id: sessionID(for: mode), language: language, mode: mode,
                                  startedAt: .now, turns: [], goal: settings.dailyGoal,
                                  level: day.level)
            session.planned = day.prompts(mode)
            holds[Store.holdKey(language, mode)] = Unfinished(session: session, turn: nil)
        }
        Vault.save(holds, Vault.holds)
        Vault.save(packDays, Vault.pack)
        // The plan names what the sets were written from.
        draws[language.rawValue] = DayDraw(day: Spend.key(.now), language: language,
                                           level: day.level, stretchID: day.stretchID,
                                           words: day.words)
        Vault.save(draws, Vault.plan)
        refreshPlan()
        return true
    }

    /// A point asked for while tomorrow is already queued: the front day takes
    /// it as its stretch and its produce set is written again. Until that
    /// lands the day has no produce set, and `prepareDay` writes one on the day.
    /// False when nothing is queued.
    func retargetFrontDay(to point: GrammarPoint) -> Bool {
        guard let at = packDays.firstIndex(where: fitsNow) else { return false }
        let id = packDays[at].id
        packDays[at].stretchID = point.id
        packDays[at].produce = []
        Vault.save(packDays, Vault.pack)
        let day = packDays[at]
        Task { [weak self] in
            guard let self else { return }
            let draft = Session(id: "\(Spend.key(.now))|\(day.language.rawValue)|produce",
                                language: day.language, mode: .produce, startedAt: .now,
                                turns: [], goal: self.settings.dailyGoal, level: day.level)
            guard let written = try? await self.writeSet(for: draft, from: 0, stretch: point,
                                                         words: day.words, avoiding: day.asked),
                  let now = self.packDays.firstIndex(where: { $0.id == id }),
                  self.packDays[now].stretchID == point.id
            else { return }
            self.packDays[now].produce = written
            Vault.save(self.packDays, Vault.pack)
        }
        return true
    }
}
