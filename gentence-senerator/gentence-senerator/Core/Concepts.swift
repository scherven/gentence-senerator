import Foundation

/// One meaning across languages: a row of `Curriculum/concepts.json`, made by
/// `tools/build_concepts.py`. Each word is the vocab list's, so its schedule
/// is the one the single-language deck keeps. A row holds the languages whose
/// glosses matched; the deck uses the rows that cover every language on.
struct Concept: Codable, Hashable, Identifiable {
    let en: String
    var words: [Language: String]

    var id: String { en }

    func word(_ language: Language) -> String { words[language] ?? "" }

    func covers(_ ring: [Language]) -> Bool { ring.allSatisfy { words[$0] != nil } }

    /// The same meaning with one language's word swapped.
    func with(_ language: Language, _ word: String) -> Concept {
        var out = self
        out.words[language] = word
        return out
    }

    init(en: String, words: [Language: String]) {
        self.en = en
        self.words = words
    }

    /// `{"en": …, "de": …, "zh": …}`: keyed by language code.
    private struct Key: CodingKey {
        var stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        en = try c.decode(String.self, forKey: Key(stringValue: "en"))
        var words: [Language: String] = [:]
        for language in Language.allCases {
            words[language] = try c.decodeIfPresent(String.self, forKey: Key(stringValue: language.code))
        }
        self.words = words
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(en, forKey: Key(stringValue: "en"))
        for (language, word) in words { try c.encode(word, forKey: Key(stringValue: language.code)) }
    }
}

/// The ALL LANGUAGES deck, over the languages that are on. The front turns
/// round them and English card by card. English is the first reveal whenever
/// it isn't the front; the others follow round the ring.
enum ConceptDeck {
    /// A side of the card: a language, or English.
    enum Face: Hashable {
        case en
        case language(Language)
    }

    /// Ring order: the European languages, then the Asian ones.
    static let order: [Language] = [.german, .french, .spanish, .mandarin, .korean]

    /// The languages on, in ring order. Under two, there is no deck.
    static func ring(_ on: [Language]) -> [Language] { order.filter(on.contains) }

    static func fronts(_ ring: [Language]) -> [Face] { ring.map(Face.language) + [.en] }

    /// Every face in the order shown, the front first.
    static func faces(turn: Int, ring: [Language]) -> [Face] {
        let fronts = fronts(ring)
        let front = fronts[((turn % fronts.count) + fronts.count) % fronts.count]
        guard case .language(let first) = front else { return [.en] + ring.map(Face.language) }
        let start = ring.firstIndex(of: first)!
        let rest = (1..<ring.count).map { ring[(start + $0) % ring.count] }
        return [front, .en] + rest.map(Face.language)
    }

    /// The vocab entry a language's side marks.
    static func entry(_ concept: Concept, _ language: Language) -> String {
        "vocab.\(language.rawValue).\(concept.word(language))"
    }

    /// Due when any of its words is; missed ones first, then the longest
    /// overdue.
    static func isDue(_ concept: Concept, ring: [Language], state: (String) -> EntryState,
                      now: Date) -> Bool {
        ring.contains { VocabDrill.isDue(state(entry(concept, $0)), now: now) }
    }

    /// The next `count` rows: due, then ones with a word never seen (easiest
    /// first, as the file is sorted), then the longest unseen.
    static func next(concepts: [Concept], ring: [Language], state: @escaping (String) -> EntryState,
                     asked: Set<String>, now: Date = .now, count: Int) -> [Concept] {
        let open = concepts.filter { !asked.contains($0.id) && $0.covers(ring) }
        let states = { (c: Concept) in ring.map { state(entry(c, $0)) } }
        let missed = { (c: Concept) in states(c).contains { $0.recent.last == false } }
        let seen = { (c: Concept) in states(c).compactMap(\.lastSeen).min() ?? now }
        var out = open.filter { isDue($0, ring: ring, state: state, now: now) }
            .sorted { a, b in
                if missed(a) != missed(b) { return missed(a) }
                return seen(a) < seen(b)
            }
        if out.count < count {
            out += open.filter { c in
                !isDue(c, ring: ring, state: state, now: now) && states(c).contains { $0.recent.isEmpty && !$0.known }
            }
        }
        if out.count < count {
            let have = Set(out.map(\.id))
            out += open.filter { !have.contains($0.id) }.sorted { seen($0) < seen($1) }
        }
        return Array(out.prefix(count))
    }

    static func dueCount(_ concepts: [Concept], ring: [Language], state: (String) -> EntryState,
                         now: Date = .now) -> Int {
        concepts.filter { $0.covers(ring) && isDue($0, ring: ring, state: state, now: now) }.count
    }
}
