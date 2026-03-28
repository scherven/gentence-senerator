import Foundation

// MARK: - French Service
// Specialised prompts for French practice.
// Each difficulty level targets a distinct grammar structure in the French learning progression.

final class FrenchService: OpenAIService {

    // MARK: - Generate English sentence

    override func generateSentence(
        difficulty: Int,
        targetLanguage: String,
        excludingTexts: [String] = [],
        grammarFocusAreas: [String] = []
    ) async throws -> String {
        let desc = frenchDifficultyDescription(difficulty)
        let exclusionHint = excludingTexts.isEmpty ? "" :
            " Do NOT generate any sentence similar to: \(excludingTexts.prefix(10).joined(separator: "; "))."
        let grammarInstruction = grammarFocusAreas.isEmpty ? "" :
            " Prioritize sentence structures that require one of these grammar patterns: \(grammarFocusAreas.joined(separator: ", "))."

        let systemPrompt = """
        You are a French language learning sentence generator.
        Generate a single natural English sentence designed for French translation practice at difficulty \(difficulty)/10.
        \(desc)\(grammarInstruction)\(exclusionHint)

        Vary these elements to prevent repetitive patterns:
        - Sentence type: mix declarative statements, questions (inversion and est-ce que), negations (ne...pas), and imperatives.
        - Verbs: avoid over-using 'être' and 'avoir' — draw from a wide range of everyday verbs.
        - Topics: rotate across daily routines, travel, food, family, hobbies, work, school, health, shopping, weather.

        Return ONLY the English sentence — no French translation, no explanation, no extra punctuation.
        """

        let text = try await performRequest(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Generate one English sentence for French translation practice at difficulty \(difficulty)/10."]
            ],
            temperature: 0.9
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else { throw OpenAIError.emptyResponse }
        return trimmed
    }

    // MARK: - Generate listening sentence

    override func generateListeningSentence(
        difficulty: Int,
        targetLanguage: String,
        excludingTexts: [String] = []
    ) async throws -> (targetText: String, englishMeaning: String) {
        let desc = frenchDifficultyDescription(difficulty)
        let exclusionHint = excludingTexts.isEmpty ? "" :
            " Do NOT generate a sentence similar to: \(excludingTexts.prefix(10).joined(separator: "; "))."

        let systemPrompt = """
        You are a French language learning content generator.
        Generate a single natural French sentence suitable for listening comprehension practice at difficulty \(difficulty)/10.
        \(desc)\(exclusionHint)

        Use standard spoken French (not overly formal or literary). Include correct accents and punctuation.
        Also provide the English meaning.

        Return ONLY valid JSON in exactly this format:
        {
          "targetText": "<the French sentence>",
          "englishMeaning": "<the English translation>"
        }
        """

        let raw = try await performRequest(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Generate one French listening sentence at difficulty \(difficulty)/10."]
            ],
            temperature: 0.9,
            responseFormat: "json_object"
        )

        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targetText = json["targetText"] as? String,
              let englishMeaning = json["englishMeaning"] as? String,
              !targetText.isEmpty, !englishMeaning.isEmpty else {
            throw OpenAIError.decodingFailed("Could not parse French listening sentence response")
        }

        return (targetText.trimmingCharacters(in: .whitespacesAndNewlines),
                englishMeaning.trimmingCharacters(in: .whitespacesAndNewlines))
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
            You are a French language tutor evaluating a student's listening comprehension attempt.

            The student heard this French sentence (played via TTS): "\(targetText)"
            Their response was recognized as: "\(transcript)"

            Evaluate how accurately the student reproduced the sentence:
            1. Key words and overall meaning captured
            2. Grammar accuracy (gender agreement, verb tense, pronoun placement, negation)
            3. Pronunciation quality

            Important:
            - Include hints for challenging French sounds in "phonemeHints"
              (e.g. "nasal vowels (an/en/in/on/un)", "silent letters", "liaison", "u vs ou", "r-sound").
            - "toneReminders" should be [] — French has no lexical tones.
            - If the transcript is empty or clearly not French, score 0 and say so.
            - Be encouraging but specific. This is attempt \(attemptNumber) of 3.
            - Set "correctTranslation" to the original French sentence that was played.

            If grammar mistakes are present, add 1-2 keys to "grammarIssues" chosen ONLY from:
              gender_agreement, verb_conjugation, tense_choice, negation_structure,
              pronoun_placement, partitive_article, subjunctive_mood,
              past_participle_agreement, relative_clause, preposition_usage
            Return [] when score ≥ 85, or only pronunciation errors were found.
            Never return more than 2 keys. No other strings allowed.

            Return ONLY valid JSON in exactly this format:
            {
              "score": <integer 0-100>,
              "feedback": "<2-3 sentences of specific, encouraging feedback in English>",
              "toneReminders": [],
              "phonemeHints": ["<difficult sound>", ...],
              "correctTranslation": "\(targetText)",
              "grammarIssues": ["<category_key>", ...]
            }
            """
        } else {
            systemPrompt = """
            You are a French language tutor evaluating a student's spoken translation.

            The student was shown this English sentence: "\(englishSentence)"
            Their French speech was recognized as: "\(transcript)"

            Evaluate on:
            1. Translation accuracy — does the French convey the correct meaning?
            2. Grammar correctness — noun gender, adjective agreement, verb tense and conjugation,
               negation (ne...pas), pronoun placement (direct/indirect objects before verb),
               partitive articles (du/de la/des), and subjunctive when required.
            3. Vocabulary appropriateness for the difficulty level.

            Important:
            - Include hints for challenging French sounds in "phonemeHints"
              (e.g. "nasal vowels", "silent final consonants", "liaison rules", "u vs ou", "guttural r").
            - "toneReminders" should be [] — French has no lexical tones.
            - If the transcript is empty or clearly not French, score 0 and say so.
            - Be encouraging but specific. Mention what was right and what needs work.
            - This is attempt \(attemptNumber) of 3.

            If grammar mistakes are present, add 1-2 keys to "grammarIssues" chosen ONLY from:
              gender_agreement, verb_conjugation, tense_choice, negation_structure,
              pronoun_placement, partitive_article, subjunctive_mood,
              past_participle_agreement, relative_clause, preposition_usage
            Return [] when score ≥ 85. Pick the most specific category.
            Never return more than 2 keys. No other strings allowed.

            Return ONLY valid JSON in exactly this format:
            {
              "score": <integer 0-100>,
              "feedback": "<2-3 sentences of specific, encouraging feedback in English>",
              "toneReminders": [],
              "phonemeHints": ["<difficult sound>", ...],
              "correctTranslation": "<a natural, correct French translation of the English sentence>",
              "grammarIssues": ["<category_key>", ...]
            }
            """
        }

        let raw = try await performRequest(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Please evaluate the student's attempt."]
            ],
            temperature: 0.3,
            responseFormat: "json_object"
        )

        return try parseEvaluationResult(raw)
    }

    // MARK: - French difficulty descriptions (10 distinct levels)

    private func frenchDifficultyDescription(_ difficulty: Int) -> String {
        switch difficulty {
        case 1:
            return """
            Difficulty 1 — Absolute beginner. Simple SVO sentences in the present tense with \
            regular -er verbs only (parler, manger, regarder, travailler, habiter, aimer). \
            No negation, no questions, no gender agreement beyond basic pronoun use. \
            Max 5–7 words in the French translation.
            """
        case 2:
            return """
            Difficulty 2 — Introduce negation (ne...pas) alongside definite and indefinite articles \
            with both genders (le/la/les/un/une/des). The sentence must include at least one \
            masculine and one feminine noun so that article gender is practised. Present tense only.
            """
        case 3:
            return """
            Difficulty 3 — Require an irregular verb in the present tense: être, avoir, aller, \
            faire, pouvoir, vouloir, or venir. The irregular conjugation must be central to the \
            sentence's meaning — not just background. Include at least one adjective that must agree \
            in gender/number with its noun.
            """
        case 4:
            return """
            Difficulty 4 — Require passé composé with avoir for a completed past action. \
            Choose regular -er/-ir/-re verbs whose past participle takes avoir as auxiliary. \
            Include a time marker (hier, déjà, ce matin, la semaine dernière) to make the \
            completed-action meaning clear. Do NOT use être-auxiliary verbs at this level.
            """
        case 5:
            return """
            Difficulty 5 — Require passé composé with être as the auxiliary verb. \
            The verb must be one of the classic être-group (aller/venir/partir/arriver/entrer/ \
            sortir/naître/mourir/rester/tomber/monter/descendre/retourner/passer). \
            The past participle must agree with the subject in gender and number.
            """
        case 6:
            return """
            Difficulty 6 — Require the imparfait tense for a habitual past action, background \
            description, or an ongoing action interrupted by something else. If possible, contrast \
            imparfait with passé composé in the same sentence \
            (e.g. 'I was reading when she called'). Avoid using imparfait for completed events.
            """
        case 7:
            return """
            Difficulty 7 — Require the futur simple tense using the inflected future form \
            (verb stem + future endings: -ai/-as/-a/-ons/-ez/-ont). Do NOT use the near-future \
            'aller + infinitif'. The sentence must describe a future event or prediction. \
            Include an irregular future stem if possible (avoir→aur-, être→ser-, aller→ir-).
            """
        case 8:
            return """
            Difficulty 8 — Require a direct or indirect object pronoun (le/la/les/lui/leur/y/en) \
            placed correctly before the conjugated verb (or before the infinitive in a modal construction). \
            The pronoun must replace a clearly identifiable noun. This tests correct pronoun placement \
            and the le/lui distinction for direct vs indirect objects.
            """
        case 9:
            return """
            Difficulty 9 — Require the subjunctive mood (présent du subjonctif) after a trigger \
            verb or expression of volition, emotion, or necessity: vouloir que, il faut que, \
            avoir peur que, être content(e) que, souhaiter que, or regretter que. \
            The subordinate que-clause must use a different subject from the main clause.
            """
        case 10:
            return """
            Difficulty 10 — Require the subjunctive after a conjunction of concession, purpose, \
            or condition: bien que, à moins que, pour que, avant que, quoique, or à condition que. \
            Alternatively, require a complex relative clause with 'dont' or 'où', or use the \
            conditionnel passé for a hypothetical past event (Si j'avais su, j'aurais…). \
            Advanced vocabulary and sophisticated syntax expected.
            """
        default:
            return "Generate a natural everyday English sentence for French translation practice."
        }
    }
}
