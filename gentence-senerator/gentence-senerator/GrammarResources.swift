import Foundation

// MARK: - GrammarResource

struct GrammarResource: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
}

// MARK: - GrammarResources

enum GrammarResources {

    /// Returns up to 2 curated resources for a grammar issue key and target language.
    /// Returns [] for any unknown key — callers should guard against empty results.
    static func resources(for key: String, language: String) -> [GrammarResource] {
        switch language {
        case "Mandarin":
            return mandarinMap[key] ?? []
        case "Japanese":
            return japaneseMap[key] ?? universalMap[key] ?? []
        case "Korean":
            return koreanMap[key] ?? universalMap[key] ?? []
        default:
            // French, German, Spanish, Italian, Portuguese
            return universalMap[key] ?? []
        }
    }

    // MARK: - Mandarin (12 categories → AllSet Learning + secondary source)

    private static let mandarinMap: [String: [GrammarResource]] = [
        "particle_usage": [
            GrammarResource(
                title: "Chinese Particles — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Particle")!),
            GrammarResource(
                title: "Chinese Grammar Particles — DigMandarin",
                url: URL(string: "https://www.digmandarin.com/commonly-used-chinese-grammar-particles.html")!)
        ],
        "measure_words": [
            GrammarResource(
                title: "Measure Words — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Measure_word")!),
            GrammarResource(
                title: "Measure Words for Counting — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Measure_words_for_counting")!)
        ],
        "word_order": [
            GrammarResource(
                title: "Time Words & Word Order — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Time_words_and_word_order")!),
            GrammarResource(
                title: "Sentence Patterns — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Sentence_Patterns")!)
        ],
        "aspect_markers": [
            GrammarResource(
                title: "Aspect (了/过/着) — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Aspect")!),
            GrammarResource(
                title: "Chinese Particles Guide — StoryLearning",
                url: URL(string: "https://storylearning.com/learn/chinese/chinese-tips/chinese-particles")!)
        ],
        "ba_sentence": [
            GrammarResource(
                title: "Using 把-Sentences — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Using_%22ba%22_sentences")!),
            GrammarResource(
                title: "Advanced Uses of 把 — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Advanced_uses_of_%22ba%22")!)
        ],
        "resultative_complement": [
            GrammarResource(
                title: "Result Complements — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Result_complements")!),
            GrammarResource(
                title: "Complement Overview — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Complement")!)
        ],
        "potential_complement": [
            GrammarResource(
                title: "Potential Complement — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/potential_complement")!),
            GrammarResource(
                title: "Result Complements — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Result_complements")!)
        ],
        "topic_comment": [
            GrammarResource(
                title: "Topic-Comment Sentences — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Topic-comment_sentences")!),
            GrammarResource(
                title: "Sentence Patterns — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Sentence_Patterns")!)
        ],
        "negation": [
            GrammarResource(
                title: "Negation with 不 — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Standard_negation_with_%22bu%22")!),
            GrammarResource(
                title: "Negating 有 with 没 — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Negation_of_%22you%22_with_%22mei%22")!)
        ],
        "comparison": [
            GrammarResource(
                title: "Comparisons with 比 — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Basic_comparisons_with_%22bi%22")!),
            GrammarResource(
                title: "Expressing 'Much More' in Comparisons — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Expressing_%22much_more%22_in_comparisons")!)
        ],
        "question_formation": [
            GrammarResource(
                title: "Question Patterns — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Replying_to_questions")!),
            GrammarResource(
                title: "Sentence Patterns — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Sentence_Patterns")!)
        ],
        "verb_complement": [
            GrammarResource(
                title: "Complement Overview — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/Complement")!),
            GrammarResource(
                title: "Degree Complement with 得 — AllSet Learning",
                url: URL(string: "https://resources.allsetlearning.com/chinese/grammar/degree_complement")!)
        ]
    ]

    // MARK: - Universal (French, German, Spanish, Italian, Portuguese)

    private static let universalMap: [String: [GrammarResource]] = [
        "word_order": [
            GrammarResource(
                title: "Word Order — Lawless French Grammar",
                url: URL(string: "https://www.lawlessfrench.com/grammar/compound-tenses-word-order/")!),
            GrammarResource(
                title: "Sentence Clause Structure — Wikipedia",
                url: URL(string: "https://en.wikipedia.org/wiki/Sentence_clause_structure")!)
        ],
        "negation": [
            GrammarResource(
                title: "Introduction to Negation — Tex's French Grammar (UT Austin)",
                url: URL(string: "https://laits.utexas.edu/tex/gr/neg1.html")!),
            GrammarResource(
                title: "Negation Placement — Kwiziq",
                url: URL(string: "https://french.kwiziq.com/revision/grammar/where-to-place-negations-in-sentences-with-two-verbs-conjugated-and-infinitive")!)
        ],
        "verb_tense": [
            GrammarResource(
                title: "Spanish Grammar — SpanishDict",
                url: URL(string: "https://www.spanishdict.com/topics/grammar")!),
            GrammarResource(
                title: "French Grammar — Lawless French",
                url: URL(string: "https://www.lawlessfrench.com/grammar/")!)
        ],
        "vocabulary_choice": [
            GrammarResource(
                title: "WordReference — Multilingual Dictionary",
                url: URL(string: "https://www.wordreference.com/")!),
            GrammarResource(
                title: "Reverso Context — Words in Authentic Sentences",
                url: URL(string: "https://context.reverso.net/translation/")!)
        ]
    ]

    // MARK: - Japanese (overrides for language-specific categories)

    private static let japaneseMap: [String: [GrammarResource]] = [
        "word_order": [
            GrammarResource(
                title: "Japanese Particles Intro — Guide to Japanese",
                url: URL(string: "https://guidetojapanese.org/learn/grammar/particlesintro")!),
            GrammarResource(
                title: "Particles with Verbs — Guide to Japanese",
                url: URL(string: "https://guidetojapanese.org/learn/complete/verb_particles")!)
        ],
        "verb_tense": [
            GrammarResource(
                title: "Japanese Grammar Index — Tofugu",
                url: URL(string: "https://www.tofugu.com/japanese-grammar/")!),
            GrammarResource(
                title: "Japanese Grammar — Wasabi",
                url: URL(string: "https://www.wasabi-jpn.com/japanese-grammar/")!)
        ]
    ]

    // MARK: - Korean (overrides for language-specific categories)

    private static let koreanMap: [String: [GrammarResource]] = [
        "word_order": [
            GrammarResource(
                title: "Korean Particles — How to Study Korean",
                url: URL(string: "https://www.howtostudykorean.com/unit1/unit-1-lessons-1-8/unit-1-lesson-2/")!),
            GrammarResource(
                title: "Korean Particles Guide — Talk To Me In Korean",
                url: URL(string: "https://blog.talktomeinkorean.com/how-korean-particles-work-a-guide-for-essential-grammar-points/")!)
        ],
        "verb_tense": [
            GrammarResource(
                title: "Level 1 Korean Grammar — Talk To Me In Korean",
                url: URL(string: "https://talktomeinkorean.com/curriculum/level-1-korean-grammar/")!),
            GrammarResource(
                title: "Korean Sentence Structure — 90 Day Korean",
                url: URL(string: "https://www.90daykorean.com/korean-sentence-structure/")!)
        ]
    ]
}
