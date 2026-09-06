import Foundation

// MARK: - Mandarin Service
// Specialised prompts for Mandarin Chinese practice.
//
// Sentence generation runs on two independent axes:
//   1. Vocab band (difficulty 1-10) — controls vocabulary sophistication and sentence length only.
//   2. Grammar point — sampled per-sentence from MandarinGrammarBank's cumulative pool of every
//      point unlocked at or below the current difficulty, weighted toward least-recently-used /
//      weakest points. This is what actually drives structural variety: a learner parked at
//      difficulty 5 draws from 15 eligible grammar points, not the single point difficulty 5 used
//      to mandate.
// Each selected point is grounded with a real example sentence (the "data bank") so the model
// varies a concrete template instead of inventing a structure from a text description alone.

struct MandarinGeneratedSentence {
    let text: String
    let grammarPointID: String
}

struct MandarinGeneratedListeningSentence {
    let targetText: String
    let englishMeaning: String
    let grammarPointID: String
}

final class MandarinService: LanguageService {

    private static let topics = [
        "food", "travel", "work", "family", "weather", "shopping",
        "hobbies", "health", "technology", "school", "sports", "money"
    ]

    // MARK: - Point-aware generation (primary API — see AppStore)

    func generateSentenceWithPoint(
        difficulty: Int,
        excludingTexts: [String] = [],
        sessionTexts: [String] = [],
        context: GrammarPointSampleContext = GrammarPointSampleContext(),
        recentPointIDs: [String] = []
    ) async throws -> MandarinGeneratedSentence {
        guard let point = MandarinGrammarBank.selectPoints(
            count: 1, difficulty: difficulty, context: context, avoiding: recentPointIDs
        ).first else {
            throw LanguageServiceError.emptyResponse
        }

        let vocabDesc = mandarinVocabBandDescription(difficulty)
        let exclusionHint = excludingTexts.isEmpty ? "" :
            " Do NOT repeat any of these previously seen sentences: \(excludingTexts.prefix(10).joined(separator: "; "))."
        let sessionHint = sessionTexts.isEmpty ? "" :
            " This session has already used these sentences — choose a DIFFERENT topic: \(sessionTexts.joined(separator: "; "))."
        let topic = Self.topics.randomElement() ?? "daily life"
        let example = point.examples.randomElement() ?? ""

        let systemPrompt = """
        You are a Mandarin Chinese language learning sentence generator.
        Generate a single natural English sentence designed for Mandarin translation practice.
        \(vocabDesc)\(exclusionHint)\(sessionHint)

        Grammar target: \(point.name) — \(point.instruction)
        Structural template (do NOT reuse its topic or vocabulary — only its grammar pattern): \(example)
        Topic: \(topic)

        Return ONLY the English sentence — no translation, no explanation, no extra punctuation.
        """

        for attempt in 1...2 {
            let text = try await performRequest(
                system: systemPrompt,
                messages: [["role": "user", "content": "Generate one English sentence for Mandarin translation practice."]],
                maxTokens: 8192,
                effort: .medium
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !trimmed.isEmpty else { throw LanguageServiceError.emptyResponse }
            if !containsCJK(trimmed) {
                return MandarinGeneratedSentence(text: trimmed, grammarPointID: point.id)
            }
            print("[MandarinService] generateSentenceWithPoint attempt \(attempt) returned CJK text, retrying: \(trimmed)")
        }
        throw LanguageServiceError.emptyResponse
    }

    func generateSentenceBatchWithPoints(
        count: Int,
        difficulty: Int,
        excludingTexts: [String] = [],
        context: GrammarPointSampleContext = GrammarPointSampleContext()
    ) async throws -> [MandarinGeneratedSentence] {
        let points = MandarinGrammarBank.selectPoints(count: count, difficulty: difficulty, context: context)
        guard !points.isEmpty else { throw LanguageServiceError.emptyResponse }

        let vocabDesc = mandarinVocabBandDescription(difficulty)
        let exclusionHint = excludingTexts.isEmpty ? "" :
            " Do NOT repeat any of these previously seen sentences: \(excludingTexts.prefix(10).joined(separator: "; "))."
        let slots = buildSlotDescriptions(points: points).joined(separator: "\n\n")

        let systemPrompt = """
        You are a Mandarin Chinese language learning sentence generator.
        Generate exactly \(points.count) English sentences for Mandarin translation practice.
        \(vocabDesc)\(exclusionHint)

        Each sentence below targets a DIFFERENT Mandarin grammar pattern. A short example sentence \
        demonstrating each pattern is given as a structural template only — your English sentence must \
        translate naturally into a NEW Mandarin sentence using that grammar pattern, with a different \
        topic and different vocabulary than the template.

        \(slots)

        Return ONLY valid JSON in exactly this format:
        {"sentences": ["<sentence 1>", "<sentence 2>", ..., "<sentence \(points.count)>"]}
        """

        let raw = try await performRequest(
            system: systemPrompt,
            messages: [["role": "user", "content": "Generate \(points.count) English sentences for Mandarin translation practice."]],
            maxTokens: 8192,
            effort: .medium
        )

        let texts = try parseSentenceBatch(raw, expected: points.count)
        let pairs = zip(texts, points).filter { !containsCJK($0.0) }
        if pairs.count < texts.count {
            print("[MandarinService] generateSentenceBatchWithPoints filtered \(texts.count - pairs.count) CJK sentences out of \(texts.count)")
        }
        guard !pairs.isEmpty else { throw LanguageServiceError.emptyResponse }
        return pairs.map { MandarinGeneratedSentence(text: $0.0, grammarPointID: $0.1.id) }
    }

    func generateListeningSentenceWithPoint(
        difficulty: Int,
        excludingTexts: [String] = [],
        context: GrammarPointSampleContext = GrammarPointSampleContext(),
        recentPointIDs: [String] = []
    ) async throws -> MandarinGeneratedListeningSentence {
        guard let point = MandarinGrammarBank.selectPoints(
            count: 1, difficulty: difficulty, context: context, avoiding: recentPointIDs
        ).first else {
            throw LanguageServiceError.emptyResponse
        }

        let vocabDesc = mandarinVocabBandDescription(difficulty)
        let exclusionHint = excludingTexts.isEmpty ? "" :
            " Do NOT generate a sentence similar to: \(excludingTexts.prefix(10).joined(separator: "; "))."
        let topic = Self.topics.randomElement() ?? "daily life"
        let example = point.examples.randomElement() ?? ""

        let systemPrompt = """
        You are a Mandarin Chinese language learning content generator.
        Generate a single natural Mandarin sentence for listening comprehension practice.
        \(vocabDesc)\(exclusionHint)

        Grammar target: \(point.name) — \(point.instruction)
        Structural template (do NOT reuse its topic or vocabulary — only its grammar pattern): \(example)
        Topic: \(topic)

        The sentence should be natural spoken Mandarin (not literary). Include characters only — no pinyin.
        Also provide the English meaning.

        Return ONLY valid JSON in exactly this format:
        {
          "targetText": "<the Mandarin sentence in Chinese characters>",
          "englishMeaning": "<the English translation>"
        }
        """

        let raw = try await performRequest(
            system: systemPrompt,
            messages: [["role": "user", "content": "Generate one Mandarin listening sentence."]],
            maxTokens: 8192,
            effort: .medium
        )

        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targetText = json["targetText"] as? String,
              let englishMeaning = json["englishMeaning"] as? String,
              !targetText.isEmpty, !englishMeaning.isEmpty else {
            throw LanguageServiceError.decodingFailed("Could not parse Mandarin listening sentence response")
        }

        return MandarinGeneratedListeningSentence(
            targetText: targetText.trimmingCharacters(in: .whitespacesAndNewlines),
            englishMeaning: englishMeaning.trimmingCharacters(in: .whitespacesAndNewlines),
            grammarPointID: point.id)
    }

    func generateListeningSentenceBatchWithPoints(
        count: Int,
        difficulty: Int,
        excludingTexts: [String] = [],
        context: GrammarPointSampleContext = GrammarPointSampleContext()
    ) async throws -> [MandarinGeneratedListeningSentence] {
        let points = MandarinGrammarBank.selectPoints(count: count, difficulty: difficulty, context: context)
        guard !points.isEmpty else { throw LanguageServiceError.emptyResponse }

        let vocabDesc = mandarinVocabBandDescription(difficulty)
        let exclusionHint = excludingTexts.isEmpty ? "" :
            " Do NOT repeat any sentence similar to: \(excludingTexts.prefix(10).joined(separator: "; "))."
        let slots = buildSlotDescriptions(points: points).joined(separator: "\n\n")

        let systemPrompt = """
        You are a Mandarin Chinese language learning content generator.
        Generate exactly \(points.count) natural Mandarin sentences for listening comprehension practice.
        \(vocabDesc)\(exclusionHint)

        Each sentence below targets a DIFFERENT Mandarin grammar pattern. A short example sentence \
        demonstrating each pattern is given as a structural template only — write a NEW sentence using \
        that grammar pattern, with a different topic and different vocabulary than the template. \
        Include characters only — no pinyin.

        \(slots)

        Return ONLY valid JSON in exactly this format:
        {
          "sentences": [
            {"targetText": "<Mandarin characters>", "englishMeaning": "<English translation>"},
            ...
          ]
        }
        """

        let raw = try await performRequest(
            system: systemPrompt,
            messages: [["role": "user", "content": "Generate \(points.count) Mandarin listening sentences."]],
            maxTokens: 8192,
            effort: .medium
        )

        let pairs = try parseListeningSentenceBatch(raw)
        return zip(pairs, points).map { pair, point in
            MandarinGeneratedListeningSentence(targetText: pair.targetText, englishMeaning: pair.englishMeaning, grammarPointID: point.id)
        }
    }

    private func buildSlotDescriptions(points: [GrammarPoint]) -> [String] {
        let shuffledTopics = Self.topics.shuffled()
        return points.enumerated().map { idx, point in
            let topic = shuffledTopics[idx % shuffledTopics.count]
            let example = point.examples.randomElement() ?? ""
            return """
            Sentence \(idx + 1) — topic: \(topic). Grammar target: \(point.name) — \(point.instruction) \
            Structural template: \(example)
            """
        }
    }

    // MARK: - LanguageService interface overrides (thin wrappers, kept for polymorphic callers)

    override func generateSentence(
        difficulty: Int,
        targetLanguage: String,
        excludingTexts: [String] = [],
        sessionTexts: [String] = [],
        grammarFocusAreas: [String] = []
    ) async throws -> String {
        var context = GrammarPointSampleContext()
        context.focusAreas = grammarFocusAreas
        let result = try await generateSentenceWithPoint(
            difficulty: difficulty, excludingTexts: excludingTexts, sessionTexts: sessionTexts, context: context)
        return result.text
    }

    override func generateSentenceBatch(
        count: Int,
        difficulty: Int,
        targetLanguage: String,
        excludingTexts: [String] = [],
        grammarFocusAreas: [String] = []
    ) async throws -> [String] {
        var context = GrammarPointSampleContext()
        context.focusAreas = grammarFocusAreas
        let results = try await generateSentenceBatchWithPoints(
            count: count, difficulty: difficulty, excludingTexts: excludingTexts, context: context)
        return results.map(\.text)
    }

    override func generateListeningSentenceBatch(
        count: Int,
        difficulty: Int,
        targetLanguage: String,
        excludingTexts: [String] = []
    ) async throws -> [(targetText: String, englishMeaning: String)] {
        let results = try await generateListeningSentenceBatchWithPoints(
            count: count, difficulty: difficulty, excludingTexts: excludingTexts)
        return results.map { ($0.targetText, $0.englishMeaning) }
    }

    override func generateListeningSentence(
        difficulty: Int,
        targetLanguage: String,
        excludingTexts: [String] = []
    ) async throws -> (targetText: String, englishMeaning: String) {
        let result = try await generateListeningSentenceWithPoint(difficulty: difficulty, excludingTexts: excludingTexts)
        return (result.targetText, result.englishMeaning)
    }

    // MARK: - Evaluate attempt

    override func evaluateAttempt(
        englishSentence: String,
        transcript: String,
        language: String,
        attemptNumber: Int,
        listeningTargetText: String? = nil
    ) async throws -> SentenceEvaluationResult {
        let systemPrompt: String

        if let targetText = listeningTargetText {
            systemPrompt = """
            You are a Mandarin Chinese language tutor evaluating a student's listening comprehension attempt.

            The user message gives the Mandarin sentence the student heard and what their response was recognized as.

            Evaluate how accurately the student reproduced the sentence:
            1. Key words and overall meaning captured
            2. Grammar and vocabulary accuracy

            Important:
            - Always include specific tone reminders for 2-3 key characters using the "toneReminders" field,
              e.g. ["妈 mā (tone 1)", "买 mǎi (tone 3)"].
            - Include pinyin pronunciation hints for any phonologically tricky sounds in "phonemeHints".
            - If the transcript is empty or clearly not Mandarin, score 0 and say so.
            - The user message says which of the 3 attempts this is.
            - Set "correctTranslation" to the original Mandarin sentence that was played.

            For "feedback":
            - If score ≥ 85 or no grammar issues: write one short encouraging sentence only (e.g. "Great job!").
            - If grammar mistakes are present: explain each mistake in full detail — what structure was expected, what the student used, and exactly why it is wrong. Do NOT write vague phrases like "wrong structure". Do NOT mention tone or pronunciation in this field.

            For "alternativeTranslations": list other equally natural Mandarin phrasings of the same sentence, if any exist. Return [] if only one phrasing is natural.

            For "wordExplanations": for 3–5 notable words/phrases in correctTranslation, explain in English why that word or structure is used (1–2 sentences each). Use complete Chinese words/phrases (词 cí), not individual characters. Include particles (了/过/着), measure words, resultative complements, and key vocabulary.

            If grammar mistakes are present, add 1-2 keys to "grammarIssues" chosen ONLY from:
              particle_usage, measure_words, word_order, aspect_markers, ba_sentence,
              resultative_complement, potential_complement, topic_comment, negation,
              comparison, question_formation, verb_complement
            Return [] when score ≥ 85, or only tone/pronunciation errors were found.
            Never return more than 2 keys. No other strings allowed.

            Return ONLY valid JSON in exactly this format:
            {
              "score": <integer 0-100>,
              "feedback": "<grammar-focused feedback per rules above>",
              "toneReminders": ["<character> <pinyin> (tone <N>)", ...],
              "phonemeHints": ["<difficult sound>", ...],
              "correctTranslation": "<the exact sentence that was played>",
              "alternativeTranslations": ["<alt phrasing>", ...],
              "wordExplanations": [{"word": "<词>", "explanation": "<why in English>"}, ...],
              "grammarIssues": ["<category_key>", ...]
            }
            """
        } else {
            systemPrompt = """
            You are a Mandarin Chinese language tutor evaluating a student's spoken translation.

            The user message gives the English sentence the student was shown and what their Mandarin speech was recognized as.

            Evaluate on:
            1. Translation accuracy — does the Mandarin convey the correct meaning?
            2. Grammar correctness — particles, measure words, word order, aspect markers
            3. Vocabulary appropriateness for the difficulty level

            Important:
            - Speech recognition cannot detect tone errors. Always include specific tone reminders
              for 2-3 key characters in the transcript using "toneReminders",
              e.g. ["她 tā (tone 1)", "买 mǎi (tone 3)"].
            - Include pinyin hints for phonologically tricky sounds in "phonemeHints"
              (e.g. "x vs sh", "zh vs z", "ü vs u").
            - If the transcript is empty or clearly not Mandarin, score 0 and say so.
            - The user message says which of the 3 attempts this is.

            For "feedback":
            - If score ≥ 85 or no grammar issues: write one short encouraging sentence only (e.g. "Great job!").
            - If grammar mistakes are present: explain each mistake in full detail — what structure was expected, what the student used, and exactly why it is wrong. Do NOT write vague phrases like "wrong structure". Do NOT mention tone or pronunciation in this field.

            For "alternativeTranslations": list other equally natural Mandarin phrasings of the English sentence, if any exist. Return [] if only one translation is natural.

            For "wordExplanations": for 3–5 notable words/phrases in correctTranslation, explain in English why that word or structure is used (1–2 sentences each). Use complete Chinese words/phrases (词 cí), not individual characters. Include particles (了/过/着), measure words, resultative complements, and key vocabulary.

            If grammar mistakes are present, add 1-2 keys to "grammarIssues" chosen ONLY from:
              particle_usage, measure_words, word_order, aspect_markers, ba_sentence,
              resultative_complement, potential_complement, topic_comment, negation,
              comparison, question_formation, verb_complement
            Return [] when score ≥ 85, or only tone/pronunciation errors were found (not grammar).
            Pick the most specific category. Never return more than 2 keys. No other strings allowed.

            Return ONLY valid JSON in exactly this format:
            {
              "score": <integer 0-100>,
              "feedback": "<grammar-focused feedback per rules above>",
              "toneReminders": ["<character> <pinyin> (tone <N>)", ...],
              "phonemeHints": ["<difficult sound>", ...],
              "correctTranslation": "<a natural, correct Mandarin translation in Chinese characters>",
              "alternativeTranslations": ["<alt phrasing>", ...],
              "wordExplanations": [{"word": "<词>", "explanation": "<why in English>"}, ...],
              "grammarIssues": ["<category_key>", ...]
            }
            """
        }

        // Everything that changes per attempt lives here rather than in the system prompt, so
        // the prompt prefix stays byte-identical across a session and the cache can hold.
        let attemptFacts: String
        if let targetText = listeningTargetText {
            attemptFacts = """
            Sentence played: "\(targetText)"
            Recognized as: "\(transcript)"
            Attempt \(attemptNumber) of 3.

            Evaluate this attempt.
            """
        } else {
            attemptFacts = """
            English sentence shown: "\(englishSentence)"
            Recognized as: "\(transcript)"
            Attempt \(attemptNumber) of 3.

            Evaluate this attempt.
            """
        }

        let raw = try await performRequest(
            system: systemPrompt,
            messages: [["role": "user", "content": attemptFacts]],
            maxTokens: 8192,
            effort: .high,
            cacheSystemPrompt: true
        )

        return try parseEvaluationResult(raw)
    }

    // MARK: - Produce mode (grammar-point-biased follow-up questions)
    // Not an override of critiqueProduceResponse — a plain additional method, called via an
    // `as? MandarinService` downcast in AppStore, matching the existing downcast pattern used
    // for generateSentenceBatchWithPoints etc. rather than threading extra params through the
    // shared LanguageService interface.

    func critiqueProduceResponseWithPoint(
        targetLanguage: String,
        difficulty: Int,
        priorQuestion: String,
        transcript: String,
        conversationSoFar: [(question: String, transcript: String)] = [],
        context: GrammarPointSampleContext = GrammarPointSampleContext(),
        intendedMeaning: String = ""
    ) async throws -> ProduceCritiqueResult {
        let point = MandarinGrammarBank.selectPoints(count: 1, difficulty: difficulty, context: context).first

        let vocabDesc = mandarinVocabBandDescription(difficulty)
        let historyBlock = conversationSoFar.isEmpty ? "" : "\n\nConversation so far:\n" +
            conversationSoFar.map { "Q: \($0.question)\nA: \($0.transcript)" }.joined(separator: "\n")
        let grammarHint = point.map {
            "\n\nSteer the follow-up question toward this grammar pattern if it fits naturally: \($0.name) — \($0.instruction)"
        } ?? ""

        let base = Self.produceCritiqueSystemPrompt(
            languageName: "Mandarin Chinese",
            levelDescription: vocabDesc,
            categoryList: "particle_usage, measure_words, word_order, aspect_markers, ba_sentence, " +
                          "resultative_complement, potential_complement, topic_comment, negation, " +
                          "comparison, question_formation, verb_complement")

        // Mandarin-specific sharpening of step 2: the expression-level pass is only useful if it
        // names the actual Mandarin machinery (aspect markers, 前/后 direction, 的 omission,
        // measure words) rather than describing the error in generic grammar-textbook terms.
        let systemPrompt = base + """


        Mandarin specifics for the expression-by-expression pass — these are exactly the kinds of \
        choice that deserve their own entry:
        - Aspect markers: 了 (completed event / change of state), 过 (experience, no fixed time), \
        着 (ongoing state), and the bare verb. A specific past time expression usually calls for 了, \
        not 过 — say so explicitly when the student picks the wrong one.
        - Time and direction words: 前 (before / ago) vs 后 (after / later), and where the time phrase \
        sits relative to the subject. If the student wrote something that is not a real word, say what \
        each character means on its own and why the combination cannot mean what they wanted.
        - Possessives and modifiers: when 的 is required, when it is optional, and when dropping it is \
        the natural choice.
        - Measure words, and 和 / 跟 / 一起 for accompaniment.
        - Word choice between near-synonyms where the collocation matters (e.g. 朋友 vs 同学 for someone \
        from school).
        Write Mandarin in simplified characters. Do not add pinyin inside any field.
        """

        let userMessage = Self.produceCritiqueUserMessage(
            languageName: "Mandarin", priorQuestion: priorQuestion, transcript: transcript,
            historyBlock: historyBlock, grammarHint: grammarHint, intendedMeaning: intendedMeaning)

        let raw = try await performRequest(
            system: systemPrompt,
            messages: [["role": "user", "content": userMessage]],
            jsonSchema: Self.produceCritiqueSchema(languageName: "Mandarin Chinese"),
            maxTokens: 8192,
            effort: .high,
            cacheSystemPrompt: true
        )
        return try parseProduceCritiqueResult(raw, grammarPointID: point?.id,
                                              targetLanguage: targetLanguage)
    }

    // MARK: - CJK Validation

    /// Returns true if `text` contains any CJK Unified Ideograph (U+4E00–U+9FFF),
    /// CJK Extension A/B, or CJK Compatibility Ideographs.
    private func containsCJK(_ text: String) -> Bool {
        LanguageService.containsNonLatinScript(text)
    }

    // MARK: - Mandarin vocab-band description (vocabulary/length only — grammar comes from MandarinGrammarBank)

    private func mandarinVocabBandDescription(_ difficulty: Int) -> String {
        switch difficulty {
        case 1, 2:
            return "Use only the most basic HSK 1 vocabulary and very short sentences (roughly 4-8 characters when translated). Avoid abstract or descriptive words."
        case 3, 4:
            return "Use everyday HSK 2-3 vocabulary. Sentences may be slightly longer (roughly 6-12 characters) but should stay concrete and simple."
        case 5, 6:
            return "Use HSK 3-4 vocabulary, including some descriptive and abstract words. Sentences can be moderately complex (roughly 10-16 characters)."
        case 7, 8:
            return "Use HSK 4-5 vocabulary with more nuanced word choices. Sentences can be longer and combine multiple clauses where natural."
        case 9, 10:
            return "Use HSK 5-6 vocabulary, including idiomatic and sophisticated phrasing appropriate for an advanced learner. Sentences may be long and stylistically natural."
        default:
            return "Use natural, everyday vocabulary appropriate for an intermediate learner."
        }
    }
}
