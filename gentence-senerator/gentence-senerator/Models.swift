import Foundation

// MARK: - Practice Mode

enum PracticeMode: String, Codable {
    case translation   // existing flow: English → target language
    case listening     // new: hear target language → reproduce it
}

// MARK: - Practice Phase (drives PracticeView state machine)

enum PracticePhase: Equatable {
    case idle
    case generatingSentences
    case readyToRecord
    case recording
    case transcribing
    case reviewingTranscription
    case evaluating
    case showingFeedback(score: Int)
    case sessionComplete
    case error(String)
}

// MARK: - Sentence Status

enum SentenceStatus: String, Codable {
    case pending, inProgress, complete
}

// MARK: - Attempt

struct Attempt: Codable, Identifiable {
    var id: UUID
    var sentenceID: UUID
    var transcript: String
    var score: Int
    var feedback: String
    var toneReminders: [String]
    var phonemeHints: [String]
    var correctTranslation: String
    var attemptNumber: Int
    var createdAt: Date
    var audioFilename: String?   // filename only (not full path) inside AudioRecordings/
    var grammarIssues: [String]  // closed-vocabulary category keys, e.g. ["ba_sentence"]
    var pronunciationAssessment: PronunciationAssessment?  // nil for non-Mandarin or pre-feature attempts

    // Memberwise initializer (allows call sites to omit optional fields)
    init(id: UUID = UUID(), sentenceID: UUID, transcript: String, score: Int,
         feedback: String, toneReminders: [String], phonemeHints: [String],
         correctTranslation: String, attemptNumber: Int, createdAt: Date = Date(),
         audioFilename: String? = nil, grammarIssues: [String] = [],
         pronunciationAssessment: PronunciationAssessment? = nil) {
        self.id = id
        self.sentenceID = sentenceID
        self.transcript = transcript
        self.score = score
        self.feedback = feedback
        self.toneReminders = toneReminders
        self.phonemeHints = phonemeHints
        self.correctTranslation = correctTranslation
        self.attemptNumber = attemptNumber
        self.createdAt = createdAt
        self.audioFilename = audioFilename
        self.grammarIssues = grammarIssues
        self.pronunciationAssessment = pronunciationAssessment
    }

    // Backward-compatible decoder: handles old records missing recently-added fields
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                 = try  c.decode(UUID.self,     forKey: .id)
        sentenceID         = try  c.decode(UUID.self,     forKey: .sentenceID)
        transcript         = try  c.decode(String.self,   forKey: .transcript)
        score              = try  c.decode(Int.self,      forKey: .score)
        feedback           = try  c.decode(String.self,   forKey: .feedback)
        toneReminders      = try  c.decode([String].self, forKey: .toneReminders)
        phonemeHints       = try  c.decode([String].self, forKey: .phonemeHints)
        correctTranslation = (try? c.decodeIfPresent(String.self,   forKey: .correctTranslation)) ?? ""
        attemptNumber      = try  c.decode(Int.self,      forKey: .attemptNumber)
        createdAt          = try  c.decode(Date.self,     forKey: .createdAt)
        audioFilename      = try? c.decodeIfPresent(String.self,   forKey: .audioFilename)
        grammarIssues          = (try? c.decodeIfPresent([String].self,              forKey: .grammarIssues)) ?? []
        pronunciationAssessment = try? c.decodeIfPresent(PronunciationAssessment.self, forKey: .pronunciationAssessment)
    }

    enum CodingKeys: String, CodingKey {
        case id, sentenceID, transcript, score, feedback, toneReminders,
             phonemeHints, correctTranslation, attemptNumber, createdAt,
             audioFilename, grammarIssues, pronunciationAssessment
    }
}

// MARK: - Sentence

struct Sentence: Codable, Identifiable {
    var id: UUID
    var englishText: String
    var targetLanguage: String
    var difficultyLevel: Int
    var createdAt: Date
    var attempts: [Attempt]
    var bestScore: Int?
    var status: SentenceStatus
    var listeningTargetText: String?   // non-nil for listening-mode sentences (target-language text played via TTS)
    var targetGrammarPointID: String?  // non-nil when generated to drill a specific MandarinGrammarBank point

    init(id: UUID = UUID(), englishText: String, targetLanguage: String, difficultyLevel: Int,
         listeningTargetText: String? = nil, targetGrammarPointID: String? = nil) {
        self.id = id
        self.englishText = englishText
        self.targetLanguage = targetLanguage
        self.difficultyLevel = difficultyLevel
        self.createdAt = Date()
        self.attempts = []
        self.bestScore = nil
        self.status = .pending
        self.listeningTargetText = listeningTargetText
        self.targetGrammarPointID = targetGrammarPointID
    }

    // Backward-compatible decoder: handles old records missing listeningTargetText / targetGrammarPointID
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                  = try  c.decode(UUID.self,            forKey: .id)
        englishText         = try  c.decode(String.self,          forKey: .englishText)
        targetLanguage      = try  c.decode(String.self,          forKey: .targetLanguage)
        difficultyLevel     = try  c.decode(Int.self,             forKey: .difficultyLevel)
        createdAt           = try  c.decode(Date.self,            forKey: .createdAt)
        attempts            = try  c.decode([Attempt].self,       forKey: .attempts)
        bestScore           = try? c.decodeIfPresent(Int.self,    forKey: .bestScore)
        status              = try  c.decode(SentenceStatus.self,  forKey: .status)
        listeningTargetText = try? c.decodeIfPresent(String.self, forKey: .listeningTargetText)
        targetGrammarPointID = (try? c.decodeIfPresent(String.self, forKey: .targetGrammarPointID)) ?? nil
    }

    enum CodingKeys: String, CodingKey {
        case id, englishText, targetLanguage, difficultyLevel, createdAt,
             attempts, bestScore, status, listeningTargetText, targetGrammarPointID
    }

    var attemptCount: Int { attempts.count }
    var canRetry: Bool { attemptCount < 3 && status != .complete }
}

// MARK: - Daily Session

struct DailySession: Codable, Identifiable {
    var id: String           // keyed as "2026-03-27_Mandarin"
    var date: Date
    var sentenceIDs: [UUID]
    var completedIDs: [UUID]
    var isComplete: Bool
    var totalXPEarned: Int
    var targetLanguage: String   // NEW — default "Mandarin" for backward compat

    var completionCount: Int { completedIDs.count }

    init(id: String, date: Date, sentenceIDs: [UUID], completedIDs: [UUID],
         isComplete: Bool, totalXPEarned: Int, targetLanguage: String = "Mandarin") {
        self.id = id
        self.date = date
        self.sentenceIDs = sentenceIDs
        self.completedIDs = completedIDs
        self.isComplete = isComplete
        self.totalXPEarned = totalXPEarned
        self.targetLanguage = targetLanguage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try  c.decode(String.self,  forKey: .id)
        date           = try  c.decode(Date.self,    forKey: .date)
        sentenceIDs    = try  c.decode([UUID].self,  forKey: .sentenceIDs)
        completedIDs   = try  c.decode([UUID].self,  forKey: .completedIDs)
        isComplete     = try  c.decode(Bool.self,    forKey: .isComplete)
        totalXPEarned  = try  c.decode(Int.self,     forKey: .totalXPEarned)
        targetLanguage = (try? c.decodeIfPresent(String.self, forKey: .targetLanguage)) ?? "Mandarin"
    }

    enum CodingKeys: String, CodingKey {
        case id, date, sentenceIDs, completedIDs, isComplete, totalXPEarned, targetLanguage
    }
}

// MARK: - Produce Mode
// A third practice mode: the AI asks an open-ended question, the learner speaks a free
// (potentially multi-sentence) response, and each sentence is critiqued individually before
// a natural follow-up question continues the conversation. Deliberately NOT modeled on
// Sentence/DailySession — a turn has no fixed "attempt 1 of 3" ceiling and produces multiple
// per-sentence critiques from one transcript, neither of which fits the flashcard shape those
// types were built for.

enum ProducePhase: Equatable {
    case idle
    case generatingQuestion
    case readyToRecord
    case recording
    case transcribing
    case reviewingTranscript
    case critiquing
    case showingCritique
    case sessionComplete
    case error(String)
}

/// How a single expression the learner reached for actually landed. This is the unit that
/// answers "was 过 the right aspect marker here?" — one entry per deliberate choice worth
/// commenting on, including the ones that were right.
struct ProduceWordChoice: Codable, Identifiable {
    var id: UUID
    var expression: String    // the exact substring the learner used, e.g. "后前", "去过"
    var verdict: String       // "correct" | "awkward" | "incorrect"
    var explanation: String   // what that expression actually means / why it does or doesn't fit
    var better: String        // the expression to use instead, empty when the verdict is "correct"

    init(id: UUID = UUID(), expression: String, verdict: String,
         explanation: String = "", better: String = "") {
        self.id = id
        self.expression = expression
        self.verdict = verdict
        self.explanation = explanation
        self.better = better
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try  c.decode(UUID.self,   forKey: .id)
        expression  = try  c.decode(String.self, forKey: .expression)
        verdict     = (try? c.decodeIfPresent(String.self, forKey: .verdict)) ?? "correct"
        explanation = (try? c.decodeIfPresent(String.self, forKey: .explanation)) ?? ""
        better      = (try? c.decodeIfPresent(String.self, forKey: .better)) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, expression, verdict, explanation, better
    }
}

struct ProduceSentenceCritique: Codable, Identifiable {
    var id: UUID
    var text: String                  // segment of the user's speech being critiqued
    var score: Int                     // 0-100
    var issue: String                  // free-text explanation, empty if no issue
    var correction: String             // minimal fix of what the learner wrote, empty if no issue
    var naturalVersion: String         // how a native would actually say it, empty if already natural
    var choices: [ProduceWordChoice]   // expression-by-expression verdicts on this sentence
    var grammarIssueCategory: String   // closed-vocabulary key (same taxonomy evaluateAttempt uses), "" if none

    init(id: UUID = UUID(), text: String, score: Int, issue: String = "",
         correction: String = "", naturalVersion: String = "",
         choices: [ProduceWordChoice] = [], grammarIssueCategory: String = "") {
        self.id = id
        self.text = text
        self.score = score
        self.issue = issue
        self.correction = correction
        self.naturalVersion = naturalVersion
        self.choices = choices
        self.grammarIssueCategory = grammarIssueCategory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                   = try  c.decode(UUID.self,   forKey: .id)
        text                 = try  c.decode(String.self, forKey: .text)
        score                = try  c.decode(Int.self,    forKey: .score)
        issue                = (try? c.decodeIfPresent(String.self, forKey: .issue)) ?? ""
        correction           = (try? c.decodeIfPresent(String.self, forKey: .correction)) ?? ""
        naturalVersion       = (try? c.decodeIfPresent(String.self, forKey: .naturalVersion)) ?? ""
        choices              = (try? c.decodeIfPresent([ProduceWordChoice].self, forKey: .choices)) ?? []
        grammarIssueCategory = (try? c.decodeIfPresent(String.self, forKey: .grammarIssueCategory)) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, text, score, issue, correction, naturalVersion, choices, grammarIssueCategory
    }
}

struct ProduceTurn: Codable, Identifiable {
    var id: UUID
    var question: String                // English prompt shown to the user
    var questionTargetText: String?     // optional target-language phrasing, for an optional TTS button
    var transcript: String              // user's full raw response
    var understoodMeaning: String       // English readback of what the response actually says
    var statedIntent: String            // what the learner said they meant, when they corrected the readback
    var overallReaction: String         // brief natural reaction to content, not a grade
    var critiques: [ProduceSentenceCritique]
    var createdAt: Date
    var audioFilename: String?
    var targetGrammarPointID: String?   // Mandarin only; nil otherwise

    var averageScore: Int {
        guard !critiques.isEmpty else { return 0 }
        return critiques.map(\.score).reduce(0, +) / critiques.count
    }

    init(id: UUID = UUID(), question: String, questionTargetText: String? = nil,
         transcript: String, understoodMeaning: String = "", statedIntent: String = "",
         overallReaction: String, critiques: [ProduceSentenceCritique],
         createdAt: Date = Date(), audioFilename: String? = nil, targetGrammarPointID: String? = nil) {
        self.id = id
        self.question = question
        self.questionTargetText = questionTargetText
        self.transcript = transcript
        self.understoodMeaning = understoodMeaning
        self.statedIntent = statedIntent
        self.overallReaction = overallReaction
        self.critiques = critiques
        self.createdAt = createdAt
        self.audioFilename = audioFilename
        self.targetGrammarPointID = targetGrammarPointID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                    = try  c.decode(UUID.self,   forKey: .id)
        question              = try  c.decode(String.self, forKey: .question)
        questionTargetText    = (try? c.decodeIfPresent(String.self, forKey: .questionTargetText)) ?? nil
        transcript            = try  c.decode(String.self, forKey: .transcript)
        understoodMeaning     = (try? c.decodeIfPresent(String.self, forKey: .understoodMeaning)) ?? ""
        statedIntent          = (try? c.decodeIfPresent(String.self, forKey: .statedIntent)) ?? ""
        overallReaction       = (try? c.decodeIfPresent(String.self, forKey: .overallReaction)) ?? ""
        critiques             = (try? c.decodeIfPresent([ProduceSentenceCritique].self, forKey: .critiques)) ?? []
        createdAt             = try  c.decode(Date.self,   forKey: .createdAt)
        audioFilename         = (try? c.decodeIfPresent(String.self, forKey: .audioFilename)) ?? nil
        targetGrammarPointID  = (try? c.decodeIfPresent(String.self, forKey: .targetGrammarPointID)) ?? nil
    }

    enum CodingKeys: String, CodingKey {
        case id, question, questionTargetText, transcript, understoodMeaning, statedIntent,
             overallReaction, critiques, createdAt, audioFilename, targetGrammarPointID
    }
}

struct ProduceSession: Codable, Identifiable {
    var id: String              // "\(todayISOString())_\(targetLanguage)_produce"
    var date: Date
    var targetLanguage: String
    var difficultyLevel: Int
    var turns: [ProduceTurn]
    var isComplete: Bool
    var totalXPEarned: Int

    init(id: String, date: Date, targetLanguage: String, difficultyLevel: Int,
         turns: [ProduceTurn] = [], isComplete: Bool = false, totalXPEarned: Int = 0) {
        self.id = id
        self.date = date
        self.targetLanguage = targetLanguage
        self.difficultyLevel = difficultyLevel
        self.turns = turns
        self.isComplete = isComplete
        self.totalXPEarned = totalXPEarned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try  c.decode(String.self, forKey: .id)
        date            = try  c.decode(Date.self,   forKey: .date)
        targetLanguage  = try  c.decode(String.self, forKey: .targetLanguage)
        difficultyLevel = (try? c.decodeIfPresent(Int.self, forKey: .difficultyLevel)) ?? 3
        turns           = (try? c.decodeIfPresent([ProduceTurn].self, forKey: .turns)) ?? []
        isComplete      = (try? c.decodeIfPresent(Bool.self, forKey: .isComplete)) ?? false
        totalXPEarned   = (try? c.decodeIfPresent(Int.self, forKey: .totalXPEarned)) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case id, date, targetLanguage, difficultyLevel, turns, isComplete, totalXPEarned
    }
}

// MARK: - Produce Critique Result (ephemeral, not persisted — one LLM call's worth of output)

struct ProduceCritiqueResult {
    let understoodMeaning: String
    let overallReaction: String
    let critiques: [ProduceSentenceCritique]
    let followUpQuestion: String
    let followUpQuestionTargetText: String?
    let grammarPointID: String?   // Mandarin only; nil otherwise
}

// MARK: - Badge

struct Badge: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var description: String
    var iconSystemName: String
    var unlockedAt: Date
}

// MARK: - Badge Definitions

enum BadgeDefinition: String, CaseIterable {
    case firstSentence = "first_sentence"
    case perfectScore = "perfect_score"
    case day3Streak = "day_3_streak"
    case day7Streak = "day_7_streak"
    case day30Streak = "day_30_streak"
    case level5 = "level_5"
    case level10 = "level_10"
    case level25 = "level_25"
    case score50Avg = "score_50_avg"
    case score75Avg = "score_75_avg"
    case difficulty5 = "difficulty_5"
    case difficulty10 = "difficulty_10"
    case sentences100 = "sentences_100"
    case retryImprover = "retry_improver"

    var name: String {
        switch self {
        case .firstSentence: return "First Words"
        case .perfectScore: return "Flawless"
        case .day3Streak: return "On a Roll"
        case .day7Streak: return "Week Warrior"
        case .day30Streak: return "Monthly Master"
        case .level5: return "Rising Star"
        case .level10: return "Dedicated"
        case .level25: return "Expert"
        case .score50Avg: return "Consistent"
        case .score75Avg: return "Advanced"
        case .difficulty5: return "Challenger"
        case .difficulty10: return "Master Speaker"
        case .sentences100: return "Century"
        case .retryImprover: return "Never Give Up"
        }
    }

    var description: String {
        switch self {
        case .firstSentence: return "Complete your first sentence"
        case .perfectScore: return "Score 100 on any attempt"
        case .day3Streak: return "Keep a 3-day streak"
        case .day7Streak: return "Keep a 7-day streak"
        case .day30Streak: return "Keep a 30-day streak"
        case .level5: return "Reach level 5"
        case .level10: return "Reach level 10"
        case .level25: return "Reach level 25"
        case .score50Avg: return "Average score ≥ 50 over 10 sentences"
        case .score75Avg: return "Average score ≥ 75 over 10 sentences"
        case .difficulty5: return "Reach difficulty level 5"
        case .difficulty10: return "Reach difficulty level 10"
        case .sentences100: return "Complete 100 total sentences"
        case .retryImprover: return "Score higher on a retry 10 times"
        }
    }

    var iconSystemName: String {
        switch self {
        case .firstSentence: return "text.bubble.fill"
        case .perfectScore: return "star.fill"
        case .day3Streak: return "flame.fill"
        case .day7Streak: return "bolt.fill"
        case .day30Streak: return "crown.fill"
        case .level5: return "arrow.up.circle.fill"
        case .level10: return "medal.fill"
        case .level25: return "rosette"
        case .score50Avg: return "chart.line.uptrend.xyaxis"
        case .score75Avg: return "chart.bar.fill"
        case .difficulty5: return "speedometer"
        case .difficulty10: return "waveform.badge.exclamationmark"
        case .sentences100: return "100.circle.fill"
        case .retryImprover: return "arrow.counterclockwise.circle.fill"
        }
    }
}

// MARK: - Pronunciation Assessment

/// Per-syllable result from Azure Pronunciation Assessment.
struct SyllableResult: Codable, Identifiable {
    var id: UUID = UUID()
    var character: String       // e.g. "买"
    var syllable: String        // pinyin with tone mark, e.g. "mǎi"
    var accuracyScore: Int      // 0–100 overall phoneme accuracy
    var toneScore: Int          // 0–100 tone accuracy
    var initialScore: Int?      // consonant (声母) accuracy (nil if no initial, e.g. vowel-only syllables)
    var finalScore: Int?        // vowel/final (韵母) accuracy
    var errorType: String       // "None", "Mispronunciation", "Omission", "Insertion"
}

/// Top-level pronunciation assessment result attached to an Attempt.
struct PronunciationAssessment: Codable {
    var overallScore: Int
    var toneScore: Int          // average tone accuracy across syllables
    var accuracyScore: Int      // average phoneme accuracy across syllables
    var consonantScore: Int     // average initial (声母) accuracy
    var vowelScore: Int         // average final (韵母) accuracy
    var syllables: [SyllableResult]
}

// MARK: - Language Profile (per-language progress)

struct LanguageProfile: Codable {
    var currentDifficultyLevel: Int = 3
    var difficultyLocked: Bool = false
    var dailySentenceGoal: Int = 5
    var grammarFocusAreas: [String] = []
    var totalXP: Int = 0
    var currentLevel: Int = 1
    var currentStreak: Int = 0
    var longestStreak: Int = 0
    var lastCompletedDate: String?
    var recentScores: [Int] = []
    var seenSentenceTexts: [String] = []
    var totalSentencesCompleted: Int = 0
    var retryImprovements: Int = 0
    var unlockedBadges: [Badge] = []
    var recentToneScores: [Int] = []           // last 10 tone scores for trend chart
    var recentPronunciationScores: [Int] = []  // last 10 overall pronunciation scores
    var grammarPointUsage: [String: Int] = [:]     // MandarinGrammarBank point id -> times targeted
    var grammarPointWeakness: [String: Int] = [:]  // MandarinGrammarBank point id -> times flagged in a sub-85 attempt

    init(currentDifficultyLevel: Int = 3, difficultyLocked: Bool = false, dailySentenceGoal: Int = 5,
         grammarFocusAreas: [String] = [], totalXP: Int = 0, currentLevel: Int = 1, currentStreak: Int = 0,
         longestStreak: Int = 0, lastCompletedDate: String? = nil, recentScores: [Int] = [],
         seenSentenceTexts: [String] = [], totalSentencesCompleted: Int = 0, retryImprovements: Int = 0,
         unlockedBadges: [Badge] = [], recentToneScores: [Int] = [], recentPronunciationScores: [Int] = [],
         grammarPointUsage: [String: Int] = [:], grammarPointWeakness: [String: Int] = [:]) {
        self.currentDifficultyLevel = currentDifficultyLevel
        self.difficultyLocked = difficultyLocked
        self.dailySentenceGoal = dailySentenceGoal
        self.grammarFocusAreas = grammarFocusAreas
        self.totalXP = totalXP
        self.currentLevel = currentLevel
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.lastCompletedDate = lastCompletedDate
        self.recentScores = recentScores
        self.seenSentenceTexts = seenSentenceTexts
        self.totalSentencesCompleted = totalSentencesCompleted
        self.retryImprovements = retryImprovements
        self.unlockedBadges = unlockedBadges
        self.recentToneScores = recentToneScores
        self.recentPronunciationScores = recentPronunciationScores
        self.grammarPointUsage = grammarPointUsage
        self.grammarPointWeakness = grammarPointWeakness
    }

    // Backward-compatible decoder: every field falls back to its default when absent, so
    // profiles saved before a field was introduced (e.g. grammarPointUsage) still decode
    // instead of silently discarding the user's saved progress.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentDifficultyLevel    = (try? c.decodeIfPresent(Int.self,    forKey: .currentDifficultyLevel)) ?? 3
        difficultyLocked          = (try? c.decodeIfPresent(Bool.self,   forKey: .difficultyLocked)) ?? false
        dailySentenceGoal         = (try? c.decodeIfPresent(Int.self,    forKey: .dailySentenceGoal)) ?? 5
        grammarFocusAreas         = (try? c.decodeIfPresent([String].self, forKey: .grammarFocusAreas)) ?? []
        totalXP                   = (try? c.decodeIfPresent(Int.self,    forKey: .totalXP)) ?? 0
        currentLevel              = (try? c.decodeIfPresent(Int.self,    forKey: .currentLevel)) ?? 1
        currentStreak             = (try? c.decodeIfPresent(Int.self,    forKey: .currentStreak)) ?? 0
        longestStreak             = (try? c.decodeIfPresent(Int.self,    forKey: .longestStreak)) ?? 0
        lastCompletedDate         = (try? c.decodeIfPresent(String.self, forKey: .lastCompletedDate)) ?? nil
        recentScores              = (try? c.decodeIfPresent([Int].self,  forKey: .recentScores)) ?? []
        seenSentenceTexts         = (try? c.decodeIfPresent([String].self, forKey: .seenSentenceTexts)) ?? []
        totalSentencesCompleted   = (try? c.decodeIfPresent(Int.self,    forKey: .totalSentencesCompleted)) ?? 0
        retryImprovements         = (try? c.decodeIfPresent(Int.self,    forKey: .retryImprovements)) ?? 0
        unlockedBadges            = (try? c.decodeIfPresent([Badge].self, forKey: .unlockedBadges)) ?? []
        recentToneScores          = (try? c.decodeIfPresent([Int].self,  forKey: .recentToneScores)) ?? []
        recentPronunciationScores = (try? c.decodeIfPresent([Int].self,  forKey: .recentPronunciationScores)) ?? []
        grammarPointUsage         = (try? c.decodeIfPresent([String: Int].self, forKey: .grammarPointUsage)) ?? [:]
        grammarPointWeakness      = (try? c.decodeIfPresent([String: Int].self, forKey: .grammarPointWeakness)) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case currentDifficultyLevel, difficultyLocked, dailySentenceGoal, grammarFocusAreas,
             totalXP, currentLevel, currentStreak, longestStreak, lastCompletedDate, recentScores,
             seenSentenceTexts, totalSentencesCompleted, retryImprovements, unlockedBadges,
             recentToneScores, recentPronunciationScores, grammarPointUsage, grammarPointWeakness
    }
}

// MARK: - User Profile

struct UserProfile: Codable {
    var selectedLanguage: String = "Mandarin"
    var languageProfiles: [String: LanguageProfile] = [:]

    // ── Legacy flat fields — kept for one-time migration only ──
    var dailySentenceGoal: Int = 5
    var currentDifficultyLevel: Int = 3
    var totalXP: Int = 0
    var currentLevel: Int = 1
    var currentStreak: Int = 0
    var longestStreak: Int = 0
    var lastCompletedDate: String?
    var unlockedBadgeIDs: [String] = []
    var unlockedBadges: [Badge] = []
    var seenSentenceTexts: [String] = []
    var recentScores: [Int] = []
    var totalSentencesCompleted: Int = 0
    var retryImprovements: Int = 0
}

// MARK: - App Settings

struct AppSettings: Codable {
    var targetLanguage: String = "Mandarin"
    var dailyGoal: Int = 5
    var difficultyLocked: Bool = false
    var showRomanization: Bool = true
    var autoAdvance: Bool = false
    var practiceMode: PracticeMode = .translation
    // grammarFocusAreas moved to LanguageProfile — kept here only for one-time migration
    var grammarFocusAreas: [String] = []
}

// MARK: - Word explanation (ephemeral, not persisted)

struct WordExplanation: Identifiable {
    let id = UUID()
    let word: String
    let explanation: String
}

// MARK: - API Cost Tracking

/// What one API call consumed. Cached input is billed at different rates from fresh input,
/// so the four buckets stay separate all the way to the dollar figure.
struct TokenUsage {
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
}

/// Running API spend. `todayTotals` is what the daily cap watches; `sessionTotals` resets
/// whenever a new practice session starts, so the home screen can show what this sitting cost.
struct CostLedger: Codable {
    var day: String = todayISOString()
    var dayInputTokens: Int = 0
    var dayOutputTokens: Int = 0
    var dayCacheWriteTokens: Int = 0
    var dayCacheReadTokens: Int = 0
    var dayCallCount: Int = 0

    var sessionInputTokens: Int = 0
    var sessionOutputTokens: Int = 0
    var sessionCacheWriteTokens: Int = 0
    var sessionCacheReadTokens: Int = 0
    var sessionCallCount: Int = 0

    /// True once the day rolls over, so the caller knows to zero the daily side before adding.
    var isStale: Bool { day != todayISOString() }

    mutating func rollDayIfNeeded() {
        guard isStale else { return }
        day = todayISOString()
        dayInputTokens = 0
        dayOutputTokens = 0
        dayCacheWriteTokens = 0
        dayCacheReadTokens = 0
        dayCallCount = 0
    }

    mutating func startNewSession() {
        sessionInputTokens = 0
        sessionOutputTokens = 0
        sessionCacheWriteTokens = 0
        sessionCacheReadTokens = 0
        sessionCallCount = 0
    }

    mutating func record(_ usage: TokenUsage) {
        rollDayIfNeeded()
        dayInputTokens += usage.inputTokens
        dayOutputTokens += usage.outputTokens
        dayCacheWriteTokens += usage.cacheWriteTokens
        dayCacheReadTokens += usage.cacheReadTokens
        dayCallCount += 1

        sessionInputTokens += usage.inputTokens
        sessionOutputTokens += usage.outputTokens
        sessionCacheWriteTokens += usage.cacheWriteTokens
        sessionCacheReadTokens += usage.cacheReadTokens
        sessionCallCount += 1
    }

    private func dollars(input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
        Double(input)      / 1_000_000 * LanguageService.inputPricePerMTok
      + Double(output)     / 1_000_000 * LanguageService.outputPricePerMTok
      + Double(cacheWrite) / 1_000_000 * LanguageService.cacheWritePricePerMTok
      + Double(cacheRead)  / 1_000_000 * LanguageService.cacheReadPricePerMTok
    }

    var todayCost: Double {
        isStale ? 0 : dollars(input: dayInputTokens, output: dayOutputTokens,
                              cacheWrite: dayCacheWriteTokens, cacheRead: dayCacheReadTokens)
    }

    var sessionCost: Double {
        dollars(input: sessionInputTokens, output: sessionOutputTokens,
                cacheWrite: sessionCacheWriteTokens, cacheRead: sessionCacheReadTokens)
    }

    /// Share of input tokens that came from cache — the number that says whether the cached
    /// prompt prefixes are actually holding.
    var cacheHitRate: Double {
        let total = dayInputTokens + dayCacheWriteTokens + dayCacheReadTokens
        guard total > 0 else { return 0 }
        return Double(dayCacheReadTokens) / Double(total)
    }
}

/// Spend past this in one day and the app says so on every screen.
let dailyCostWarningThreshold: Double = 5.00

func formattedCost(_ dollars: Double) -> String {
    if dollars > 0 && dollars < 0.01 { return "<$0.01" }
    return String(format: "$%.2f", dollars)
}

// MARK: - Expression Lesson (ephemeral drill-down from a Produce critique)

/// One "write this yourself" exercise attached to an ExpressionLesson. The reference answer
/// comes down with the lesson so the UI can reveal it after grading without a second call.
struct ExpressionDrill: Identifiable {
    let id = UUID()
    let englishPrompt: String    // what to express, in English
    let hint: String             // short nudge, e.g. "you'll need a time phrase"
    let referenceAnswer: String  // a model answer in the target language
}

/// What a learner gets when they tap one expression in a Produce critique: the short
/// version of the rule, then immediate practice. Deliberately capped — the critique row is
/// a headline, this is a paragraph and three drills, not an essay.
struct ExpressionLesson {
    let expression: String   // the expression as the learner used it
    let better: String       // the replacement, empty when their choice was already right
    let headline: String     // one line: what this pattern does
    let explanation: String  // 2-3 sentences of why
    let contrast: String     // the near-miss it is confused with, empty if none
    let drills: [ExpressionDrill]
}

struct ExpressionDrillResult {
    let isCorrect: Bool
    let feedback: String        // one or two sentences
    let correctedAnswer: String // empty when the learner's answer stands on its own
}

// MARK: - Evaluation Result (ephemeral, not persisted)

struct SentenceEvaluationResult {
    let score: Int
    let feedback: String
    let toneReminders: [String]
    let phonemeHints: [String]
    let correctTranslation: String
    let alternativeTranslations: [String]   // other equally valid phrasings
    let wordExplanations: [WordExplanation] // tappable word → explanation pairs
    let grammarIssues: [String]   // closed-vocabulary category keys from the LLM
}

// MARK: - XP Helpers

func levelForXP(_ xp: Int) -> Int {
    var level = 1
    while xp >= 100 * (level + 1) * (level + 1) {
        level += 1
    }
    return min(level, 50)
}

func xpToNextLevel(currentXP: Int, currentLevel: Int) -> Int {
    let nextLevelXP = 100 * (currentLevel + 1) * (currentLevel + 1)
    return max(0, nextLevelXP - currentXP)
}

func xpForLevel(_ level: Int) -> Int {
    return 100 * level * level
}

// MARK: - Date Helpers

func isoDateString(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: date)
}

func todayISOString() -> String {
    isoDateString(Date())
}

func yesterdayISOString() -> String {
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    return isoDateString(yesterday)
}
