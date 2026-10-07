import Foundation

/// A quiz format. Adding one: a case here, a `rules` entry saying which item
/// fields it needs, and a view registered in `QuizFormatView`. Quizzing a new
/// subject needs no code: a chapter in `book-<lang>.json` and items in
/// `quiz-<lang>.json` using an existing format.
enum QuizFormat: String, Codable, Hashable, CaseIterable {
    /// One step, 3–4 options.
    case pickOne = "pick-one"
    /// One step, exactly 2 options. Tap or swipe.
    case flip
    /// Order `tiles`; `decoys` are mixed in. `accept` holds alternative orders,
    /// each tiles joined by a single space.
    case build
    /// 2 steps, each scored.
    case twoStep = "two-step"
    /// Step 0: options are the sentence's tokens, answer is the wrong one.
    /// Step 1: the fix.
    case spotIt = "spot-it"
    /// One step per syllable; prompt is the syllable, options are its tone
    /// marks (mā má mǎ mà ma). `speak` is played first.
    case toneTap = "tone-tap"
    /// One step per item; prompt is the item, options are the buckets, the
    /// same on every step.
    case sort
    /// Rewrite `prompt` as `task` says; typed, checked against `accept`.
    case transform
    /// A flashcard: `prompt` on the front, `accept[0]` on the back with
    /// `gloss` under it. Turned, then marked right or wrong by the learner.
    case card

    /// Which item fields a format needs. `tools/check_book.py` mirrors this.
    struct Rules {
        var steps: ClosedRange<Int>
        var options: ClosedRange<Int>?
        var tiles = false
        var accept = false
    }

    var rules: Rules {
        switch self {
        case .pickOne:   return Rules(steps: 1...1, options: 3...4)
        case .flip:      return Rules(steps: 1...1, options: 2...2)
        case .build:     return Rules(steps: 0...0, tiles: true)
        case .twoStep:   return Rules(steps: 2...2, options: 2...5)
        case .spotIt:    return Rules(steps: 2...2, options: 2...12)
        case .toneTap:   return Rules(steps: 1...4, options: 4...5)
        case .sort:      return Rules(steps: 4...12, options: 2...4)
        case .transform: return Rules(steps: 0...0, accept: true)
        case .card:      return Rules(steps: 0...0, accept: true)
        }
    }
}

/// One question. Loaded from `Curriculum/quiz-<language>.json`, a flat array.
struct QuizItem: Identifiable, Codable, Hashable {
    let id: String
    /// The `Chapter.Entry.id` it tests. Results move that entry.
    var entry: String
    var format: QuizFormat
    /// The sentence. `＿` (U+FF3F) marks each gap.
    var prompt: String?
    /// Translation or context under the prompt.
    var gloss: String?
    /// transform: the instruction ("→ 被", "→ Perfekt").
    var task: String?
    /// Said aloud before answering (tone-tap, listening items).
    var speak: String?
    /// Shown on a miss, three words at most: "机器 → 台".
    var why: String?
    var steps: [Step] = []
    var tiles: [String] = []
    var decoys: [String] = []
    var accept: [String] = []

    struct Step: Codable, Hashable {
        var prompt: String?
        var options: [String]
        var answer: Int
    }

    init(id: String, entry: String, format: QuizFormat, prompt: String? = nil,
         gloss: String? = nil, task: String? = nil, speak: String? = nil,
         why: String? = nil, steps: [Step] = [], tiles: [String] = [],
         decoys: [String] = [], accept: [String] = []) {
        self.id = id; self.entry = entry; self.format = format
        self.prompt = prompt; self.gloss = gloss; self.task = task
        self.speak = speak; self.why = why; self.steps = steps
        self.tiles = tiles; self.decoys = decoys; self.accept = accept
    }

    /// Absent arrays decode as empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        entry = try c.decode(String.self, forKey: .entry)
        format = try c.decode(QuizFormat.self, forKey: .format)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        gloss = try c.decodeIfPresent(String.self, forKey: .gloss)
        task = try c.decodeIfPresent(String.self, forKey: .task)
        speak = try c.decodeIfPresent(String.self, forKey: .speak)
        why = try c.decodeIfPresent(String.self, forKey: .why)
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        tiles = try c.decodeIfPresent([String].self, forKey: .tiles) ?? []
        decoys = try c.decodeIfPresent([String].self, forKey: .decoys) ?? []
        accept = try c.decodeIfPresent([String].self, forKey: .accept) ?? []
    }
}

/// What a quiz button starts. A chapter's speed round is the plan
/// `{id: chapter.id, chapters: [chapter.id], formats: chapter.formats}`.
struct QuizPlan: Identifiable, Codable, Hashable {
    /// Rounds are counted per plan id.
    let id: String
    var name: String
    /// Empty means every chapter.
    var chapters: [String] = []
    /// Empty means every format.
    var formats: [QuizFormat] = []
    var count: Int = 20
    /// Draws on the rules quizzes (`rules-<lang>.json`) instead of the tests.
    var rules = false
    /// Set: no end, items keep coming from these sources.
    var mix: Mix?

    /// What an endless quiz draws on. Chapter ids, as tests and as rules.
    struct Mix: Codable, Hashable {
        var tests: [String] = []
        var rules: [String] = []
        var words = false

        var isEmpty: Bool { tests.isEmpty && rules.isEmpty && !words }
    }

    init(id: String, name: String, chapters: [String] = [],
         formats: [QuizFormat] = [], count: Int = 20, rules: Bool = false, mix: Mix? = nil) {
        self.id = id; self.name = name; self.chapters = chapters
        self.formats = formats; self.count = count; self.rules = rules; self.mix = mix
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        chapters = try c.decodeIfPresent([String].self, forKey: .chapters) ?? []
        formats = try c.decodeIfPresent([QuizFormat].self, forKey: .formats) ?? []
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 20
        rules = try c.decodeIfPresent(Bool.self, forKey: .rules) ?? false
        mix = try c.decodeIfPresent(Mix.self, forKey: .mix)
    }

    var endless: Bool { mix != nil }

    /// A chapter's rules round: one item per entry.
    static func rules(for chapter: Chapter) -> QuizPlan {
        QuizPlan(id: chapter.id + ".rules", name: chapter.name, chapters: [chapter.id], rules: true)
    }

    /// Plan id of a language's endless quiz.
    static func endlessID(_ language: Language) -> String { "\(language.rawValue).endless" }
}
