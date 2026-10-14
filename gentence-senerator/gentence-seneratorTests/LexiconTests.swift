import Testing
import Foundation
@testable import gentence_senerator

/// Word matching is the half of reach that runs on the device, so it is the
/// half that can be wrong quietly. Mandarin and the European languages are
/// matched by different rules and fail in opposite directions, and both of
/// those are pinned here — including the misses, which are deliberate.
struct LexiconTests {

    static let lexicon = Lexicon([
        .mandarin: ["好": 1, "吃": 1, "白": 1, "明白": 2, "喜欢": 1, "环境": 3],
        .german: ["haus": 1, "fahren": 1, "arbeiten": 2, "gehen": 1, "buch": 2],
        .french: ["manger": 1, "maison": 1, "livre": 2, "être": 1, "aimer": 2],
        .spanish: ["hablar": 1, "comer": 1, "casa": 1, "tener": 1, "ventana": 2],
        .korean: ["가다": 1, "먹다": 1, "마시다": 1, "하다": 1, "학교": 1, "듣다": 1, "커피": 1]
    ])

    static func found(_ text: String, _ language: Language) -> Set<String> {
        Set(lexicon.words(in: text, language: language))
    }

    // MARK: Mandarin — containment, no segmenter

    @Test func mandarinFindsWordsInsideAnUnspacedSentence() {
        let said = Self.found("我很喜欢这里的环境", .mandarin)
        #expect(said.contains("喜欢"))
        #expect(said.contains("环境"))
        #expect(!said.contains("吃"))
    }

    /// The known cost of containment: 白 is inside 明白 and both are ticked.
    /// Over-counting stops us offering a word, which is the cheaper way to be
    /// wrong than telling a learner they have never said something they say
    /// daily.
    @Test func mandarinOverCountsACharacterInsideAWord() {
        let said = Self.found("我明白了", .mandarin)
        #expect(said.contains("明白"))
        #expect(said.contains("白"))
    }

    // MARK: German and French — boundaries, then a stem

    @Test func germanMatchesAcrossRegularInflection() {
        let said = Self.found("Ich bin gestern nach Hause gefahren", .german)
        #expect(said.contains("fahren"))   // gefahren: participle ge- and -en
        #expect(said.contains("haus"))     // Hause: dative -e
        #expect(!said.contains("gehen"))
    }

    @Test func germanStopsAtWordBoundaries() {
        // `haus` is inside `Hausaufgaben`, and a compound is not the word.
        #expect(!Self.found("Ich mache meine Hausaufgaben", .german).contains("haus"))
    }

    @Test func germanMatchesAParticipleBackToItsInfinitive() {
        #expect(Self.found("Ich habe lange gearbeitet", .german).contains("arbeiten"))
    }

    /// The honest limit. A stem whose vowel changes is a different string and
    /// this does not chase it — `ging` never reaches `gehen`. The failure is an
    /// undercount: we offer them a word they already use, which is a dull
    /// prompt and nothing worse.
    @Test func germanMissesAStrongVerb() {
        #expect(!Self.found("Ich ging nach Hause", .german).contains("gehen"))
    }

    @Test func frenchMatchesAcrossRegularInflection() {
        #expect(Self.found("J'ai mangé une pomme", .french).contains("manger"))
        #expect(Self.found("Les maisons sont grandes", .french).contains("maison"))
        #expect(Self.found("Elle aimait ce film", .french).contains("aimer"))
    }

    @Test func frenchStopsAtWordBoundaries() {
        #expect(!Self.found("Il faut délivrer le message", .french).contains("livre"))
    }

    /// The other honest limit, and the same shape: suppletion. `est` and `être`
    /// share nothing to strip.
    @Test func frenchMissesSuppletion() {
        #expect(!Self.found("Il est tard", .french).contains("être"))
    }

    @Test func spanishMatchesAcrossRegularInflection() {
        let said = Self.found("Hablaron mucho y comimos en casa", .spanish)
        #expect(said.contains("hablar"))
        #expect(said.contains("comer"))
        #expect(said.contains("casa"))
    }

    /// Same limit as German: `tengo` is not a regular form of `tener`.
    @Test func spanishMissesAStemChange() {
        #expect(!Self.found("Tengo hambre", .spanish).contains("tener"))
    }

    // MARK: Korean — a stem prefix, in jamo

    @Test func koreanMatchesAStemThroughItsEndings() {
        let said = Self.found("어제 학교에 갔어요. 밥을 먹었어요.", .korean)
        #expect(said.contains("가다"))     // 갔: the past marker merged into 가
        #expect(said.contains("먹다"))
        #expect(said.contains("학교"))     // particle 에 glued on
    }

    @Test func koreanMatchesAContractedStem() {
        let said = Self.found("커피를 마셨어요. 숙제를 했어요.", .korean)
        #expect(said.contains("마시다"))   // 시 + 었 → 셨
        #expect(said.contains("하다"))     // 하 + 였 → 했
        #expect(said.contains("커피"))
    }

    /// ㄷ-irregular: 듣 becomes 들 before a vowel, and nothing chases it.
    @Test func koreanMissesAnIrregularStem() {
        #expect(!Self.found("음악을 들었어요", .korean).contains("듣다"))
    }

    // MARK: Bands

    @Test func aBandIsEverythingAtOrBelowTheLevel() {
        #expect(Set(Self.lexicon.band(upTo: 1, language: .mandarin))
                == ["好", "吃", "白", "喜欢"])
        #expect(Set(Self.lexicon.band(upTo: 2, language: .mandarin))
                == ["好", "吃", "白", "喜欢", "明白"])
    }

    /// An empty bundle is an empty lexicon, not a crash and not a throw: a
    /// missing list costs the word half of reach and nothing else.
    @Test func aMissingListFailsSoft() {
        let none = Lexicon(bundle: Bundle(for: Marker.self))
        #expect(none.isEmpty)
        #expect(none.words(in: "我明白了", language: .mandarin).isEmpty)
        #expect(none.band(upTo: 9, language: .mandarin).isEmpty)
    }

    /// Only to give `Bundle(for:)` something with no resources in it.
    private final class Marker {}

    /// The shipped lists, which is the only way to catch one that never made it
    /// into the bundle — every other test here builds its own.
    @Test func theShippedListsLoad() {
        let shipped = Lexicon()
        #expect(!shipped.isEmpty)
        for language in Language.allCases {
            #expect(shipped.band(upTo: 6, language: language).count > 3000)
            #expect(shipped.band(upTo: 1, language: language).count > 400)
        }
        #expect(shipped.words(in: "我已经吃过了", language: .mandarin).contains("已经"))
        #expect(shipped.words(in: "Ich habe ein Buch gelesen", language: .german)
                    .contains("buch"))
        #expect(shipped.words(in: "Je vais à la maison", language: .french)
                    .contains("maison"))
        #expect(shipped.words(in: "Vivo en una casa grande", language: .spanish)
                    .contains("casa"))
        #expect(shipped.words(in: "학교에 갔어요", language: .korean).contains("학교"))
    }
}
