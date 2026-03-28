import Foundation

// MARK: - Mandarin Service
// Specialised prompts for Mandarin Chinese practice.
// Each difficulty level targets a distinct grammar structure or vocabulary tier.

final class MandarinService: OpenAIService {

    // MARK: - Generate English sentence

    override func generateSentence(
        difficulty: Int,
        targetLanguage: String,
        excludingTexts: [String] = [],
        grammarFocusAreas: [String] = []
    ) async throws -> String {
        let desc = mandarinDifficultyDescription(difficulty)
        let exclusionHint = excludingTexts.isEmpty ? "" :
            " Do NOT generate any sentence similar to: \(excludingTexts.prefix(10).joined(separator: "; "))."
        let grammarInstruction = grammarFocusAreas.isEmpty ? "" :
            " Prioritize sentence structures that require one of these grammar patterns: \(grammarFocusAreas.joined(separator: ", "))."

        let systemPrompt = """
        You are a Mandarin Chinese language learning sentence generator.
        Generate a single natural English sentence designed for Mandarin translation practice at difficulty \(difficulty)/10.
        \(desc)\(grammarInstruction)\(exclusionHint)

        Actively vary these elements to prevent repetitive patterns:
        - Sentence type: mix SVO statements, 不/没 negations, 吗 yes-no questions, imperatives, and topic-comment frames.
        - Verbs: do NOT default to 是/有/去/喜欢 — draw from a wide range of everyday actions.
        - Topics: rotate across food, travel, work, family, weather, shopping, hobbies, health, technology, school.

        Return ONLY the English sentence — no translation, no explanation, no extra punctuation.
        """

        let text = try await performRequest(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Generate one English sentence for Mandarin translation practice at difficulty \(difficulty)/10."]
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
        let desc = mandarinDifficultyDescription(difficulty)
        let exclusionHint = excludingTexts.isEmpty ? "" :
            " Do NOT generate a sentence similar to: \(excludingTexts.prefix(10).joined(separator: "; "))."

        let systemPrompt = """
        You are a Mandarin Chinese language learning content generator.
        Generate a single natural Mandarin sentence suitable for listening comprehension practice at difficulty \(difficulty)/10.
        \(desc)\(exclusionHint)

        The sentence should be natural spoken Mandarin (not literary). Include characters only — no pinyin in the targetText field.
        Also provide the English meaning.

        Return ONLY valid JSON in exactly this format:
        {
          "targetText": "<the Mandarin sentence in Chinese characters>",
          "englishMeaning": "<the English translation>"
        }
        """

        let raw = try await performRequest(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Generate one Mandarin listening sentence at difficulty \(difficulty)/10."]
            ],
            temperature: 0.9,
            responseFormat: "json_object"
        )

        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targetText = json["targetText"] as? String,
              let englishMeaning = json["englishMeaning"] as? String,
              !targetText.isEmpty, !englishMeaning.isEmpty else {
            throw OpenAIError.decodingFailed("Could not parse Mandarin listening sentence response")
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
            You are a Mandarin Chinese language tutor evaluating a student's listening comprehension attempt.

            The student heard this Mandarin sentence (played via TTS): "\(targetText)"
            Their response was recognized as: "\(transcript)"

            Evaluate how accurately the student reproduced the sentence:
            1. Key words and overall meaning captured
            2. Grammar and vocabulary accuracy

            Important:
            - Always include specific tone reminders for 2-3 key characters using the "toneReminders" field,
              e.g. ["妈 mā (tone 1)", "买 mǎi (tone 3)"].
            - Include pinyin pronunciation hints for any phonologically tricky sounds in "phonemeHints".
            - If the transcript is empty or clearly not Mandarin, score 0 and say so.
            - Be encouraging but specific. This is attempt \(attemptNumber) of 3.
            - Set "correctTranslation" to the original Mandarin sentence that was played.

            If grammar mistakes are present, add 1-2 keys to "grammarIssues" chosen ONLY from:
              particle_usage, measure_words, word_order, aspect_markers, ba_sentence,
              resultative_complement, potential_complement, topic_comment, negation,
              comparison, question_formation, verb_complement
            Return [] when score ≥ 85, or only tone/pronunciation errors were found.
            Never return more than 2 keys. No other strings allowed.

            Return ONLY valid JSON in exactly this format:
            {
              "score": <integer 0-100>,
              "feedback": "<2-3 sentences of specific, encouraging feedback in English>",
              "toneReminders": ["<character> <pinyin> (tone <N>)", ...],
              "phonemeHints": ["<difficult sound>", ...],
              "correctTranslation": "\(targetText)",
              "grammarIssues": ["<category_key>", ...]
            }
            """
        } else {
            systemPrompt = """
            You are a Mandarin Chinese language tutor evaluating a student's spoken translation.

            The student was shown this English sentence: "\(englishSentence)"
            Their Mandarin speech was recognized as: "\(transcript)"

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
            - Be encouraging but specific. Mention what was right and what needs work.
            - This is attempt \(attemptNumber) of 3.

            If grammar mistakes are present, add 1-2 keys to "grammarIssues" chosen ONLY from:
              particle_usage, measure_words, word_order, aspect_markers, ba_sentence,
              resultative_complement, potential_complement, topic_comment, negation,
              comparison, question_formation, verb_complement
            Return [] when score ≥ 85, or only tone/pronunciation errors were found (not grammar).
            Pick the most specific category. Never return more than 2 keys. No other strings allowed.

            Return ONLY valid JSON in exactly this format:
            {
              "score": <integer 0-100>,
              "feedback": "<2-3 sentences of specific, encouraging feedback in English>",
              "toneReminders": ["<character> <pinyin> (tone <N>)", ...],
              "phonemeHints": ["<difficult sound>", ...],
              "correctTranslation": "<a natural, correct Mandarin translation in Chinese characters>",
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

    // MARK: - Mandarin difficulty descriptions (10 distinct levels)

    private func mandarinDifficultyDescription(_ difficulty: Int) -> String {
        switch difficulty {
        case 1:
            return """
            Difficulty 1 — HSK 1 core only. Use simple subject-verb-object sentences with the most \
            basic everyday verbs (eat 吃, drink 喝, see 看, buy 买, like 喜欢). \
            No negation, no questions, no measure words, no particles. \
            The Mandarin translation should be 4–6 characters with zero grammar structures.
            """
        case 2:
            return """
            Difficulty 2 — Introduce 不 negation OR a 吗 yes-no question (not both). \
            Add simple 1–2 word time phrases (every day 每天, right now 现在, today 今天). \
            Still no measure words or aspect particles. Mix affirmative statements with \
            one negation or one question per session.
            """
        case 3:
            return """
            Difficulty 3 — Require a time expression (今天/昨天/明天/这周) alongside a concrete action. \
            Sentences should alternate between affirmative statements, 不 negations, and 吗 questions. \
            Introduce 也 (also) or 都 (all/both). No measure words or aspect particles yet.
            """
        case 4:
            return """
            Difficulty 4 — Require at least one measure word + noun (一本书/两杯水/三个人/一件事). \
            The quantity and object must be central to the sentence. \
            Mix affirmative and negative forms. No aspect particles yet.
            """
        case 5:
            return """
            Difficulty 5 — Require the completion particle 了 (action completed or change of state). \
            The Mandarin answer must naturally use 了 — e.g. 'I already ate', 'She has left', \
            'It became cold'. Do not target 过 or 着 here; focus entirely on 了.
            """
        case 6:
            return """
            Difficulty 6 — Require the experiential particle 过 ('have ever done') OR the \
            durative/progressive particle 着. Choose only ONE per sentence. \
            E.g. 'Have you ever been to Shanghai?' (过) or 'She is wearing a red coat' (着). \
            Avoid 了 at this level; the new particle is the grammatical focus.
            """
        case 7:
            return """
            Difficulty 7 — Require a resultative verb complement (verb + result morpheme): \
            写完 (finish writing), 听懂 (understand by listening), 做好 (do well/finish), \
            说清楚 (explain clearly), 找到 (find successfully). \
            The complement must be essential to the meaning of the sentence.
            """
        case 8:
            return """
            Difficulty 8 — Require a potential complement with 得 or 不 to express possibility \
            or impossibility: 听得懂/听不懂, 做得完/做不完, 吃得下/吃不下, 看得见/看不见. \
            The core meaning must hinge on whether the action can or cannot be accomplished.
            """
        case 9:
            return """
            Difficulty 9 — Require a 把-sentence (disposal construction) where the object is \
            specifically moved, changed, placed, or disposed of by the action: \
            把书放在桌上, 把作业交给老师, 把房间打扫干净. \
            The 把 structure must be the most natural way to express the idea in Mandarin.
            """
        case 10:
            return """
            Difficulty 10 — Require one of: (a) a complex topic-comment structure with an \
            embedded relative clause; (b) a chengyu (4-character idiom) used naturally in context; \
            (c) a sophisticated conditional (如果...就.../只要...才...); \
            or (d) a formal/literary expression that would appear in written Chinese. \
            Advanced vocabulary expected. Challenge a high-intermediate to advanced learner.
            """
        default:
            return "Generate a natural everyday English sentence for Mandarin translation practice."
        }
    }
}
