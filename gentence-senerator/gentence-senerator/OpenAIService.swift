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

// MARK: - OpenAI Service

final class OpenAIService {

    private let apiKey: String
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    init(apiKey: String = Key.key) {
        self.apiKey = apiKey
    }

    // MARK: - Generate English sentence

    /// Generates a single English sentence designed for translation practice at the given Mandarin difficulty level.
    func generateSentence(
        difficulty: Int,
        targetLanguage: String,
        excludingTexts: [String] = [],
        grammarFocusAreas: [String] = []
    ) async throws -> String {
        let difficultyDescription = mandarinDifficultyDescription(difficulty)
        let exclusionHint = excludingTexts.isEmpty ? "" : " Do NOT generate any sentence similar to: \(excludingTexts.prefix(10).joined(separator: "; "))."

        let varietyInstruction = """
         Actively vary the following to avoid repetitive patterns: \
        sentence structure (mix SVO statements, negations with 不/没, yes-no questions with 吗, imperatives, \
        and topic-comment frames even at lower difficulty levels), \
        verbs (do NOT default to 是/有/去/喜欢 — draw from a wide range of everyday actions), \
        and topics (rotate across food, travel, work, family, weather, shopping, hobbies, health, technology).
        """

        let grammarInstruction = grammarFocusAreas.isEmpty ? "" :
            " Prioritize sentence structures that require one of these grammar patterns: \(grammarFocusAreas.joined(separator: ", "))."

        let systemPrompt = """
        You are a language learning sentence generator. Generate a single natural English sentence \
        suitable for \(targetLanguage) translation practice at difficulty \(difficulty)/10. \
        \(difficultyDescription)\(varietyInstruction)\(grammarInstruction)\(exclusionHint)
        Return ONLY the English sentence text — no translation, no explanation, no punctuation beyond the sentence itself.
        """

        let userPrompt = "Generate one English sentence for \(targetLanguage) translation practice at difficulty \(difficulty)/10."

        let text = try await performRequest(
            messages: [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            temperature: 0.9
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else { throw OpenAIError.emptyResponse }
        return trimmed
    }

    // MARK: - Evaluate attempt

    /// Evaluates a user's spoken translation against the English source sentence.
    func evaluateAttempt(
        englishSentence: String,
        transcript: String,
        language: String,
        attemptNumber: Int
    ) async throws -> SentenceEvaluationResult {
        let systemPrompt = """
        You are a \(language) language tutor evaluating a student's spoken translation.

        The student was shown this English sentence: "\(englishSentence)"
        Their speech was recognized as: "\(transcript)"

        Evaluate on:
        1. Translation accuracy — does the \(language) convey the correct meaning?
        2. Grammar correctness — particles, measure words, word order, aspect markers
        3. Vocabulary appropriateness for the difficulty level

        Important notes for \(language):
        - Speech recognition cannot detect tone errors. Always include specific tone reminders \
        for 2-3 key words in the transcript using the "toneReminders" field (e.g. "妈 mā (tone 1)").
        - If the transcript is empty or clearly not \(language), score 0 and say so.
        - Be encouraging but specific. Mention what was right and what needs work.
        - This is attempt \(attemptNumber) of 3.

        Grammar issue categorization:
        If grammar mistakes are present, add 1-2 keys to "grammarIssues" chosen ONLY from:
          Mandarin: particle_usage, measure_words, word_order, aspect_markers, ba_sentence, \
        resultative_complement, potential_complement, topic_comment, negation, comparison, \
        question_formation, verb_complement
          Other languages: word_order, negation, verb_tense, vocabulary_choice
        Return [] when score ≥ 85, or only tone/pronunciation errors were found (not grammar). \
        Pick the most specific category. Never return more than 2 keys. No other strings allowed.

        Return ONLY valid JSON in exactly this format:
        {
          "score": <integer 0-100>,
          "feedback": "<2-3 sentences of specific, encouraging feedback in English>",
          "toneReminders": ["<word> <pinyin> (tone <N>)", ...],
          "phonemeHints": ["<difficult sound>", ...],
          "correctTranslation": "<a natural, correct \(language) translation of the English sentence>",
          "grammarIssues": ["<category_key>", ...]
        }
        """

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

    // MARK: - Private helpers

    private func performRequest(
        messages: [[String: String]],
        temperature: Double,
        responseFormat: String? = nil
    ) async throws -> String {
        var body: [String: Any] = [
            "model": "gpt-4o",
            "messages": messages,
            "temperature": temperature,
            "max_tokens": 512
        ]
        if let format = responseFormat {
            body["response_format"] = ["type": format]
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: endpoint)
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

    private func parseEvaluationResult(_ raw: String) throws -> SentenceEvaluationResult {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIError.decodingFailed("Could not parse JSON from evaluation response")
        }

        let score = min(100, max(0, json["score"] as? Int ?? 0))
        let feedback = json["feedback"] as? String ?? "No feedback available."
        let toneReminders = json["toneReminders"] as? [String] ?? []
        let phonemeHints = json["phonemeHints"] as? [String] ?? []
        let correctTranslation = json["correctTranslation"] as? String ?? ""
        let grammarIssues = json["grammarIssues"] as? [String] ?? []

        return SentenceEvaluationResult(
            score: score,
            feedback: feedback,
            toneReminders: toneReminders,
            phonemeHints: phonemeHints,
            correctTranslation: correctTranslation,
            grammarIssues: grammarIssues
        )
    }

    // MARK: - Difficulty descriptions

    private func mandarinDifficultyDescription(_ difficulty: Int) -> String {
        switch difficulty {
        case 1, 2:
            return "Use simple everyday nouns and a variety of common verbs (not just 是/有/去). " +
                   "Mix in simple negations (not, don't) and yes/no questions alongside statements. " +
                   "The Mandarin translation should not require measure words or aspect particles."
        case 3, 4:
            return "Use time expressions (today/tomorrow/yesterday), basic adjectives as predicates, " +
                   "simple negation, and common measure words. Vary between affirmative statements, " +
                   "negations, and simple questions. Avoid complex particles or complements."
        case 5, 6:
            return "Target sentences requiring aspect particles (了/过/着), serial verb constructions, " +
                   "or pivotal sentences. Moderate vocabulary difficulty."
        case 7, 8:
            return "Target sentences requiring resultative or directional complements, potential " +
                   "complements (得/不), or ba-sentences (把). Higher vocabulary."
        case 9, 10:
            return "Target sentences requiring complex topic-comment structures, classical-style phrases, " +
                   "chengyu usage, or sophisticated conditionals. Advanced vocabulary expected."
        default:
            return "Generate a natural everyday English sentence appropriate for intermediate language learners."
        }
    }
}
