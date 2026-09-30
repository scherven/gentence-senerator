import Foundation

/// A pin in the textbook, from a day's summary or the textbook itself. One
/// entry per point: keeping the same point twice replaces it rather than
/// stacking, so the bank is a list of things, not a log of decisions.
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
    /// Set when the pin is a curriculum point rather than a finding. Optional,
    /// so entries stored before it decode.
    var pointID: String?

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

    init(entry: Textbook.Entry, language: Language, savedAt: Date = .now) {
        atomID = entry.id
        kind = entry.kind
        self.language = language
        subject = entry.seed.subject
        fix = ""
        note = entry.detail
        sentence = entry.sentence ?? entry.seed.context
        self.savedAt = savedAt
        pointID = entry.pointID
    }

    /// Openable, like everything else in the app.
    var seed: Atom.Seed { Atom.Seed(subject: subject, context: sentence, pointID: pointID) }
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
