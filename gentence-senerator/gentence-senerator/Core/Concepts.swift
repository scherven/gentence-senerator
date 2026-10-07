import Foundation

/// One meaning in all three languages: a row of `Curriculum/concepts.json`,
/// made by `tools/build_concepts.py`. Each word is the vocab list's, so its
/// schedule is the one the single-language deck keeps.
struct Concept: Codable, Hashable, Identifiable {
    let en: String
    let de: String
    let fr: String
    let zh: String

    var id: String { en }

    func word(_ language: Language) -> String {
        switch language {
        case .german:   return de
        case .french:   return fr
        case .mandarin: return zh
        }
    }
}

/// The ALL LANGUAGES deck. The front turns DE → FR → 中文 → EN card by card.
/// English is the first reveal whenever it isn't the front; the others follow
/// round the ring DE → FR → 中文.
enum ConceptDeck {
    /// A side of the card: a language, or English.
    enum Face: Hashable {
        case en
        case language(Language)
    }

    static let ring: [Language] = [.german, .french, .mandarin]
    static let fronts: [Face] = ring.map(Face.language) + [.en]

    /// Every face in the order shown, the front first.
    static func faces(turn: Int) -> [Face] {
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
    static func isDue(_ concept: Concept, state: (String) -> EntryState, now: Date) -> Bool {
        ring.contains { VocabDrill.isDue(state(entry(concept, $0)), now: now) }
    }

    /// The next `count` rows: due, then ones with a word never seen (easiest
    /// first, as the file is sorted), then the longest unseen.
    static func next(concepts: [Concept], state: @escaping (String) -> EntryState,
                     asked: Set<String>, now: Date = .now, count: Int) -> [Concept] {
        let open = concepts.filter { !asked.contains($0.id) }
        let states = { (c: Concept) in ring.map { state(entry(c, $0)) } }
        let missed = { (c: Concept) in states(c).contains { $0.recent.last == false } }
        let seen = { (c: Concept) in states(c).compactMap(\.lastSeen).min() ?? now }
        var out = open.filter { isDue($0, state: state, now: now) }
            .sorted { a, b in
                if missed(a) != missed(b) { return missed(a) }
                return seen(a) < seen(b)
            }
        if out.count < count {
            out += open.filter { c in
                !isDue(c, state: state, now: now) && states(c).contains { $0.recent.isEmpty && !$0.known }
            }
        }
        if out.count < count {
            let have = Set(out.map(\.id))
            out += open.filter { !have.contains($0.id) }.sorted { seen($0) < seen($1) }
        }
        return Array(out.prefix(count))
    }

    static func dueCount(_ concepts: [Concept], state: (String) -> EntryState, now: Date = .now) -> Int {
        concepts.filter { isDue($0, state: state, now: now) }.count
    }
}
