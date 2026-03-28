import SwiftUI

struct ScoreRingView: View {
    let score: Int
    var size: CGFloat = 120
    var lineWidth: CGFloat = 12
    @State private var animatedProgress: Double = 0

    private var scoreColor: Color {
        switch score {
        case 0..<50: return .red
        case 50..<75: return .yellow
        default: return .green
        }
    }

    var body: some View {
        ZStack {
            // Background ring
            Circle()
                .stroke(scoreColor.opacity(0.15), lineWidth: lineWidth)
                .frame(width: size, height: size)

            // Score ring
            Circle()
                .trim(from: 0, to: animatedProgress)
                .stroke(scoreColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.8), value: animatedProgress)

            // Score text
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                    .foregroundColor(scoreColor)
                Text("/ 100")
                    .font(.system(size: size * 0.12))
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            animatedProgress = Double(score) / 100.0
        }
    }
}

#Preview {
    HStack(spacing: 20) {
        ScoreRingView(score: 92)
        ScoreRingView(score: 67)
        ScoreRingView(score: 28)
    }
    .padding()
}
