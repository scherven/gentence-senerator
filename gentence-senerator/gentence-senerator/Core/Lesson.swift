import Foundation

/// What opening an atom produces: blocks, which contain atoms, which open.
/// No sub-lesson type, no depth cap.
struct Lesson: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var blocks: [Block]
    /// Replaces the rule on a third visit. Explaining twice didn't work.
    var patterns: [Example]

    /// Practice arrives in a second call and is what adds the drills block.
    var hasPractice: Bool { blocks.contains { $0.kind == .drills } }

    static func empty(id: String) -> Lesson {
        Lesson(id: id, title: "", blocks: [], patterns: [])
    }
}

/// Flat and tagged, matching the JSON schema the model returns.
struct Block: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case rule, contrast, examples, drills, atoms
    }

    let id: String
    let kind: Kind
    var label: String?

    var text: String?
    var sides: [Side]?
    var examples: [Example]?
    var drills: [Drill]?
    var atoms: [AtomLink]?
}

struct Side: Identifiable, Codable, Hashable {
    let id: String
    var term: String
    var note: String
    var seed: Atom.Seed?
}

struct Example: Identifiable, Codable, Hashable {
    let id: String
    var target: String
    var gloss: String
    var seed: Atom.Seed?
}

struct AskItem: Identifiable, Codable, Hashable {
    let id: String
    var question: String
    var answer: String
    var atoms: [AtomLink]
}

// MARK: - Production

/// Failing removes scaffolding rather than adding explanation.
struct Drill: Identifiable, Codable, Hashable {
    let id: String
    /// Hardest first. Index 0 is unsupported production.
    var rungs: [Rung]
    var correct: String
    var incorrect: String
    var atoms: [AtomLink]
}

struct Rung: Identifiable, Codable, Hashable {
    enum Support: String, Codable, Hashable {
        case free       // build from English
        case transform  // change a given sentence
        case frame      // fill the gap
        case choice     // pick between two

        var label: String {
            switch self {
            case .free:      return "No support"
            case .transform: return "Change one thing"
            case .frame:     return "With a frame"
            case .choice:    return "Pick one"
            }
        }
    }

    let id: String
    var support: Support
    var prompt: String
    var accept: [String]
    var options: [String]?
    var answerIndex: Int?

    func accepts(_ input: String) -> Bool {
        let normalised = Rung.normalise(input)
        guard !normalised.isEmpty else { return false }
        return accept.contains { Rung.normalise($0) == normalised }
    }

    /// Punctuation and spacing never decide a grammar question.
    static func normalise(_ s: String) -> String {
        let drop = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "，。？！、；：「」『』（）"))
        return s.unicodeScalars
            .filter { !drop.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .lowercased()
    }
}

/// The learner's own sentence with one thing moved. Transfer, not recall.
struct Respeak: Identifiable, Codable, Hashable {
    let id: String
    var instruction: String
    var accept: [String]
    var correct: String
    var incorrect: String
}

// MARK: - Requesting one

/// Hashable: this is the `NavigationStack` path value.
struct LessonRequest: Hashable, Codable {
    var seed: Atom.Seed
    var kind: AtomKind
    var language: Language
    /// Drives the shift from explaining to showing.
    var priorVisits: Int = 0

    var cacheKey: String { "\(language.rawValue)|\(kind.rawValue)|\(seed.subject)" }
}

/// Lessons kept across launches, with the order they were written in so the
/// oldest can be dropped.
struct LessonShelf: Codable {
    static let cap = 400
    var order: [String]
    var lessons: [String: Lesson]
}
