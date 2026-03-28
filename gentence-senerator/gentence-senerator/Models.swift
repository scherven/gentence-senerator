import Foundation

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

    // Memberwise initializer (allows call sites to omit grammarIssues)
    init(id: UUID = UUID(), sentenceID: UUID, transcript: String, score: Int,
         feedback: String, toneReminders: [String], phonemeHints: [String],
         correctTranslation: String, attemptNumber: Int, createdAt: Date = Date(),
         audioFilename: String? = nil, grammarIssues: [String] = []) {
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
        grammarIssues      = (try? c.decodeIfPresent([String].self, forKey: .grammarIssues)) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, sentenceID, transcript, score, feedback, toneReminders,
             phonemeHints, correctTranslation, attemptNumber, createdAt,
             audioFilename, grammarIssues
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

    init(id: UUID = UUID(), englishText: String, targetLanguage: String, difficultyLevel: Int) {
        self.id = id
        self.englishText = englishText
        self.targetLanguage = targetLanguage
        self.difficultyLevel = difficultyLevel
        self.createdAt = Date()
        self.attempts = []
        self.bestScore = nil
        self.status = .pending
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
    // grammarFocusAreas moved to LanguageProfile — kept here only for one-time migration
    var grammarFocusAreas: [String] = []
}

// MARK: - Evaluation Result (ephemeral, not persisted)

struct SentenceEvaluationResult {
    let score: Int
    let feedback: String
    let toneReminders: [String]
    let phonemeHints: [String]
    let correctTranslation: String
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
