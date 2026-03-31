import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var showResetAlert = false
    @State private var newGrammarArea = ""
    @State private var offlineDownloadCount = 10

    let languages = ["Mandarin", "French", "German", "Spanish", "Italian", "Portuguese", "Japanese", "Korean"]

    private func flag(for language: String) -> String {
        switch language {
        case "Mandarin":   return "🇨🇳"
        case "French":     return "🇫🇷"
        case "German":     return "🇩🇪"
        case "Spanish":    return "🇪🇸"
        case "Italian":    return "🇮🇹"
        case "Portuguese": return "🇵🇹"
        case "Japanese":   return "🇯🇵"
        case "Korean":     return "🇰🇷"
        default:           return "🌐"
        }
    }

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
                        store.switchLanguage(to: newValue)
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
                        Text("\(store.currentLangProfile.currentDifficultyLevel)/10")
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
                                            .fontWeight(store.currentLangProfile.currentDifficultyLevel == level ? .bold : .regular)
                                            .frame(width: 36, height: 36)
                                            .background(
                                                store.currentLangProfile.currentDifficultyLevel == level
                                                    ? Color.accentColor
                                                    : Color(.systemGray5)
                                            )
                                            .foregroundColor(
                                                store.currentLangProfile.currentDifficultyLevel == level ? .white : .primary
                                            )
                                            .clipShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        Text(store.settings.difficultyLocked
                             ? "Locked at level \(store.currentLangProfile.currentDifficultyLevel). Tap a circle to change."
                             : "Auto-adjusting based on performance. Tap a circle to override.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Lock Difficulty", isOn: $store.settings.difficultyLocked)
                        .onChange(of: store.settings.difficultyLocked) { _, locked in
                            store.setDifficultyLocked(locked)
                        }
                }

                Section(header: Text("Display")) {
                    Toggle("Show Romanization Hints", isOn: $store.settings.showRomanization)
                        .onChange(of: store.settings.showRomanization) { _, _ in store.save() }
                    Toggle("Auto-advance After Completion", isOn: $store.settings.autoAdvance)
                        .onChange(of: store.settings.autoAdvance) { _, _ in store.save() }
                }

                Section(header: Text("Progress")) {
                    NavigationLink(destination: StatsView()) {
                        HStack {
                            Label("View Progress", systemImage: "chart.bar.fill")
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Level \(store.currentLangProfile.currentLevel)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text("\(store.currentLangProfile.currentStreak) day streak")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
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
                                    let isActive = store.currentLangProfile.grammarFocusAreas.contains(pattern)
                                    Button {
                                        var areas = store.currentLangProfile.grammarFocusAreas
                                        if isActive {
                                            areas.removeAll { $0 == pattern }
                                        } else {
                                            areas.append(pattern)
                                        }
                                        store.setGrammarFocusAreas(areas)
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

                    if !store.currentLangProfile.grammarFocusAreas.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Active Focus Areas")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            FlowLayout(spacing: 6) {
                                ForEach(store.currentLangProfile.grammarFocusAreas, id: \.self) { area in
                                    HStack(spacing: 4) {
                                        Text(area)
                                            .font(.caption)
                                        Button {
                                            var areas = store.currentLangProfile.grammarFocusAreas
                                            areas.removeAll { $0 == area }
                                            store.setGrammarFocusAreas(areas)
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
                                  !store.currentLangProfile.grammarFocusAreas.contains(trimmed) else { return }
                            var areas = store.currentLangProfile.grammarFocusAreas
                            areas.append(trimmed)
                            store.setGrammarFocusAreas(areas)
                            newGrammarArea = ""
                        }
                        .disabled(newGrammarArea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section(header: Text("Offline Mode")) {
                    let lang = store.settings.targetLanguage
                    let diff = store.currentLangProfile.currentDifficultyLevel
                    let cached = store.cachedSentenceCount(language: lang, difficulty: diff)
                    HStack {
                        Text("Cached sentences")
                        Spacer()
                        Text("\(cached)")
                            .foregroundColor(.secondary)
                    }

                    Stepper("Download \(offlineDownloadCount) sentences", value: $offlineDownloadCount, in: 5...50, step: 5)

                    if store.isCachingOffline {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Downloading sentences...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Button {
                            Task { await store.prefetchSentences(count: offlineDownloadCount) }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Download for Offline Use")
                                    .fontWeight(.medium)
                            }
                        }
                    }

                    Text("Downloads \(offlineDownloadCount) sentences at difficulty \(diff)/10 for \(lang). Used automatically when you're offline.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Danger Zone")) {
                    Button("Reset All Progress") {
                        showResetAlert = true
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("\(flag(for: store.settings.targetLanguage)) \(store.settings.targetLanguage)")
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
