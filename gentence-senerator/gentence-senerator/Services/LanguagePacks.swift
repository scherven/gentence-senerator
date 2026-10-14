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

    /// HSK runs to 9, CEFR and TOPIK to 6.
    var levels: Int { language == .mandarin ? 9 : 6 }

    func level(_ n: Int) -> String {
        switch language {
        case .mandarin:
            // HSK 3.0 was designed for CEFR-style alignment: 1-3 ≈ A1-A2,
            // 4-6 ≈ B1-B2, 7-9 ≈ C1-C2.
            return "HSK \(min(max(n, 1), 9))"
        case .korean:
            return "TOPIK \(min(max(n, 1), 6))"
        case .german, .french, .spanish:
            let bands = ["A1", "A2", "B1", "B2", "C1", "C2"]
            return bands[min(max(n - 1, 0), bands.count - 1)]
        }
    }

    /// The vocabulary of ids the model may tag an attempt with. Anything else
    /// it returns was invented.
    var pointIDs: Set<String> { Set(points.map(\.id)) }

    /// Points the learner could reach for at this level, in this mode.
    func reachable(at level: Int, use: GrammarPoint.Use) -> [GrammarPoint] {
        points.filter { $0.level <= level && !$0.formulaic && ($0.use == .both || $0.use == use) }
    }
}

enum LanguagePacks {

    /// Loaded once, off the bundle. The points themselves are authored in
    /// `Curriculum/grammar-*.json`; what is here is everything that cannot be
    /// data — the kinds the assessor may return, and the routing rules.
    private static let curriculum = Curriculum()

    static func pack(for language: Language) -> LanguagePack {
        switch language {
        case .mandarin: return mandarin
        case .german:   return german
        case .french:   return french
        case .spanish:  return spanish
        case .korean:   return korean
        }
    }

    private static let universal: [AtomKind] = [
        .wordOrder, .wordChoice, .missingPiece, .extraPiece,
        .register, .collocation, .comprehension, .pronunciation
    ]

    // MARK: Mandarin

    static let mandarin = LanguagePack(
        language: .mandarin,
        kinds: universal + [.tone, .particle, .measureWord, .tenseAspect,
                            .negation, .preposition, .mood],
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
        不 against 没 is negation, never word-choice: 没 negates completion and
        existence, 不 everything else. 别 is negation too.
        A coverb — 在, 给, 跟, 对, 从 — is preposition when the wrong one is
        chosen, word-order when the right one is misplaced. English speakers put
        it after the verb; that is word-order.
        会/能/可以 and 得/应该/必须 are mood, including when the wrong modal is
        just the wrong word for the meaning.
        In translate and produce, a typed answer came through a pinyin keyboard.
        A character with the same pinyin as the right one, whatever its tone,
        is a slip of the keyboard: spelling, as word-choice, never tone.
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
        points: curriculum.points(for: .mandarin)
    )

    // MARK: German

    static let german = LanguagePack(
        language: .german,
        kinds: universal + [
            .verbSecond, .bracket, .verbFinal,
            .caseChoice, .caseForm, .adjectiveEnding, .gender,
            .negation, .preposition, .tenseAspect, .mood, .particle,
            // haben vs sein in the Perfekt. Without it `perfekt-aux` names a kind
            // the assessor can never return, so the point can never be linked.
            .auxiliary
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
        Typed, a lower-case noun, ss for ß, and a missing umlaut are spelling —
        the keyboard, usually — unless the plain vowel makes another word
        (schon/schön, zahlen/zählen). ae, oe, ue for the umlaut are correct.
        Spoken, weil or obwohl with main-clause order is common native speech:
        verb-final, at most "weakens", ranked below anything else a listener
        would notice.
        """,
        assessmentNotes: """
        Case has two separate failures. Choosing the wrong case is a fact about
        the verb or preposition; producing the wrong ending for the right case
        is morphology. Say which, because they take different repairs.
        Direction versus position after a two-way preposition genuinely changes
        meaning; most other ending errors do not, and are "weakens", ranked
        below any word or phrasing a speaker would not use.
        """,
        generationNotes: "No German in the English prompt.",
        points: curriculum.points(for: .german)
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
        agreement-written, a missing or wrong accent, and one homophone written
        for another (a/à, et/est, ces/ses, -er for -é) are spelling: at most
        "weakens", ranked below anything a listener would hear.
        A missing object pronoun is pronoun-placement, not missing-piece — for
        English speakers omission is the commonest pronoun error, not misorder.
        """,
        assessmentNotes: """
        Gender errors get worse with distance from the noun and are worse on
        adjectives than on determiners; say which word is failing to agree with
        which.
        """,
        generationNotes: "No French in the English prompt.",
        points: curriculum.points(for: .french)
    )

    // MARK: Spanish

    static let spanish = LanguagePack(
        language: .spanish,
        kinds: universal + [
            .gender, .agreementHeard, .copula, .tenseAspect, .mood,
            .pronounPlacement, .preposition, .negation
        ],
        routing: """
        The target is Mexican Spanish, but Spain's is correct Spanish: never
        report vosotros, leísmo or a Peninsular word as an error. Spoken,
        si hubiera… hubiera and habían before a plural noun are Mexican
        usage: kept.
        A dropped subject pronoun is correct. One used where nothing is
        contrasted is extra-piece, at most "weakens".
        ser against estar is copula, never word-choice; so is estar where an
        indefinite thing exists and hay was needed.
        Preterite against imperfect is tense-aspect. A missing subjunctive
        after a trigger — querer que, para que, cuando about the future — is
        mood, never tense-aspect.
        por against para, and a missing personal a, are preposition.
        An object pronoun missing, misplaced, or lo where le belongs is
        pronoun-placement, never missing-piece.
        The wrong gender for a noun is gender; an article or adjective failing
        to agree with a noun whose gender is right is agreement-heard.
        No before the verb with nada, nadie or nunca after it is required;
        leaving it out is negation.
        A missing written accent is spelling: word-choice, written only, at
        most "weakens" — unless it changes the word (esta/está, el/él).
        """,
        assessmentNotes: """
        ser/estar, preterite/imperfect and the subjunctive are the three an
        English speaker carries longest. In speech, what comes back wrong is
        unstressed vowels drifting to schwa, and a tap r for a trilled rr —
        pero against perro, which is a different word.
        """,
        generationNotes: "No Spanish in the English prompt. Plural you is ustedes.",
        points: curriculum.points(for: .spanish)
    )

    // MARK: Korean

    static let korean = LanguagePack(
        language: .korean,
        kinds: universal + [
            .particle, .verbFinal, .speechLevel, .connective,
            .tenseAspect, .negation, .mood
        ],
        routing: """
        은/는 against 이/가, 에 against 에서, and any missing or wrong case
        particle are particle, never word-choice and never preposition. The
        wrong allomorph for the final consonant (을 for 를, 으로 for 로) is
        particle, at most "weakens".
        Speech drops 을/를 and 이/가, and subjects and objects once the topic is
        set: spoken, a dropped one is kept. Report a missing one only when you
        cannot tell who did what.
        A verb or adjective that is not last in its clause is verb-final, never
        word-order.
        The ending's level against the listener — 반말 in a 해요체 sentence, or
        the wrong level for who the prompt names — is speech-level, never
        register. A missing -시- for an honoured subject, and honorific forms
        (드시다, 계시다, 댁, 께서), are speech-level too. With no listener named, any
        consistent polite level is right.
        A clause-linking ending chosen wrong — -아서/-어서 against -니까, -고,
        -는데, -지만, -면 — is connective, including -아서 before a command or
        suggestion. Never word-choice or mood.
        안 against 못, and -지 마세요, are negation.
        되/돼 and 안/않 confusions are spelling: word-choice, written only, at
        most "weakens".
        """,
        assessmentNotes: """
        은/는 against 이/가 is the single most common confusion an English
        speaker has: new information takes 이/가, the topic and the contrast
        take 은/는. In speech, what comes back wrong is plain, aspirated and
        tense consonants — 달, 탈, 딸 are three words — and ㅓ against ㅗ.
        """,
        generationNotes: """
        No Korean in the English prompt. When the speech level matters, say who
        is being spoken to; otherwise 해요체 is expected.
        """,
        points: curriculum.points(for: .korean)
    )
}
