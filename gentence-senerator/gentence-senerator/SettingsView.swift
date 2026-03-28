import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var showResetAlert = false
    @State private var newGrammarArea = ""

    let languages = ["Mandarin", "French", "German", "Spanish", "Italian", "Portuguese", "Japanese", "Korean"]

    private let suggestedGrammarPatterns = [
        "把-sentences",
        "比较 comparisons",
        "resultative complements",
        "potential complements 得/不",
        "aspect particles 了/过/着",
        "pivotal sentences",
        "topic-comment structure",
        "serial verb construction",
        "吗 questions",
        "是...的 emphasis"
    ]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Language")) {
                    Picker("Target Language", selection: $store.settings.targetLanguage) {
                        ForEach(languages, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: store.settings.targetLanguage) { _, newValue in
                        store.updateLanguage(newValue)
                    }
                }

                Section(header: Text("Daily Goal")) {
                    Stepper("Sentences per day: \(store.settings.dailyGoal)",
                            value: $store.settings.dailyGoal, in: 1...20)
                        .onChange(of: store.settings.dailyGoal) { _, newValue in
                            store.updateDailyGoal(newValue)
                        }
                }

                Section(header: Text("Difficulty")) {
                    HStack {
                        Text("Current Level")
                        Spacer()
                        Text("\(store.profile.currentDifficultyLevel)/10")
                            .foregroundColor(.secondary)
                        if store.settings.difficultyLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Set Level")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(1...10, id: \.self) { level in
                                    Button {
                                        store.setDifficulty(level)
                                    } label: {
                                        Text("\(level)")
                                            .font(.subheadline)
                                            .fontWeight(store.profile.currentDifficultyLevel == level ? .bold : .regular)
                                            .frame(width: 36, height: 36)
                                            .background(
                                                store.profile.currentDifficultyLevel == level
                                                    ? Color.accentColor
                                                    : Color(.systemGray5)
                                            )
                                            .foregroundColor(
                                                store.profile.currentDifficultyLevel == level ? .white : .primary
                                            )
                                            .clipShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        Text(store.settings.difficultyLocked
                             ? "Locked at level \(store.profile.currentDifficultyLevel). Tap a circle to change."
                             : "Auto-adjusting based on performance. Tap a circle to override.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Lock Difficulty", isOn: $store.settings.difficultyLocked)
                        .onChange(of: store.settings.difficultyLocked) { _, _ in store.save() }
                }

                Section(header: Text("Display")) {
                    Toggle("Show Romanization Hints", isOn: $store.settings.showRomanization)
                        .onChange(of: store.settings.showRomanization) { _, _ in store.save() }
                    Toggle("Auto-advance After Completion", isOn: $store.settings.autoAdvance)
                        .onChange(of: store.settings.autoAdvance) { _, _ in store.save() }
                }

                Section(header: Text("Stats")) {
                    HStack {
                        Text("Total Sentences")
                        Spacer()
                        Text("\(store.profile.totalSentencesCompleted)").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Total XP")
                        Spacer()
                        Text("\(store.profile.totalXP)").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Level")
                        Spacer()
                        Text("\(store.profile.currentLevel)").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Longest Streak")
                        Spacer()
                        Text("\(store.profile.longestStreak) days").foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Grammar Focus")) {
                    Text("Sentences will be generated to practice these grammar patterns.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if store.settings.targetLanguage == "Mandarin" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Suggested Patterns")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            FlowLayout(spacing: 6) {
                                ForEach(suggestedGrammarPatterns, id: \.self) { pattern in
                                    let isActive = store.settings.grammarFocusAreas.contains(pattern)
                                    Button {
                                        if isActive {
                                            store.settings.grammarFocusAreas.removeAll { $0 == pattern }
                                        } else {
                                            store.settings.grammarFocusAreas.append(pattern)
                                        }
                                        store.save()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: isActive ? "checkmark.circle.fill" : "plus.circle")
                                                .font(.caption)
                                            Text(pattern)
                                                .font(.caption)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(isActive ? Color.accentColor.opacity(0.15) : Color(.systemGray5))
                                        .foregroundColor(isActive ? .accentColor : .primary)
                                        .cornerRadius(16)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if !store.settings.grammarFocusAreas.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Active Focus Areas")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            FlowLayout(spacing: 6) {
                                ForEach(store.settings.grammarFocusAreas, id: \.self) { area in
                                    HStack(spacing: 4) {
                                        Text(area)
                                            .font(.caption)
                                        Button {
                                            store.settings.grammarFocusAreas.removeAll { $0 == area }
                                            store.save()
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.1))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(16)
                                }
                            }
                        }
                    }

                    HStack {
                        TextField("Custom pattern (e.g. 把-sentences)", text: $newGrammarArea)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        Button("Add") {
                            let trimmed = newGrammarArea.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty,
                                  !store.settings.grammarFocusAreas.contains(trimmed) else { return }
                            store.settings.grammarFocusAreas.append(trimmed)
                            store.save()
                            newGrammarArea = ""
                        }
                        .disabled(newGrammarArea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section(header: Text("Danger Zone")) {
                    Button("Reset All Progress") {
                        showResetAlert = true
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Settings")
            .alert("Reset Progress?", isPresented: $showResetAlert) {
                Button("Reset", role: .destructive) { store.resetProgress() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will erase all your XP, streaks, badges, and history. This cannot be undone.")
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppStore())
}
