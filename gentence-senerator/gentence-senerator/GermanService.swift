import Foundation

// MARK: - German Service
// Specialised prompts for German practice.
// Each difficulty level targets a distinct grammar structure in the German learning progression.

final class GermanService: OpenAIService {

    // MARK: - Generate English sentence

    override func generateSentence(
        difficulty: Int,
        targetLanguage: String,
        excludingTexts: [String] = [],
        grammarFocusAreas: [String] = []
    ) async throws -> String {
        let desc = germanDifficultyDescription(difficulty)
        let exclusionHint = excludingTexts.isEmpty ? "" :
            " Do NOT generate any sentence similar to: \(excludingTexts.prefix(10).joined(separator: "; "))."
        let grammarInstruction = grammarFocusAreas.isEmpty ? "" :
            " Prioritize sentence structures that require one of these grammar patterns: \(grammarFocusAreas.joined(separator: ", "))."

        let systemPrompt = """
        You are a German language learning sentence generator.
        Generate a single natural English sentence designed for German translation practice at difficulty \(difficulty)/10.
        \(desc)\(grammarInstruction)\(exclusionHint)

        Vary these elements to prevent repetitive patterns:
        - Sentence type: mix declarative statements, questions (W-Fragen and Ja/Nein-Fragen), negations, and commands.
        - Verbs: avoid over-using 'sein' and 'haben' — draw from a wide range of everyday verbs.
        - Topics: rotate across daily routines, travel, work, family, food, hobbies, health, school, shopping, weather.

        Return ONLY the English sentence — no German translation, no explanation, no extra punctuation.
        """

        let text = try await performRequest(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Generate one English sentence for German translation practice at difficulty \(difficulty)/10."]
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
        let desc = germanDifficultyDescription(difficulty)
        let exclusionHint = excludingTexts.isEmpty ? "" :
            " Do NOT generate a sentence similar to: \(excludingTexts.prefix(10).joined(separator: "; "))."

        let systemPrompt = """
        You are a German language learning content generator.
        Generate a single natural German sentence suitable for listening comprehension practice at difficulty \(difficulty)/10.
        \(desc)\(exclusionHint)

        Use standard spoken German (no dialect, no overly formal Schriftdeutsch).
        Also provide the English meaning.

        Return ONLY valid JSON in exactly this format:
        {
          "targetText": "<the German sentence>",
          "englishMeaning": "<the English translation>"
        }
        """

        let raw = try await performRequest(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Generate one German listening sentence at difficulty \(difficulty)/10."]
            ],
            temperature: 0.9,
            responseFormat: "json_object"
        )

        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targetText = json["targetText"] as? String,
              let englishMeaning = json["englishMeaning"] as? String,
              !targetText.isEmpty, !englishMeaning.isEmpty else {
            throw OpenAIError.decodingFailed("Could not parse German listening sentence response")
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
            You are a German language tutor evaluating a student's listening comprehension attempt.

            The student heard this German sentence (played via TTS): "\(targetText)"
            Their response was recognized as: "\(transcript)"

            Evaluate how accurately the student reproduced the sentence:
            1. Key words and overall meaning captured
            2. Grammar accuracy (articles, case, verb position, word order)
            3. Pronunciation quality

            Important:
            - Include hints for challenging German sounds in "phonemeHints"
              (e.g. "ü vs u", "ch (ich-Laut) vs ch (ach-Laut)", "ß vs ss", "long vs short vowels").
            - "toneReminders" should be [] for German (German has no lexical tones).
            - If the transcript is empty or clearly not German, score 0 and say so.
            - Be encouraging but specific. This is attempt \(attemptNumber) of 3.
            - Set "correctTranslation" to the original German sentence.

            If grammar mistakes are present, add 1-2 keys to "grammarIssues" chosen ONLY from:
              article_gender, case_usage, word_order, verb_position, separable_verb,
              adjective_ending, modal_verb, subordinate_clause, past_tense, reflexive_verb
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
            You are a German language tutor evaluating a student's spoken translation.

            The student was shown this English sentence: "\(englishSentence)"
            Their German speech was recognized as: "\(transcript)"

            Evaluate on:
            1. Translation accuracy — does the German convey the correct meaning?
            2. Grammar correctness — article gender (der/die/das), case (nominative/accusative/dative/genitive),
               verb position (V2 in main clause, verb-final in subordinate clause), separable verbs,
               adjective endings, and tense agreement.
            3. Vocabulary appropriateness for the difficulty level.

            Important:
            - Include hints for challenging German sounds in "phonemeHints"
              (e.g. "ü vs u", "ch (ich-Laut)", "r-sound", "umlauts").
            - "toneReminders" should be [] — German has no lexical tones.
            - If the transcript is empty or clearly not German, score 0 and say so.
            - Be encouraging but specific. Mention what was right and what needs work.
            - This is attempt \(attemptNumber) of 3.

            If grammar mistakes are present, add 1-2 keys to "grammarIssues" chosen ONLY from:
              article_gender, case_usage, word_order, verb_position, separable_verb,
              adjective_ending, modal_verb, subordinate_clause, past_tense, reflexive_verb
            Return [] when score ≥ 85. Pick the most specific category.
            Never return more than 2 keys. No other strings allowed.

            Return ONLY valid JSON in exactly this format:
            {
              "score": <integer 0-100>,
              "feedback": "<2-3 sentences of specific, encouraging feedback in English>",
              "toneReminders": [],
              "phonemeHints": ["<difficult sound>", ...],
              "correctTranslation": "<a natural, correct German translation of the English sentence>",
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

    // MARK: - German difficulty descriptions (10 distinct levels)

    private func germanDifficultyDescription(_ difficulty: Int) -> String {
        switch difficulty {
        case 1:
            return """
            Difficulty 1 — Absolute beginner. Simple SVO sentences in the present tense with \
            common regular -en verbs (spielen, wohnen, trinken, essen, kaufen). \
            No articles required — use only personal pronouns (ich/du/er/sie/wir). \
            No negation, no questions. Max 5–7 words in the German translation.
            """
        case 2:
            return """
            Difficulty 2 — Introduce definite and indefinite articles (der/die/das/ein/eine) \
            with common nouns in nominative case only. Add simple negation with 'nicht' or 'kein/keine'. \
            Use present tense only. Do NOT yet require accusative or dative case forms.
            """
        case 3:
            return """
            Difficulty 3 — Require a modal verb (können/müssen/wollen/dürfen/sollen/mögen) \
            combined with an infinitive. The modal + infinitive pairing must be the structural \
            core of the sentence. Keep all nouns in nominative. Introduce adverbs like 'oft', \
            'immer', 'nie', 'schon', 'noch'.
            """
        case 4:
            return """
            Difficulty 4 — Require accusative case with a clear direct object. The sentence must \
            include a masculine noun in accusative position (den/einen) to make the case marking \
            visible and meaningful. Use a transitive verb (sehen/kaufen/lesen/nehmen/brauchen).
            """
        case 5:
            return """
            Difficulty 5 — Require dative case through a common dative preposition: \
            mit, nach, aus, von, bei, seit, zu, or gegenüber. The preposition must be \
            essential to the meaning. Mix genders (dem/der/einem/einer). \
            Do NOT use two-way prepositions (in/auf/an) at this level.
            """
        case 6:
            return """
            Difficulty 6 — Require a separable verb (anrufen/aufstehen/mitnehmen/einkaufen/ \
            zurückkommen/anfangen). The prefix must be split and placed at the end of the main clause. \
            The separability must be structurally necessary — not just decorative.
            """
        case 7:
            return """
            Difficulty 7 — Require Perfekt tense (auxiliary haben or sein + past participle). \
            Deliberately mix verbs that take 'haben' with those that take 'sein' (motion/state-change verbs). \
            Include a time expression (gestern, letzte Woche, schon, noch nie). \
            Do NOT use Präteritum — only Perfekt.
            """
        case 8:
            return """
            Difficulty 8 — Require a subordinate clause with a subordinating conjunction that \
            forces verb-final word order in the sub-clause: weil, dass, wenn, obwohl, während, \
            bevor, nachdem, damit, or seitdem. The conjunction must be semantically meaningful \
            (causal, temporal, or concessive), not just filler.
            """
        case 9:
            return """
            Difficulty 9 — Require Konjunktiv II to express a hypothetical, unreal condition, \
            polite request, or wish. Use 'würde + infinitive' OR the special KII forms of \
            sein/haben/können/müssen/dürfen. Example structures: 'If I were you…', \
            'I would like to…', 'Could you please…', 'If only I had…'.
            """
        case 10:
            return """
            Difficulty 10 — Require one of: (a) passive voice (werden + past participle) in a \
            semantically meaningful context; (b) Konjunktiv I for reported speech \
            (Er sagte, er sei…/habe…); or (c) an extended attributive phrase (Erweitertes Attribut) \
            — a long adjective phrase before a noun. Advanced vocabulary and formal register expected. \
            Challenge an upper-intermediate to advanced learner.
            """
        default:
            return "Generate a natural everyday English sentence for German translation practice."
        }
    }
}
