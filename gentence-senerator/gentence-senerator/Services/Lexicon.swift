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

    /// One band exactly. `upTo` is what they should have; this is the band
    /// above it, which they are not expected to have at all.
    func band(at level: Int, language: Language) -> [String] {
        guard let bank = banks[language] else { return [] }
        return bank.bands.compactMap { $0.value == level ? $0.key : nil }
    }
}

/// Vocabulary worked into a generated sentence, and never anything more.
///
/// Two sources answering different questions. `have` is a word already inside
/// the learner's band that they have never once said — widening production,
/// and the only half that needs their history. `new` is a word one band up,
/// sampled blind: nothing is known about it and nothing is expected of it.
///
/// Seasoning, not a task. The learner is not told the words are there, is never
/// asked about them, and nothing is written down beyond the production count
/// every attempt already gets.
///
/// Codable because the draw is held for the whole day — see `DayDraw`.
struct WordSeeds: Codable, Hashable {
    var have: [String] = []
    var new: [String] = []

    var isEmpty: Bool { have.isEmpty && new.isEmpty }

    /// Two of each. One is not enough of a chance to meet a word and four turn
    /// a sentence into a list. The draw is random; what is eligible is not.
    static func read(band: [String], above: [String],
                     progress: Progress, language: Language,
                     each: Int = 2) -> WordSeeds {
        WordSeeds(
            have: Array(progress.neverProduced(among: band, language: language)
                .shuffled().prefix(each)),
            new: Array(above.shuffled().prefix(each))
        )
    }
}

extension WordSeeds {
    /// `Vault.load` decodes behind `try?`, and a synthesised `init(from:)`
    /// throws on a missing key rather than taking the default — discarding the
    /// whole stored draw. In an extension, to keep the memberwise init.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        have = try container.decodeIfPresent([String].self, forKey: .have) ?? []
        new = try container.decodeIfPresent([String].self, forKey: .new) ?? []
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
// (`mer` and `mère`), which costs one word we stop offering. Spanish takes the
// same path.
//
// Korean glues particles and endings onto the stem, and the tense marker
// merges into the stem's last syllable: 갔 is 가 plus ㅆ. So a band word's stem
// (its 다 dropped) is matched as a prefix of a token in jamo, not characters.
// A vowel-final stem also gets its contracted form — 하 → 해, 보 → 봐, 시 → 셔 —
// since 했어요 and 마셨어요 merge there. ㄷ/ㅂ/ㅅ/르 irregulars are missed.
// A one-syllable stem over-counts (가 inside 가방), the cheap direction.
private struct Bank {

    let bands: [String: Int]
    private let language: Language
    /// Mandarin. Words by their first character: containment against five
    /// thousand words is a scan, against the few sharing a character it is not.
    private let byFirst: [Character: [String]]
    /// German, French, Spanish. Plain form and every stem, all onto the words
    /// they could be, in one map — so a token is a handful of lookups.
    private let byKey: [String: [String]]
    /// Korean. Stems in jamo, by their first syllable's onset and vowel.
    private let byOnset: [Onset: [(word: String, stem: [Unicode.Scalar])]]

    init(_ language: Language, _ bands: [String: Int]) {
        self.language = language
        self.bands = bands
        var byFirst: [Character: [String]] = [:]
        var byKey: [String: [String]] = [:]
        var byOnset: [Onset: [(word: String, stem: [Unicode.Scalar])]] = [:]
        switch language {
        case .mandarin:
            for word in bands.keys {
                guard let first = word.first else { continue }
                byFirst[first, default: []].append(word)
            }
        case .german, .french, .spanish:
            for word in bands.keys {
                for key in Bank.keys(for: word, in: language) {
                    byKey[key, default: []].append(word)
                }
            }
        case .korean:
            for word in bands.keys {
                for stem in Bank.stems(of: word) {
                    guard let onset = Onset(stem) else { continue }
                    byOnset[onset, default: []].append((word, stem))
                }
            }
        }
        self.byFirst = byFirst
        self.byKey = byKey
        self.byOnset = byOnset
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
        case .german, .french, .spanish:
            for token in attempt.split(whereSeparator: { !$0.isLetter }) {
                for key in Bank.keys(for: String(token), in: language) {
                    found.formUnion(byKey[key] ?? [])
                }
            }
        case .korean:
            for token in attempt.split(whereSeparator: { !$0.isLetter }) {
                let jamo = Bank.jamo(String(token))
                guard let onset = Onset(jamo) else { continue }
                for (word, stem) in byOnset[onset] ?? [] where jamo.starts(with: stem) {
                    found.insert(word)
                }
            }
        }
        return Array(found)
    }

    // MARK: Korean

    struct Onset: Hashable {
        let initial: Unicode.Scalar
        let vowel: Unicode.Scalar
        init?(_ jamo: [Unicode.Scalar]) {
            guard jamo.count >= 2 else { return nil }
            initial = jamo[0]
            vowel = jamo[1]
        }
    }

    static func jamo(_ s: String) -> [Unicode.Scalar] {
        Array(s.decomposedStringWithCanonicalMapping.unicodeScalars)
    }

    /// Vowels a vowel-final stem contracts to before -아/-어.
    private static let contracted: [UInt32: UInt32] = [
        0x1161: 0x1162,   // ㅏ → ㅐ   하 → 해
        0x1169: 0x116A,   // ㅗ → ㅘ   보 → 봐
        0x116E: 0x116F,   // ㅜ → ㅝ   주 → 줘
        0x1175: 0x1167,   // ㅣ → ㅕ   마시 → 마셔
        0x116C: 0x116B,   // ㅚ → ㅙ   되 → 돼
        0x1173: 0x1165    // ㅡ → ㅓ   쓰 → 써
    ]

    /// The word's stem in jamo — 다 dropped from a predicate — and its
    /// contracted form if it has one.
    static func stems(of word: String) -> [[Unicode.Scalar]] {
        let bare = word.count >= 2 && word.hasSuffix("다") ? String(word.dropLast()) : word
        let stem = jamo(bare)
        guard bare != word, let last = stem.last,
              let short = contracted[last.value].flatMap(Unicode.Scalar.init)
        else { return [stem] }
        return [stem, Array(stem.dropLast()) + [short]]
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
                  "er", "ir", "re", "ees", "ee", "es", "s", "e"],
        .spanish: ["ariamos", "eriamos", "iriamos", "abamos", "aremos", "eremos",
                   "iremos", "aste", "iste", "aron", "ieron", "aran", "eran", "iran",
                   "aria", "eria", "iria", "ando", "iendo", "ado", "ido", "ada",
                   "ida", "aba", "ian", "ia", "io", "amos", "emos", "imos", "ar",
                   "er", "ir", "as", "es", "an", "en", "os", "a", "e", "i", "o", "s"]
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
