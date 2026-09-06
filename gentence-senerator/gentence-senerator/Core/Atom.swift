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
    ///
    /// Only `locate` arrives with the review. The rest is fetched while the
    /// learner is still looking at `locate` and trying to fix it themselves —
    /// the pedagogy pays for the latency.
    struct Stages: Codable, Hashable {
        /// Where, not what. "Something is out of place in the second half."
        var locate: String
        /// What, without the answer. "已经 is in a slot only a particle can hold."
        var name: String = ""
        var fix: String = ""
        var note: String = ""
    }

    /// Whether the second call has landed.
    var isDeep: Bool { !stages.name.isEmpty }

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

    var link: AtomLink {
        AtomLink(id: id, kind: kind, headline: stages.name, subject: seed.subject)
    }
}

/// A way onward, not a finding. Inside a lesson an atom is only ever rendered
/// as its kind and one line, so it carries no stages — and keeping the full
/// Atom out of nested positions is also what keeps the response schema small
/// enough for the model to compile.
struct AtomLink: Identifiable, Codable, Hashable {
    let id: String
    var kind: AtomKind
    var headline: String
    /// What a lesson about this would be about. The context comes from wherever
    /// the link was tapped.
    var subject: String

    func request(in language: Language, context: String, priorVisits: Int = 0) -> LessonRequest {
        LessonRequest(
            seed: .init(subject: subject, context: context, pointID: nil),
            kind: kind, language: language, priorVisits: priorVisits
        )
    }
}

/// Learner-facing labels, naming *the decision the learner got wrong* rather
/// than the morpheme that surfaced. Two tests decide whether a kind earns its
/// place: one sentence of explanation should repair every error under it, and
/// it should be possible to write a drill that hits it and nothing else.
///
/// The set is universal; `LanguagePack` gates which are reachable. Encoding the
/// language in the case name was the wrong axis — gender, negation, particles
/// and agreement are language-general with language-specific content.
enum AtomKind: String, Codable, Hashable, CaseIterable {

    // Everywhere
    case wordOrder      = "word-order"
    case wordChoice     = "word-choice"
    case missingPiece   = "missing-piece"
    case extraPiece     = "extra-piece"
    case register       = "register"
    case collocation    = "collocation"
    case comprehension  = "comprehension"
    case pronunciation  = "pronunciation"
    case negation       = "negation"
    case preposition    = "preposition"
    case tenseAspect    = "tense-aspect"
    case mood           = "mood"
    case gender         = "gender"
    case particle       = "particle"

    // German word order. Three separately-acquired rules, not one:
    // fronting-with-inversion, the bracket, and verb-final each arrive at a
    // different stage and take a different repair.
    case verbSecond     = "verb-second"
    case bracket        = "bracket"
    case verbFinal      = "verb-final"

    // German nominal morphology. Choosing the wrong case and marking the right
    // case wrongly are different mistakes; wrong gender makes the ending
    // unreachable, so it is diagnosed first.
    case caseChoice     = "case-choice"
    case caseForm       = "case-form"
    case adjectiveEnding = "adjective-ending"

    // French. Split by audibility: only one of these is detectable in speech.
    case agreementHeard   = "agreement-heard"
    case agreementWritten = "agreement-written"
    case auxiliary        = "auxiliary"
    case pronounPlacement = "pronoun-placement"
    case liaison          = "liaison"

    // Mandarin
    case tone           = "tone"
    case measureWord    = "measure-word"

    var label: String {
        switch self {
        case .wordOrder:         return "Word order"
        case .wordChoice:        return "Word choice"
        case .missingPiece:      return "Missing"
        case .extraPiece:        return "Not needed"
        case .register:          return "Register"
        case .collocation:       return "Pairing"
        case .comprehension:     return "Meaning"
        case .pronunciation:     return "Sound"
        case .negation:          return "Negation"
        case .preposition:       return "Preposition"
        case .tenseAspect:       return "Tense"
        case .mood:              return "Mood"
        case .gender:            return "Gender"
        case .particle:          return "Particle"
        case .verbSecond:        return "Verb second"
        case .bracket:           return "Verb bracket"
        case .verbFinal:         return "Verb last"
        case .caseChoice:        return "Case"
        case .caseForm:          return "Ending"
        case .adjectiveEnding:   return "Adjective ending"
        case .agreementHeard:    return "Agreement"
        case .agreementWritten:  return "Written form"
        case .auxiliary:         return "Auxiliary"
        case .pronounPlacement:  return "Pronoun"
        case .liaison:           return "Liaison"
        case .tone:              return "Tone"
        case .measureWord:       return "Measure word"
        }
    }

    /// Silent in speech. Suppressed when the attempt was spoken, so recognition
    /// and orthography are never scored as grammar.
    var isWrittenOnly: Bool { self == .agreementWritten }
}
