import SwiftUI

// MARK: - Main Produce View
// Third practice mode: the AI asks an open-ended question, the learner speaks a free
// (potentially multi-sentence) response, each sentence gets critiqued, and a natural
// follow-up question continues the conversation. Structurally mirrors PracticeView.swift
// (phase switch, matching visual language) without sharing its private sub-views, since
// those are coupled to PracticePhase/Sentence's fixed-prompt, up-to-3-attempts shape.

struct ProduceView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationView {
            Group {
                switch store.producePhase {
                case .idle, .generatingQuestion:
                    ProduceLoadingView()
                case .readyToRecord:
                    ProduceQuestionView()
                case .recording:
                    ProduceRecordingView()
                case .transcribing:
                    ProcessingView(message: "Transcribing...")
                case .reviewingTranscript:
                    ProduceTranscriptReviewView()
                case .critiquing:
                    ProcessingView(message: "Thinking about your response...")
                case .showingCritique:
                    ProduceCritiqueView()
                case .sessionComplete:
                    ProduceSessionCompleteView()
                case .error(let msg):
                    ProduceErrorView(message: msg)
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
        switch store.producePhase {
        case .sessionComplete: return "Complete!"
        case .error: return "Error"
        default: return "Produce"
        }
    }

    private var progressIndicator: some View {
        Group {
            if store.isProduceEndlessMode {
                HStack(spacing: 4) {
                    Image(systemName: "infinity")
                        .font(.caption)
                    Text("\(store.produceTurnCount)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .foregroundColor(.accentColor)
            } else if store.produceSession != nil {
                Text("\(store.produceTurnCount)/\(store.produceTurnGoal)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            } else {
                EmptyView()
            }
        }
    }
}

// MARK: - Loading View

private struct ProduceLoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Starting your conversation...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Conversation Thread (past turns as chat bubbles)

private struct ProduceConversationThreadView: View {
    let turns: [ProduceTurn]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(turns) { turn in
                aiBubble(turn.question)
                userBubble(turn)
                if !turn.overallReaction.isEmpty {
                    aiBubble(turn.overallReaction)
                }
            }
        }
    }

    private func aiBubble(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.body)
                .padding(10)
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .frame(maxWidth: 280, alignment: .leading)
            Spacer()
        }
    }

    private func userBubble(_ turn: ProduceTurn) -> some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(turn.transcript.isEmpty ? "(no speech detected)" : turn.transcript)
                    .font(.body)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(12)
                if !turn.critiques.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                        Text("\(turn.averageScore)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(scoreColor(turn.averageScore))
                }
            }
            .frame(maxWidth: 280, alignment: .trailing)
        }
    }

    private func scoreColor(_ score: Int) -> Color {
        if score >= 85 { return .green }
        if score >= 60 { return .orange }
        return .red
    }
}

// MARK: - Question View (readyToRecord)

private struct ProduceQuestionView: View {
    @EnvironmentObject var store: AppStore
    @State private var showTypeInput = false
    @State private var typedInput = ""
    @FocusState private var isTypingFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let turns = store.produceSession?.turns, !turns.isEmpty {
                    ProduceConversationThreadView(turns: turns)
                }

                currentQuestionCard

                if showTypeInput {
                    typeInputSection
                } else {
                    micSection
                }

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

                Button {
                    store.endProduceSessionEarly()
                } label: {
                    Text("End conversation")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
            .padding()
        }
        .onTapGesture { isTypingFocused = false }
    }

    private var currentQuestionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.produceCurrentQuestion)
                .font(.title3)
                .fontWeight(.medium)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let targetText = store.produceCurrentQuestionTargetText, !targetText.isEmpty {
                HStack(spacing: 8) {
                    PlaybackButton(text: targetText, language: store.settings.targetLanguage)
                    Text("Hear it in \(store.settings.targetLanguage)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(14)
    }

    private var micSection: some View {
        VStack(spacing: 16) {
            Button {
                store.startProduceRecording()
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
                Text("Tap the mic and answer in \(store.settings.targetLanguage) — a few sentences is great")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 12)
    }

    private var typeInputSection: some View {
        VStack(spacing: 12) {
            TextField("Type your \(store.settings.targetLanguage) response...", text: $typedInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .focused($isTypingFocused)

            Button {
                guard !typedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                Task { await store.evaluateProduceTypedInput(transcript: typedInput) }
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

private struct ProduceRecordingView: View {
    @EnvironmentObject var store: AppStore
    @State private var pulseScale: CGFloat = 1.0
    @State private var displayTranscript: String = ""
    @State private var userHasEdited: Bool = false

    private var transcriptBinding: Binding<String> {
        Binding(
            get: { displayTranscript },
            set: { newVal in
                displayTranscript = newVal
                userHasEdited = true
                store.producePendingUserEdit = newVal
            }
        )
    }

    var body: some View {
        VStack(spacing: 24) {
            Text(store.produceCurrentQuestion)
                .font(.title3)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .padding()
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(12)
                .padding(.horizontal)

            Spacer()

            Button {
                Task { await store.stopProduceRecordingAndReview() }
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

            Text("Tap to stop — take your time, tell the whole story")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Transcript")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    if userHasEdited {
                        Text("Edited")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)

                TextField("Listening…", text: transcriptBinding, axis: .vertical)
                    .font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    .padding(.horizontal)
            }
            .onChange(of: store.speech.transcript) { newVal in
                if !userHasEdited {
                    displayTranscript = newVal
                }
            }
            .onAppear {
                displayTranscript = store.speech.transcript
                userHasEdited = false
                store.producePendingUserEdit = nil
            }

            Spacer()
        }
        .padding(.top)
    }
}

// MARK: - Transcript Review View

private struct ProduceTranscriptReviewView: View {
    @EnvironmentObject var store: AppStore

    private var isMandarin: Bool { store.settings.targetLanguage == "Mandarin" }
    private var showPinyin: Bool { isMandarin && store.settings.showRomanization }
    private var transcript: String { store.producePendingTranscript }
    private var isEmpty: Bool { transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var transcriptBinding: Binding<String> {
        Binding(get: { store.producePendingTranscript }, set: { store.producePendingTranscript = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("You were asked")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Text(store.produceCurrentQuestion)
                        .font(.body)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08))
                        .cornerRadius(10)
                }

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
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "mic.slash")
                                    .foregroundColor(.orange)
                                Text("No speech detected — type it below")
                                    .foregroundColor(.orange)
                            }
                            TextField("Type your answer…", text: transcriptBinding, axis: .vertical)
                                .font(.title3)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemGray6))
                                .cornerRadius(10)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.08))
                        .cornerRadius(10)
                    } else if showPinyin {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(toPinyin(transcript))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Edit transcript…", text: transcriptBinding, axis: .vertical)
                                .font(.title3)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    } else {
                        TextField("Edit transcript…", text: transcriptBinding, axis: .vertical)
                            .font(.title3)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                    }
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await store.submitProduceResponse() }
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
                        store.reRecordProduce()
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

// MARK: - Critique View (showingCritique)

private struct ProduceCritiqueView: View {
    @EnvironmentObject var store: AppStore

    private var turn: ProduceTurn? { store.produceLastTurn }
    private var isLastTurn: Bool { store.produceTurnCount >= store.produceTurnGoal }
    private var continueLabel: String {
        store.isProduceEndlessMode ? "Continue" : (isLastTurn ? "Finish" : "Continue")
    }
    private var continueIcon: String {
        store.isProduceEndlessMode ? "arrow.right" : (isLastTurn ? "checkmark" : "arrow.right")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let turn {
                    if !turn.overallReaction.isEmpty {
                        HStack {
                            Text(turn.overallReaction)
                                .font(.body)
                                .padding(12)
                                .background(Color(.systemGray6))
                                .cornerRadius(12)
                            Spacer()
                        }
                    }

                    if store.produceXPJustEarned > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                                .font(.caption)
                            Text("+\(store.produceXPJustEarned) XP")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.yellow)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.yellow.opacity(0.1))
                        .cornerRadius(20)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sentence by sentence")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        ForEach(turn.critiques) { critique in
                            ProduceCritiqueCard(critique: critique, language: store.settings.targetLanguage)
                        }
                    }

                    if !store.produceNewlyUnlockedBadges.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "gift.fill")
                                    .foregroundColor(.yellow)
                                Text("Badge Unlocked!")
                                    .font(.headline)
                            }
                            ForEach(store.produceNewlyUnlockedBadges) { badge in
                                BadgeView(badge: badge, isLocked: false)
                            }
                        }
                        .padding()
                        .background(Color.yellow.opacity(0.08))
                        .cornerRadius(12)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Next")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        HStack {
                            Text(store.produceCurrentQuestion)
                                .font(.body)
                                .padding(12)
                                .background(Color(.systemGray6))
                                .cornerRadius(12)
                            Spacer()
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            store.endProduceSessionEarly()
                        } label: {
                            Text("End")
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color(.systemGray5))
                                .foregroundColor(.primary)
                                .cornerRadius(12)
                        }

                        Button {
                            store.continueProduceConversation()
                        } label: {
                            HStack {
                                Text(continueLabel)
                                Image(systemName: continueIcon)
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
            }
            .padding()
        }
    }
}

private struct ProduceCritiqueCard: View {
    let critique: ProduceSentenceCritique
    let language: String

    private var scoreColor: Color {
        if critique.score >= 85 { return .green }
        if critique.score >= 60 { return .orange }
        return .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(critique.text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PlaybackButton(text: critique.text, language: language)
                Text("\(critique.score)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(scoreColor)
                    .frame(width: 28, height: 28)
                    .background(scoreColor.opacity(0.12))
                    .clipShape(Circle())
            }
            if !critique.issue.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(critique.issue)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if !critique.correction.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption2)
                                .foregroundColor(.green)
                            Text(critique.correction)
                                .font(.subheadline)
                                .foregroundColor(.green)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
}

// MARK: - Session Complete View

private struct ProduceSessionCompleteView: View {
    @EnvironmentObject var store: AppStore
    @State private var showConfetti = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
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

                Text("Conversation Complete!")
                    .font(.title)
                    .fontWeight(.bold)

                if store.currentLangProfile.currentStreak > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .foregroundColor(.orange)
                        Text("\(store.currentLangProfile.currentStreak)-day streak!")
                            .fontWeight(.semibold)
                    }
                    .font(.headline)
                }

                VStack(spacing: 12) {
                    HStack(spacing: 16) {
                        StatCard(title: "Turns", value: "\(store.produceTurnCount)",
                                 color: .accentColor, icon: "bubble.left.and.bubble.right.fill")
                        let totalXP = store.produceSession?.totalXPEarned ?? 0
                        StatCard(title: "XP Earned", value: "+\(totalXP)", color: .yellow, icon: "star.fill")
                    }
                    HStack(spacing: 16) {
                        let scores = store.produceSession?.turns.map(\.averageScore) ?? []
                        let avg = scores.isEmpty ? 0 : scores.reduce(0, +) / scores.count
                        StatCard(title: "Avg Score", value: "\(avg)%", color: .blue, icon: "chart.bar.fill")
                        StatCard(title: "Level", value: "\(store.currentLangProfile.currentLevel)",
                                 color: .purple, icon: "trophy.fill")
                    }
                }

                if !store.produceNewlyUnlockedBadges.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "gift.fill")
                                .foregroundColor(.yellow)
                            Text("New Badges!")
                                .font(.headline)
                        }
                        ForEach(store.produceNewlyUnlockedBadges) { badge in
                            BadgeView(badge: badge, isLocked: false)
                        }
                    }
                    .padding()
                    .background(Color.yellow.opacity(0.08))
                    .cornerRadius(12)
                }

                Button {
                    Task { await store.startProduceEndlessMode() }
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
}

// MARK: - Error View

private struct ProduceErrorView: View {
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
                Task { await store.prepareOrResumeProduceSession() }
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

#Preview {
    ProduceView()
        .environmentObject(AppStore())
}
