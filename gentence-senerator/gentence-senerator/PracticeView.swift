import SwiftUI

// MARK: - Main Practice View

struct PracticeView: View {
    @EnvironmentObject var store: AppStore
    let mode: PracticeMode

    var body: some View {
        NavigationView {
            Group {
                switch store.practicePhase {
                case .idle, .generatingSentences:
                    PracticeLoadingView()
                case .readyToRecord:
                    SentenceDisplayView()
                case .recording:
                    RecordingView()
                case .transcribing:
                    ProcessingView(message: "Transcribing...")
                case .reviewingTranscription:
                    TranscriptionReviewView()
                case .evaluating:
                    ProcessingView(message: "Evaluating your response...")
                case .showingFeedback(let score):
                    FeedbackView(score: score)
                case .sessionComplete:
                    SessionCompleteView()
                case .error(let msg):
                    PracticeErrorView(message: msg)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    progressIndicator
                }
            }
        }
    }

    private var navTitle: String {
        switch store.practicePhase {
        case .sessionComplete: return "Complete!"
        case .error: return "Error"
        default: return mode == .listening ? "Listen" : "Translate"
        }
    }

    private var progressIndicator: some View {
        Group {
            if store.todaySentences.isEmpty { EmptyView() }
            else if store.isEndlessMode {
                HStack(spacing: 4) {
                    Image(systemName: "infinity")
                        .font(.caption)
                    Text("\(store.todayCompletedCount)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .foregroundColor(.accentColor)
            } else {
                Text("\(store.todayCompletedCount)/\(store.todayGoal)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Loading View

private struct PracticeLoadingView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Generating today's sentences...")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("This may take a few moments")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sentence Display View

private struct SentenceDisplayView: View {
    @EnvironmentObject var store: AppStore
    @State private var showTypeInput = false
    @State private var typedInput = ""
    @State private var hasPlayedAudio = false
    @FocusState private var isTypingFocused: Bool

    private var sentence: Sentence? { store.currentSentence }
    private var attemptNumber: Int { (sentence?.attemptCount ?? 0) + 1 }
    private var isListeningMode: Bool { store.settings.practiceMode == .listening }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Sentence progress
                sentenceProgress

                // Instruction + sentence display
                if isListeningMode {
                    listeningSection
                } else {
                    translationSection
                }

                // Attempt indicator
                if attemptNumber > 1 {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption)
                        Text("Attempt \(attemptNumber) of 3")
                            .font(.caption)
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(20)
                }

                // Mic button or type input (only shown after audio plays in listening mode)
                if !isListeningMode || hasPlayedAudio {
                    if showTypeInput {
                        typeInputSection
                    } else {
                        micSection
                    }

                    // Toggle to type mode
                    Button {
                        showTypeInput.toggle()
                        typedInput = ""
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showTypeInput ? "mic" : "keyboard")
                                .font(.caption)
                            Text(showTypeInput ? "Switch to speaking" : "Type instead")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
        .onTapGesture { isTypingFocused = false }
        .onChange(of: store.currentSentenceIndex) { _ in
            hasPlayedAudio = false
        }
    }

    private var translationSection: some View {
        VStack(spacing: 8) {
            Text("Translate and say this in \(store.settings.targetLanguage):")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text(sentence?.englishText ?? "")
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(16)
        }
    }

    private var listeningSection: some View {
        VStack(spacing: 16) {
            Text("Listen and repeat in \(store.settings.targetLanguage):")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                if let text = sentence?.listeningTargetText {
                    store.speech.speak(text: text, language: store.settings.targetLanguage)
                    hasPlayedAudio = true
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.purple.opacity(0.12))
                        .frame(width: 100, height: 100)
                    Circle()
                        .fill(Color.purple)
                        .frame(width: 80, height: 80)
                    Image(systemName: store.speech.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                        .font(.title)
                        .foregroundColor(.white)
                        .symbolEffect(.pulse, isActive: store.speech.isSpeaking)
                }
            }
            .disabled(store.speech.isSpeaking)

            if !hasPlayedAudio {
                Text("Tap to hear the sentence")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if store.speech.isSpeaking {
                Text("Playing...")
                    .font(.caption)
                    .foregroundColor(.purple)
            } else {
                Text("Tap again to replay, then speak or type below")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var sentenceProgress: some View {
        Group {
            if store.isEndlessMode {
                endlessProgressRow
            } else {
                HStack(spacing: 8) {
                    ForEach(0..<store.todayGoal, id: \.self) { i in
                        Capsule()
                            .fill(progressColor(for: i))
                            .frame(height: 6)
                    }
                }
            }
        }
    }

    /// Endless mode: show last 10 sentences as capsules + ∞ label
    private var endlessProgressRow: some View {
        HStack(spacing: 6) {
            let visible = min(store.todaySentences.count, 10)
            let start = store.todaySentences.count - visible
            ForEach(start..<store.todaySentences.count, id: \.self) { i in
                Capsule()
                    .fill(progressColor(for: i))
                    .frame(width: i == store.currentSentenceIndex ? 24 : 10, height: 6)
                    .animation(.easeInOut(duration: 0.2), value: store.currentSentenceIndex)
            }
            Image(systemName: "infinity")
                .font(.caption2)
                .foregroundColor(.accentColor)
        }
    }

    private func progressColor(for index: Int) -> Color {
        if index < store.todaySentences.count {
            switch store.todaySentences[index].status {
            case .complete: return .green
            case .inProgress: return .accentColor
            case .pending:
                return index == store.currentSentenceIndex ? .accentColor.opacity(0.5) : .gray.opacity(0.3)
            }
        }
        return .gray.opacity(0.3)
    }

    private var micSection: some View {
        VStack(spacing: 16) {
            Button {
                store.startRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 80, height: 80)
                        .shadow(color: Color.accentColor.opacity(0.4), radius: 12)
                    Image(systemName: "mic.fill")
                        .font(.title)
                        .foregroundColor(.white)
                }
            }
            .disabled(!store.speech.isFullyAuthorized)

            if !store.speech.isFullyAuthorized {
                Text("Tap to grant microphone access")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                Text(isListeningMode ? "Tap the mic and repeat what you heard" : "Tap the mic and speak your translation")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 20)
    }

    private var typeInputSection: some View {
        VStack(spacing: 12) {
            TextField(isListeningMode ? "Type what you heard in \(store.settings.targetLanguage)..." : "Type your \(store.settings.targetLanguage) translation...", text: $typedInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3)
                .focused($isTypingFocused)

            Button {
                guard !typedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                Task {
                    await store.evaluateTypedInput(transcript: typedInput)
                }
            } label: {
                Text("Review")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(typedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(typedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

// MARK: - Recording View

private struct RecordingView: View {
    @EnvironmentObject var store: AppStore
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Sentence reminder
            if let sentence = store.currentSentence {
                let isListening = store.settings.practiceMode == .listening
                let reminderText = isListening
                    ? "Repeat the sentence you heard"
                    : sentence.englishText
                Text(reminderText)
                    .font(.title3)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(Color.accentColor.opacity(0.08))
                    .cornerRadius(12)
                    .padding(.horizontal)
            }

            // Live transcript
            if !store.speech.transcript.isEmpty {
                Text(store.speech.transcript)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .transition(.opacity)
            }

            // Pulsing stop button
            Button {
                Task {
                    await store.stopAndReview()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 100, height: 100)
                        .scaleEffect(pulseScale)
                        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulseScale)
                    Circle()
                        .fill(Color.red)
                        .frame(width: 80, height: 80)
                    Image(systemName: "stop.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                }
            }
            .onAppear { pulseScale = 1.15 }

            Text("Tap to stop recording")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
    }
}

// MARK: - Processing View

private struct ProcessingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text(message)
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Feedback View

private struct FeedbackView: View {
    @EnvironmentObject var store: AppStore
    let score: Int

    private var evaluation: SentenceEvaluationResult? { store.lastEvaluation }
    private var sentence: Sentence? { store.currentSentence }
    private var canRetry: Bool { sentence?.canRetry ?? false }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Score ring
                ScoreRingView(score: score)
                    .padding(.top, 8)

                // XP earned
                if store.xpJustEarned > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                        Text("+\(store.xpJustEarned) XP")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.yellow)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.yellow.opacity(0.1))
                    .cornerRadius(20)
                }

                // Sentence context: "You heard" (listening) or "Original" (translation)
                let isListeningMode = sentence?.listeningTargetText != nil
                if isListeningMode {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("You heard")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            Spacer()
                            PlaybackButton(
                                text: sentence?.listeningTargetText ?? "",
                                language: store.settings.targetLanguage
                            )
                        }
                        Text(sentence?.listeningTargetText ?? "")
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.purple.opacity(0.08))
                            .cornerRadius(10)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Meaning")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text(sentence?.englishText ?? "")
                            .font(.body)
                            .italic()
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.06))
                            .cornerRadius(10)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Original")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text(sentence?.englishText ?? "")
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.08))
                            .cornerRadius(10)
                    }
                }

                // What you said
                if let transcript = sentence?.attempts.last?.transcript, !transcript.isEmpty {
                    let isMandarin = store.settings.targetLanguage == "Mandarin"
                    let showPinyin = isMandarin && store.settings.showRomanization
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("You said")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            Spacer()
                            PlaybackButton(text: transcript, language: store.settings.targetLanguage)
                        }
                        if showPinyin {
                            PinyinAnnotationView(text: transcript)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemGray6))
                                .cornerRadius(10)
                        } else {
                            Text(transcript)
                                .font(.body)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemGray6))
                                .cornerRadius(10)
                        }
                    }
                }

                if let eval = evaluation {
                    // Feedback (grammar-only or "good job")
                    if !eval.feedback.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Feedback")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            Text(eval.feedback)
                                .font(.body)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.accentColor.opacity(0.06))
                                .cornerRadius(10)
                        }
                    }

                    // Pronunciation breakdown (Mandarin only, when Azure assessment is available)
                    if let assessment = sentence?.attempts.last?.pronunciationAssessment {
                        PronunciationBreakdownView(assessment: assessment)
                    }

                    // Correct translation with tappable word explanations
                    if !eval.correctTranslation.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Correct Translation")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                Spacer()
                                PlaybackButton(text: eval.correctTranslation,
                                               language: store.settings.targetLanguage)
                            }
                            TappableTranslationView(
                                wordExplanations: eval.wordExplanations,
                                fallbackText: eval.correctTranslation
                            )
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08))
                            .cornerRadius(10)
                        }
                    }

                    // Alternative translations
                    if !eval.alternativeTranslations.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Also accepted")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                            ForEach(eval.alternativeTranslations, id: \.self) { alt in
                                HStack {
                                    Text(alt)
                                        .font(.body)
                                    Spacer()
                                    PlaybackButton(text: alt, language: store.settings.targetLanguage)
                                }
                                .padding()
                                .background(Color.green.opacity(0.05))
                                .cornerRadius(10)
                            }
                        }
                    }

                    // Learn More — grammar resource links
                    if !eval.grammarIssues.isEmpty {
                        let resources = Array(eval.grammarIssues
                            .flatMap { GrammarResources.resources(for: $0, language: store.settings.targetLanguage) }
                            .prefix(4))    // cap: 2 issues × 2 links = 4 max

                        if !resources.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    Image(systemName: "book.pages.fill")
                                        .foregroundColor(.blue)
                                        .font(.caption)
                                    Text("Learn More")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .textCase(.uppercase)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(resources) { resource in
                                        Link(destination: resource.url) {
                                            HStack(spacing: 8) {
                                                Image(systemName: "arrow.up.right.square")
                                                    .font(.caption)
                                                    .foregroundColor(.blue)
                                                Text(resource.title)
                                                    .font(.subheadline)
                                                    .foregroundColor(.blue)
                                                    .multilineTextAlignment(.leading)
                                                Spacer()
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(Color.blue.opacity(0.06))
                                            .cornerRadius(8)
                                        }
                                    }
                                }
                            }
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                        }
                    }
                }   // end if let eval = evaluation

                // New badges
                if !store.newlyUnlockedBadges.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "gift.fill")
                                .foregroundColor(.yellow)
                            Text("Badge Unlocked!")
                                .font(.headline)
                        }
                        ForEach(store.newlyUnlockedBadges) { badge in
                            BadgeView(badge: badge, isLocked: false)
                        }
                    }
                    .padding()
                    .background(Color.yellow.opacity(0.08))
                    .cornerRadius(12)
                }

                // Follow-up questions
                FollowUpChatView()

                // Action buttons
                HStack(spacing: 12) {
                    if canRetry {
                        Button {
                            store.retryCurrentSentence()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.counterclockwise")
                                Text("Retry")
                            }
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.systemGray5))
                            .foregroundColor(.primary)
                            .cornerRadius(12)
                        }
                    }

                    Button {
                        store.advanceToNextSentence()
                    } label: {
                        HStack {
                            Text(nextButtonLabel)
                            Image(systemName: nextButtonIcon)
                        }
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                }
            }
            .padding()
        }
    }

    private var isLastSentence: Bool {
        store.currentSentenceIndex >= store.todaySentences.count - 1
    }

    private var nextButtonLabel: String {
        if store.isEndlessMode { return "Next" }
        return isLastSentence ? "Finish" : "Next"
    }

    private var nextButtonIcon: String {
        if store.isEndlessMode { return "arrow.right" }
        return isLastSentence ? "checkmark" : "arrow.right"
    }
}

// MARK: - Follow-up Chat View

private struct FollowUpChatView: View {
    @EnvironmentObject var store: AppStore
    @State private var inputText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask the tutor")
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            if !store.followUpMessages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(store.followUpMessages.enumerated()), id: \.offset) { _, msg in
                        HStack {
                            if msg.role == "user" {
                                Spacer()
                                Text(msg.content)
                                    .font(.body)
                                    .padding(10)
                                    .background(Color.accentColor.opacity(0.15))
                                    .cornerRadius(12)
                                    .frame(maxWidth: 280, alignment: .trailing)
                            } else {
                                Text(msg.content)
                                    .font(.body)
                                    .padding(10)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(12)
                                    .frame(maxWidth: 280, alignment: .leading)
                                Spacer()
                            }
                        }
                    }
                }
            }

            if store.isLoadingFollowUp {
                HStack {
                    ProgressView()
                        .padding(10)
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                TextField("Ask a follow-up question…", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { sendQuestion() }

                Button(action: sendQuestion) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.white)
                        .padding(8)
                        .background(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLoadingFollowUp
                            ? Color.accentColor.opacity(0.4)
                            : Color.accentColor)
                        .cornerRadius(8)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLoadingFollowUp)
            }
        }
    }

    private func sendQuestion() {
        let q = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !store.isLoadingFollowUp else { return }
        inputText = ""
        Task { await store.askFollowUpQuestion(q) }
    }
}

// MARK: - Session Complete View

private struct SessionCompleteView: View {
    @EnvironmentObject var store: AppStore
    @State private var showConfetti = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Celebration icon
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.1))
                        .frame(width: 120, height: 120)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                        .symbolEffect(.bounce, value: showConfetti)
                }
                .padding(.top, 20)
                .onAppear { showConfetti = true }

                Text("Session Complete!")
                    .font(.title)
                    .fontWeight(.bold)

                // Streak
                if store.currentLangProfile.currentStreak > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .foregroundColor(.orange)
                        Text("\(store.currentLangProfile.currentStreak)-day streak!")
                            .fontWeight(.semibold)
                    }
                    .font(.headline)
                }

                // Stats
                VStack(spacing: 12) {
                    HStack(spacing: 16) {
                        summaryCard(
                            title: "Sentences",
                            value: "\(store.todayGoal)",
                            icon: "text.bubble.fill",
                            color: .accentColor
                        )
                        let totalXP = store.todaySession?.totalXPEarned ?? 0
                        summaryCard(
                            title: "XP Earned",
                            value: "+\(totalXP)",
                            icon: "star.fill",
                            color: .yellow
                        )
                    }
                    HStack(spacing: 16) {
                        let scores = store.todaySentences.compactMap(\.bestScore)
                        let avg = scores.isEmpty ? 0 : scores.reduce(0, +) / scores.count
                        summaryCard(
                            title: "Avg Score",
                            value: "\(avg)%",
                            icon: "chart.bar.fill",
                            color: .blue
                        )
                        summaryCard(
                            title: "Level",
                            value: "\(store.currentLangProfile.currentLevel)",
                            icon: "trophy.fill",
                            color: .purple
                        )
                    }
                }

                // New badges from session
                if !store.newlyUnlockedBadges.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "gift.fill")
                                .foregroundColor(.yellow)
                            Text("New Badges!")
                                .font(.headline)
                        }
                        ForEach(store.newlyUnlockedBadges) { badge in
                            BadgeView(badge: badge, isLocked: false)
                        }
                    }
                    .padding()
                    .background(Color.yellow.opacity(0.08))
                    .cornerRadius(12)
                }

                // Keep Going button
                Button {
                    Task { await store.startEndlessMode() }
                } label: {
                    HStack {
                        Image(systemName: "infinity")
                        Text("Keep Going")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                }

                Text("Come back tomorrow to keep your streak!")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }

    private func summaryCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Error View

private struct PracticeErrorView: View {
    @EnvironmentObject var store: AppStore
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.red)

            Text("Something went wrong")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                Task {
                    await store.prepareOrResumeTodaySession()
                }
            } label: {
                Text("Try Again")
                    .fontWeight(.semibold)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pinyin helpers

/// Converts Chinese characters to pinyin with tone diacritics (e.g. 你好 → "nǐ hǎo").
/// Safe to call on non-Chinese strings; non-Chinese characters are left unchanged.
func toPinyin(_ text: String) -> String {
    let s = NSMutableString(string: text)
    CFStringTransform(s, nil, kCFStringTransformMandarinLatin, false)
    return s as String
}

struct CharacterWithPinyin: Identifiable {
    let id = UUID()
    let character: String
    let pinyin: String
}

/// Splits a Chinese string into per-character pinyin pairs.
/// Returns [] if the character / syllable counts don't align (fallback to two-line display).
func splitWithPinyin(_ text: String) -> [CharacterWithPinyin] {
    guard !text.isEmpty else { return [] }
    let chars = text.map { String($0) }
    let syllables = toPinyin(text).components(separatedBy: " ")
    guard chars.count == syllables.count else { return [] }
    return zip(chars, syllables).map { CharacterWithPinyin(character: $0, pinyin: $1) }
}

// MARK: - Pinyin Annotation View

private struct PinyinAnnotationView: View {
    let text: String

    var body: some View {
        let pairs = splitWithPinyin(text)
        if pairs.isEmpty {
            // Fallback: characters on one line, full pinyin below
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.title3)
                Text(toPinyin(text))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else {
            FlowLayout(spacing: 4) {
                ForEach(pairs) { pair in
                    VStack(spacing: 1) {
                        Text(pair.pinyin)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(pair.character)
                            .font(.title3)
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }
}

// MARK: - Playback Button

/// A small speaker button that reads `text` aloud in `language` using TTS.
private struct PlaybackButton: View {
    @EnvironmentObject var store: AppStore
    let text: String
    let language: String

    private var isSpeaking: Bool { store.speech.isSpeaking }

    var body: some View {
        Button {
            if isSpeaking {
                store.speech.stopSpeaking()
            } else {
                store.speech.speak(text: text, language: language)
            }
        } label: {
            Image(systemName: isSpeaking ? "stop.circle.fill" : "speaker.wave.2.fill")
                .font(.caption)
                .foregroundColor(.accentColor)
                .padding(6)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSpeaking ? "Stop playback" : "Play back your response")
    }
}

// MARK: - Transcription Review View

private struct TranscriptionReviewView: View {
    @EnvironmentObject var store: AppStore

    private var isMandarin: Bool { store.settings.targetLanguage == "Mandarin" }
    private var showPinyin: Bool { isMandarin && store.settings.showRomanization }
    private var transcript: String { store.pendingTranscript }
    private var isEmpty: Bool { transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // Sentence reminder
                if let sentence = store.currentSentence {
                    let isListening = store.settings.practiceMode == .listening
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isListening ? "Listen again" : "Translate")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        if isListening {
                            HStack {
                                Spacer()
                                PlaybackButton(
                                    text: sentence.listeningTargetText ?? "",
                                    language: store.settings.targetLanguage
                                )
                                Spacer()
                            }
                            .padding()
                            .background(Color.purple.opacity(0.08))
                            .cornerRadius(10)
                        } else {
                            Text(sentence.englishText)
                                .font(.body)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.accentColor.opacity(0.08))
                                .cornerRadius(10)
                        }
                    }
                }

                // Transcription with optional pinyin
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("You said")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        if !isEmpty {
                            PlaybackButton(text: transcript, language: store.settings.targetLanguage)
                        }
                    }

                    if isEmpty {
                        HStack {
                            Image(systemName: "mic.slash")
                                .foregroundColor(.orange)
                            Text("No speech detected")
                                .foregroundColor(.orange)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08))
                        .cornerRadius(10)
                    } else if showPinyin {
                        PinyinAnnotationView(text: transcript)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                    } else {
                        Text(transcript)
                            .font(.title3)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                    }
                }

                // Action buttons
                VStack(spacing: 12) {
                    Button {
                        Task { await store.submitForEvaluation() }
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text(isEmpty ? "Submit Anyway" : "Submit")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }

                    Button {
                        store.reRecord()
                    } label: {
                        HStack {
                            Image(systemName: "mic.fill")
                            Text("Re-record")
                                .fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Tappable translation view

/// Shows the full correct translation sentence, then a row of tappable word chips
/// for each notable word/phrase. Tapping a chip slides down its grammar explanation.
private struct TappableTranslationView: View {
    let wordExplanations: [WordExplanation]
    let fallbackText: String
    @State private var selected: WordExplanation? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Always show the complete sentence
            Text(fallbackText)
                .font(.title3)

            // Tappable chips for notable words (only when explanations exist)
            if !wordExplanations.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(wordExplanations) { we in
                        Text(we.word)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(selected?.id == we.id
                                ? Color.accentColor.opacity(0.18)
                                : Color.accentColor.opacity(0.07))
                            .foregroundColor(selected?.id == we.id
                                ? Color.accentColor
                                : Color.primary)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.accentColor.opacity(
                                        selected?.id == we.id ? 0.5 : 0.2), lineWidth: 1)
                            )
                            .onTapGesture {
                                withAnimation(.spring(duration: 0.25)) {
                                    selected = (selected?.id == we.id) ? nil : we
                                }
                            }
                    }
                }

                // Sliding explanation panel
                if let sel = selected {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sel.word)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text(sel.explanation)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.06))
                    .cornerRadius(10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }
}

// MARK: - FlowLayout helper

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Pronunciation Breakdown View

private struct PronunciationBreakdownView: View {
    let assessment: PronunciationAssessment
    @State private var expandedSyllableID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pronunciation")
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            // Summary pills: Tone | Consonants | Vowels
            HStack(spacing: 10) {
                PronunciationScorePill(label: "Tone", score: assessment.toneScore)
                PronunciationScorePill(label: "Consonants", score: assessment.consonantScore)
                PronunciationScorePill(label: "Vowels", score: assessment.vowelScore)
            }

            // Per-syllable row
            if !assessment.syllables.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(assessment.syllables) { syllable in
                            SyllableCardView(
                                syllable: syllable,
                                isExpanded: expandedSyllableID == syllable.id
                            )
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedSyllableID = expandedSyllableID == syllable.id ? nil : syllable.id
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            // "What to work on" — shown only when something scores below 75
            let warnings = buildWarnings(from: assessment)
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Text(warning)
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.07))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    private func buildWarnings(from assessment: PronunciationAssessment) -> [String] {
        var result: [String] = []

        if assessment.toneScore < 75 {
            let bad = assessment.syllables
                .filter { $0.toneScore < 75 }
                .map { "\($0.character) (\($0.syllable.isEmpty ? "?" : $0.syllable)): \($0.toneScore)" }
                .prefix(3)
            if !bad.isEmpty {
                result.append("Tones need work: " + bad.joined(separator: ", "))
            }
        }

        if assessment.consonantScore < 75 {
            result.append("Consonants need work: \(assessment.consonantScore)/100")
        }

        if assessment.vowelScore < 75 {
            result.append("Vowels need work: \(assessment.vowelScore)/100")
        }

        return result
    }
}

private struct PronunciationScorePill: View {
    let label: String
    let score: Int

    private var color: Color {
        if score >= 80 { return .green }
        if score >= 60 { return .orange }
        return .red
    }

    var body: some View {
        VStack(spacing: 2) {
            Text("\(score)")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

private struct SyllableCardView: View {
    let syllable: SyllableResult
    let isExpanded: Bool

    private var borderColor: Color {
        if syllable.accuracyScore >= 80 { return .green }
        if syllable.accuracyScore >= 60 { return .orange }
        return .red
    }

    private var toneIndicator: String {
        syllable.errorType == "None" || syllable.toneScore >= 75 ? "✓" : "✗"
    }

    var body: some View {
        VStack(spacing: 3) {
            // Tone check indicator
            Text(toneIndicator)
                .font(.caption2)
                .foregroundColor(syllable.toneScore >= 75 ? .green : .red)

            // Pinyin (if available)
            if !syllable.syllable.isEmpty {
                Text(syllable.syllable)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Character
            Text(syllable.character)
                .font(.title3)

            // Overall score
            Text("\(syllable.accuracyScore)")
                .font(.caption2)
                .foregroundColor(borderColor)

            // Expanded: show initial/final sub-scores
            if isExpanded {
                Divider()
                if let ini = syllable.initialScore {
                    Text("声母 \(ini)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let fin = syllable.finalScore {
                    Text("韵母 \(fin)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor.opacity(0.6), lineWidth: 1.5)
        )
        .cornerRadius(8)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }
}

// MARK: - Retry Practice View

/// Presented as a sheet from RetryView. Reuses all the existing practice sub-views
/// and shows a simple completion screen (instead of the full SessionCompleteView).
struct RetryPracticeView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                switch store.practicePhase {
                case .idle, .generatingSentences:
                    PracticeLoadingView()
                case .readyToRecord:
                    SentenceDisplayView()
                case .recording:
                    RecordingView()
                case .transcribing:
                    ProcessingView(message: "Transcribing...")
                case .reviewingTranscription:
                    TranscriptionReviewView()
                case .evaluating:
                    ProcessingView(message: "Evaluating your response...")
                case .showingFeedback(let score):
                    FeedbackView(score: score)
                case .sessionComplete:
                    RetryDoneView(dismiss: { dismiss() })
                case .error(let msg):
                    PracticeErrorView(message: msg)
                }
            }
            .navigationTitle("Retry Practice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct RetryDoneView: View {
    @EnvironmentObject var store: AppStore
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 70))
                .foregroundColor(.green)
            Text("Nice work!")
                .font(.title)
                .fontWeight(.bold)
            if let score = store.todaySentences.first?.bestScore {
                Text("Session best: \(score)")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    PracticeView(mode: .translation)
        .environmentObject(AppStore())
}
