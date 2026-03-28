import SwiftUI

struct BadgeView: View {
    let badge: Badge
    let isLocked: Bool
    var compact: Bool = false

    private var iconColor: Color {
        isLocked ? .gray : badgeColor
    }

    private var badgeColor: Color {
        switch badge.id {
        case "perfect_score", "level_25": return .yellow
        case "day_3_streak", "day_7_streak", "day_30_streak": return .orange
        case "level_5", "level_10": return .purple
        case "score_50_avg", "score_75_avg": return .blue
        case "difficulty_5", "difficulty_10": return .red
        case "sentences_100": return .green
        default: return .accentColor
        }
    }

    var body: some View {
        if compact {
            compactBody
        } else {
            fullBody
        }
    }

    private var compactBody: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: badge.iconSystemName)
                    .font(.title3)
                    .foregroundColor(iconColor)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .offset(x: 14, y: 14)
                }
            }
            Text(badge.name)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(isLocked ? .secondary : .primary)
                .frame(width: 60)
        }
    }

    private var fullBody: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: badge.iconSystemName)
                    .font(.title2)
                    .foregroundColor(iconColor)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .offset(x: 16, y: 16)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(badge.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(isLocked ? .secondary : .primary)
                Text(badge.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !isLocked {
                    Text("Unlocked \(badge.unlockedAt, style: .date)")
                        .font(.caption2)
                        .foregroundColor(badgeColor)
                }
            }
            Spacer()
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .opacity(isLocked ? 0.6 : 1.0)
    }
}
