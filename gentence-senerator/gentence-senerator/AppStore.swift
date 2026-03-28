import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {

    // MARK: - Published State

    @Published var profile: UserProfile = UserProfile()
    @Published var settings: AppSettings = AppSettings()
    @Published var todaySession: DailySession?
    @Published var todaySentences: [Sentence] = []

    @Published var currentSentenceIndex: Int = 0
    @Published var practicePhase: PracticePhase = .idle
    @Published var lastEvaluation: SentenceEvaluationResult?
    @Published var isLoadingAI: Bool = false
    @Published var errorMessage: String?
    @Published var newlyUnlockedBadges: [Badge] = []
    @Published var xpJustEarned: Int = 0
    @Published var isEndlessMode: Bool = false
    @Published var pendingTranscript: String = ""

    // MARK: - Services

    let openAI = OpenAIService()
    let speech = SpeechService()

    // MARK: - UserDefaults Keys

    private let profileKey = "userProfile_v1"
    private let settingsKey = "appSettings_v1"
    private let sessionsKey = "dailySessions_v1"
    private let sentencesKey = "sentences_v1"

    // MARK: - Init

    init() {
        load()
    }

    // MARK: - Computed Properties

    var currentSentence: Sentence? {
        guard currentSentenceIndex < todaySentences.count else { return nil }
        return todaySentences[currentSentenceIndex]
    }

    var todayCompletedCount: Int {
        todaySentences.filter { $0.status == .complete }.count
    }

    var todayGoal: Int { settings.dailyGoal }

    var averageScore: Double {
        guard !profile.recentScores.isEmpty else { return 0 }
        return Double(profile.recentScores.reduce(0, +)) / Double(profile.recentScores.count)
    }

    var xpForCurrentLevel: Int { xpForLevel(profile.currentLevel) }
    var xpForNextLevel: Int { xpForLevel(profile.currentLevel + 1) }
    var xpProgressInLevel: Int { profile.totalXP - xpForCurrentLevel }
    var xpNeededForNextLevel: Int { xpForNextLevel - xpForCurrentLevel }
    var levelProgress: Double {
        guard xpNeededForNextLevel > 0 else { return 1.0 }
        return Double(xpProgressInLevel) / Double(xpNeededForNextLevel)
    }

    // MARK: - Session Management

    func prepareOrResumeTodaySession() async {
        let today = todayISOString()

        // Check if today's session already exists in our sentences
        if let session = todaySession, session.id == today {
            if session.isComplete {
                practicePhase = .sessionComplete
            } else {
                resumeSession()
            }
            return
        }

        // Try to load from UserDefaults
        let sessions = loadSessions()
        if let existing = sessions.first(where: { $0.id == today }) {
            todaySession = existing
            let allSentences = loadSentences()
            todaySentences = allSentences.filter { existing.sentenceIDs.contains($0.id) }
                .sorted { lhs, rhs in
                    let lIdx = existing.sentenceIDs.firstIndex(of: lhs.id) ?? 0
                    let rIdx = existing.sentenceIDs.firstIndex(of: rhs.id) ?? 0
                    return lIdx < rIdx
                }
            if existing.isComplete {
                practicePhase = .sessionComplete
            } else {
                resumeSession()
            }
            return
        }

        // Generate new session
        await generateDailySentences()
    }

    private func resumeSession() {
        // Find first incomplete sentence
        currentSentenceIndex = todaySentences.firstIndex(where: { $0.status != .complete }) ?? 0
        practicePhase = .readyToRecord
    }

    func generateDailySentences() async {
        practicePhase = .generatingSentences
        isLoadingAI = true
        defer { isLoadingAI = false }

        let today = todayISOString()
        let n = settings.dailyGoal
        let language = settings.targetLanguage
        let difficulty = profile.currentDifficultyLevel
        let recent = Array(profile.seenSentenceTexts.suffix(50))

        var newSentences: [Sentence] = []

        for _ in 0..<n {
            do {
                let text = try await openAI.generateSentence(
                    difficulty: difficulty,
                    targetLanguage: language,
                    excludingTexts: recent + newSentences.map(\.englishText),
                    grammarFocusAreas: settings.grammarFocusAreas
                )
                let sentence = Sentence(
                    englishText: text,
                    targetLanguage: language,
                    difficultyLevel: difficulty
                )
                newSentences.append(sentence)
            } catch {
                practicePhase = .error("Failed to generate sentences: \(error.localizedDescription)")
                return
            }
        }

        todaySentences = newSentences

        // Add to seen list (cap at 200)
        profile.seenSentenceTexts.append(contentsOf: newSentences.map(\.englishText))
        if profile.seenSentenceTexts.count > 200 {
            profile.seenSentenceTexts = Array(profile.seenSentenceTexts.suffix(200))
        }

        let session = DailySession(
            id: today,
            date: Date(),
            sentenceIDs: newSentences.map(\.id),
            completedIDs: [],
            isComplete: false,
            totalXPEarned: 0
        )
        todaySession = session

        saveSentences(newSentences)
        saveSession(session)
        save()

        currentSentenceIndex = 0
        practicePhase = .readyToRecord
    }

    // MARK: - Practice Flow

    func startRecording() {
        guard practicePhase == .readyToRecord else { return }
        do {
            try speech.startRecording(language: settings.targetLanguage)
            practicePhase = .recording
        } catch {
            practicePhase = .error(error.localizedDescription)
        }
    }

    func stopAndReview() async {
        guard practicePhase == .recording else { return }
        practicePhase = .transcribing

        let transcript = await speech.stopRecording()
        pendingTranscript = transcript
        practicePhase = .reviewingTranscription
    }

    func submitForEvaluation() async {
        guard practicePhase == .reviewingTranscription else { return }
        practicePhase = .evaluating

        guard let sentence = currentSentence else {
            practicePhase = .error("No current sentence found.")
            return
        }

        let transcript = pendingTranscript
        let attemptNumber = sentence.attemptCount + 1

        do {
            let result = try await openAI.evaluateAttempt(
                englishSentence: sentence.englishText,
                transcript: transcript.isEmpty ? "[no speech detected]" : transcript,
                language: settings.targetLanguage,
                attemptNumber: attemptNumber
            )

            lastEvaluation = result

            let attempt = Attempt(
                id: UUID(),
                sentenceID: sentence.id,
                transcript: transcript,
                score: result.score,
                feedback: result.feedback,
                toneReminders: result.toneReminders,
                phonemeHints: result.phonemeHints,
                attemptNumber: attemptNumber,
                createdAt: Date()
            )

            processAttemptResult(attempt: attempt, result: result)

        } catch {
            practicePhase = .error("Evaluation failed: \(error.localizedDescription)")
        }
    }

    func reRecord() {
        guard practicePhase == .reviewingTranscription else { return }
        pendingTranscript = ""
        speech.resetTranscript()
        practicePhase = .readyToRecord
    }

    private func processAttemptResult(attempt: Attempt, result: SentenceEvaluationResult) {
        guard currentSentenceIndex < todaySentences.count else { return }

        todaySentences[currentSentenceIndex].attempts.append(attempt)

        let previousBest = todaySentences[currentSentenceIndex].bestScore
        if let prev = previousBest {
            if attempt.score > prev {
                todaySentences[currentSentenceIndex].bestScore = attempt.score
                // Track retry improvement
                if attempt.attemptNumber > 1 {
                    profile.retryImprovements += 1
                }
            }
        } else {
            todaySentences[currentSentenceIndex].bestScore = attempt.score
        }

        // Award XP
        let xp = calculateXP(score: result.score, attemptNumber: attempt.attemptNumber)
        awardXP(xp)
        xpJustEarned = xp

        // Update difficulty tracking
        updateDifficulty(with: result.score)

        // Check badges
        let newBadges = checkAndAwardBadges()
        newlyUnlockedBadges = newBadges

        // Save sentences
        saveSentences(todaySentences)
        save()

        practicePhase = .showingFeedback(score: result.score)
    }

    func advanceToNextSentence() {
        guard currentSentenceIndex < todaySentences.count else { return }

        // Mark current sentence complete
        todaySentences[currentSentenceIndex].status = .complete

        // Mark in session
        if var session = todaySession {
            if !session.completedIDs.contains(todaySentences[currentSentenceIndex].id) {
                session.completedIDs.append(todaySentences[currentSentenceIndex].id)
            }
            todaySession = session
            saveSession(session)
        }

        profile.totalSentencesCompleted += 1
        saveSentences(todaySentences)
        save()

        let nextIndex = currentSentenceIndex + 1
        if nextIndex >= todaySentences.count {
            if isEndlessMode {
                Task { await generateAndContinue() }
            } else {
                completeSession()
            }
        } else {
            currentSentenceIndex = nextIndex
            speech.resetTranscript()
            pendingTranscript = ""
            lastEvaluation = nil
            newlyUnlockedBadges = []
            xpJustEarned = 0
            practicePhase = .readyToRecord
        }
    }

    func retryCurrentSentence() {
        guard let sentence = currentSentence, sentence.canRetry else { return }
        speech.resetTranscript()
        pendingTranscript = ""
        lastEvaluation = nil
        newlyUnlockedBadges = []
        xpJustEarned = 0
        practicePhase = .readyToRecord
    }

    func setDifficulty(_ level: Int) {
        profile.currentDifficultyLevel = min(10, max(1, level))
        settings.difficultyLocked = true
        save()
    }

    /// Evaluate a typed (rather than spoken) input — routes through review screen so user can see pinyin.
    func evaluateTypedInput(transcript: String) async {
        guard practicePhase == .readyToRecord else { return }
        pendingTranscript = transcript
        practicePhase = .reviewingTranscription
    }

    func completeSession() {
        guard var session = todaySession else { return }

        session.isComplete = true

        // Completion bonus XP
        let bonus = 50 + (profile.currentStreak * 5)
        awardXP(bonus)
        session.totalXPEarned = todaySentences.compactMap(\.bestScore).reduce(0, +)

        todaySession = session
        updateStreak()

        let newBadges = checkAndAwardBadges()
        newlyUnlockedBadges.append(contentsOf: newBadges)

        saveSession(session)
        save()

        practicePhase = .sessionComplete
    }

    // MARK: - Endless Mode

    func startEndlessMode() async {
        isEndlessMode = true
        newlyUnlockedBadges = []
        await generateAndContinue()
    }

    private func generateAndContinue() async {
        practicePhase = .generatingSentences
        await generateAdditionalSentences(count: 1)
        guard case .generatingSentences = practicePhase else { return } // error check
        currentSentenceIndex = todaySentences.count - 1
        speech.resetTranscript()
        lastEvaluation = nil
        newlyUnlockedBadges = []
        xpJustEarned = 0
        practicePhase = .readyToRecord
    }

    private func generateAdditionalSentences(count: Int) async {
        let language = settings.targetLanguage
        let difficulty = profile.currentDifficultyLevel
        let recent = Array(profile.seenSentenceTexts.suffix(50))

        var newSentences: [Sentence] = []
        for _ in 0..<count {
            do {
                let text = try await openAI.generateSentence(
                    difficulty: difficulty,
                    targetLanguage: language,
                    excludingTexts: recent + todaySentences.map(\.englishText) + newSentences.map(\.englishText),
                    grammarFocusAreas: settings.grammarFocusAreas
                )
                let sentence = Sentence(englishText: text, targetLanguage: language, difficultyLevel: difficulty)
                newSentences.append(sentence)
            } catch {
                practicePhase = .error("Failed to generate sentence: \(error.localizedDescription)")
                return
            }
        }

        todaySentences.append(contentsOf: newSentences)
        profile.seenSentenceTexts.append(contentsOf: newSentences.map(\.englishText))
        if profile.seenSentenceTexts.count > 200 {
            profile.seenSentenceTexts = Array(profile.seenSentenceTexts.suffix(200))
        }
        saveSentences(newSentences)
        save()
    }

    func resetForNewDay() {
        currentSentenceIndex = 0
        todaySentences = []
        todaySession = nil
        lastEvaluation = nil
        newlyUnlockedBadges = []
        xpJustEarned = 0
        isEndlessMode = false
        practicePhase = .idle
    }

    // MARK: - XP & Gamification

    private func calculateXP(score: Int, attemptNumber: Int) -> Int {
        let baseXP = score / 5
        let diffMult = 1.0 + Double(profile.currentDifficultyLevel - 1) * 0.15
        let attemptPenalty: Double
        switch attemptNumber {
        case 1: attemptPenalty = 1.0
        case 2: attemptPenalty = 0.7
        default: attemptPenalty = 0.5
        }
        let streakBonus: Double
        switch profile.currentStreak {
        case 0..<3: streakBonus = 1.0
        case 3..<7: streakBonus = 1.1
        case 7..<14: streakBonus = 1.25
        case 14..<30: streakBonus = 1.5
        default: streakBonus = 2.0
        }
        let xp = Int(Double(baseXP) * diffMult * attemptPenalty * streakBonus)
        return max(1, xp)
    }

    private func awardXP(_ xp: Int) {
        profile.totalXP += xp
        profile.currentLevel = levelForXP(profile.totalXP)
    }

    private func updateDifficulty(with score: Int) {
        profile.recentScores.append(score)
        if profile.recentScores.count > 10 {
            profile.recentScores.removeFirst()
        }

        guard profile.recentScores.count >= 5 else { return }
        guard !settings.difficultyLocked else { return }

        let avg = Double(profile.recentScores.reduce(0, +)) / Double(profile.recentScores.count)
        let current = profile.currentDifficultyLevel

        let newLevel: Int
        switch avg {
        case 90...: newLevel = min(10, current + 2)
        case 80..<90: newLevel = min(10, current + 1)
        case 65..<80: newLevel = current
        case 50..<65: newLevel = max(1, current - 1)
        default: newLevel = max(1, current - 2)
        }

        if newLevel != current {
            profile.currentDifficultyLevel = newLevel
            profile.recentScores = []
        }
    }

    private func updateStreak() {
        let today = todayISOString()
        let yesterday = yesterdayISOString()

        guard let last = profile.lastCompletedDate else {
            profile.currentStreak = 1
            profile.longestStreak = max(1, profile.longestStreak)
            profile.lastCompletedDate = today
            return
        }

        if last == today { return }

        if last == yesterday {
            profile.currentStreak += 1
        } else {
            profile.currentStreak = 1
        }
        profile.longestStreak = max(profile.longestStreak, profile.currentStreak)
        profile.lastCompletedDate = today
    }

    @discardableResult
    private func checkAndAwardBadges() -> [Badge] {
        var newBadges: [Badge] = []
        let unlockedIDs = Set(profile.unlockedBadges.map(\.id))

        func unlock(_ def: BadgeDefinition) {
            guard !unlockedIDs.contains(def.rawValue) else { return }
            let badge = Badge(
                id: def.rawValue,
                name: def.name,
                description: def.description,
                iconSystemName: def.iconSystemName,
                unlockedAt: Date()
            )
            profile.unlockedBadges.append(badge)
            newBadges.append(badge)
        }

        if profile.totalSentencesCompleted >= 1 { unlock(.firstSentence) }
        if todaySentences.compactMap(\.bestScore).contains(100) { unlock(.perfectScore) }
        if profile.currentStreak >= 3 { unlock(.day3Streak) }
        if profile.currentStreak >= 7 { unlock(.day7Streak) }
        if profile.currentStreak >= 30 { unlock(.day30Streak) }
        if profile.currentLevel >= 5 { unlock(.level5) }
        if profile.currentLevel >= 10 { unlock(.level10) }
        if profile.currentLevel >= 25 { unlock(.level25) }
        if profile.recentScores.count >= 10 && averageScore >= 50 { unlock(.score50Avg) }
        if profile.recentScores.count >= 10 && averageScore >= 75 { unlock(.score75Avg) }
        if profile.currentDifficultyLevel >= 5 { unlock(.difficulty5) }
        if profile.currentDifficultyLevel >= 10 { unlock(.difficulty10) }
        if profile.totalSentencesCompleted >= 100 { unlock(.sentences100) }
        if profile.retryImprovements >= 10 { unlock(.retryImprover) }

        return newBadges
    }

    // MARK: - Settings

    func updateLanguage(_ language: String) {
        settings.targetLanguage = language
        profile.selectedLanguage = language
        save()
    }

    func updateDailyGoal(_ goal: Int) {
        settings.dailyGoal = goal
        profile.dailySentenceGoal = goal
        save()
    }

    func resetProgress() {
        profile = UserProfile()
        settings = AppSettings()
        todaySession = nil
        todaySentences = []
        currentSentenceIndex = 0
        practicePhase = .idle
        lastEvaluation = nil
        newlyUnlockedBadges = []
        xpJustEarned = 0

        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.removeObject(forKey: settingsKey)
        UserDefaults.standard.removeObject(forKey: sessionsKey)
        UserDefaults.standard.removeObject(forKey: sentencesKey)
    }

    // MARK: - Persistence

    func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
        }
        if let data = try? encoder.encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: profileKey),
           let saved = try? decoder.decode(UserProfile.self, from: data) {
            profile = saved
        }
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let saved = try? decoder.decode(AppSettings.self, from: data) {
            settings = saved
        }
    }

    private func loadSessions() -> [DailySession] {
        guard let data = UserDefaults.standard.data(forKey: sessionsKey),
              let sessions = try? JSONDecoder().decode([DailySession].self, from: data) else {
            return []
        }
        return sessions
    }

    private func saveSession(_ session: DailySession) {
        var sessions = loadSessions()
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.append(session)
        }
        // Keep only last 30 sessions
        if sessions.count > 30 {
            sessions = Array(sessions.suffix(30))
        }
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: sessionsKey)
        }
    }

    func loadSentences() -> [Sentence] {
        guard let data = UserDefaults.standard.data(forKey: sentencesKey),
              let sentences = try? JSONDecoder().decode([Sentence].self, from: data) else {
            return []
        }
        return sentences
    }

    func saveSentences(_ sentences: [Sentence]) {
        var all = loadSentences()
        for sentence in sentences {
            if let idx = all.firstIndex(where: { $0.id == sentence.id }) {
                all[idx] = sentence
            } else {
                all.append(sentence)
            }
        }
        // Keep only last 500
        if all.count > 500 {
            all = Array(all.suffix(500))
        }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: sentencesKey)
        }
    }

    func allSessions() -> [DailySession] {
        loadSessions()
    }

    func allSentences() -> [Sentence] {
        loadSentences()
    }
}
