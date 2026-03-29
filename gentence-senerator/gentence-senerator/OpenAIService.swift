import Foundation

// MARK: - Errors

enum OpenAIError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case badStatusCode(Int, String)
    case decodingFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .badStatusCode(let code, let body): return "API error \(code): \(body)"
        case .decodingFailed(let msg): return "Decoding failed: \(msg)"
        case .emptyResponse: return "Empty response from API"
        }
    }
}

// MARK: - Base OpenAI Service
// Provides generic prompts suitable for languages without a specialised subclass.
// Subclass and override generateSentence / generateListeningSentence / evaluateAttempt
// to supply language-tailored prompts (see MandarinService, GermanService, FrenchService).

class OpenAIService {

    private let apiKey: String
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    init(apiKey: String = Key.key) {
        self.apiKey = apiKey
    }

    // MARK: - Generate English sentence (generic fallback)

    func generateSentence(
        difficulty: Int,
        targetLanguage: String,
        excludingTexts: [String] = [],
        sessionTexts: [String] = [],
        grammarFocusAreas: [String] = []
    ) async throws -> String {
        let desc = difficultyDescription(difficulty, for: targetLanguage)
        let exclusionHint = excludingTexts.isEmpty ? "" :
            " Do NOT repeat any of these previously seen sentences: \(excludingTexts.prefix(10).joined(separator: "; "))."
        let sessionHint = sessionTexts.isEmpty ? "" :
            " This session has already used these sentences — choose a DIFFERENT sentence structure and topic: \(sessionTexts.joined(separator: "; "))."
        let grammarInstruction = grammarFocusAreas.isEmpty ? "" :
            " Prioritize sentence structures that require one of these grammar patterns: \(grammarFocusAreas.joined(separator: ", "))."

        let systemPrompt = """
        You are a language learning sentence generator. Generate a single natural English sentence \
        suitable for \(targetLanguage) translation practice at difficulty \(difficulty)/10. \
        \(desc)\(grammarInstruction)\(exclusionHint)\(sessionHint)
        Vary the sentence type (statement, question, negation, imperative) and topic across the session.
        Return ONLY the English sentence text — no translation, no explanation, no punctuation beyond the sentence itself.
        """

        let text = try await performRequest(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Generate one English sentence for \(targetLanguage) translation practice at difficulty \(difficulty)/10."]
            ],
            temperature: 0.9
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else { throw OpenAIError.emptyResponse }
        return trimmed
    }

    // MARK: - Generate sentence batch (generic fallback)

    func generateSentenceBatch(
        count: Int,
        difficulty: Int,
        targetLanguage: String,
        excludingTexts: [String] = [],
        grammarFocusAreas: [String] = []
    ) async throws -> [String] {
        let desc = difficultyDescription(difficulty, for: targetLanguage)
        let exclusionHint = excludingTexts.isEmpty ? "" :
            " Do NOT repeat any of these previously seen sentences: \(excludingTexts.prefix(10).joined(separator: "; "))."
        let grammarInstruction = grammarFocusAreas.isEmpty ? "" :
            " Prioritize structures that require one of these grammar patterns: \(grammarFocusAreas.joined(separator: ", "))."

        let structureList = (1...count).map { i -> String in
            switch i {
            case 1: return "Sentence \(i): affirmative/positive statement"
            case 2: return "Sentence \(i): negation"
            case 3: return "Sentence \(i): question (yes/no or wh-)"
            case 4: return "Sentence \(i): imperative or polite request"
            default: return "Sentence \(i): conditional or compound sentence"
            }
        }.joined(separator: "\n")

        let systemPrompt = """
        You are a language learning sentence generator.
        Generate exactly \(count) English sentences for \(targetLanguage) translation practice at difficulty \(difficulty)/10.
        \(desc)\(grammarInstruction)\(exclusionHint)

        Each sentence MUST use a DIFFERENT grammatical structure — assign one per sentence:
        \(structureList)

        Each sentence MUST cover a DIFFERENT topic (e.g. food, travel, work, family, weather, hobbies, health, technology, school, shopping).
        Vary verbs widely — do not reuse the same verb across sentences.

        Return ONLY valid JSON in exactly this format:
        {"sentences": ["<sentence 1>", "<sentence 2>", ..., "<sentence \(count)>"]}
        """

        let raw = try await performRequest(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Generate \(count) English sentences for \(targetLanguage) practice at difficulty \(difficulty)/10."]
            ],
            temperature: 0.9,
            responseFormat: "json_object",
            maxTokens: 600
        )

        return try parseSentenceBatch(raw, expected: count)
    }

    // MARK: - Generate listening sentence batch (generic fallback)

    func generateListeningSentenceBatch(
        count: Int,
        difficulty: Int,
        targetLanguage: String,
        excludingTexts: [String] = []
    ) async throws -> [(targetText: String, englishMeaning: String)] {
        let desc = difficultyDescription(difficulty, for: targetLanguage)
        let exclusionHint = excludingTexts.isEmpty ? "" :
            " Do NOT repeat any sentence similar to: \(excludingTexts.prefix(10).joined(separator: "; "))."

        let structureList = (1...count).map { i -> String in
            switch i {
            case 1: return "Sentence \(i): affirmative/positive statement"
            case 2: return "Sentence \(i): negation"
            case 3: return "Sentence \(i): question"
            case 4: return "Sentence \(i): imperative or request"
            default: return "Sentence \(i): compound or conditional"
            }
        }.joined(separator: "\n")

        let systemPrompt = """
        You are a language learning content generator.
        Generate exactly \(count) natural \(targetLanguage) sentences for listening comprehension practice at difficulty \(difficulty)/10.
        \(desc)\(exclusionHint)

        Each sentence MUST use a DIFFERENT grammatical structure:
        \(structureList)

        Each sentence MUST cover a DIFFERENT topic.

        Return ONLY valid JSON in exactly this format:
        {
          "sentences": [
            {"targetText": "<\(targetLanguage) sentence>", "englishMeaning": "<English translation>"},
            ...
          ]
        }
        """

        let raw = try await performRequest(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Generate \(count) \(targetLanguage) listening sentences at difficulty \(difficulty)/10."]
            ],
            temperature: 0.9,
            responseFormat: "json_object",
            maxTokens: 800
        )

        return try parseListeningSentenceBatch(raw)
    }

    // MARK: - Generate listening sentence (generic fallback)

    func generateListeningSentence(
        difficulty: Int,
        targetLanguage: String,
        excludingTexts: [String] = []
    ) async throws -> (targetText: String, englishMeaning: String) {
        let desc = difficultyDescription(difficulty, for: targetLanguage)
        let exclusionHint = excludingTexts.isEmpty ? "" :
            " Do NOT generate a sentence similar to: \(excludingTexts.prefix(10).joined(separator: "; "))."

        let systemPrompt = """
        You are a language learning content generator. Generate a single natural \(targetLanguage) sentence \
        suitable for listening comprehension practice at difficulty \(difficulty)/10. \
        \(desc)\(exclusionHint)
        Also provide the English meaning of the sentence.
        Return ONLY valid JSON in exactly this format:
        {
          "targetText": "<the \(targetLanguage) sentence>",
          "englishMeaning": "<the English translation of the sentence>"
        }
        """

        let raw = try await performRequest(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Generate one \(targetLanguage) listening sentence at difficulty \(difficulty)/10."]
            ],
            temperature: 0.9,
            responseFormat: "json_object"
        )

        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targetText = json["targetText"] as? String,
              let englishMeaning = json["englishMeaning"] as? String,
              !targetText.isEmpty, !englishMeaning.isEmpty else {
            throw OpenAIError.decodingFailed("Could not parse listening sentence response")
        }

        return (targetText.trimmingCharacters(in: .whitespacesAndNewlines),
                englishMeaning.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Evaluate attempt (generic fallback)

    func evaluateAttempt(
        englishSentence: String,
        transcript: String,
        language: String,
        attemptNumber: Int,
        listeningTargetText: String? = nil
    ) async throws -> SentenceEvaluationResult {
        let systemPrompt: String

        if let targetText = listeningTargetText {
            systemPrompt = """
            You are a \(language) language tutor evaluating a student's listening comprehension attempt.

            The student heard this \(language) sentence (played via text-to-speech): "\(targetText)"
            Their response was recognized as: "\(transcript)"

            Evaluate how accurately the student reproduced the sentence they heard:
            1. Did they capture the key words and meaning?
            2. Grammar and vocabulary accuracy of their reproduction
            3. Pronunciation quality

            Notes:
            - If the transcript is empty or clearly not \(language), score 0 and say so.
            - This is attempt \(attemptNumber) of 3.
            - Set "correctTranslation" to the original \(language) sentence that was played.

            For "feedback":
            - If score ≥ 85 or no grammar issues: write one short encouraging sentence only (e.g. "Great job!").
            - If grammar mistakes are present: explain each mistake in full detail — what structure was expected, what the student used, and exactly why it is wrong. Do NOT write vague phrases like "wrong structure". Do NOT mention tone or pronunciation in this field.

            For "alternativeTranslations": list other equally natural ways to express the same sentence in \(language), if any exist. Return [] if only one phrasing is natural.

            For "wordExplanations": for 3–5 notable words or phrases in correctTranslation, explain in English why that word/form is used (1–2 sentences each).

            If grammar mistakes are present, add 1-2 keys to "grammarIssues" chosen ONLY from:
              word_order, negation, verb_tense, vocabulary_choice, agreement, preposition_usage
            Return [] when score ≥ 85, or only pronunciation errors were found.
            Never return more than 2 keys. No other strings allowed.

            Return ONLY valid JSON in exactly this format:
            {
              "score": <integer 0-100>,
              "feedback": "<grammar-focused feedback per rules above>",
              "toneReminders": [],
              "phonemeHints": ["<difficult sound>", ...],
              "correctTranslation": "\(targetText)",
              "alternativeTranslations": ["<alt phrasing>", ...],
              "wordExplanations": [{"word": "<word>", "explanation": "<why>"}, ...],
              "grammarIssues": ["<category_key>", ...]
            }
            """
        } else {
            systemPrompt = """
            You are a \(language) language tutor evaluating a student's spoken translation.

            The student was shown this English sentence: "\(englishSentence)"
            Their speech was recognized as: "\(transcript)"

            Evaluate on:
            1. Translation accuracy — does the \(language) convey the correct meaning?
            2. Grammar correctness
            3. Vocabulary appropriateness for the difficulty level

            Notes:
            - If the transcript is empty or clearly not \(language), score 0 and say so.
            - This is attempt \(attemptNumber) of 3.

            For "feedback":
            - If score ≥ 85 or no grammar issues: write one short encouraging sentence only (e.g. "Great job!").
            - If grammar mistakes are present: explain each mistake in full detail — what structure was expected, what the student used, and exactly why it is wrong. Do NOT write vague phrases like "wrong structure". Do NOT mention tone or pronunciation in this field.

            For "alternativeTranslations": list other equally natural \(language) phrasings of the English sentence, if any exist. Return [] if only one translation is natural.

            For "wordExplanations": for 3–5 notable words or phrases in correctTranslation, explain in English why that word/form is used (1–2 sentences each).

            If grammar mistakes are present, add 1-2 keys to "grammarIssues" chosen ONLY from:
              word_order, negation, verb_tense, vocabulary_choice, agreement, preposition_usage
            Return [] when score ≥ 85. Pick the most specific category.
            Never return more than 2 keys. No other strings allowed.

            Return ONLY valid JSON in exactly this format:
            {
              "score": <integer 0-100>,
              "feedback": "<grammar-focused feedback per rules above>",
              "toneReminders": [],
              "phonemeHints": ["<difficult sound>", ...],
              "correctTranslation": "<a natural, correct \(language) translation of the English sentence>",
              "alternativeTranslations": ["<alt phrasing>", ...],
              "wordExplanations": [{"word": "<word>", "explanation": "<why>"}, ...],
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
            responseFormat: "json_object",
            maxTokens: 1500
        )

        return try parseEvaluationResult(raw)
    }

    // MARK: - Internal helpers (accessible to subclasses)

    func performRequest(
        messages: [[String: String]],
        temperature: Double,
        responseFormat: String? = nil,
        maxTokens: Int = 512
    ) async throws -> String {
        var body: [String: Any] = [
            "model": "gpt-4o",
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens
        ]
        if let format = responseFormat {
            body["response_format"] = ["type": format]
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OpenAIError.networkError(error)
        }

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? "unknown"
            throw OpenAIError.badStatusCode(httpResponse.statusCode, bodyStr)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OpenAIError.decodingFailed("Could not parse choices from response")
        }

        return content
    }

    func parseEvaluationResult(_ raw: String) throws -> SentenceEvaluationResult {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIError.decodingFailed("Could not parse JSON from evaluation response")
        }

        let score = min(100, max(0, json["score"] as? Int ?? 0))
        let feedback = json["feedback"] as? String ?? "No feedback available."
        let toneReminders = json["toneReminders"] as? [String] ?? []
        let phonemeHints = json["phonemeHints"] as? [String] ?? []
        let correctTranslation = json["correctTranslation"] as? String ?? ""
        let alternativeTranslations = json["alternativeTranslations"] as? [String] ?? []
        let grammarIssues = json["grammarIssues"] as? [String] ?? []

        let wordExplanations: [WordExplanation]
        if let rawExplanations = json["wordExplanations"] as? [[String: String]] {
            wordExplanations = rawExplanations.compactMap { dict in
                guard let word = dict["word"], let explanation = dict["explanation"] else { return nil }
                return WordExplanation(word: word, explanation: explanation)
            }
        } else {
            wordExplanations = []
        }

        return SentenceEvaluationResult(
            score: score,
            feedback: feedback,
            toneReminders: toneReminders,
            phonemeHints: phonemeHints,
            correctTranslation: correctTranslation,
            alternativeTranslations: alternativeTranslations,
            wordExplanations: wordExplanations,
            grammarIssues: grammarIssues
        )
    }

    // MARK: - Batch parsing helpers

    func parseSentenceBatch(_ raw: String, expected: Int) throws -> [String] {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sentences = json["sentences"] as? [String] else {
            throw OpenAIError.decodingFailed("Could not parse sentence batch response")
        }
        let cleaned = sentences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                     .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw OpenAIError.emptyResponse }
        return cleaned
    }

    func parseListeningSentenceBatch(_ raw: String) throws -> [(targetText: String, englishMeaning: String)] {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["sentences"] as? [[String: Any]] else {
            throw OpenAIError.decodingFailed("Could not parse listening batch response")
        }
        let pairs = items.compactMap { item -> (String, String)? in
            guard let target = item["targetText"] as? String,
                  let meaning = item["englishMeaning"] as? String,
                  !target.isEmpty, !meaning.isEmpty else { return nil }
            return (target.trimmingCharacters(in: .whitespacesAndNewlines),
                    meaning.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !pairs.isEmpty else { throw OpenAIError.emptyResponse }
        return pairs
    }

    // MARK: - Generic difficulty description (fallback)

    func difficultyDescription(_ difficulty: Int, for language: String) -> String {
        switch difficulty {
        case 1, 2:
            return "Use very simple, common vocabulary and short sentences suitable for absolute beginners."
        case 3, 4:
            return "Use everyday vocabulary with simple grammatical structures, suitable for elementary learners."
        case 5, 6:
            return "Use intermediate vocabulary with moderately complex sentences. Include some grammatical nuance."
        case 7, 8:
            return "Use advanced vocabulary and complex grammatical structures for upper-intermediate learners."
        case 9, 10:
            return "Use sophisticated vocabulary, idiomatic expressions, and complex syntax for advanced learners."
        default:
            return "Generate a natural everyday sentence appropriate for intermediate language learners."
        }
    }
}
