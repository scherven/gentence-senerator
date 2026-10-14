import Foundation

extension Store {

    // MARK: Today


    /// Today's order on the start screen: produce carries the day.
    nonisolated static let todayOrder: [Mode] = [.produce, .translate, .listen]

    /// The first mode not yet done today.
    var nextMode: Mode? {
        Store.todayOrder.first { settings.language.modes.contains($0) && !isDone($0) }
    }

    var modesDoneToday: Int { settings.language.modes.filter(isDone).count }

    /// One answer the learner wrote today.
    struct Written: Identifiable, Hashable {
        let turn: Turn
        let mode: Mode
        /// 1-based, within its session.
        let number: Int
        var id: UUID { turn.id }
    }

    /// The learner's own sentences today, oldest first. Listen is
    /// transcription, not writing.
    var writtenToday: [Written] {
        Store.written([Mode.translate, .produce].compactMap { today($0) })
    }

    nonisolated static func written(_ sessions: [Session]) -> [Written] {
        sessions.filter { $0.mode != .listen }
            .flatMap { session in
                session.turns.filter { !$0.attempt.confirmed.isEmpty }
                    .enumerated()
                    .map { Written(turn: $0.element, mode: session.mode, number: $0.offset + 1) }
            }
            .sorted { $0.turn.createdAt < $1.turn.createdAt }
    }

    /// The turn on screen, 1-based: the one being answered, or the one just
    /// answered while its reference is up.
    nonisolated static func turnNumber(session: Session, current: Turn?) -> Int {
        if let current, let at = session.turns.firstIndex(where: { $0.id == current.id }) {
            return at + 1
        }
        return min(session.completedCount + 1, max(session.goal, 1))
    }

    /// What the session just finished sent: the newest job's answers, else
    /// the answers not filed before.
    func justSent(_ session: Session) -> [Turn] {
        if let job = jobs.last(where: { $0.sessionID == session.id }) {
            let turns = job.exchanges.flatMap(\.turnIDs)
                .compactMap { id in session.turns.first { $0.id == id } }
            if !turns.isEmpty { return turns }
        }
        return session.open.filter { !$0.attempt.confirmed.isEmpty }
    }

    nonisolated static func showsSendNow(_ job: GradingJob, sending: Bool) -> Bool {
        job.state == .unsent && job.batchID == nil && !job.uploading && !sending
    }

    /// The speed round Today offers: only once a mode is done, with the single
    /// worst item as its reason.
    func todaysRound() -> (plan: QuizPlan, reason: String)? {
        guard let pick = recommended(),
              let reason = Store.roundReason(pick.reason, modesDone: modesDoneToday)
        else { return nil }
        return (pick.plan, reason)
    }

    /// `QuizLog.recommend` ranks its parts worst first, joined with " · ".
    nonisolated static func roundReason(_ reason: String, modesDone: Int) -> String? {
        guard modesDone > 0 else { return nil }
        return reason.components(separatedBy: " · ").first ?? reason
    }

    /// Scores of today's graded answers, in the order they were given.
    var todayScores: [Int] {
        Mode.allCases.compactMap { today($0) }
            .flatMap(\.turns)
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { $0.review?.score }
    }

    /// The book entry a point is taught under, if the book shows one.
    func bookEntry(for pointID: String) -> (chapter: String, entry: String)? {
        for chapter in visibleBook.chapters {
            if let entry = chapter.entries.first(where: { $0.point == pointID }) {
                return (chapter.id, entry.id)
            }
        }
        return nil
    }

    /// The stretch's lesson, on the current path.
    func openLesson(for point: GrammarPoint) {
        let request = ruleRequest(for: point)
        open(seed: request.seed, kind: request.kind)
    }
}
