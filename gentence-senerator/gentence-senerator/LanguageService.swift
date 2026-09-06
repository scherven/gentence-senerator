import Foundation

// MARK: - Errors

enum LanguageServiceError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case badStatusCode(Int, String)
    case decodingFailed(String)
    case emptyResponse
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .badStatusCode(let code, let body): return "API error \(code): \(body)"
        case .decodingFailed(let msg): return "Decoding failed: \(msg)"
        case .emptyResponse: return "Empty response from API"
        case .refused(let why): return "The model declined that request: \(why)"
        }
    }
}

// MARK: - Base Language Service
// Talks to the Anthropic Messages API. Provides generic prompts suitable for languages
// without a specialised subclass; subclass and override generateSentence /
// generateListeningSentence / evaluateAttempt to supply language-tailored prompts
// (see MandarinService, GermanService, FrenchService).

class LanguageService {

    private let apiKey: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-opus-5"

    /// Called on every completed request with what it cost in tokens. AppStore hooks this up
    /// so the running dollar total covers every call the app makes, not just the ones a
    /// particular screen remembers to report.
    var onUsage: ((TokenUsage) -> Void)?

    init(apiKey: String = Key.anthropicKey) {
        self.apiKey = apiKey
    }

    /// Per-1M-token rates for the model this service calls. Cache write is 1.25x input and a
    /// cache read 0.1x input, the standard multipliers for the 5-minute TTL used here.
    static let inputPricePerMTok = 5.00
    static let outputPricePerMTok = 25.00
    static var cacheWritePricePerMTok: Double { inputPricePerMTok * 1.25 }
    static var cacheReadPricePerMTok: Double { inputPricePerMTok * 0.10 }

    /// How hard the model should think about a given call. Adaptive thinking is always on for
    /// this model, so this — not temperature, which the model rejects — is the depth dial.
    /// Generation is routine; anything that judges the learner's language gets the full budget.
    enum Effort: String {
        case low, medium, high
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
            system: systemPrompt,
            messages: [["role": "user", "content": "Generate one English sentence for \(targetLanguage) translation practice at difficulty \(difficulty)/10."]],
            maxTokens: 8192,
            effort: .medium
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else { throw LanguageServiceError.emptyResponse }
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
            system: systemPrompt,
            messages: [["role": "user", "content": "Generate \(count) English sentences for \(targetLanguage) practice at difficulty \(difficulty)/10."]],
            maxTokens: 8192,
            effort: .medium
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
            system: systemPrompt,
            messages: [["role": "user", "content": "Generate \(count) \(targetLanguage) listening sentences at difficulty \(difficulty)/10."]],
            maxTokens: 8192,
            effort: .medium
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
            system: systemPrompt,
            messages: [["role": "user", "content": "Generate one \(targetLanguage) listening sentence at difficulty \(difficulty)/10."]],
            maxTokens: 8192,
            effort: .medium
        )

        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targetText = json["targetText"] as? String,
              let englishMeaning = json["englishMeaning"] as? String,
              !targetText.isEmpty, !englishMeaning.isEmpty else {
            throw LanguageServiceError.decodingFailed("Could not parse listening sentence response")
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

            The user message gives the \(language) sentence the student heard and what their response was recognized as.

            Evaluate how accurately the student reproduced the sentence they heard:
            1. Did they capture the key words and meaning?
            2. Grammar and vocabulary accuracy of their reproduction
            3. Pronunciation quality

            Notes:
            - If the transcript is empty or clearly not \(language), score 0 and say so.
            - The user message says which of the 3 attempts this is.
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
              "correctTranslation": "<the exact sentence that was played>",
              "alternativeTranslations": ["<alt phrasing>", ...],
              "wordExplanations": [{"word": "<word>", "explanation": "<why>"}, ...],
              "grammarIssues": ["<category_key>", ...]
            }
            """
        } else {
            systemPrompt = """
            You are a \(language) language tutor evaluating a student's spoken translation.

            The user message gives the English sentence the student was shown and what their speech was recognized as.

            Evaluate on:
            1. Translation accuracy — does the \(language) convey the correct meaning?
            2. Grammar correctness
            3. Vocabulary appropriateness for the difficulty level

            Notes:
            - If the transcript is empty or clearly not \(language), score 0 and say so.
            - The user message says which of the 3 attempts this is.

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

    /// Everything about this particular turn. Sits in the user message so the cached system
    /// prefix above never changes.
    static func produceCritiqueUserMessage(
        languageName: String,
        priorQuestion: String,
        transcript: String,
        historyBlock: String,
        grammarHint: String,
        intendedMeaning: String
    ) -> String {
        // When the learner rejects the readback and tells you what they meant, that statement
        // outranks anything inferable from their words — the whole analysis is rebuilt against it.
        let intentBlock = intendedMeaning.isEmpty ? "" : """


        IMPORTANT — the student has read your earlier interpretation and says it was wrong. What \
        they were actually trying to say is: "\(intendedMeaning)"

        Treat that as the truth about their intent. Analyse their words against it: in step 1 say \
        how what they actually wrote differs from what they meant, and from step 2 on judge every \
        choice by whether it expresses THAT intent. Do not defend your earlier reading, and do not \
        apologise for it — just redo the analysis against the real target.
        """

        return """
        You just asked: "\(priorQuestion)"
        The student responded in \(languageName): "\(transcript)"
        \(historyBlock)\(grammarHint)\(intentBlock)

        Critique my response and ask a follow-up.
        """
    }

    // MARK: - Produce-mode response schemas
    // These four responses are the deeply nested ones, so they go over the wire as schemas the
    // API validates rather than as a shape merely requested in the prompt. The older
    // generate/evaluate calls still ask for JSON in their prompt text and parse defensively.

    static func produceQuestionSchema(targetLanguage: String) -> [String: Any] {
        objectSchema([
            "question": stringField("The question, in English only."),
            "questionTargetText": stringField("The same question in \(targetLanguage) only.")
        ])
    }

    static func produceCritiqueSchema(languageName: String) -> [String: Any] {
        let choice = objectSchema([
            "expression": stringField("The exact substring the learner used, copied verbatim."),
            "verdict": ["type": "string", "enum": ["correct", "awkward", "incorrect"]],
            "explanation": stringField("One English sentence, 20 words or fewer, naming the contrast."),
            "better": stringField("The replacement expression, or an empty string when correct.")
        ])
        let critique = objectSchema([
            "text": stringField("The sentence as the learner said it."),
            "score": ["type": "integer", "description": "0-100."],
            "issue": stringField("One English sentence, or empty when there is no issue."),
            "correction": stringField("Minimal fix in \(languageName), or empty."),
            "naturalVersion": stringField("How a native would say it, or empty."),
            "grammarIssueCategory": stringField("One category key, or empty."),
            "choices": ["type": "array", "items": choice]
        ])
        return objectSchema([
            "understoodMeaning": stringField("English readback of what they said and what you think they meant. At most two sentences."),
            "overallReaction": stringField("One conversational English sentence about the content."),
            "critiques": ["type": "array", "items": critique],
            "followUpQuestion": stringField("The follow-up question, in English only."),
            "followUpQuestionTargetText": stringField("The same follow-up question, in \(languageName) only.")
        ])
    }

    static func expressionLessonSchema(targetLanguage: String) -> [String: Any] {
        let drill = objectSchema([
            "englishPrompt": stringField("The English sentence to express in \(targetLanguage)."),
            "hint": stringField("A 3-8 word nudge, in English."),
            "referenceAnswer": stringField("A natural \(targetLanguage) model answer.")
        ])
        return objectSchema([
            "headline": stringField("What the pattern does, under 12 words."),
            "explanation": stringField("2-3 sentences on when it applies."),
            "contrast": stringField("One sentence on the confusable neighbor, or empty."),
            "drills": ["type": "array", "items": drill]
        ])
    }

    static var drillResultSchema: [String: Any] {
        objectSchema([
            "isCorrect": ["type": "boolean"],
            "feedback": stringField("At most two English sentences."),
            "correctedAnswer": stringField("Their sentence with the minimum fix, or empty when it needs none.")
        ])
    }

    // MARK: - Produce mode (generic fallback — conversational storytelling practice)
    // Overridden per-language only where richer behavior is warranted (see MandarinService,
    // which adds grammar-point-biased follow-up questions via a separate downcast-only method
    // rather than an override — see critiqueProduceResponseWithPoint).

    func startProduceConversation(
        difficulty: Int,
        targetLanguage: String
    ) async throws -> (question: String, questionTargetText: String?) {
        let desc = difficultyDescription(difficulty, for: targetLanguage)
        let systemPrompt = """
        You are a friendly \(targetLanguage) conversation partner helping a language learner practice \
        telling a story or describing an experience in \(targetLanguage), difficulty \(difficulty)/10. \(desc)

        Ask ONE natural, open-ended opening question that invites the learner to describe \
        something personal (e.g. their weekend, a memorable trip, their daily routine, a hobby, a favorite meal). \
        The question should be simple enough to answer in \(targetLanguage) at this difficulty level.

        Return BOTH phrasings of that one question, and keep the two fields strictly in their own languages:
        - "question" must be written in ENGLISH ONLY, with no \(targetLanguage) in it.
        - "questionTargetText" must be the same question in \(targetLanguage) ONLY. It is required — never null.

        """

        let raw = try await performRequest(
            system: systemPrompt,
            messages: [["role": "user", "content": "Ask me an opening question."]],
            jsonSchema: Self.produceQuestionSchema(targetLanguage: targetLanguage),
            maxTokens: 8192,
            effort: .medium
        )

        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let question = json["question"] as? String, !question.isEmpty else {
            throw LanguageServiceError.decodingFailed("Could not parse produce conversation start")
        }
        return Self.normalizedQuestionPair(
            english: question, target: json["questionTargetText"] as? String,
            targetLanguage: targetLanguage)
    }

    func critiqueProduceResponse(
        targetLanguage: String,
        difficulty: Int,
        priorQuestion: String,
        transcript: String,
        conversationSoFar: [(question: String, transcript: String)] = [],
        intendedMeaning: String = ""
    ) async throws -> ProduceCritiqueResult {
        let desc = difficultyDescription(difficulty, for: targetLanguage)
        let historyBlock = conversationSoFar.isEmpty ? "" : "\n\nConversation so far:\n" +
            conversationSoFar.map { "Q: \($0.question)\nA: \($0.transcript)" }.joined(separator: "\n")

        let systemPrompt = Self.produceCritiqueSystemPrompt(
            languageName: targetLanguage,
            levelDescription: desc,
            categoryList: "word_order, negation, verb_tense, vocabulary_choice, agreement, preposition_usage")

        let userMessage = Self.produceCritiqueUserMessage(
            languageName: targetLanguage, priorQuestion: priorQuestion, transcript: transcript,
            historyBlock: historyBlock, grammarHint: "", intendedMeaning: intendedMeaning)

        let raw = try await performRequest(
            system: systemPrompt,
            messages: [["role": "user", "content": userMessage]],
            jsonSchema: Self.produceCritiqueSchema(languageName: targetLanguage),
            maxTokens: 8192,
            effort: .high,
            cacheSystemPrompt: true
        )
        return try parseProduceCritiqueResult(raw, grammarPointID: nil, targetLanguage: targetLanguage)
    }

    // MARK: - Produce critique prompt (shared by the generic and per-language critique paths)

    /// The one place the produce-mode critique brief lives. Every language builds the same
    /// analysis — read the meaning back, judge each expression the learner reached for
    /// (including the ones they got right), then rewrite twice — and varies only in the
    /// language name, the level description, the grammar-category vocabulary, and any
    /// language-specific hint appended to the follow-up instruction.
    /// The static half of the critique brief — no per-turn content, so the prefix is
    /// byte-identical across every turn of a session and the prompt cache holds.
    /// The volatile half is `produceCritiqueUserMessage`.
    static func produceCritiqueSystemPrompt(
        languageName: String,
        levelDescription: String,
        categoryList: String
    ) -> String {
        """
        You are a warm, exacting \(languageName) tutor and conversation partner. \(levelDescription)

        The user message gives you the question you just asked, the student's response in \
        \(languageName), the conversation so far, and — sometimes — a correction from the student \
        saying what they actually meant.

        Work through their response the way a patient tutor sitting next to them would.

        1. READ THE MEANING BACK. In English, in AT MOST two sentences, say what their words literally \
        say — including any part that came out garbled, contradictory, or ambiguous. If the literal \
        reading differs from what they clearly intended, give both: "You said X; I think you meant Y." \
        Never silently repair their sentence in this step; the point is to show them what they \
        actually communicated.

        2. GO EXPRESSION BY EXPRESSION. For each sentence, list the specific choices the student made \
        that are worth a verdict: time expressions, tense/aspect markers, particles, measure words, \
        word order, connectives, and any word where a near-synonym would have been the better pick. \
        Include the choices they got RIGHT as well as the wrong ones — they need to know which of their \
        decisions to trust, not just where they slipped. For each entry give:
           - "expression": the exact substring they used, copied verbatim from their response
           - "verdict": "correct", "awkward", or "incorrect"
           - "explanation": ONE sentence, 20 words or fewer, naming the contrast — what the form they \
        chose signals versus what this situation calls for. This is a headline the learner can tap to \
        expand, so do not teach the full rule here.
           - "better": the expression to use instead ("" when the verdict is "correct")
        Aim for 2-5 entries per sentence. Never invent an entry for something they did not say, and \
        never split a word into pieces that are not real morphemes.

        3. REWRITE TWICE. For each sentence give:
           - "correction": their own sentence with only the errors fixed, so they can see the delta. \
        Leave "" if the sentence had no errors.
           - "naturalVersion": how a native speaker would actually express that idea, even if it \
        restructures the sentence. Leave "" if the correction is already what a native would say.

        4. REACT. One brief, warm, natural reaction to the CONTENT of what they said (1 sentence, \
        conversational, NOT a grade or score commentary — e.g. "That sounds like a relaxing weekend!").

        5. ASK. One natural follow-up question that continues the conversation, building on what they \
        just said. If the user message names a grammar pattern to steer toward, phrase the question so \
        a good answer would naturally use it — but never at the cost of the question sounding natural.

        Scoring: "score" is 0-100 per sentence — how close that sentence is to what a native speaker \
        would accept without hesitation.
        Categories: for a sentence with an issue, pick ONE "grammarIssueCategory" from ONLY: \(categoryList). \
        Use "" for a sentence with no issue.

        Notes:
        - If the transcript is empty or clearly not \(languageName), return one critique entry saying no \
        usable speech was detected, score 0, empty "choices", and still give an encouraging reaction and \
        a follow-up question.
        - BE BRIEF. This whole response is a scannable summary, not a lesson: "issue" is one sentence, \
        each "explanation" is one sentence of 20 words or fewer. Cut every hedge, restatement and \
        pleasantry. Be concrete rather than encouraging-vague — "过 is for experiences with no fixed \
        time; 两个月前 fixes the time, so use 了" beats "the aspect marker is a little off". Anything \
        that needs a paragraph belongs in the tap-through explanation, not here.
        - Language discipline: "understoodMeaning", "issue", "explanation" and "overallReaction" are ENGLISH. \
        "text", "correction", "naturalVersion", "expression" and "better" are \(languageName). \
        "followUpQuestion" is ENGLISH ONLY and "followUpQuestionTargetText" is \(languageName) ONLY — the \
        latter is required, never null.

        """
    }

    // MARK: - Produce parsing helper (accessible to subclasses)

    func parseProduceCritiqueResult(_ raw: String, grammarPointID: String?,
                                    targetLanguage: String) throws -> ProduceCritiqueResult {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LanguageServiceError.decodingFailed("Could not parse produce critique response")
        }

        let understoodMeaning = (json["understoodMeaning"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let overallReaction = json["overallReaction"] as? String ?? ""
        let rawFollowUp = (json["followUpQuestion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawFollowUp.isEmpty else {
            throw LanguageServiceError.decodingFailed("Missing followUpQuestion in produce critique response")
        }
        let (followUpQuestion, followUpTargetText) = Self.normalizedQuestionPair(
            english: rawFollowUp, target: json["followUpQuestionTargetText"] as? String,
            targetLanguage: targetLanguage)

        let critiques: [ProduceSentenceCritique]
        if let rawCritiques = json["critiques"] as? [[String: Any]] {
            critiques = rawCritiques.compactMap { dict in
                guard let text = dict["text"] as? String, !text.isEmpty else { return nil }
                let score = min(100, max(0, dict["score"] as? Int ?? 0))
                let issue = dict["issue"] as? String ?? ""
                let correction = dict["correction"] as? String ?? ""
                let naturalVersion = dict["naturalVersion"] as? String ?? ""
                let grammarIssueCategory = dict["grammarIssueCategory"] as? String ?? ""
                let choices = (dict["choices"] as? [[String: Any]] ?? []).compactMap { c -> ProduceWordChoice? in
                    guard let expression = (c["expression"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !expression.isEmpty else { return nil }
                    let rawVerdict = (c["verdict"] as? String)?.lowercased() ?? "correct"
                    let verdict = ["correct", "awkward", "incorrect"].contains(rawVerdict) ? rawVerdict : "awkward"
                    return ProduceWordChoice(
                        expression: expression, verdict: verdict,
                        explanation: c["explanation"] as? String ?? "",
                        better: c["better"] as? String ?? "")
                }
                return ProduceSentenceCritique(text: text, score: score, issue: issue,
                                                correction: correction, naturalVersion: naturalVersion,
                                                choices: choices, grammarIssueCategory: grammarIssueCategory)
            }
        } else {
            critiques = []
        }

        return ProduceCritiqueResult(
            understoodMeaning: understoodMeaning,
            overallReaction: overallReaction,
            critiques: critiques,
            followUpQuestion: followUpQuestion,
            followUpQuestionTargetText: followUpTargetText,
            grammarPointID: grammarPointID
        )
    }

    // MARK: - Expression drill-down (tap-through from one critique row)

    /// The long form of a single critique row. Kept separate from the critique call on purpose:
    /// the critique stays terse and scannable, and the learner pays for depth only on the one
    /// expression they actually tapped.
    func explainExpression(
        targetLanguage: String,
        difficulty: Int,
        expression: String,
        better: String,
        verdict: String,
        learnerSentence: String
    ) async throws -> ExpressionLesson {
        let desc = difficultyDescription(difficulty, for: targetLanguage)
        let betterLine = better.isEmpty
            ? "They used it correctly."
            : "You told them to use \"\(better)\" instead."

        let systemPrompt = """
        You are a \(targetLanguage) tutor. \(desc)

        A student wrote: "\(learnerSentence)"
        You flagged their use of "\(expression)" as \(verdict). \(betterLine)

        They tapped that item to learn more. Teach them the pattern, then make them use it.

        - "headline": what this pattern does, in one short line (under 12 words).
        - "explanation": 2-3 sentences on when to use it and why it applies (or doesn't) in their \
        sentence. Concrete and specific. No preamble, no encouragement, no restating the headline.
        - "contrast": the near-miss this is most often confused with, in ONE sentence, framed as \
        "X does this, Y does that". Use "" if there is no genuinely confusable neighbor.
        - "drills": exactly 3 short exercises. Each gives an English sentence the student should \
        express in \(targetLanguage), chosen so a correct answer REQUIRES the pattern being taught. \
        Order them easy to hard, keep them one sentence each, and keep them at the student's level. \
        "hint" is a 3-8 word nudge. "referenceAnswer" is a natural \(targetLanguage) model answer.

        Write "headline", "explanation", "contrast" and "hint" in English. Write "referenceAnswer" \
        in \(targetLanguage).
        """

        let raw = try await performRequest(
            system: systemPrompt,
            messages: [["role": "user", "content": "Explain \"\(expression)\" and give me practice."]],
            jsonSchema: Self.expressionLessonSchema(targetLanguage: targetLanguage),
            maxTokens: 8192,
            effort: .high
        )

        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LanguageServiceError.decodingFailed("Could not parse expression lesson")
        }

        let drills = (json["drills"] as? [[String: Any]] ?? []).compactMap { d -> ExpressionDrill? in
            guard let prompt = (d["englishPrompt"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { return nil }
            return ExpressionDrill(
                englishPrompt: prompt,
                hint: d["hint"] as? String ?? "",
                referenceAnswer: d["referenceAnswer"] as? String ?? "")
        }

        return ExpressionLesson(
            expression: expression,
            better: better,
            headline: (json["headline"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            explanation: (json["explanation"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            contrast: (json["contrast"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            drills: drills)
    }

    /// Grades one drill answer. Graded against the pattern being practiced, not against the
    /// reference answer verbatim — several phrasings are usually fine.
    func checkExpressionDrill(
        targetLanguage: String,
        expression: String,
        englishPrompt: String,
        referenceAnswer: String,
        learnerAnswer: String
    ) async throws -> ExpressionDrillResult {
        let systemPrompt = """
        You are a \(targetLanguage) tutor grading one short exercise.

        The student is practicing the pattern behind "\(expression)".
        They were asked to express in \(targetLanguage): "\(englishPrompt)"
        A model answer is: "\(referenceAnswer)"
        They wrote: "\(learnerAnswer)"

        Mark it correct if it conveys the meaning AND uses the pattern correctly. Wording that \
        differs from the model answer is fine — do not require a verbatim match. Mark it incorrect \
        if the pattern is misused, the meaning is wrong, or the answer is empty or not \(targetLanguage).

        "feedback" is at most 2 sentences of English, naming exactly what worked or what to change. \
        "correctedAnswer" is their sentence with the minimum fix applied, in \(targetLanguage) — \
        leave it "" when their answer needs no change.

        """

        let raw = try await performRequest(
            system: systemPrompt,
            messages: [["role": "user", "content": "Grade my answer."]],
            jsonSchema: Self.drillResultSchema,
            maxTokens: 8192,
            effort: .high
        )

        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LanguageServiceError.decodingFailed("Could not parse drill result")
        }
        return ExpressionDrillResult(
            isCorrect: json["isCorrect"] as? Bool ?? false,
            feedback: (json["feedback"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            correctedAnswer: (json["correctedAnswer"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Question language normalization

    /// Keeps the English/target-language halves of a generated question in their intended
    /// fields. The model is told which language each field takes, but at conversational
    /// temperatures it sometimes answers the opening question entirely in the target
    /// language — which made Produce mode open in Mandarin and then flip to English on the
    /// first follow-up. When the two fields are swapped, swap them back; when the target
    /// half is missing but the "English" half is plainly target-script, keep it as the
    /// target text so the UI still has something to show and speak.
    static func normalizedQuestionPair(
        english: String, target: String?, targetLanguage: String
    ) -> (question: String, questionTargetText: String?) {
        let englishTrimmed = english.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetTrimmed = target?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetText = (targetTrimmed?.isEmpty ?? true) ? nil : targetTrimmed

        // Only languages written in a non-Latin script can be told apart this cheaply.
        guard usesNonLatinScript(targetLanguage) else { return (englishTrimmed, targetText) }

        let englishLooksTarget = containsNonLatinScript(englishTrimmed)
        guard englishLooksTarget else { return (englishTrimmed, targetText) }

        if let targetText, !containsNonLatinScript(targetText) {
            return (targetText, englishTrimmed)   // fields arrived swapped
        }
        return (englishTrimmed, targetText ?? englishTrimmed)
    }

    static func usesNonLatinScript(_ language: String) -> Bool {
        language == "Mandarin"
    }

    /// True if `text` contains any CJK Unified Ideograph (U+4E00–U+9FFF), CJK Extension A/B,
    /// or CJK Compatibility Ideographs.
    static func containsNonLatinScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||   // CJK Unified Ideographs
            (0x3400...0x4DBF).contains(scalar.value) ||   // CJK Extension A
            (0x20000...0x2A6DF).contains(scalar.value) || // CJK Extension B
            (0xF900...0xFAFF).contains(scalar.value)      // CJK Compatibility Ideographs
        }
    }

    // MARK: - Internal helpers (accessible to subclasses)

    /// One request to the Messages API.
    ///
    /// Differences from the OpenAI shape this replaced, all forced by the API:
    /// the system prompt is its own top-level field rather than a `system` role inside
    /// `messages`; `temperature` is rejected outright, so call sites tune `effort` instead;
    /// and `content` comes back as an array of blocks rather than a single string.
    ///
    /// `maxTokens` also covers the model's own thinking, so callers budget well above the
    /// length of the answer they actually want — a tight cap truncates mid-JSON.
    func performRequest(
        system: String,
        messages: [[String: String]],
        jsonSchema: [String: Any]? = nil,
        maxTokens: Int = 8192,
        effort: Effort = .high,
        cacheSystemPrompt: Bool = false
    ) async throws -> String {
        // Caching is prefix-based, so it only pays where the system prompt is byte-identical
        // across several calls in a row — the evaluation and critique prompts, which repeat once
        // per sentence or per turn. Callers with a one-off prompt leave it off; a marker on a
        // prompt that never repeats just pays the 1.25x write for a hit that never comes.
        let systemField: Any = cacheSystemPrompt
            ? [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]]
            : system

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemField,
            "messages": messages,
            "output_config": ["effort": effort.rawValue]
        ]

        // Structured outputs: the API validates the response against the schema, so a
        // well-formed object is guaranteed rather than merely requested in the prompt.
        if let jsonSchema {
            var outputConfig = body["output_config"] as? [String: Any] ?? [:]
            outputConfig["format"] = ["type": "json_schema", "schema": jsonSchema]
            body["output_config"] = outputConfig
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LanguageServiceError.networkError(error)
        }

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? "unknown"
            throw LanguageServiceError.badStatusCode(httpResponse.statusCode, bodyStr)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LanguageServiceError.decodingFailed("Response was not JSON")
        }

        // A safety decline arrives as a normal 200 with no usable content, so check before reading.
        if let stop = json["stop_reason"] as? String, stop == "refusal" {
            let details = json["stop_details"] as? [String: Any]
            throw LanguageServiceError.refused(details?["explanation"] as? String ?? "no explanation given")
        }

        if let usage = json["usage"] as? [String: Any] {
            onUsage?(TokenUsage(
                inputTokens: usage["input_tokens"] as? Int ?? 0,
                outputTokens: usage["output_tokens"] as? Int ?? 0,
                cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0))
        }

        guard let blocks = json["content"] as? [[String: Any]] else {
            throw LanguageServiceError.decodingFailed("Could not read content blocks from response")
        }

        // Thinking blocks ride along with the answer; only the text blocks are the reply.
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            if json["stop_reason"] as? String == "max_tokens" {
                throw LanguageServiceError.decodingFailed("Ran out of tokens before answering — raise maxTokens")
            }
            throw LanguageServiceError.emptyResponse
        }
        return text
    }

    // MARK: - Schema helper

    /// Wraps a property map into the object schema shape structured outputs require:
    /// every field required, no extra properties.
    static func objectSchema(_ properties: [String: Any]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": Array(properties.keys),
            "additionalProperties": false
        ]
    }

    static func stringField(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    func parseEvaluationResult(_ raw: String) throws -> SentenceEvaluationResult {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LanguageServiceError.decodingFailed("Could not parse JSON from evaluation response")
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
            throw LanguageServiceError.decodingFailed("Could not parse sentence batch response")
        }
        let cleaned = sentences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                     .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw LanguageServiceError.emptyResponse }
        return cleaned
    }

    func parseListeningSentenceBatch(_ raw: String) throws -> [(targetText: String, englishMeaning: String)] {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["sentences"] as? [[String: Any]] else {
            throw LanguageServiceError.decodingFailed("Could not parse listening batch response")
        }
        let pairs = items.compactMap { item -> (String, String)? in
            guard let target = item["targetText"] as? String,
                  let meaning = item["englishMeaning"] as? String,
                  !target.isEmpty, !meaning.isEmpty else { return nil }
            return (target.trimmingCharacters(in: .whitespacesAndNewlines),
                    meaning.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !pairs.isEmpty else { throw LanguageServiceError.emptyResponse }
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
