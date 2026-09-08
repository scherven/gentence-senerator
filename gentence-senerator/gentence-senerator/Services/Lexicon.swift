import Foundation

/// Graded word lists, and what a sentence actually used out of them.
///
/// Reach has two axes. Structures the model tags; words are counted here,
/// because counting them needs no call, and a call we can avoid is one that
/// cannot be slow or wrong. Where each list came from and under what licence
/// is in the `meta` of its own file.
struct Lexicon {

    private struct File: Decodable {
        var meta: [String: String]?
        var words: [String: Int]      // word → band
    }

    private let banks: [Language: Bank]

    init(bundle: Bundle = .main) {
        var banks: [Language: Bank] = [:]
        for language in Language.allCases {
            guard let url = bundle.url(forResource: "words-\(language.rawValue)",
                                       withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(File.self, from: data)
            else { continue }
            banks[language] = Bank(language, file.words)
        }
        self.banks = banks
    }

    /// A list held already, rather than one on disk.
    init(_ words: [Language: [String: Int]]) {
        var banks: [Language: Bank] = [:]
        for (language, list) in words { banks[language] = Bank(language, list) }
        self.banks = banks
    }

    var isEmpty: Bool { banks.isEmpty }

    /// Band words this attempt used. Give it `Turn.Attempt.confirmed` — the
    /// transcript the learner signed off on, never what recognition heard.
    func words(in attempt: String, language: Language) -> [String] {
        banks[language]?.words(in: attempt) ?? []
    }

    /// Every band word the learner could be expected to have, at or below their
    /// level. What "never produced" is measured against.
    func band(upTo level: Int, language: Language) -> [String] {
        guard let bank = banks[language] else { return [] }
        return bank.bands.compactMap { $0.value <= level ? $0.key : nil }
    }
}

// MARK: - Finding a word in a sentence
//
// Two strategies, because the languages differ in kind and not in degree.
//
// Mandarin is written without spaces, and the only question ever asked is
// "does this known word occur in this string" — which is containment, so no
// segmenter is needed or wanted. It over-counts: 白 sits inside 明白 and both
// are ticked off. A word wrongly counted as produced is one we stop offering,
// which is the cheaper direction to be wrong in.
//
// German and French need word boundaries, and boundaries alone are not enough:
// `gefahren` and `fahren` are one word to a learner and two strings here. So
// every form is reduced as well as taken plain — lower-cased, diacritics
// dropped, a German participle `ge-` removed, then every regular ending that
// fits stripped, none leaving fewer than three letters — and all of those keys
// index the same word. Because a band word and a learner's token go through
// the same reduction, a stem that is linguistically wrong still matches, so
// long as it is wrong the same way on both sides.
//
// What it genuinely misses: a stem vowel that changes (`ging` against `gehen`,
// `peux` against `pouvoir`), suppletion (`est` against `être`), a separable
// prefix left at the end of its clause, and a compound the list only holds
// whole. Each of those is an undercount — a word they did say reads as never
// said, so we offer it again. That is a dull prompt, not a wrong lesson. The
// error in the other direction is a short stem shared by two real words
// (`mer` and `mère`), which costs one word we stop offering.
private struct Bank {

    let bands: [String: Int]
    private let language: Language
    /// Mandarin. Words by their first character: containment against five
    /// thousand words is a scan, against the few sharing a character it is not.
    private let byFirst: [Character: [String]]
    /// German and French. Plain form and every stem, all onto the words they
    /// could be, in one map — so a token is a handful of lookups.
    private let byKey: [String: [String]]

    init(_ language: Language, _ bands: [String: Int]) {
        self.language = language
        self.bands = bands
        var byFirst: [Character: [String]] = [:]
        var byKey: [String: [String]] = [:]
        switch language {
        case .mandarin:
            for word in bands.keys {
                guard let first = word.first else { continue }
                byFirst[first, default: []].append(word)
            }
        case .german, .french:
            for word in bands.keys {
                for key in Bank.keys(for: word, in: language) {
                    byKey[key, default: []].append(word)
                }
            }
        }
        self.byFirst = byFirst
        self.byKey = byKey
    }

    func words(in attempt: String) -> [String] {
        var found: Set<String> = []
        switch language {
        case .mandarin:
            for character in attempt {
                for word in byFirst[character] ?? [] where attempt.contains(word) {
                    found.insert(word)
                }
            }
        case .german, .french:
            for token in attempt.split(whereSeparator: { !$0.isLetter }) {
                for key in Bank.keys(for: String(token), in: language) {
                    found.formUnion(byKey[key] ?? [])
                }
            }
        }
        return Array(found)
    }

    // MARK: The reduction

    private static let minimum = 3

    /// One strip each, not a cascade: `mangeons` gives up both `mange` and
    /// `mangeon`, and it is `mange` that meets the band word.
    private static let endings: [Language: [String]] = [
        .german: ["enden", "ende", "esten", "este", "est", "en", "em", "er",
                  "es", "et", "st", "e", "t", "n", "s"],
        .french: ["eraient", "erions", "aient", "erais", "erait", "eront",
                  "ions", "iez", "ais", "ait", "ant", "ent", "ons", "ez",
                  "er", "ir", "re", "ees", "ee", "es", "s", "e"]
    ]

    static func keys(for word: String, in language: Language) -> [String] {
        let plain = word.lowercased()
        var body = plain.folding(options: .diacriticInsensitive, locale: nil)
        if language == .german, body.hasPrefix("ge"), body.count - 2 >= minimum {
            body.removeFirst(2)
        }
        var keys = [plain]
        if body != plain { keys.append(body) }
        for ending in endings[language] ?? []
        where body.hasSuffix(ending) && body.count - ending.count >= minimum {
            keys.append(String(body.dropLast(ending.count)))
        }
        return keys
    }
}
