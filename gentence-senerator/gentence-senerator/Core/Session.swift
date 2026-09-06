import Foundation

/// One enum, one state machine, one set of stored properties across all three.
enum Mode: String, Codable, Hashable, CaseIterable, Identifiable {
    case translate
    case listen
    case produce

    var id: String { rawValue }

    var name: String {
        switch self {
        case .translate: return "Translate"
        case .listen:    return "Listen"
        case .produce:   return "Produce"
        }
    }

    var blurb: String {
        switch self {
        case .translate: return "Read English, say it in the language."
        case .listen:    return "Hear it, write what was said."
        case .produce:   return "Hold a conversation. Corrections wait."
        }
    }

    /// False for produce: turns run uninterrupted, review comes after.
    var reviewsEachAttempt: Bool { self != .produce }
}

enum Phase: Hashable {
    case idle
    case preparing
    case ready
    case recording
    case transcribing
    case confirming
    case assessing
    case reviewing
    case complete
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .transcribing, .assessing: return true
        default: return false
        }
    }
}

// MARK: - What was asked, and what came of it

/// One exchange. Same record for all three modes; they differ only in which
/// fields are filled.
struct Turn: Identifiable, Codable, Hashable {
    let id: UUID
    var mode: Mode
    var language: Language
    var createdAt: Date

    var prompt: Prompt
    var attempt: Attempt
    var review: Review?

    struct Prompt: Codable, Hashable {
        var english: String?
        /// The sentence played in listen, the question asked in produce.
        var target: String?
        var audioSource: AudioSource?
        var pointID: String?
    }

    struct Attempt: Codable, Hashable {
        /// What recognition heard.
        var heard: String
        /// Only this is assessed — recognition errors are never scored as
        /// language errors.
        var confirmed: String
        var wasTyped: Bool
        var audioFilename: String?
        var pronunciation: PronunciationResult?
    }
}

struct AudioSource: Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case synthesised
        case recording
    }
    var kind: Kind
    var url: URL?
    var attribution: String?
    var licence: String?
    var startSeconds: Double?
    var endSeconds: Double?
}

struct Review: Codable, Hashable {
    var score: Int
    /// One clause on what the score means. Not a breakdown.
    var readOfScore: String

    /// Ranked. Exactly one carries `.start`; all are shown.
    var atoms: [Atom]

    var fixed: String?
    /// Often not the minimal correction.
    var natural: String?

    /// Produce only. Correctable before it is graded.
    var understood: String?

    var respeaks: [Respeak]

    var problems: [Atom] { atoms.filter { $0.verdict.isProblem } }
    var kept: [Atom] { atoms.filter { !$0.verdict.isProblem } }
}

struct PronunciationResult: Codable, Hashable {
    var overall: Int
    var units: [Unit]

    /// Azure names phonemes only for en-US and zh-CN. German and French come
    /// back as an ordered array of scores with no labels, so `name` is nil and
    /// `index` is the only handle — a diagnosis there has to align positionally
    /// against our own grapheme-to-phoneme pass.
    struct Unit: Identifiable, Codable, Hashable {
        let id: String
        var index: Int
        var name: String?
        var score: Int
        /// Absent rather than zero where the language has no tones.
        var toneScore: Int?
        var gloss: String?
    }
}

// MARK: - A sitting

struct Session: Identifiable, Codable, Hashable {
    let id: String          // "2026-09-05|mandarin|produce"
    var language: Language
    var mode: Mode
    var startedAt: Date
    var turns: [Turn]
    var goal: Int
    var endless: Bool

    var completedCount: Int { turns.filter { $0.review != nil }.count }
    var isComplete: Bool { !endless && completedCount >= goal }

    var averageScore: Int {
        let scores = turns.compactMap { $0.review?.score }
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0, +) / scores.count
    }
}
