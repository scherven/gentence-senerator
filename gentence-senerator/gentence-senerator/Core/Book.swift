import Foundation

/// One language's book: chapters of entries, and the drills its front page
/// offers. Loaded from `Curriculum/book-<language>.json`.
struct Book: Codable, Hashable {
    var language: Language
    var chapters: [Chapter]
    /// The quiz buttons on the front page, in order.
    var drills: [QuizPlan]

    func chapter(_ id: String) -> Chapter? { chapters.first { $0.id == id } }

    func chapter(of entryID: String) -> Chapter? {
        chapters.first { $0.entries.contains { $0.id == entryID } }
    }
}

struct Chapter: Identifiable, Codable, Hashable {
    /// Stable, `<lang>.<slug>`. Quiz history is keyed on it.
    let id: String
    var name: String
    /// Two or three short examples shown under the name.
    var sub: String
    var layout: Layout
    var entries: [Entry]
    /// What this chapter's speed round mixes.
    var formats: [QuizFormat]

    /// How the chapter page draws its entries. Each reads the same `Entry`
    /// fields differently; a new layout is a new case and a new view.
    enum Layout: String, Codable, Hashable {
        /// One row per entry.
        case list
        /// Cards in a 3-column grid, grouped by `group` (measure words by shape).
        case cards
        /// `head` drawn as a formula; `…` becomes a slot (等…再…).
        case formulas
        /// Rows keyed by `group`, entries as chips carrying `tag`
        /// (verb + preposition + case).
        case pairs
        /// Two columns, `tag` picks the side, `group` is the middle key
        /// (two-way prepositions, être/avoir).
        case split
    }

    struct Entry: Identifiable, Codable, Hashable {
        /// Unique within the language, `<lang>.<chapter slug>.<slug>`.
        let id: String
        /// What the entry is: 台 · warten · 等…再… · aller.
        var head: String
        /// Pinyin, or a form (suis allé).
        var reading: String?
        /// What it covers: "computers, TVs".
        var gloss: String?
        var group: String?
        /// AKK · DAT · ÊTRE · AVOIR.
        var tag: String?
        var example: String?
        /// Curriculum point id, for the lesson and for production evidence.
        var point: String?
        /// HSK band or CEFR step (1 = A1) of this entry itself, which can
        /// differ from its point's: 匹 is later than 个. The learner sees
        /// entries up to their level + 1. Nil falls back to the point's level.
        var level: Int?
    }
}

/// Where an entry stands. Quizzes can move an entry as far as `holding`;
/// `solid` needs production evidence from a linked curriculum point.
struct EntryState: Hashable {
    var standing: DayPlan.Standing
    /// Was holding or better, and the latest attempt was wrong.
    var slipping: Bool
    var lastSeen: Date?
    /// Most recent last, at most 8.
    var recent: [Bool]
}
