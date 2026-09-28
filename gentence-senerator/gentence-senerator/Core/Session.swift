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
    /// A dialogue is running. It has its own screen: nothing in it is recorded,
    /// transcribed or assessed, so none of the other phases apply.
    case passage
    case ready
    case recording
    case transcribing
    case confirming
    case assessing
    /// A translate answer is in, and one good rendering is on screen. Not a
    /// grade — that arrives with the batch.
    case reference
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
    /// The turns one review covers share this. Unique per turn now; shared
    /// across a held produce exchange before each answer was graded alone.
    /// Nil on turns from before grading moved to a batch, where "no review
    /// yet" was the grouping.
    var exchangeID: UUID? = nil

    struct Prompt: Codable, Hashable {
        var english: String?
        /// The sentence played in listen, the question asked in produce.
        var target: String?
        /// Translate: one natural rendering, shown once the learner has
        /// answered. A reference, not a verdict.
        var reference: String? = nil
        var audioSource: AudioSource?
        var pointID: String?
        /// Due subjects woven into this prompt. What the review is checked
        /// against to decide whether they were retrieved.
        var revisited: [String] = []
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

/// A default value is not a fallback: the synthesised decoder still demands
/// the key, so sessions stored before `revisited` existed would fail to load
/// and take the whole archive with them. In an extension, so the memberwise
/// initialiser survives.
extension Turn.Prompt {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        english = try container.decodeIfPresent(String.self, forKey: .english)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        reference = try container.decodeIfPresent(String.self, forKey: .reference)
        audioSource = try container.decodeIfPresent(AudioSource.self, forKey: .audioSource)
        pointID = try container.decodeIfPresent(String.self, forKey: .pointID)
        revisited = try container.decodeIfPresent([String].self, forKey: .revisited) ?? []
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

    /// What a speaker would actually say. Second stage.
    var natural: String?

    /// Second stage. Empty until it arrives.
    var respeaks: [Respeak] = []
    /// Grammar points the attempt used, whoever asked for them. Second stage,
    /// and evidence rather than a verdict: the model over-tags, so the
    /// threshold for "they produce this" is applied where it is read.
    var usedPoints: [String] = []
    /// True once the second call has filled in the rest.
    var isDeep = false

    var problems: [Atom] { atoms.filter { $0.verdict.isProblem } }
    var kept: [Atom] { atoms.filter { !$0.verdict.isProblem } }
}

/// The same hazard as `Turn.Prompt`, and a live one: `respeaks` and `isDeep`
/// have never had a fallback either, so this is what stops an archive written
/// before any of the three from taking every session with it.
extension Review {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        score = try container.decode(Int.self, forKey: .score)
        readOfScore = try container.decode(String.self, forKey: .readOfScore)
        atoms = try container.decode([Atom].self, forKey: .atoms)
        natural = try container.decodeIfPresent(String.self, forKey: .natural)
        respeaks = try container.decodeIfPresent([Respeak].self, forKey: .respeaks) ?? []
        usedPoints = try container.decodeIfPresent([String].self, forKey: .usedPoints) ?? []
        isDeep = try container.decodeIfPresent(Bool.self, forKey: .isDeep) ?? false
    }
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
    /// A cap, not a target. Nothing goes past it.
    var goal: Int
    /// Translate and produce: every prompt the session will ask, written
    /// before it starts. Optional so archives from before it still decode.
    var planned: [Turn.Prompt]? = nil
    /// The level it was answered at. Graded at that level, however long the
    /// grading waits and whatever the learner has switched to since.
    var level: Int? = nil

    /// Turns the learner actually finished. Counting reviewed turns instead
    /// would never advance in produce mode, where the review is deliberately
    /// held until the end of the exchange — so the session never ended and the
    /// review never fired.
    var completedCount: Int { turns.filter { !$0.attempt.confirmed.isEmpty }.count }
    var isComplete: Bool { completedCount >= goal }

    var averageScore: Int {
        let scores = turns.compactMap { $0.review?.score }
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0, +) / scores.count
    }
}
