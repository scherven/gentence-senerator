import Foundation

/// One grammar point in a language's inventory. Stable ids, because the whole
/// scheduling and reach machinery keys on them.
struct GrammarPoint: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var level: Int          // 1 = earliest
    var kind: AtomKind
    /// How to build a sentence that exercises this, given to the generator.
    var instruction: String
    var examples: [String]
}

/// Everything that varies by language, in one place. Nothing outside this file
/// branches on `Language`.
struct LanguagePack {
    let language: Language
    /// Which atom kinds can occur. The model is only offered these.
    let kinds: [AtomKind]
    /// Appended to the shared assessment prompt.
    let assessmentNotes: String
    /// Appended to the shared generation prompt.
    let generationNotes: String
    let points: [GrammarPoint]

    func level(_ n: Int) -> String {
        switch language {
        case .mandarin: return "HSK \(min(max(n, 1), 6))"
        case .german, .french:
            let bands = ["A1", "A2", "B1", "B2", "C1", "C2"]
            return bands[min(max(n - 1, 0), bands.count - 1)]
        }
    }
}

enum LanguagePacks {
    static func pack(for language: Language) -> LanguagePack {
        switch language {
        case .mandarin: return mandarin
        case .german:   return german
        case .french:   return french
        }
    }

    private static let universal: [AtomKind] = [
        .wordOrder, .wordChoice, .missingPiece, .extraPiece,
        .register, .collocation, .comprehension, .pronunciation
    ]

    // MARK: Mandarin

    static let mandarin = LanguagePack(
        language: .mandarin,
        kinds: universal + [.tone, .particle, .measureWord, .aspect],
        assessmentNotes: """
        Tone errors are spelling errors: a wrong tone is a different word, so
        report them as tone, not pronunciation, and name the character meant.
        Do not report a missing subject as word order — Mandarin drops subjects
        far less than English, and that is its own finding.
        Aspect covers 了 / 过 / 着; the two jobs of 了 are the most common
        single confusion an English speaker has.
        """,
        generationNotes: """
        Write the English prompt so that a natural Mandarin rendering needs the
        target structure. Do not include any Chinese in the English prompt.
        """,
        points: [
            GrammarPoint(id: "le-completion", name: "了 for a completed action", level: 1,
                         kind: .aspect,
                         instruction: "A finished action, followed by something else.",
                         examples: ["我吃了饭就走了"]),
            GrammarPoint(id: "le-change", name: "了 for a change of state", level: 1,
                         kind: .particle,
                         instruction: "Something that was not true and now is.",
                         examples: ["下雨了", "我懂了"]),
            GrammarPoint(id: "guo-experience", name: "过 for experience", level: 2,
                         kind: .aspect,
                         instruction: "Having done something at least once.",
                         examples: ["我去过北京"]),
            GrammarPoint(id: "adverb-placement", name: "Adverbs before the verb", level: 1,
                         kind: .wordOrder,
                         instruction: "已经, 常常, 也, 都 between subject and verb.",
                         examples: ["我已经吃饭了", "我们常常打篮球"]),
            GrammarPoint(id: "measure-words", name: "Number + measure word + noun", level: 1,
                         kind: .measureWord,
                         instruction: "Counting anything.",
                         examples: ["三本书", "两个人"]),
            GrammarPoint(id: "ma-question", name: "吗 for yes-no questions", level: 1,
                         kind: .particle,
                         instruction: "A statement turned into a question.",
                         examples: ["你有空吗？"]),
            GrammarPoint(id: "ba-construction", name: "把 to front the object", level: 3,
                         kind: .wordOrder,
                         instruction: "Doing something concrete to a definite object, with a result.",
                         examples: ["我把书放在桌子上", "她把门关了"]),
            GrammarPoint(id: "de-complement", name: "得 for how an action goes", level: 3,
                         kind: .wordOrder,
                         instruction: "Evaluating an action rather than a thing.",
                         examples: ["他说得很快", "你唱得很好"]),
            GrammarPoint(id: "suiran-danshi", name: "虽然…但是 concession pair", level: 3,
                         kind: .missingPiece,
                         instruction: "Both halves marked; English marks only one.",
                         examples: ["虽然很贵，但是我买了"]),
            GrammarPoint(id: "subject-in-clause", name: "Clauses keep their subject", level: 2,
                         kind: .missingPiece,
                         instruction: "因为 / 所以 clauses where English would drop the subject.",
                         examples: ["因为那里很安静"])
        ]
    )

    // MARK: German — provisional

    /// Provisional. The kind list and points here are a working set, pending the
    /// grammar-inventory research; `case` in particular may need splitting into
    /// selection versus marking.
    static let german = LanguagePack(
        language: .german,
        kinds: universal + [.caseEnding, .gender, .verbPosition, .separableVerb],
        assessmentNotes: """
        Distinguish choosing the wrong case from choosing the right case and
        marking it wrong — they are different mistakes with different fixes.
        Verb position covers V2 in main clauses, verb-final in subordinate
        clauses, and stranded separable prefixes; say which.
        """,
        generationNotes: "Do not include any German in the English prompt.",
        points: [
            GrammarPoint(id: "v2-main", name: "Verb second in main clauses", level: 1,
                         kind: .verbPosition,
                         instruction: "A fronted adverb or object, pushing the subject after the verb.",
                         examples: ["Morgen gehe ich ins Kino"]),
            GrammarPoint(id: "verb-final-sub", name: "Verb last in subordinate clauses", level: 2,
                         kind: .verbPosition,
                         instruction: "weil / dass / wenn clauses.",
                         examples: ["Ich bleibe zu Hause, weil es regnet"]),
            GrammarPoint(id: "separable-prefix", name: "Separable verbs split", level: 1,
                         kind: .separableVerb,
                         instruction: "aufstehen, anrufen, einkaufen in a main clause.",
                         examples: ["Ich stehe um sieben Uhr auf"]),
            GrammarPoint(id: "accusative-dative", name: "Accusative versus dative", level: 2,
                         kind: .caseEnding,
                         instruction: "A two-way preposition with motion versus position.",
                         examples: ["Ich gehe in die Stadt", "Ich bin in der Stadt"]),
            GrammarPoint(id: "adjective-endings", name: "Adjective endings", level: 3,
                         kind: .caseEnding,
                         instruction: "An adjective before a noun, after der/ein/nothing.",
                         examples: ["ein guter Freund", "der gute Freund"]),
            GrammarPoint(id: "konjunktiv-ii", name: "Konjunktiv II", level: 4,
                         kind: .mood,
                         instruction: "Politeness or a hypothetical — systematically avoided by English speakers.",
                         examples: ["Ich hätte gern einen Kaffee", "Wenn ich Zeit hätte…"])
        ]
    )

    // MARK: French — provisional

    /// Provisional, as above.
    static let french = LanguagePack(
        language: .french,
        kinds: universal + [.agreement, .auxiliary, .mood, .elision],
        assessmentNotes: """
        Agreement covers gender and number on adjectives and past participles;
        say which word is agreeing with which.
        Auxiliary covers être versus avoir in compound tenses, including the
        participle agreement that follows from être.
        """,
        generationNotes: "Do not include any French in the English prompt.",
        points: [
            GrammarPoint(id: "passe-compose-aux", name: "être or avoir in the passé composé", level: 2,
                         kind: .auxiliary,
                         instruction: "A movement or reflexive verb in the past.",
                         examples: ["Je suis allé au marché", "Je me suis levé tôt"]),
            GrammarPoint(id: "adjective-agreement", name: "Adjective agreement", level: 1,
                         kind: .agreement,
                         instruction: "A feminine or plural noun with an adjective.",
                         examples: ["une grande maison", "des livres intéressants"]),
            GrammarPoint(id: "negation-frame", name: "The ne…pas frame", level: 1,
                         kind: .missingPiece,
                         instruction: "Negation wrapping the verb.",
                         examples: ["Je ne mange pas de viande"]),
            GrammarPoint(id: "partitive", name: "Partitive articles", level: 1,
                         kind: .wordChoice,
                         instruction: "Some quantity of an uncountable thing.",
                         examples: ["Je bois du café", "Je mange de la soupe"]),
            GrammarPoint(id: "pronouns-y-en", name: "y and en", level: 3,
                         kind: .wordChoice,
                         instruction: "Replacing a place or a quantity — systematically avoided.",
                         examples: ["J'y vais", "J'en ai trois"]),
            GrammarPoint(id: "subjunctive", name: "The subjunctive", level: 4,
                         kind: .mood,
                         instruction: "After il faut que, bien que, vouloir que — systematically avoided.",
                         examples: ["Il faut que tu viennes"])
        ]
    )
}
