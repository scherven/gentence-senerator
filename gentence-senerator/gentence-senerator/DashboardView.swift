import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var store: AppStore
    @Binding var selectedTab: Int

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    headerSection
                    progressSection
                    statsSection
                    if !store.profile.unlockedBadges.isEmpty {
                        recentBadgesSection
                    }
                    startButton
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting + "!")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(store.settings.targetLanguage + " Practice")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            difficultyPill
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(16)
    }

    private var difficultyPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "speedometer")
                .font(.caption)
            Text("Lvl \(store.profile.currentDifficultyLevel)/10")
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.15))
        .foregroundColor(.accentColor)
        .cornerRadius(20)
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Today's Progress")
                    .font(.headline)
                Spacer()
                Text("\(store.todayCompletedCount)/\(store.todayGoal)")
                    .font(.headline)
                    .foregroundColor(.accentColor)
            }

            ProgressView(value: Double(store.todayCompletedCount), total: Double(max(1, store.todayGoal)))
                .tint(store.todayCompletedCount >= store.todayGoal ? .green : .accentColor)
                .scaleEffect(x: 1, y: 2)

            if store.todayCompletedCount >= store.todayGoal {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("All done for today!")
                        .font(.subheadline)
                        .foregroundColor(.green)
                }
            }

            VStack(spacing: 4) {
                HStack {
                    Text("Level \(store.profile.currentLevel)")
                        .font(.caption)
                        .fontWeight(.medium)
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

    // MARK: - Stats

    private var statsSection: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatCard(title: "Streak", value: "\(store.profile.currentStreak)", color: .orange, icon: "flame.fill")
            StatCard(title: "Total XP", value: "\(store.profile.totalXP)", color: .yellow, icon: "star.fill")
            StatCard(title: "Avg Score", value: store.profile.recentScores.isEmpty ? "—" : "\(Int(store.averageScore))%", color: .blue, icon: "chart.line.uptrend.xyaxis")
            StatCard(title: "Sentences", value: "\(store.profile.totalSentencesCompleted)", color: .purple, icon: "text.bubble.fill")
        }
    }

    // MARK: - Recent Badges

    private var recentBadgesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Badges")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(store.profile.unlockedBadges.suffix(5).reversed()) { badge in
                        BadgeView(badge: badge, isLocked: false, compact: true)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(16)
    }

    // MARK: - Start Button

    private var startButton: some View {
        Button {
            selectedTab = 1
        } label: {
            HStack {
                Image(systemName: store.todayCompletedCount >= store.todayGoal ? "checkmark.circle.fill" : "mic.fill")
                Text(store.todayCompletedCount >= store.todayGoal ? "Review Today's Practice" : "Start Today's Practice")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(store.todayCompletedCount >= store.todayGoal ? Color.green : Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(16)
        }
    }
}

#Preview {
    DashboardView(selectedTab: .constant(0))
        .environmentObject(AppStore())
}
