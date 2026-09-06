import Foundation

/// One addressable thing the tutor has to say. Findings, notes inside a
/// lesson, drill verdicts, praise — all atoms, all openable.
///
/// `id` is model-assigned, so it survives a round trip. `seed` carries enough
/// to generate the expansion, so `expand` has one signature at every depth.
struct Atom: Identifiable, Codable, Hashable {

    /// `word-order/已经`. Same point, same id, across sessions.
    let id: String

    let kind: AtomKind
    let verdict: Verdict

    /// The learner's own words this is about, verbatim.
    var anchor: String?

    var stages: Stages
    var seed: Seed

    /// Revealed one at a time, so the learner can self-repair before being told.
    struct Stages: Codable, Hashable {
        /// Where, not what. "Something is out of place in the second half."
        var locate: String
        /// What, without the answer. "已经 is in a slot only a particle can hold."
        var name: String
        var fix: String
        var note: String
    }

    /// Everything `Tutor.expand` needs.
    struct Seed: Codable, Hashable {
        /// What the lesson is about: an expression, a rule, a contrast.
        var subject: String
        /// The sentence it came from.
        var context: String
        var pointID: String?
    }

    enum Verdict: String, Codable, Hashable {
        case breaks     // stops comprehension
        case weakens    // understood, but marks you as a learner
        case kept

        var isProblem: Bool { self != .kept }
    }

    /// One atom per review is `.start`. Nothing is hidden.
    enum Weight: String, Codable, Hashable {
        case start
        case also
    }
    var weight: Weight = .also

    var cacheKey: String { "\(kind.rawValue)|\(seed.subject)" }
}

/// Learner-facing labels. `LanguagePack` decides which are reachable per language.
enum AtomKind: String, Codable, Hashable, CaseIterable {

    // Universal
    case wordOrder      = "word-order"
    case wordChoice     = "word-choice"
    case missingPiece   = "missing-piece"
    case extraPiece     = "extra-piece"
    case register       = "register"
    case collocation    = "collocation"
    case comprehension  = "comprehension"

    // Mandarin
    case tone           = "tone"
    case particle       = "particle"
    case measureWord    = "measure-word"
    case aspect         = "aspect"

    // German
    case caseEnding     = "case"
    case gender         = "gender"
    case verbPosition   = "verb-position"
    case separableVerb  = "separable-verb"

    // French
    case agreement      = "agreement"
    case auxiliary      = "auxiliary"
    case mood           = "mood"
    case elision        = "elision"

    case pronunciation  = "pronunciation"

    var label: String {
        switch self {
        case .wordOrder:     return "Word order"
        case .wordChoice:    return "Word choice"
        case .missingPiece:  return "Missing"
        case .extraPiece:    return "Not needed"
        case .register:      return "Register"
        case .collocation:   return "Pairing"
        case .comprehension: return "Meaning"
        case .tone:          return "Tone"
        case .particle:      return "Particle"
        case .measureWord:   return "Measure word"
        case .aspect:        return "Aspect"
        case .caseEnding:    return "Case"
        case .gender:        return "Gender"
        case .verbPosition:  return "Verb position"
        case .separableVerb: return "Separable verb"
        case .agreement:     return "Agreement"
        case .auxiliary:     return "Auxiliary"
        case .mood:          return "Mood"
        case .elision:       return "Elision"
        case .pronunciation: return "Sound"
        }
    }
}
