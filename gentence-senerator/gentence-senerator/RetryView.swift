import SwiftUI

// MARK: - Retry View

struct RetryView: View {
    @EnvironmentObject var store: AppStore
    @State private var pickedSentences: [Sentence] = []
    @State private var completedIDs: Set<UUID> = []
    @State private var showPractice = false

    private var allDone: Bool { !pickedSentences.isEmpty && completedIDs.count >= pickedSentences.count }

    var body: some View {
        Group {
            if pickedSentences.isEmpty {
                emptyState
            } else if allDone {
                allDoneState
            } else {
                practiceSet
            }
        }
        .navigationTitle("Retry")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { if pickedSentences.isEmpty { pickSentences() } }
        .sheet(isPresented: $showPractice, onDismiss: {
            if let s = store.retryOriginalSentence {
                completedIDs.insert(s.id)
            }
            store.endRetrySession()
            refreshPickedSentences()
        }) {
            RetryPracticeView()
        }
    }

    // MARK: - Practice Set

    private var practiceSet: some View {
        ScrollView {
            VStack(spacing: 0) {
                progressHeader
                    .padding(.bottom, 24)

                VStack(spacing: 16) {
                    ForEach(pickedSentences) { sentence in
                        RetryCard(
                            sentence: sentence,
                            isDone: completedIDs.contains(sentence.id)
                        ) {
                            store.startRetrySession(sentence: sentence)
                            showPractice = true
                        }
                    }
                }
                .padding(.horizontal)

                refreshButton
                    .padding(.top, 32)
                    .padding(.bottom, 16)
            }
            .padding(.top, 8)
        }
    }

    private var progressHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                ForEach(0..<pickedSentences.count, id: \.self) { idx in
                    let done = idx < pickedSentences.count && completedIDs.contains(pickedSentences[idx].id)
                    Circle()
                        .fill(done ? Color.accentColor : Color(.systemGray4))
                        .frame(width: 10, height: 10)
                        .animation(.spring(), value: done)
                }
            }
            Text("\(completedIDs.count) of \(pickedSentences.count) done")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }

    private var refreshButton: some View {
        Button {
            completedIDs.removeAll()
            pickSentences()
        } label: {
            Label("Pick different sentences", systemImage: "arrow.clockwise")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            Text("Nothing to retry!")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Sentences where you scored below 85 will appear here.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - All Done State

    private var allDoneState: some View {
        VStack(spacing: 20) {
            Image(systemName: "star.fill")
                .font(.system(size: 60))
                .foregroundColor(.yellow)
            Text("Great work!")
                .font(.title)
                .fontWeight(.bold)
            Text("You've finished today's retry set.")
                .font(.body)
                .foregroundColor(.secondary)
            Button {
                completedIDs.removeAll()
                pickSentences()
            } label: {
                Label("Practice more", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Selection Logic

    private func pickSentences() {
        let pool = store.allSentences()
            .filter { $0.targetLanguage == store.settings.targetLanguage }
            .filter { ($0.bestScore ?? 0) < 85 }

        guard !pool.isEmpty else { pickedSentences = []; return }

        // Sort by score ascending (worst first), break ties by most recent
        let sorted = pool.sorted {
            let ls = $0.bestScore ?? 0; let rs = $1.bestScore ?? 0
            if ls != rs { return ls < rs }
            return $0.createdAt > $1.createdAt
        }

        // Pick up to 3 with variety: spread across difficulty levels if possible
        var picked: [Sentence] = []
        var usedDifficulties: Set<Int> = []

        // First pass: one per difficulty tier
        for sentence in sorted where picked.count < 3 {
            if !usedDifficulties.contains(sentence.difficultyLevel) {
                picked.append(sentence)
                usedDifficulties.insert(sentence.difficultyLevel)
            }
        }
        // Fill remaining slots from worst-score pool (no duplicate sentences)
        let pickedIDs = Set(picked.map(\.id))
        for sentence in sorted where picked.count < 3 && !pickedIDs.contains(sentence.id) {
            picked.append(sentence)
        }

        pickedSentences = picked
    }

    private func refreshPickedSentences() {
        let all = store.allSentences()
        pickedSentences = pickedSentences.map { old in
            all.first(where: { $0.id == old.id }) ?? old
        }
    }
}

// MARK: - Retry Card

private struct RetryCard: View {
    let sentence: Sentence
    let isDone: Bool
    let onTap: () -> Void

    private var scoreColor: Color {
        guard let score = sentence.bestScore else { return .secondary }
        if score >= 75 { return .orange }
        if score >= 50 { return .yellow }
        return .red
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // Score badge
                ZStack {
                    Circle()
                        .fill(isDone ? Color.green.opacity(0.15) : scoreColor.opacity(0.12))
                        .frame(width: 52, height: 52)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.green)
                    } else if let score = sentence.bestScore {
                        Text("\(score)")
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(scoreColor)
                    } else {
                        Image(systemName: "questionmark")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }

                // Sentence info
                VStack(alignment: .leading, spacing: 4) {
                    Text(sentence.englishText)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(isDone ? .secondary : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        Text("Difficulty \(sentence.difficultyLevel)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if isDone {
                            Text("Done")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.green)
                        }
                    }
                }

                Spacer()

                if !isDone {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
            .background(Color(.systemGray6))
            .cornerRadius(16)
            .opacity(isDone ? 0.7 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDone)
    }
}

#Preview {
    NavigationView {
        RetryView()
    }
    .environmentObject(AppStore())
}
