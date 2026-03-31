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
    @Published var pendingAudioURL: URL?
    @Published var isCachingOffline: Bool = false
    @Published var isRetryMode: Bool = false

    private var retryOriginalSentence: Sentence?
    /// In-flight Azure pronunciation assessment task, started during stopAndReview()
    /// so it can complete while the user reviews the transcript.
    private var pendingAzureTask: Task<PronunciationAssessment?, Never>?

    // MARK: - Services

    let openAI = OpenAIService()          // generic fallback (Spanish, Italian, etc.)
    private let mandarinService = MandarinService()
    private let germanService   = GermanService()
    private let frenchService   = FrenchService()
    let speech = SpeechService()
    private let azureService = AzureSpeechService()

    /// Returns the language-specialised service for the active target language,
    /// falling back to the generic OpenAIService for languages without a dedicated service.
    var languageService: OpenAIService {
        switch settings.targetLanguage {
        case "Mandarin": return mandarinService
        case "German":   return germanService
        case "French":   return frenchService
        default:         return openAI
        }
    }

    // MARK: - UserDefaults Keys

    private let profileKey = "userProfile_v1"
    private let settingsKey = "appSettings_v1"
    private let sessionsKey = "dailySessions_v1"
    private let sentencesKey = "sentences_v1"
    private let sentenceCacheKey = "sentenceCache_v1"

    // MARK: - Init

    init() {
        load()
    }

    // MARK: - Per-Language Profile Accessor

    /// Computed get/set for the active language's progress.
    /// Because `profile` is a @Published struct, assigning to its nested dict triggers SwiftUI re-render.
    var currentLangProfile: LanguageProfile {
        get { profile.languageProfiles[settings.targetLanguage] ?? LanguageProfile() }
        set { profile.languageProfiles[settings.targetLanguage] = newValue }
    }

    // MARK: - Computed Properties

    var currentSentence: Sentence? {
        guard currentSentenceIndex < todaySentences.count else { return nil }
        return todaySentences[currentSentenceIndex]
    }

    var todayCompletedCount: Int {
        todaySentences.filter { $0.status == .complete }.count
    }

    var todayGoal: Int { currentLangProfile.dailySentenceGoal }

    var averageScore: Double {
        guard !currentLangProfile.recentScores.isEmpty else { return 0 }
        return Double(currentLangProfile.recentScores.reduce(0, +)) / Double(currentLangProfile.recentScores.count)
    }

    var xpForCurrentLevel: Int { xpForLevel(currentLangProfile.currentLevel) }
    var xpForNextLevel: Int { xpForLevel(currentLangProfile.currentLevel + 1) }
    var xpProgressInLevel: Int { currentLangProfile.totalXP - xpForCurrentLevel }
    var xpNeededForNextLevel: Int { xpForNextLevel - xpForCurrentLevel }
    var levelProgress: Double {
        guard xpNeededForNextLevel > 0 else { return 1.0 }
        return Double(xpProgressInLevel) / Double(xpNeededForNextLevel)
    }

    // MARK: - Session Management

    func prepareOrResumeTodaySession() async {
        let sessionID = todaySessionID()

        // Check if today's session for this language is already loaded
        if let session = todaySession, session.id == sessionID {
            if session.isComplete {
                practicePhase = .sessionComplete
            } else {
                resumeSession()
            }
            return
        }

        // Try to load from UserDefaults
        let sessions = loadSessions()
        if let existing = sessions.first(where: { $0.id == sessionID }) {
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
        currentSentenceIndex = todaySentences.firstIndex(where: { $0.status != .complete }) ?? 0
        practicePhase = .readyToRecord
    }

    func generateDailySentences() async {
        practicePhase = .generatingSentences
        isLoadingAI = true
        defer { isLoadingAI = false }

        let sessionID = todaySessionID()
        let n = currentLangProfile.dailySentenceGoal
        let language = settings.targetLanguage
        let difficulty = currentLangProfile.currentDifficultyLevel
        let recent = Array(currentLangProfile.seenSentenceTexts.suffix(50))
        let isListening = settings.practiceMode == .listening

        var newSentences: [Sentence] = []
        let batchSize = 5

        var remaining = n
        while remaining > 0 {
            let batchCount = min(batchSize, remaining)
            do {
                if isListening {
                    let pairs = try await languageService.generateListeningSentenceBatch(
                        count: batchCount,
                        difficulty: difficulty,
                        targetLanguage: language,
                        excludingTexts: recent + newSentences.map(\.englishText)
                    )
                    for (targetText, englishMeaning) in pairs {
                        newSentences.append(Sentence(
                            englishText: englishMeaning,
                            targetLanguage: language,
                            difficultyLevel: difficulty,
                            listeningTargetText: targetText
                        ))
                    }
                } else {
                    let texts = try await languageService.generateSentenceBatch(
                        count: batchCount,
                        difficulty: difficulty,
                        targetLanguage: language,
                        excludingTexts: recent + newSentences.map(\.englishText),
                        grammarFocusAreas: currentLangProfile.grammarFocusAreas
                    )
                    for text in texts {
                        newSentences.append(Sentence(
                            englishText: text,
                            targetLanguage: language,
                            difficultyLevel: difficulty
                        ))
                    }
                }
                remaining = n - newSentences.count
            } catch let error as OpenAIError {
                if case .networkError = error {
                    // Offline: fill remaining slots from cache
                    let needed = n - newSentences.count
                    let cached = popCachedSentences(count: needed, language: language, difficulty: difficulty)
                    newSentences.append(contentsOf: cached)
                    if newSentences.isEmpty {
                        practicePhase = .error("You're offline and have no cached sentences. Download some in Settings → Offline Mode.")
                        return
                    }
                    break  // use what we have
                } else {
                    practicePhase = .error("Failed to generate sentences: \(error.localizedDescription)")
                    return
                }
            } catch {
                practicePhase = .error("Failed to generate sentences: \(error.localizedDescription)")
                return
            }
        }

        todaySentences = newSentences

        // Update seen sentence list (cap at 200)
        currentLangProfile.seenSentenceTexts.append(contentsOf: newSentences.map(\.englishText))
        if currentLangProfile.seenSentenceTexts.count > 200 {
            currentLangProfile.seenSentenceTexts = Array(currentLangProfile.seenSentenceTexts.suffix(200))
        }

        let session = DailySession(
            id: sessionID,
            date: Date(),
            sentenceIDs: newSentences.map(\.id),
            completedIDs: [],
            isComplete: false,
            totalXPEarned: 0,
            targetLanguage: language
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
        pendingAudioURL = speech.lastRecordingURL
        practicePhase = .reviewingTranscription

        // Fire Azure pronunciation assessment immediately (Mandarin only) so it can
        // complete in the background while the user reviews the transcript.
        if settings.targetLanguage == "Mandarin", let audioURL = speech.lastRecordingURL {
            // Use the listening target text if available; otherwise fall back to the transcript.
            // For translation mode we'll use the LLM's correctTranslation in processAttemptResult,
            // but we need something now — the transcript is the best available reference.
            let referenceText = currentSentence?.listeningTargetText ?? transcript
            pendingAzureTask = Task {
                await azureService.assessPronunciation(audioURL: audioURL, referenceText: referenceText)
            }
        } else {
            pendingAzureTask = nil
        }
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
            let result = try await languageService.evaluateAttempt(
                englishSentence: sentence.englishText,
                transcript: transcript.isEmpty ? "[no speech detected]" : transcript,
                language: settings.targetLanguage,
                attemptNumber: attemptNumber,
                listeningTargetText: sentence.listeningTargetText
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
                correctTranslation: result.correctTranslation,
                attemptNumber: attemptNumber,
                createdAt: Date(),
                audioFilename: pendingAudioURL?.lastPathComponent,
                grammarIssues: result.grammarIssues
            )

            await processAttemptResult(attempt: attempt, result: result)

        } catch {
            practicePhase = .error("Evaluation failed: \(error.localizedDescription)")
        }
    }

    func reRecord() {
        guard practicePhase == .reviewingTranscription else { return }
        speech.stopSpeaking()
        pendingTranscript = ""
        pendingAudioURL = nil
        speech.resetTranscript()
        practicePhase = .readyToRecord
    }

    private func processAttemptResult(attempt: Attempt, result: SentenceEvaluationResult) async {
        guard currentSentenceIndex < todaySentences.count else { return }

        // Await Azure assessment (should already be done since user spent time on transcript review)
        var finalAttempt = attempt
        if let azureTask = pendingAzureTask {
            let assessment = await azureTask.value
            finalAttempt.pronunciationAssessment = assessment
            pendingAzureTask = nil
            // Track pronunciation scores in language profile
            if let a = assessment {
                currentLangProfile.recentToneScores.append(a.toneScore)
                if currentLangProfile.recentToneScores.count > 10 {
                    currentLangProfile.recentToneScores.removeFirst()
                }
                currentLangProfile.recentPronunciationScores.append(a.overallScore)
                if currentLangProfile.recentPronunciationScores.count > 10 {
                    currentLangProfile.recentPronunciationScores.removeFirst()
                }
            }
        }

        todaySentences[currentSentenceIndex].attempts.append(finalAttempt)

        let previousBest = todaySentences[currentSentenceIndex].bestScore
        if let prev = previousBest {
            if finalAttempt.score > prev {
                todaySentences[currentSentenceIndex].bestScore = finalAttempt.score
                if finalAttempt.attemptNumber > 1 {
                    currentLangProfile.retryImprovements += 1
                }
            }
        } else {
            todaySentences[currentSentenceIndex].bestScore = finalAttempt.score
        }

        // Award XP
        let xp = calculateXP(score: result.score, attemptNumber: finalAttempt.attemptNumber)
        awardXP(xp)
        xpJustEarned = xp

        // Update difficulty tracking
        updateDifficulty(with: result.score)

        // Check badges
        let newBadges = checkAndAwardBadges()
        newlyUnlockedBadges = newBadges

        // In retry mode, merge the new attempt into the original stored sentence
        // (the in-memory copy has cleared attempts, so we persist to the real record)
        if isRetryMode, var original = retryOriginalSentence {
            original.attempts.append(finalAttempt)
            if let prev = original.bestScore {
                if finalAttempt.score > prev { original.bestScore = finalAttempt.score }
            } else {
                original.bestScore = finalAttempt.score
            }
            retryOriginalSentence = original
            saveSentences([original])
        } else {
            saveSentences(todaySentences)
        }
        save()

        practicePhase = .showingFeedback(score: result.score)
    }

    func advanceToNextSentence() {
        guard currentSentenceIndex < todaySentences.count else { return }

        // Mark current sentence complete
        todaySentences[currentSentenceIndex].status = .complete

        if var session = todaySession {
            if !session.completedIDs.contains(todaySentences[currentSentenceIndex].id) {
                session.completedIDs.append(todaySentences[currentSentenceIndex].id)
            }
            todaySession = session
            saveSession(session)
        }

        currentLangProfile.totalSentencesCompleted += 1
        saveSentences(todaySentences)
        save()

        let nextIndex = currentSentenceIndex + 1
        if nextIndex >= todaySentences.count {
            speech.stopSpeaking()
            if isRetryMode {
                practicePhase = .sessionComplete
            } else if isEndlessMode {
                Task { await generateAndContinue() }
            } else {
                completeSession()
            }
        } else {
            speech.stopSpeaking()
            currentSentenceIndex = nextIndex
            speech.resetTranscript()
            pendingTranscript = ""
            pendingAudioURL = nil
            lastEvaluation = nil
            newlyUnlockedBadges = []
            xpJustEarned = 0
            practicePhase = .readyToRecord
        }
    }

    func retryCurrentSentence() {
        guard let sentence = currentSentence, sentence.canRetry else { return }
        speech.stopSpeaking()
        speech.resetTranscript()
        pendingTranscript = ""
        pendingAudioURL = nil
        lastEvaluation = nil
        newlyUnlockedBadges = []
        xpJustEarned = 0
        practicePhase = .readyToRecord
    }

    func setDifficulty(_ level: Int) {
        currentLangProfile.currentDifficultyLevel = min(10, max(1, level))
        currentLangProfile.difficultyLocked = true
        settings.difficultyLocked = true
        save()
        // Regenerate sentences at the new difficulty level
        todaySession = nil
        todaySentences = []
        currentSentenceIndex = 0
        practicePhase = .idle
        lastEvaluation = nil
        pendingTranscript = ""
        pendingAudioURL = nil
        Task { await generateDailySentences() }
    }

    func setDifficultyLocked(_ locked: Bool) {
        settings.difficultyLocked = locked
        currentLangProfile.difficultyLocked = locked
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

        let bonus = 50 + (currentLangProfile.currentStreak * 5)
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
        guard case .generatingSentences = practicePhase else { return }
        currentSentenceIndex = todaySentences.count - 1
        speech.resetTranscript()
        lastEvaluation = nil
        newlyUnlockedBadges = []
        xpJustEarned = 0
        practicePhase = .readyToRecord
    }

    private func generateAdditionalSentences(count: Int) async {
        let language = settings.targetLanguage
        let difficulty = currentLangProfile.currentDifficultyLevel
        let recent = Array(currentLangProfile.seenSentenceTexts.suffix(50))
        let isListening = settings.practiceMode == .listening

        var newSentences: [Sentence] = []
        for _ in 0..<count {
            do {
                let sentence: Sentence
                if isListening {
                    let (targetText, englishMeaning) = try await languageService.generateListeningSentence(
                        difficulty: difficulty,
                        targetLanguage: language,
                        excludingTexts: recent + todaySentences.map(\.englishText)
                    )
                    sentence = Sentence(
                        englishText: englishMeaning,
                        targetLanguage: language,
                        difficultyLevel: difficulty,
                        listeningTargetText: targetText
                    )
                } else {
                    let text = try await languageService.generateSentence(
                        difficulty: difficulty,
                        targetLanguage: language,
                        excludingTexts: recent + todaySentences.map(\.englishText),
                        sessionTexts: newSentences.map(\.englishText),
                        grammarFocusAreas: currentLangProfile.grammarFocusAreas
                    )
                    sentence = Sentence(englishText: text, targetLanguage: language, difficultyLevel: difficulty)
                }
                newSentences.append(sentence)
            } catch let error as OpenAIError {
                if case .networkError = error {
                    let cached = popCachedSentences(count: count - newSentences.count, language: language, difficulty: difficulty)
                    newSentences.append(contentsOf: cached)
                    if newSentences.isEmpty {
                        practicePhase = .error("You're offline and have no cached sentences.")
                        return
                    }
                    break
                } else {
                    practicePhase = .error("Failed to generate sentence: \(error.localizedDescription)")
                    return
                }
            } catch {
                practicePhase = .error("Failed to generate sentence: \(error.localizedDescription)")
                return
            }
        }

        todaySentences.append(contentsOf: newSentences)
        currentLangProfile.seenSentenceTexts.append(contentsOf: newSentences.map(\.englishText))
        if currentLangProfile.seenSentenceTexts.count > 200 {
            currentLangProfile.seenSentenceTexts = Array(currentLangProfile.seenSentenceTexts.suffix(200))
        }
        saveSentences(newSentences)
        save()
    }

    // MARK: - Retry Mode

    func startRetrySession(sentence: Sentence) {
        isRetryMode = true
        retryOriginalSentence = sentence
        speech.stopSpeaking()
        if speech.isRecording { speech.cancelRecording() }
        // Use a fresh in-memory copy so canRetry is true and attempt counting starts at 0
        var fresh = sentence
        fresh.attempts = []
        fresh.bestScore = nil
        fresh.status = .pending
        todaySentences = [fresh]
        currentSentenceIndex = 0
        practicePhase = .readyToRecord
        lastEvaluation = nil
        pendingTranscript = ""
        pendingAudioURL = nil
        newlyUnlockedBadges = []
        xpJustEarned = 0
    }

    func endRetrySession() {
        isRetryMode = false
        retryOriginalSentence = nil
        todaySentences = []
        currentSentenceIndex = 0
        practicePhase = .idle
        lastEvaluation = nil
        pendingTranscript = ""
        pendingAudioURL = nil
        Task { await prepareOrResumeTodaySession() }
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

    // MARK: - Practice Mode

    /// Switches to `mode` and loads (or resumes) its session.
    /// No-op if the mode is already active, so it's safe to call on every tab appear.
    func activateMode(_ mode: PracticeMode) {
        guard mode != settings.practiceMode else { return }
        // Clean up any in-progress activity from the previous mode.
        speech.stopSpeaking()
        if speech.isRecording { speech.cancelRecording() }
        settings.practiceMode = mode
        todaySession = nil
        todaySentences = []
        currentSentenceIndex = 0
        practicePhase = .idle
        lastEvaluation = nil
        pendingTranscript = ""
        pendingAudioURL = nil
        save()
        Task { await prepareOrResumeTodaySession() }
    }

    // MARK: - Offline Sentence Cache

    /// Download and store `count` sentences for the current language + difficulty.
    func prefetchSentences(count: Int) async {
        guard !isCachingOffline else { return }
        isCachingOffline = true
        defer { isCachingOffline = false }

        let language = settings.targetLanguage
        let difficulty = currentLangProfile.currentDifficultyLevel
        let existingTexts = loadCache().map(\.englishText)
        let recent = Array(currentLangProfile.seenSentenceTexts.suffix(50))

        var fetched: [Sentence] = []
        let batchSize = 5
        var remaining = count
        while remaining > 0 {
            let batchCount = min(batchSize, remaining)
            do {
                let texts = try await languageService.generateSentenceBatch(
                    count: batchCount,
                    difficulty: difficulty,
                    targetLanguage: language,
                    excludingTexts: recent + existingTexts + fetched.map(\.englishText),
                    grammarFocusAreas: currentLangProfile.grammarFocusAreas
                )
                for text in texts {
                    fetched.append(Sentence(englishText: text, targetLanguage: language, difficultyLevel: difficulty))
                }
                remaining -= texts.count
                if texts.count < batchCount { break }  // API returned fewer than requested
            } catch {
                break  // stop on error, keep what we have
            }
        }

        if !fetched.isEmpty {
            var cache = loadCache()
            cache.append(contentsOf: fetched)
            saveCache(cache)
        }
    }

    func cachedSentenceCount(language: String, difficulty: Int) -> Int {
        loadCache().filter { $0.targetLanguage == language && $0.difficultyLevel == difficulty }.count
    }

    private func popCachedSentences(count: Int, language: String, difficulty: Int) -> [Sentence] {
        var cache = loadCache()
        let matching = cache.filter { $0.targetLanguage == language && $0.difficultyLevel == difficulty }
        let popped = Array(matching.prefix(count))
        let poppedIDs = Set(popped.map(\.id))
        cache.removeAll { poppedIDs.contains($0.id) }
        saveCache(cache)
        return popped
    }

    private func loadCache() -> [Sentence] {
        guard let data = UserDefaults.standard.data(forKey: sentenceCacheKey),
              let sentences = try? JSONDecoder().decode([Sentence].self, from: data) else {
            return []
        }
        return sentences
    }

    private func saveCache(_ sentences: [Sentence]) {
        var capped = sentences
        if capped.count > 500 { capped = Array(capped.suffix(500)) }
        if let data = try? JSONEncoder().encode(capped) {
            UserDefaults.standard.set(data, forKey: sentenceCacheKey)
        }
    }

    // MARK: - XP & Gamification

    private func calculateXP(score: Int, attemptNumber: Int) -> Int {
        let baseXP = score / 5
        let diffMult = 1.0 + Double(currentLangProfile.currentDifficultyLevel - 1) * 0.15
        let attemptPenalty: Double
        switch attemptNumber {
        case 1: attemptPenalty = 1.0
        case 2: attemptPenalty = 0.7
        default: attemptPenalty = 0.5
        }
        let streakBonus: Double
        switch currentLangProfile.currentStreak {
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
        currentLangProfile.totalXP += xp
        currentLangProfile.currentLevel = levelForXP(currentLangProfile.totalXP)
    }

    private func updateDifficulty(with score: Int) {
        currentLangProfile.recentScores.append(score)
        if currentLangProfile.recentScores.count > 10 {
            currentLangProfile.recentScores.removeFirst()
        }

        guard currentLangProfile.recentScores.count >= 5 else { return }
        guard !currentLangProfile.difficultyLocked else { return }

        let avg = Double(currentLangProfile.recentScores.reduce(0, +)) / Double(currentLangProfile.recentScores.count)
        let current = currentLangProfile.currentDifficultyLevel

        let newLevel: Int
        switch avg {
        case 90...: newLevel = min(10, current + 2)
        case 80..<90: newLevel = min(10, current + 1)
        case 65..<80: newLevel = current
        case 50..<65: newLevel = max(1, current - 1)
        default: newLevel = max(1, current - 2)
        }

        if newLevel != current {
            currentLangProfile.currentDifficultyLevel = newLevel
            currentLangProfile.recentScores = []
        }
    }

    private func updateStreak() {
        let today = todayISOString()
        let yesterday = yesterdayISOString()

        guard let last = currentLangProfile.lastCompletedDate else {
            currentLangProfile.currentStreak = 1
            currentLangProfile.longestStreak = max(1, currentLangProfile.longestStreak)
            currentLangProfile.lastCompletedDate = today
            return
        }

        if last == today { return }

        if last == yesterday {
            currentLangProfile.currentStreak += 1
        } else {
            currentLangProfile.currentStreak = 1
        }
        currentLangProfile.longestStreak = max(currentLangProfile.longestStreak, currentLangProfile.currentStreak)
        currentLangProfile.lastCompletedDate = today
    }

    @discardableResult
    private func checkAndAwardBadges() -> [Badge] {
        var newBadges: [Badge] = []
        let unlockedIDs = Set(currentLangProfile.unlockedBadges.map(\.id))

        func unlock(_ def: BadgeDefinition) {
            guard !unlockedIDs.contains(def.rawValue) else { return }
            let badge = Badge(
                id: def.rawValue,
                name: def.name,
                description: def.description,
                iconSystemName: def.iconSystemName,
                unlockedAt: Date()
            )
            currentLangProfile.unlockedBadges.append(badge)
            newBadges.append(badge)
        }

        if currentLangProfile.totalSentencesCompleted >= 1 { unlock(.firstSentence) }
        if todaySentences.compactMap(\.bestScore).contains(100) { unlock(.perfectScore) }
        if currentLangProfile.currentStreak >= 3 { unlock(.day3Streak) }
        if currentLangProfile.currentStreak >= 7 { unlock(.day7Streak) }
        if currentLangProfile.currentStreak >= 30 { unlock(.day30Streak) }
        if currentLangProfile.currentLevel >= 5 { unlock(.level5) }
        if currentLangProfile.currentLevel >= 10 { unlock(.level10) }
        if currentLangProfile.currentLevel >= 25 { unlock(.level25) }
        if currentLangProfile.recentScores.count >= 10 && averageScore >= 50 { unlock(.score50Avg) }
        if currentLangProfile.recentScores.count >= 10 && averageScore >= 75 { unlock(.score75Avg) }
        if currentLangProfile.currentDifficultyLevel >= 5 { unlock(.difficulty5) }
        if currentLangProfile.currentDifficultyLevel >= 10 { unlock(.difficulty10) }
        if currentLangProfile.totalSentencesCompleted >= 100 { unlock(.sentences100) }
        if currentLangProfile.retryImprovements >= 10 { unlock(.retryImprover) }

        return newBadges
    }

    // MARK: - Settings

    func switchLanguage(to language: String) {
        guard language != settings.targetLanguage else { return }
        settings.targetLanguage = language
        profile.selectedLanguage = language
        // Sync AppSettings mirrors from the incoming language profile
        let lp = profile.languageProfiles[language] ?? LanguageProfile()
        settings.dailyGoal = lp.dailySentenceGoal
        settings.difficultyLocked = lp.difficultyLocked
        // Reset in-progress session state
        todaySession = nil
        todaySentences = []
        currentSentenceIndex = 0
        practicePhase = .idle
        lastEvaluation = nil
        pendingTranscript = ""
        pendingAudioURL = nil
        save()
        Task { await prepareOrResumeTodaySession() }
    }

    func updateLanguage(_ language: String) {
        switchLanguage(to: language)
    }

    func updateDailyGoal(_ goal: Int) {
        settings.dailyGoal = goal
        currentLangProfile.dailySentenceGoal = goal
        save()
    }

    func setGrammarFocusAreas(_ areas: [String]) {
        currentLangProfile.grammarFocusAreas = areas
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
        UserDefaults.standard.removeObject(forKey: sentenceCacheKey)
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

        // One-time migration: lift legacy flat fields → Mandarin LanguageProfile
        if profile.languageProfiles.isEmpty {
            var lp = LanguageProfile()
            lp.currentDifficultyLevel  = profile.currentDifficultyLevel
            lp.dailySentenceGoal       = profile.dailySentenceGoal
            lp.grammarFocusAreas       = settings.grammarFocusAreas
            lp.totalXP                 = profile.totalXP
            lp.currentLevel            = profile.currentLevel
            lp.currentStreak           = profile.currentStreak
            lp.longestStreak           = profile.longestStreak
            lp.lastCompletedDate       = profile.lastCompletedDate
            lp.seenSentenceTexts       = profile.seenSentenceTexts
            lp.recentScores            = profile.recentScores
            lp.totalSentencesCompleted = profile.totalSentencesCompleted
            lp.retryImprovements       = profile.retryImprovements
            lp.unlockedBadges          = profile.unlockedBadges
            lp.difficultyLocked        = settings.difficultyLocked
            profile.languageProfiles["Mandarin"] = lp
        }

        // Sync AppSettings mirrors from the active language profile
        let lp = profile.languageProfiles[settings.targetLanguage] ?? LanguageProfile()
        settings.dailyGoal = lp.dailySentenceGoal
        settings.difficultyLocked = lp.difficultyLocked
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
        // Keep only last 30 sessions per language (90 total across 3 languages typical)
        if sessions.count > 90 {
            sessions = Array(sessions.suffix(90))
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

    // MARK: - Helpers

    private func todaySessionID() -> String {
        let modeSuffix = settings.practiceMode == .listening ? "_listening" : ""
        return "\(todayISOString())_\(settings.targetLanguage)\(modeSuffix)"
    }
}
