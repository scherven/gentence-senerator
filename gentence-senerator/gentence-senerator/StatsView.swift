import SwiftUI
import Charts

struct StatsView: View {
    @EnvironmentObject var store: AppStore

    private var recentScores: [(index: Int, score: Int)] {
        store.currentLangProfile.recentScores.enumerated().map { (index: $0.offset, score: $0.element) }
    }

    private var allBadgeDefs: [BadgeDefinition] { BadgeDefinition.allCases }
    private var unlockedBadgeIDs: Set<String> { Set(store.currentLangProfile.unlockedBadges.map(\.id)) }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    levelSection
                    if !recentScores.isEmpty {
                        scoreChartSection
                    }
                    streakSection
                    badgesSection
                }
                .padding()
            }
            .navigationTitle("Progress")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Level Section

    private var levelSection: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Level \(store.currentLangProfile.currentLevel)")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("\(store.currentLangProfile.totalXP) total XP")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                ZStack {
                    Circle()
                        .fill(Color.yellow.opacity(0.15))
                        .frame(width: 56, height: 56)
                    Image(systemName: "trophy.fill")
                        .font(.title2)
                        .foregroundColor(.yellow)
                }
            }

            VStack(spacing: 4) {
                HStack {
                    Text("Progress to Level \(store.currentLangProfile.currentLevel + 1)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(store.xpProgressInLevel) / \(store.xpNeededForNextLevel) XP")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ProgressView(value: store.levelProgress)
                    .tint(.yellow)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(16)
    }

    // MARK: - Score Chart

    private var scoreChartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Scores")
                .font(.headline)

            Chart(recentScores, id: \.index) { item in
                LineMark(
                    x: .value("Attempt", item.index + 1),
                    y: .value("Score", item.score)
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Attempt", item.index + 1),
                    y: .value("Score", item.score)
                )
                .foregroundStyle(scoreColor(item.score))
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 75, 100])
            }
            .frame(height: 160)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(16)
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 0..<50: return .red
        case 50..<75: return .yellow
        default: return .green
        }
    }

    // MARK: - Streak Calendar

    private var streakSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "flame.fill")
                    .foregroundColor(.orange)
                Text("Streak")
                    .font(.headline)
            }

            HStack(spacing: 24) {
                VStack(spacing: 4) {
                    Text("\(store.currentLangProfile.currentStreak)")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                    Text("Current")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Divider().frame(height: 40)
                VStack(spacing: 4) {
                    Text("\(store.currentLangProfile.longestStreak)")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Best")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Last 7 days indicator
            lastSevenDaysRow
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(16)
    }

    private var lastSevenDaysRow: some View {
        let lang = store.settings.targetLanguage
        let sessions = store.allSessions()
        let completedDates = Set(
            sessions.filter { $0.isComplete && $0.targetLanguage == lang }.map(\.id)
        )

        return HStack(spacing: 6) {
            ForEach(-6...0, id: \.self) { offset in
                let date = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
                let iso = isoDateString(date)
                let isComplete = completedDates.contains("\(iso)_\(lang)")
                let isToday = offset == 0

                VStack(spacing: 4) {
                    Circle()
                        .fill(isComplete ? Color.orange : Color(.systemGray4))
                        .frame(width: isToday ? 30 : 24, height: isToday ? 30 : 24)
                        .overlay(
                            Circle().stroke(isToday ? Color.orange : Color.clear, lineWidth: 2)
                        )
                    Text(dayLetter(date))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func dayLetter(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "E"
        return String(f.string(from: date).prefix(1))
    }

    // MARK: - Badges

    private var badgesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Badges")
                    .font(.headline)
                Spacer()
                Text("\(store.currentLangProfile.unlockedBadges.count)/\(allBadgeDefs.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            LazyVStack(spacing: 10) {
                ForEach(allBadgeDefs, id: \.rawValue) { def in
                    let isUnlocked = unlockedBadgeIDs.contains(def.rawValue)
                    let badge = store.currentLangProfile.unlockedBadges.first(where: { $0.id == def.rawValue })
                        ?? Badge(id: def.rawValue, name: def.name, description: def.description,
                                 iconSystemName: def.iconSystemName, unlockedAt: Date())
                    BadgeView(badge: badge, isLocked: !isUnlocked)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(16)
    }
}

#Preview {
    StatsView()
        .environmentObject(AppStore())
}
