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

// MARK: - Question Text (one rendering of the prompt, used by every Produce phase)

/// The question the learner is answering, shown the same way in every phase: the target
/// language leads — it is the language they are about to answer in — with the English
/// underneath as a gloss. Rendering both, always, is what keeps the mode from appearing to
/// switch languages between the opening question and the follow-ups.
private struct ProduceQuestionText: View {
    let english: String
    let targetText: String?
    var alignment: HorizontalAlignment = .leading
    var primaryFont: Font = .title3

    private var textAlignment: TextAlignment { alignment == .center ? .center : .leading }
    private var frameAlignment: Alignment { alignment == .center ? .center : .leading }

    private var hasTarget: Bool {
        !(targetText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            if hasTarget, let targetText {
                line(targetText, font: primaryFont, weight: .medium, color: .primary)
                line(english, font: .subheadline, weight: .regular, color: .secondary)
            } else {
                line(english, font: primaryFont, weight: .medium, color: .primary)
            }
        }
    }

    private func line(_ text: String, font: Font, weight: Font.Weight, color: Color) -> some View {
        Text(text)
            .font(font)
            .fontWeight(weight)
            .foregroundColor(color)
            .multilineTextAlignment(textAlignment)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

// MARK: - Conversation Thread (past turns as chat bubbles)

private struct ProduceConversationThreadView: View {
    let turns: [ProduceTurn]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(turns) { turn in
                aiQuestionBubble(turn)
                userBubble(turn)
                if !turn.overallReaction.isEmpty {
                    aiBubble(turn.overallReaction)
                }
            }
        }
    }

    private func aiQuestionBubble(_ turn: ProduceTurn) -> some View {
        HStack {
            ProduceQuestionText(english: turn.question, targetText: turn.questionTargetText,
                                primaryFont: .body)
                .padding(10)
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .frame(maxWidth: 280, alignment: .leading)
            Spacer()
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
            ProduceQuestionText(english: store.produceCurrentQuestion,
                                targetText: store.produceCurrentQuestionTargetText)

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
            ProduceQuestionText(english: store.produceCurrentQuestion,
                                targetText: store.produceCurrentQuestionTargetText,
                                alignment: .center)
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
                    ProduceQuestionText(english: store.produceCurrentQuestion,
                                        targetText: store.produceCurrentQuestionTargetText,
                                        primaryFont: .body)
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

                    if !turn.understoodMeaning.isEmpty {
                        ProduceUnderstoodCard(turn: turn)
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
                            ProduceQuestionText(english: store.produceCurrentQuestion,
                                                targetText: store.produceCurrentQuestionTargetText,
                                                primaryFont: .body)
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
    @EnvironmentObject var store: AppStore
    let critique: ProduceSentenceCritique
    let language: String
    @State private var lessonChoice: ProduceWordChoice?

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
                Text(critique.issue)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }

            if !critique.choices.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(critique.choices) { choice in
                        Button {
                            lessonChoice = choice
                        } label: {
                            ProduceChoiceRow(choice: choice)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }

            if !critique.correction.isEmpty {
                rewriteRow(label: "Fixed", text: critique.correction,
                           icon: "arrow.turn.down.right", color: .green)
            }
            if !critique.naturalVersion.isEmpty {
                rewriteRow(label: "More natural", text: critique.naturalVersion,
                           icon: "sparkles", color: .blue)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .sheet(item: $lessonChoice) { choice in
            ExpressionLessonView(choice: choice, sentence: critique.text, language: language)
                .environmentObject(store)
        }
    }

    private func rewriteRow(label: String, text: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.caption2)
                .foregroundColor(color)
            HStack(alignment: .top, spacing: 6) {
                Text(text)
                    .font(.subheadline)
                    .foregroundColor(color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PlaybackButton(text: text, language: language)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Understood Card (the readback, and the learner's right to reject it)

/// The meaning readback is a guess, and a wrong guess makes every verdict under it wrong too —
/// grading 去过 against a trip the learner never described teaches them nothing. So the readback
/// is correctable: say what you meant, and the whole critique is rebuilt against that intent.
private struct ProduceUnderstoodCard: View {
    @EnvironmentObject var store: AppStore
    let turn: ProduceTurn

    @State private var isCorrecting = false
    @State private var intent: String = ""
    @FocusState private var isFocused: Bool

    private var canSubmit: Bool {
        !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(turn.statedIntent.isEmpty ? "What I understood" : "Reanalyzed against what you meant",
                  systemImage: turn.statedIntent.isEmpty ? "text.bubble" : "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            if !turn.statedIntent.isEmpty {
                Text("“\(turn.statedIntent)”")
                    .font(.subheadline)
                    .italic()
                    .foregroundColor(.secondary)
            }

            Text(turn.understoodMeaning)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isCorrecting {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("What were you trying to say?", text: $intent, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($isFocused)
                        .submitLabel(.done)

                    HStack(spacing: 10) {
                        Button {
                            isFocused = false
                            let text = intent
                            Task { await store.reanalyzeProduceTurn(intendedMeaning: text) }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Reanalyze")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(canSubmit ? Color.accentColor : Color(.systemGray4))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        .disabled(!canSubmit)

                        Button("Cancel") {
                            isFocused = false
                            withAnimation { isCorrecting = false }
                            intent = ""
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }
                }
            } else {
                Button {
                    intent = turn.statedIntent
                    withAnimation { isCorrecting = true }
                    isFocused = true
                } label: {
                    Label(turn.statedIntent.isEmpty ? "That's not what I meant" : "Still not right",
                          systemImage: "pencil")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(12)
    }
}

// MARK: - Choice Row (one expression the learner reached for, and how it landed)

private struct ProduceChoiceRow: View {
    let choice: ProduceWordChoice

    private var color: Color {
        switch choice.verdict {
        case "correct": return .green
        case "incorrect": return .red
        default: return .orange
        }
    }

    private var icon: String {
        switch choice.verdict {
        case "correct": return "checkmark.circle.fill"
        case "incorrect": return "xmark.circle.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(color)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(choice.expression)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    if !choice.better.isEmpty {
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(choice.better)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                    }
                }
                if !choice.explanation.isEmpty {
                    Text(choice.explanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Expression Lesson (tap-through sheet: the rule, then practice)

/// The depth the critique row deliberately leaves out. Tapping "去过 → 去了" lands here: a
/// one-line headline, a short why, the neighbor it gets confused with, and three sentences to
/// write using the pattern — graded one at a time so the learner uses it rather than reads it.
private struct ExpressionLessonView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let choice: ProduceWordChoice
    let sentence: String
    let language: String

    var body: some View {
        NavigationView {
            Group {
                if let lesson = store.activeExpressionLesson {
                    lessonBody(lesson)
                } else if let error = store.expressionLessonError {
                    errorState(error)
                } else {
                    loadingState
                }
            }
            .navigationTitle(choice.expression)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await store.openExpressionLesson(for: choice, inSentence: sentence) }
        .onDisappear { store.closeExpressionLesson() }
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.3)
            Text("Working out how to explain \(choice.expression)...")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await store.openExpressionLesson(for: choice, inSentence: sentence) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func lessonBody(_ lesson: ExpressionLesson) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                swapHeader(lesson)

                if !lesson.headline.isEmpty {
                    Text(lesson.headline)
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                if !lesson.explanation.isEmpty {
                    Text(lesson.explanation)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !lesson.contrast.isEmpty {
                    Label {
                        Text(lesson.contrast)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundColor(.orange)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(10)
                }

                if !lesson.drills.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your turn")
                            .font(.headline)
                        Text("Write each one in \(language) using this pattern.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ForEach(Array(lesson.drills.enumerated()), id: \.element.id) { index, drill in
                        ExpressionDrillRow(drill: drill, index: index + 1, language: language)
                    }
                }
            }
            .padding()
        }
    }

    private func swapHeader(_ lesson: ExpressionLesson) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("You wrote")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(lesson.expression)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(choice.verdict == "correct" ? .green : .red)
            }
            if !lesson.better.isEmpty {
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        Text(lesson.better)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                        PlaybackButton(text: lesson.better, language: language)
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Drill Row (one write-it-yourself exercise inside a lesson)

private struct ExpressionDrillRow: View {
    @EnvironmentObject var store: AppStore
    let drill: ExpressionDrill
    let index: Int
    let language: String

    @State private var answer: String = ""
    @FocusState private var isFocused: Bool

    private var result: ExpressionDrillResult? { store.drillResults[drill.id] }
    private var isGrading: Bool { store.gradingDrillIDs.contains(drill.id) }
    private var canSubmit: Bool {
        !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGrading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.accentColor)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(drill.englishPrompt)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    if !drill.hint.isEmpty {
                        Text(drill.hint)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Your answer in \(language)", text: $answer)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .disabled(isGrading)
                    .submitLabel(.done)
                    .onSubmit { submit() }
                Button(action: submit) {
                    if isGrading {
                        ProgressView()
                            .frame(width: 44, height: 30)
                    } else {
                        Text(result == nil ? "Check" : "Recheck")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .frame(minWidth: 44)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 6)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }

            if let result {
                VStack(alignment: .leading, spacing: 6) {
                    Label(result.isCorrect ? "Correct" : "Not quite",
                          systemImage: result.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(result.isCorrect ? .green : .red)
                    if !result.feedback.isEmpty {
                        Text(result.feedback)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !result.correctedAnswer.isEmpty {
                        answerRow(label: "Fixed", text: result.correctedAnswer, color: .green)
                    }
                    if !drill.referenceAnswer.isEmpty {
                        answerRow(label: "One good answer", text: drill.referenceAnswer, color: .secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((result.isCorrect ? Color.green : Color.red).opacity(0.08))
                .cornerRadius(10)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func answerRow(label: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(text)
                .font(.caption)
                .foregroundColor(color)
                .frame(maxWidth: .infinity, alignment: .leading)
            PlaybackButton(text: text, language: language)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isFocused = false
        Task { await store.submitDrillAnswer(drill, answer: answer) }
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
