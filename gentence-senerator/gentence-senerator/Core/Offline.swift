import Foundation

/// One day's translate and produce sets, written ahead for a stretch without
/// signal. Days are a queue, not dates: the front one becomes today's set on
/// the next day that has none, so a skipped day wastes nothing.
struct PackDay: Codable, Hashable, Identifiable {
    let id: UUID
    let language: Language
    let level: Int
    var stretchID: String?
    let words: WordSeeds
    let translate: [Turn.Prompt]
    var produce: [Turn.Prompt]
    let writtenAt: Date

    func prompts(_ mode: Mode) -> [Turn.Prompt] {
        mode == .produce ? produce : translate
    }

    /// Every English line in it, for the next day's `avoid`.
    var asked: [String] { (translate + produce).compactMap { $0.english } }
}

extension PackDay {
    /// Tolerant of a missing key: `loadList` drops a day that fails whole.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        language = try c.decode(Language.self, forKey: .language)
        level = try c.decode(Int.self, forKey: .level)
        stretchID = try c.decodeIfPresent(String.self, forKey: .stretchID)
        words = try c.decodeIfPresent(WordSeeds.self, forKey: .words) ?? WordSeeds()
        translate = try c.decodeIfPresent([Turn.Prompt].self, forKey: .translate) ?? []
        produce = try c.decodeIfPresent([Turn.Prompt].self, forKey: .produce) ?? []
        writtenAt = try c.decodeIfPresent(Date.self, forKey: .writtenAt) ?? .distantPast
    }
}

/// What writing a set and grading an answer have actually cost lately, so the
/// pack can be priced before it is written.
struct CostLog: Codable, Hashable {
    var sets: [Double] = []
    var answers: [Double] = []

    static let kept = 30
    /// Until there is history. Rough: an Opus set at high effort, and a Sonnet
    /// review split across the answers it covers.
    static let setFallback = 0.06
    static let answerFallback = 0.015

    mutating func noteSet(_ dollars: Double) {
        sets = Array((sets + [dollars]).suffix(Self.kept))
    }

    mutating func noteAnswers(_ dollars: Double, count: Int) {
        guard count > 0 else { return }
        let each = dollars / Double(count)
        answers = Array((answers + Array(repeating: each, count: count)).suffix(Self.kept))
    }

    var perSet: Double { sets.isEmpty ? Self.setFallback : sets.reduce(0, +) / Double(sets.count) }
    var perAnswer: Double {
        answers.isEmpty ? Self.answerFallback : answers.reduce(0, +) / Double(answers.count)
    }

    /// Writing is paid on download; grading when the answers go out.
    func estimate(days: Int, goal: Int) -> (now: Double, later: Double) {
        let modes = 2.0
        return (Double(days) * modes * perSet,
                Double(days) * modes * Double(goal) * perAnswer)
    }
}

extension CostLog {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sets = try c.decodeIfPresent([Double].self, forKey: .sets) ?? []
        answers = try c.decodeIfPresent([Double].self, forKey: .answers) ?? []
    }
}

extension Vault {
    /// Written-ahead days, every language, oldest first.
    static let pack = "pack.v1"
    static let costs = "costs.v1"
}
