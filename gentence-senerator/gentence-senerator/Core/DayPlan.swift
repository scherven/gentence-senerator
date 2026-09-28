import Foundation

/// Today, before it starts: what the app has picked, and how much of the
/// curriculum the learner has working.
///
/// The picks are held here rather than recomputed by the view, because the
/// stretch and the words are random draws: recomputing them would show the
/// learner a plan the sentences were not written from. `DayDraw` keeps the
/// other end of that promise — the draw is made once and then kept for the day.
struct DayPlan: Hashable {

    /// The four ways the app chooses what to ask.
    enum Slot: String, Hashable, CaseIterable, Identifiable {
        case structure, words, new, back
        var id: String { rawValue }

        var label: String {
            switch self {
            case .structure: return "Structure"
            case .words:     return "Known words"
            case .new:       return "New"
            case .back:      return "Back"
            }
        }
    }

    struct Row: Hashable, Identifiable {
        let slot: Slot
        /// What was picked. Empty when there was nothing to pick.
        let items: [String]

        var id: Slot { slot }
    }

    /// Where a point stands, as four steps of one thing rather than four
    /// things. Ordinal, so the record can encode it as one hue getting darker.
    enum Standing: Hashable, CaseIterable {
        case never, tried, holding, solid

        /// Learner language. The legend under the record.
        var name: String {
            switch self {
            case .never:   return "never used"
            case .tried:   return "tried, with errors"
            case .holding: return "holding"
            case .solid:   return "solid"
            }
        }
    }

    /// Clean uses before a point reads as solid. Three, for the reason
    /// `Encounter.cleanRunsToHold` is three: two is a coincidence.
    static let solidUses = 3

    struct Cell: Hashable, Identifiable {
        /// The point id. Never rendered — it is here to key the view.
        let id: String
        let standing: Standing
        /// Today's stretch, marked rather than filled.
        let today: Bool
    }

    /// One level's worth of the record.
    struct Band: Hashable, Identifiable {
        let level: Int
        /// `HSK 1`, `A2`.
        let name: String
        let cells: [Cell]

        var id: Int { level }
        /// Points that have worked at least once — the count on the right.
        var held: Int {
            cells.filter { $0.standing == .holding || $0.standing == .solid }.count
        }
    }

    let stretch: GrammarPoint?
    let words: WordSeeds
    let rows: [Row]
    let bands: [Band]

    /// Before anything has been loaded. Never rendered — the store replaces it
    /// as soon as the archive is in.
    static let empty = DayPlan(stretch: nil, words: WordSeeds(), rows: [], bands: [])

    // MARK: The read

    /// Drawing is the caller's job — the stretch and the words are random, and
    /// held for the day rather than taken again here. Everything decided from
    /// them is below, and nothing here needs a store, a clock or a screen.
    static func read(pack: LanguagePack, level: Int, use: GrammarPoint.Use,
                     progress: Progress, stretch: GrammarPoint?, words: WordSeeds,
                     now: Date = .now) -> DayPlan {

        // The same call the store makes, so what is listed is what is woven.
        let woven = progress.seedsForGeneration(language: pack.language, on: now)

        // Reachable, not every point: the passé simple is absent from speech
        // because that is correct, and a record counting it shows a hole the
        // learner cannot close.
        let record = pack.reachable(at: level, use: use)
        var bands: [Band] = []
        for n in 1...max(level, 1) {
            let cells = record.filter { $0.level == n }
                .map { Cell(id: $0.id,
                            standing: standing(of: $0.id, in: progress),
                            today: $0.id == stretch?.id) }
            guard !cells.isEmpty else { continue }
            bands.append(Band(level: n, name: pack.level(n), cells: cells))
        }

        return DayPlan(
            stretch: stretch,
            words: words,
            rows: [
                Row(slot: .structure, items: stretch.map { [$0.name] } ?? []),
                Row(slot: .words, items: words.have),
                Row(slot: .new, items: words.new),
                Row(slot: .back, items: woven)
            ],
            bands: bands
        )
    }

    static func standing(of pointID: String, in progress: Progress) -> Standing {
        switch progress.state(of: pointID) {
        case .neverAttempted: return .never
        case .failing:        return .tried
        case .holding:
            return progress.successes(of: pointID) >= solidUses ? .solid : .holding
        }
    }
}

// MARK: - Seasoning the day's sentences

extension DayPlan {

    /// Ordinary corners of a life to set a translate sentence in. Never shown
    /// to the learner — they exist only to keep a day's sentences from all
    /// landing in the same place, the job produce does from its own system
    /// prompt. Deliberately broad and everyday; nothing here narrows to a topic.
    static let lifeDomains: [String] = [
        "work", "family", "food and cooking", "money", "sleep", "travel",
        "a daily habit", "the weekend", "health or the body", "studying",
        "the neighbourhood or commute", "the home", "a friend", "childhood or the past"
    ]

    /// The corner to set turn `turn` in. The order is fixed for a day and a
    /// language and reshuffles for the next — so it holds across a relaunch like
    /// the rest of the draw, without being stored, and two languages practised
    /// the same day do not march through it in step.
    static func domain(day: String, language: Language, turn: Int) -> String {
        let order = shuffled(lifeDomains, seed: seedHash(day, language.rawValue))
        return order[((turn % order.count) + order.count) % order.count]
    }

    /// One seasoning word for turn `turn`, or none. At most one a turn, and
    /// roughly every third turn none, so no single word can theme the day the
    /// way the whole seed set once did. The pool is the day's fixed draw, so the
    /// same turn index always yields the same word.
    static func seed(from words: WordSeeds, turn: Int) -> String? {
        let pool = words.have + words.new
        guard !pool.isEmpty, turn % 3 != 2 else { return nil }
        return pool[((turn % pool.count) + pool.count) % pool.count]
    }

    /// A deterministic order, so no state has to be stored to keep a day steady.
    /// A seeded xorshift rather than `shuffled()`, whose generator cannot be
    /// pinned, and FNV-1a for the seed. Neither needs to be good randomness —
    /// only stable for a key and different across keys.
    private static func shuffled(_ items: [String], seed: UInt64) -> [String] {
        var a = items
        var state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        var i = a.count - 1
        while i > 0 { a.swapAt(i, Int(next() % UInt64(i + 1))); i -= 1 }
        return a
    }

    private static func seedHash(_ parts: String...) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for p in parts {
            for b in p.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            h = (h ^ 0x2f) &* 1099511628211   // separator, so "ab"+"c" ≠ "a"+"bc"
        }
        return h
    }
}

// MARK: - The day's draw

/// The random half of a day, kept. Reopening the app or stepping back to the
/// start screen used to redraw the stretch and the word seeds, so the plan
/// changed under the learner and stopped matching what the sentences were
/// written from.
///
/// Only the draw is stored. The record and the standings are derived from
/// `Progress`, and recomputing those is what keeps the screen honest as the day
/// goes on — a point used at lunchtime should have moved by the evening.
struct DayDraw: Codable, Hashable {
    /// `yyyy-MM-dd`, as `Spend.key` writes it.
    let day: String
    let language: Language
    let level: Int
    /// The stretch, by id. Resolved against the pack on the way back in, so a
    /// curriculum edit cannot resurrect a point that no longer exists.
    let stretchID: String?
    let words: WordSeeds

    /// The stored draw when it still holds, and a fresh one otherwise. `draw`
    /// is a closure because it is the random half: whether it runs at all is
    /// the whole question, and running it to find out would defeat the point.
    static func forToday(_ stored: DayDraw?, day: String, language: Language, level: Int,
                         draw: () -> (stretchID: String?, words: WordSeeds)) -> DayDraw {
        if let stored, stored.day == day, stored.language == language,
           stored.level == level {
            return stored
        }
        let fresh = draw()
        return DayDraw(day: day, language: language, level: level,
                       stretchID: fresh.stretchID, words: fresh.words)
    }
}

extension DayDraw {
    /// `Vault.load` decodes behind `try?`, and a synthesised `init(from:)`
    /// throws on a missing key rather than falling back to a default — which
    /// would silently discard the whole draw. Every field is read as optional,
    /// and the fallbacks match no real day, so a half-written draw redraws
    /// instead of standing. In an extension, to keep the memberwise init.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decodeIfPresent(String.self, forKey: .day) ?? ""
        language = try container.decodeIfPresent(Language.self, forKey: .language) ?? .mandarin
        level = try container.decodeIfPresent(Int.self, forKey: .level) ?? 0
        stretchID = try container.decodeIfPresent(String.self, forKey: .stretchID)
        words = try container.decodeIfPresent(WordSeeds.self, forKey: .words) ?? WordSeeds()
    }
}

/// The key list lives on `Vault`; this one is declared here, next to the type
/// it stores.
extension Vault {
    /// Today's draw — the stretch and the word seeds — keyed by language, the
    /// way `holds` is.
    static let plan = "plan.v1"
}
