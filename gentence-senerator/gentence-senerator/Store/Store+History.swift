import Foundation

extension Store {

    // MARK: Activity


    /// Days from before the log existed, or from sessions filed some other
    /// way, read off what the archive and quiz scores still hold.
    func backfillActivity() {
        var changed = false
        for s in past + holds.values.map(\.session) { changed = activity.add(s) || changed }
        for (key, plan) in quizLog.plans {
            guard let language = key.split(separator: "|").first
                .flatMap({ Language(rawValue: String($0)) }) else { continue }
            for score in plan.scores {
                changed = activity.add(.quiz, on: score.at, language) || changed
            }
        }
        if changed { Vault.save(activity, Vault.activity) }

        var scored = false
        for turn in (past + holds.values.map(\.session)).flatMap(\.turns) {
            scored = scores.add(turn) || scored
        }
        if scored { Vault.save(scores, Vault.scores) }
    }

    // MARK: Scores


    /// Mean score in the current language over `from...through`, by calendar day.
    func averageScore(from: Date = .distantPast, through: Date = .now) -> Int? {
        scores.average(settings.language,
                       from: from == .distantPast ? "" : Spend.key(from),
                       through: Spend.key(through))
    }

    func activity(on day: Date) -> Set<ActivityLog.Mark> {
        var marks = activity.marks(on: day, settings.language)
        // Today's sessions may not be filed yet.
        if Calendar.current.isDateInToday(day) {
            for mode in Mode.written {
                if let s = today(mode), let m = ActivityLog.mark(for: s) { marks.insert(m) }
            }
        }
        return marks
    }

    // MARK: History

    /// The archive in the current language, with quiz rounds, by day.
    var history: [HistoryDay] {
        let names = Dictionary(book.chapters.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return HistoryDay.build(archive: archive, quizzes: quizLog.plans,
                                language: settings.language, today: Spend.key(.now)) {
            names[$0] ?? (VocabDrill.isVocab(QuizPlan(id: $0, name: "")) ? "Words" : "Quiz")
        }
    }
}
