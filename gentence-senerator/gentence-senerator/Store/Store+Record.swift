import Foundation

/// The learner record: every mode writes through here, and the point page,
/// the feed, the Book and quiz weighting read it.
extension Store {

    func saveRecord() { Vault.save(learner, Vault.record) }

    // MARK: Writing

    /// A graded answer or a finished dialogue.
    func noteResult(_ turn: Turn, review: Review, dialogue: Bool = false) {
        if dialogue { learner.noteListen(turn, review: review) }
        else { learner.note(turn, review: review) }
        saveRecord()
    }

    /// One answered quiz item. A miss on an entry with a point puts the point
    /// on the production schedule, so it is woven into the next sentences.
    func noteQuiz(_ item: QuizItem, _ answer: QuizRound.Answer, in round: QuizRound, at date: Date = .now) {
        let language = settings.language
        let words = item.entry.hasPrefix(VocabWord.entryPrefix)
        let entry = words ? nil : book.chapters.lazy.flatMap(\.entries).first { $0.id == item.entry }
        let pointID = entry?.point.flatMap { id in pack.points.contains { $0.id == id } ? id : nil }
        let miss = words ? Store.word(ofVocabEntry: item.entry) : entry?.head ?? ""
        learner.note(item, answer: answer, pointID: pointID, planID: round.plan.id,
                     roundID: round.id.uuidString, language: language,
                     words: words || VocabDrill.isVocab(round.plan), miss: miss, at: date)
        if !answer.right, let point = point(pointID) {
            progress.saw(pointAtom(point), language: language, on: date)
            save()
        }
    }

    func noteWords(_ concept: Concept, _ marks: [Language: Bool]) {
        for (language, right) in marks {
            learner.noteWords([(concept.word(language), right)], language: language)
        }
        saveRecord()
    }

    /// The point as something to schedule: due points are woven into the
    /// day's sentences by name.
    func pointAtom(_ point: GrammarPoint) -> Atom {
        Atom(id: Atom.identify(point.kind, point.name), kind: point.kind, verdict: .breaks,
             stages: .init(locate: point.name),
             seed: .init(subject: point.name, context: point.examples.first ?? "", pointID: point.id))
    }

    nonisolated static func word(ofVocabEntry id: String) -> String {
        // vocab.<language>.<word>; the word may itself contain dots.
        id.split(separator: ".", maxSplits: 2).dropFirst(2).first.map(String.init) ?? id
    }

    /// Deck words missed in the last fortnight, for the day's word seeds.
    var missedWords: [String] {
        let prefix = "\(VocabWord.entryPrefix)\(settings.language.rawValue)."
        return quizLog.entries.filter { id, e in
            id.hasPrefix(prefix) && e.recent.last == false
                && e.last.map { Date.now.timeIntervalSince($0) < QuizLog.fresh } == true
        }.keys.map(Store.word(ofVocabEntry:)).sorted()
    }

    // MARK: Reading

    /// Production and quizzes together. Quizzes reach holding at most; solid
    /// is production's. A point whose latest sentence went wrong is slipping,
    /// which brings its quiz items forward.
    func pointState(_ pointID: String) -> EntryState {
        let entries = book.chapters.flatMap(\.entries).filter { $0.point == pointID }
        let quiz = entries.map { quizLog.state(of: $0.id) }
        var s = EntryState(standing: .never, slipping: false, lastSeen: nil, recent: [])
        for q in quiz {
            s.standing = Store.higher(s.standing, q.standing)
            s.slipping = s.slipping || q.slipping
            s.lastSeen = [s.lastSeen, q.lastSeen].compactMap { $0 }.max()
        }
        return combined(s, pointID: pointID)
    }

    /// An entry's quiz state with its point's production folded in.
    func combined(_ quiz: EntryState, pointID: String) -> EntryState {
        var s = quiz
        s.standing = Store.higher(s.standing, DayPlan.standing(of: pointID, in: progress))
        if let last = learner.point(pointID, settings.language).uses.last {
            s.lastSeen = [s.lastSeen, last.at].compactMap { $0 }.max()
            if last.verdict != .clean, Date.now.timeIntervalSince(last.at) < QuizLog.fresh {
                s.slipping = true
            }
        }
        return s
    }

    nonisolated static func higher(_ a: DayPlan.Standing, _ b: DayPlan.Standing) -> DayPlan.Standing {
        let order = DayPlan.Standing.allCases
        return (order.firstIndex(of: a) ?? 0) >= (order.firstIndex(of: b) ?? 0) ? a : b
    }

    /// Book entries that teach a point, with their chapters, in book order.
    func entries(of pointID: String) -> [(chapter: Chapter, entry: Chapter.Entry)] {
        visibleBook.chapters.flatMap { c in
            c.entries.filter { $0.point == pointID }.map { (c, $0) }
        }
    }

    /// When the point itself comes back in sentences: a due label, or nil.
    func pointReturns(_ point: GrammarPoint) -> String? {
        progress.backLabel(pointAtom(point).id)
    }

    /// The feed in the current language, newest first.
    var feed: [LearnerRecord.FeedItem] { learner.feed(settings.language) }

    /// What a feed line is called: the round's chapter, or the sentence.
    func feedTitle(_ item: LearnerRecord.FeedItem) -> String {
        guard item.kind == .quiz || item.kind == .words else { return item.title }
        if item.kind == .words { return "Words" }
        guard let id = item.planID else { return "Quiz" }
        if let chapter = book.chapter(id) { return chapter.name }
        if let drill = book.drills.first(where: { $0.id == id }) { return drill.name }
        if id.hasSuffix(".endless") { return "Endless" }
        return "Quiz"
    }

    /// The turn a feed line came from, if the archive still has it.
    func turn(_ item: LearnerRecord.FeedItem) -> Turn? {
        item.turnID.flatMap(archived)
    }
}
