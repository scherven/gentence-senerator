import Foundation

extension Store {

    // MARK: Offline pack

    /// Days queued for the language and level in use.
    var packReady: Int { packDays.filter(fitsNow).count }

    private func fitsNow(_ day: PackDay) -> Bool {
        day.language == settings.language && day.level == settings.level
    }

    func packEstimate(days: Int) -> (now: Double, later: Double) {
        costs.estimate(days: days, goal: settings.dailyGoal)
    }

    func noteGraded(_ dollars: Double, answers: Int) {
        costs.noteAnswers(dollars, count: answers)
        Vault.save(costs, Vault.costs)
    }

    /// Writes `days` more days after the ones already queued. Each day is
    /// saved as it lands, so stopping or losing signal keeps what was written.
    func downloadPack(days: Int) {
        guard packTask == nil, days > 0 else { return }
        let language = settings.language, level = settings.level, goal = settings.dailyGoal
        packTrouble = nil
        packSpent = nil
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
                    if !Task.isCancelled { self.packTrouble = Plain.message(error, "download") }
                    break
                }
            }
            self.packSpent = self.spend.today().dollars - before
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
        let stretch = pickStretch(excluding: taken)
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
        let modes: [Mode] = [.translate, .produce]
        guard let at = packDays.firstIndex(where: fitsNow),
              modes.allSatisfy({ today($0) == nil
                  && holds[Store.holdKey(language, $0)] == nil
                  && writing[Store.holdKey(language, $0)] == nil })
        else { return false }

        let day = packDays.remove(at: at)
        for mode in modes {
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
}
