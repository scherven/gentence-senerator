import Foundation

/// Kept by hand off a day's summary. One entry per point: keeping the same
/// point twice replaces it rather than stacking, so the bank is a list of
/// things, not a log of decisions.
struct BankEntry: Identifiable, Codable, Hashable {
    var id: String { atomID }

    let atomID: String
    let kind: AtomKind
    let language: Language
    var subject: String
    /// What the review had said by the time it was kept. A finding whose second
    /// call never landed keeps its `locate` line instead — better than nothing.
    var fix: String
    var note: String
    /// The learner's own sentence it came out of.
    var sentence: String
    var savedAt: Date

    init(atom: Atom, language: Language, sentence: String, savedAt: Date = .now) {
        atomID = atom.id
        kind = atom.kind
        self.language = language
        subject = atom.seed.subject
        fix = atom.stages.fix
        note = atom.stages.note.isEmpty ? atom.stages.locate : atom.stages.note
        self.sentence = sentence
        self.savedAt = savedAt
    }

    /// Openable, like everything else in the app.
    var seed: Atom.Seed { Atom.Seed(subject: subject, context: sentence, pointID: nil) }
}

/// One point as it stood across a whole day, not one finding on one turn. The
/// same mistake made three times is one row with a count — three rows would
/// bury exactly the thing worth working on.
struct DayFinding: Identifiable, Hashable {
    var atom: Atom
    /// The learner's own words, from the attempt that first raised it.
    var sentence: String
    var mode: Mode
    var count: Int = 1

    var id: String { atom.id }
    var headline: String { atom.isDeep ? atom.stages.name : atom.stages.locate }
    var isProblem: Bool { atom.verdict.isProblem }

    /// Consequence first — the same order the review itself ranks in.
    static func rank(_ verdict: Atom.Verdict) -> Int {
        switch verdict {
        case .breaks:  return 0
        case .weakens: return 1
        case .kept:    return 2
        }
    }
}
