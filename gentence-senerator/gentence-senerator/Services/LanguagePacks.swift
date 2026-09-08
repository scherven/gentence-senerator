import Foundation

/// One grammar point. Stable ids, because scheduling and reach both key on them.
struct GrammarPoint: Identifiable, Codable, Hashable {
    /// Where a point legitimately applies. Some things are only avoided because
    /// avoiding them is correct — the passé simple in speech, `ne` retention in
    /// casual register — and must not count as a gap in reach.
    enum Use: String, Codable, Hashable { case spoken, written, both }

    let id: String
    var name: String
    var level: Int
    var kind: AtomKind
    var use: Use = .both
    /// Taught as fixed phrases before it is productive (`ich hätte gern`).
    /// A formulaic point is not "reached for" in the sense reach measures.
    var formulaic: Bool = false
    var instruction: String
    var examples: [String]
}

/// Everything that varies by language. Nothing outside this file branches on
/// `Language`.
struct LanguagePack {
    let language: Language
    /// Which kinds the model may return.
    let kinds: [AtomKind]
    /// Priority rules. Without these the model reports a dropped `ne` as
    /// "missing" and a V2 failure as "word order", and the grammar-point
    /// linkage collapses.
    let routing: String
    let assessmentNotes: String
    let generationNotes: String
    let points: [GrammarPoint]

    func level(_ n: Int) -> String {
        switch language {
        case .mandarin:
            // HSK 3.0 was designed for CEFR-style alignment: 1-3 ≈ A1-A2,
            // 4-6 ≈ B1-B2, 7-9 ≈ C1-C2.
            return "HSK \(min(max(n, 1), 9))"
        case .german, .french:
            let bands = ["A1", "A2", "B1", "B2", "C1", "C2"]
            return bands[min(max(n - 1, 0), bands.count - 1)]
        }
    }

    /// Points the learner could reach for at this level, in this mode.
    func reachable(at level: Int, use: GrammarPoint.Use) -> [GrammarPoint] {
        points.filter { $0.level <= level && !$0.formulaic && ($0.use == .both || $0.use == use) }
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
        kinds: universal + [.tone, .particle, .measureWord, .tenseAspect],
        routing: """
        A wrong tone is a different word, so report it as tone, not
        pronunciation, and name the character actually said.
        Mandarin drops subjects freely once the topic is set: a clause after a
        comma, and a sentence continuing the same topic, do not need one.
        Report a dropped subject only when you genuinely cannot tell who is
        meant, and then it is missing-piece, never word-order.
        个 is what speech reaches for when the specific classifier does not
        come to mind. Spoken, treat it as kept; written, it is at most
        "weakens" — never "breaks".
        Taking dictation, a syllable written as a character with a different
        tone is tone: the tone did not land. Written as a character with the
        same sound and the same tone it is word-choice — they heard it and wrote
        it wrong, and it is neither tone nor pronunciation. A sentence-final
        particle that never arrived is particle, never missing-piece.
        """,
        assessmentNotes: """
        The two jobs of 了 — completion after the verb, change of state at the
        end — are the single most common confusion an English speaker has.
        What goes missing in dictation is whatever carries no stress:
        sentence-final 了 吧 呢 啊 吗, and 了 after a vowel worst of all. What comes
        back as a different sound is zh/z, ch/c, sh/s, and n against ng in a
        final.
        """,
        generationNotes: """
        Write the English prompt so a natural Mandarin rendering needs the
        target structure. No Chinese in the English prompt.
        """,
        points: [
            GrammarPoint(id: "le-completion", name: "了 for a completed action", level: 1,
                         kind: .tenseAspect,
                         instruction: "A finished action, followed by something else.",
                         examples: ["我吃了饭就走了"]),
            GrammarPoint(id: "le-change", name: "了 for a change of state", level: 1,
                         kind: .particle,
                         instruction: "Something that was not true and now is.",
                         examples: ["下雨了", "我懂了"]),
            GrammarPoint(id: "guo-experience", name: "过 for experience", level: 2,
                         kind: .tenseAspect,
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
            GrammarPoint(id: "ba-construction", name: "把 to front the object", level: 4,
                         kind: .wordOrder,
                         instruction: "Something concrete done to a definite object, with a result.",
                         examples: ["我把书放在桌子上", "她把门关了"]),
            GrammarPoint(id: "de-complement", name: "得 for how an action goes", level: 4,
                         kind: .wordOrder,
                         instruction: "Evaluating an action rather than a thing.",
                         examples: ["他说得很快", "你唱得很好"]),
            GrammarPoint(id: "resultative", name: "Resultative complements", level: 4,
                         kind: .collocation,
                         instruction: "吃完, 听懂, 走出去 — the result fused to the verb.",
                         examples: ["我吃完了", "你听懂了吗？"]),
            GrammarPoint(id: "shi-de", name: "是…的 for circumstances", level: 5,
                         kind: .wordOrder,
                         instruction: "Emphasising when, where or how a known past event happened.",
                         examples: ["我是坐飞机来的"]),
            GrammarPoint(id: "suiran-danshi", name: "虽然…但是 concession pair", level: 4,
                         kind: .missingPiece,
                         instruction: "Both halves marked; English marks only one.",
                         examples: ["虽然很贵，但是我买了"]),
            GrammarPoint(id: "subject-in-clause", name: "Clauses keep their subject", level: 2,
                         kind: .missingPiece,
                         instruction: "因为 / 所以 clauses where English would drop the subject.",
                         examples: ["因为那里很安静"])
        ]
    )

    // MARK: German

    static let german = LanguagePack(
        language: .german,
        kinds: universal + [
            .verbSecond, .bracket, .verbFinal,
            .caseChoice, .caseForm, .adjectiveEnding, .gender,
            .negation, .preposition, .tenseAspect, .mood, .particle
        ],
        routing: """
        Diagnose gender before case-form: with the wrong gender the ending is
        unreachable, so reporting "ending" for a gender lookup failure sends the
        learner to the wrong lesson.
        A finite verb out of second position is verb-second, never word-order.
        A participle, infinitive or separable prefix left in the English slot is
        bracket, never word-order and never a separate "separable verb" finding
        — separability is a property of the verb, not a kind of mistake.
        Misplaced nicht is negation, never missing-piece.
        """,
        assessmentNotes: """
        Case has two separate failures. Choosing the wrong case is a fact about
        the verb or preposition; producing the wrong ending for the right case
        is morphology. Say which, because they take different repairs.
        Direction versus position after a two-way preposition genuinely changes
        meaning; most other ending errors do not.
        """,
        generationNotes: "No German in the English prompt.",
        points: [
            GrammarPoint(id: "v2-fronting", name: "Verb second after a fronted element", level: 1,
                         kind: .verbSecond,
                         instruction: "Start with a time or place phrase, so the subject follows the verb.",
                         examples: ["Morgen gehe ich ins Kino", "In Berlin wohnt meine Schwester"]),
            GrammarPoint(id: "bracket", name: "The verb bracket", level: 1,
                         kind: .bracket,
                         instruction: "A participle, an infinitive after a modal, or a separable prefix at the end.",
                         examples: ["Ich habe ein Buch gelesen", "Ich stehe um sieben auf",
                                    "Ich will meine Tante besuchen"]),
            GrammarPoint(id: "verb-final", name: "Verb last in subordinate clauses", level: 2,
                         kind: .verbFinal,
                         instruction: "weil, dass, wenn, ob.",
                         examples: ["Ich bleibe zu Hause, weil es regnet"]),
            GrammarPoint(id: "two-way-prep", name: "Two-way prepositions", level: 2,
                         kind: .caseChoice,
                         instruction: "Motion takes accusative, position takes dative.",
                         examples: ["Ich gehe in die Stadt", "Ich bin in der Stadt"]),
            GrammarPoint(id: "verb-government", name: "Case governed by the verb", level: 2,
                         kind: .caseChoice,
                         instruction: "helfen, danken, gehören with dative.",
                         examples: ["Ich helfe meinem Bruder"]),
            GrammarPoint(id: "gender", name: "Noun gender", level: 1,
                         kind: .gender,
                         instruction: "A noun whose gender an English speaker cannot guess.",
                         examples: ["das Mädchen", "der Löffel", "die Gabel"]),
            GrammarPoint(id: "adjective-endings", name: "Adjective endings", level: 3,
                         kind: .adjectiveEnding,
                         instruction: "An adjective before a noun, after der, after ein, and after nothing.",
                         examples: ["ein guter Freund", "der gute Freund", "guter Wein"]),
            GrammarPoint(id: "nicht-placement", name: "Where nicht goes", level: 1,
                         kind: .negation,
                         instruction: "Negating a whole clause versus one element; nicht against kein.",
                         examples: ["Ich kenne ihn nicht", "Ich habe kein Geld"]),
            GrammarPoint(id: "perfekt-aux", name: "haben or sein in the Perfekt", level: 2,
                         kind: .auxiliary,
                         instruction: "A movement or change-of-state verb in the past.",
                         examples: ["Ich bin nach Hause gegangen", "Ich habe gegessen"]),
            GrammarPoint(id: "passive", name: "The passive", level: 3,
                         kind: .tenseAspect,
                         instruction: "An action whose agent does not matter — heavily under-produced.",
                         examples: ["Das Haus wird gebaut"]),
            GrammarPoint(id: "man", name: "man for the generic subject", level: 3,
                         kind: .wordChoice,
                         instruction: "Where English says 'you' or 'people' in general.",
                         examples: ["Hier darf man nicht rauchen"]),
            GrammarPoint(id: "genitive", name: "The genitive", level: 4,
                         kind: .caseChoice,
                         instruction: "Possession, where a learner would reach for von + Dativ.",
                         examples: ["das Auto meines Bruders"]),
            GrammarPoint(id: "konjunktiv-ii", name: "Konjunktiv II", level: 4,
                         kind: .mood, formulaic: false,
                         instruction: "A hypothetical, beyond the fixed polite phrases.",
                         examples: ["Wenn ich Zeit hätte, würde ich mitkommen"]),
            GrammarPoint(id: "konjunktiv-ii-polite", name: "Polite Konjunktiv II phrases", level: 1,
                         kind: .mood, formulaic: true,
                         instruction: "Fixed phrases only.",
                         examples: ["Ich hätte gern einen Kaffee", "Könnten Sie mir helfen?"]),
            GrammarPoint(id: "modal-particles", name: "Modal particles", level: 4,
                         kind: .particle, use: .spoken,
                         instruction: "doch, mal, ja, eben — what makes speech sound German.",
                         examples: ["Komm doch mal vorbei", "Das ist ja toll"])
        ]
    )

    // MARK: French

    static let french = LanguagePack(
        language: .french,
        kinds: universal + [
            .agreementHeard, .agreementWritten, .gender, .auxiliary,
            .pronounPlacement, .liaison, .negation, .preposition,
            .tenseAspect, .mood
        ],
        routing: """
        Never report a dropped `ne`. Native speakers delete it in most casual
        speech; flagging it teaches something false. If it matters at all it is
        a register note, and only in writing.
        Agreement splits by whether it can be heard. Report agreement-heard for
        anything that changes the sound; agreement-written for silent
        orthography, and never at all when the attempt was spoken.
        Participle agreement after être is agreement, not auxiliary, even though
        the auxiliary is what triggers it.
        A missing object pronoun is pronoun-placement, not missing-piece — for
        English speakers omission is the commonest pronoun error, not misorder.
        """,
        assessmentNotes: """
        Gender errors get worse with distance from the noun and are worse on
        adjectives than on determiners; say which word is failing to agree with
        which.
        """,
        generationNotes: "No French in the English prompt.",
        points: [
            GrammarPoint(id: "verb-agreement-heard", name: "Audible verb endings", level: 1,
                         kind: .agreementHeard,
                         instruction: "A plural subject where the verb form actually changes sound.",
                         examples: ["ils finissent", "elles viennent"]),
            GrammarPoint(id: "passe-compose-aux", name: "être or avoir in the passé composé", level: 2,
                         kind: .auxiliary,
                         instruction: "A movement or reflexive verb in the past.",
                         examples: ["Je suis allé au marché", "Je me suis levé tôt"]),
            GrammarPoint(id: "gender", name: "Noun gender", level: 1,
                         kind: .gender,
                         instruction: "A noun taking an adjective, so the gender is visible.",
                         examples: ["une grande maison", "un vieux livre"]),
            GrammarPoint(id: "pas-de", name: "pas de after negation", level: 1,
                         kind: .negation,
                         instruction: "Negating a sentence with an indefinite object.",
                         examples: ["Je n'ai pas de pain", "Il ne mange pas de viande"]),
            GrammarPoint(id: "negation-frames", name: "ne…que, plus, jamais, personne", level: 3,
                         kind: .negation,
                         instruction: "Negation other than pas.",
                         examples: ["Je n'ai que dix euros", "Il ne vient jamais"]),
            GrammarPoint(id: "object-pronouns", name: "Object pronouns before the verb", level: 2,
                         kind: .pronounPlacement,
                         instruction: "Replacing a stated object — English speakers repeat the noun instead.",
                         examples: ["Je le vois", "Je lui parle"]),
            GrammarPoint(id: "y-en", name: "y and en", level: 3,
                         kind: .pronounPlacement,
                         instruction: "Replacing a place or a quantity. No English equivalent, so never reached for.",
                         examples: ["J'y vais", "J'en ai trois"]),
            GrammarPoint(id: "clitic-clusters", name: "Two pronouns together", level: 4,
                         kind: .pronounPlacement,
                         instruction: "me le, le lui — avoided even by learners comfortable with one.",
                         examples: ["Je le lui ai donné"]),
            GrammarPoint(id: "pc-imparfait", name: "Passé composé against imparfait", level: 3,
                         kind: .tenseAspect,
                         instruction: "A narrative with both a background and an event.",
                         examples: ["Je regardais la télé quand il est arrivé"]),
            GrammarPoint(id: "preposition-government", name: "Verbs with à or de", level: 2,
                         kind: .preposition,
                         instruction: "penser à against penser de, commencer à, essayer de.",
                         examples: ["Je pense à toi", "J'essaie de comprendre"]),
            GrammarPoint(id: "partitive", name: "Partitive articles", level: 1,
                         kind: .wordChoice,
                         instruction: "Some quantity of an uncountable thing.",
                         examples: ["Je bois du café", "Je mange de la soupe"]),
            GrammarPoint(id: "subjunctive", name: "The subjunctive", level: 4,
                         kind: .mood,
                         instruction: "After il faut que, bien que, vouloir que — learners restructure to dodge it.",
                         examples: ["Il faut que tu viennes", "Bien qu'il soit tard"]),
            GrammarPoint(id: "dont", name: "The relative dont", level: 4,
                         kind: .pronounPlacement,
                         instruction: "A relative clause whose verb takes de.",
                         examples: ["le livre dont je parle"]),
            GrammarPoint(id: "liaison", name: "Liaison", level: 2,
                         kind: .liaison, use: .spoken,
                         instruction: "Obligatory liaison across a determiner or pronoun boundary.",
                         examples: ["les amis", "nous avons", "un petit enfant"]),
            GrammarPoint(id: "written-agreement", name: "Silent written agreement", level: 2,
                         kind: .agreementWritten, use: .written,
                         instruction: "Plural -s and participle agreement that cannot be heard.",
                         examples: ["les livres intéressants", "les lettres que j'ai écrites"]),
            GrammarPoint(id: "passe-simple", name: "The passé simple", level: 5,
                         kind: .tenseAspect, use: .written,
                         instruction: "Written narrative only — correctly absent from speech.",
                         examples: ["Il entra dans la pièce"])
        ]
    )
}
