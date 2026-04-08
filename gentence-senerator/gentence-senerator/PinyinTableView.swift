import SwiftUI

// MARK: - Pinyin Reference Chart

struct PinyinTableView: View {
    @EnvironmentObject var store: AppStore
    let phonemeData: (initials: [AppStore.PhonemeStats], finals: [AppStore.PhonemeStats])

    @State private var lastSpoken: String = ""

    // Standard Mandarin pinyin rows: (initial, [valid finals])
    // Empty initial = standalone vowel syllables
    private let pinyinRows: [(String, [String])] = [
        ("",   ["a","o","e","er","ai","ei","ao","ou","an","en","ang","eng"]),
        ("b",  ["a","o","ai","ei","ao","an","en","ang","eng","i","ie","iao","in","ing","u"]),
        ("p",  ["a","o","ai","ei","ao","an","en","ang","eng","i","ie","iao","in","ing","u"]),
        ("m",  ["a","o","e","ai","ei","ao","ou","an","en","ang","eng","i","ie","iao","in","ing","u"]),
        ("f",  ["a","o","ei","ao","ou","an","en","ang","eng","u"]),
        ("d",  ["a","e","ai","ei","ao","ou","an","en","ang","eng","i","ie","iao","iu","ing","u","un","uo"]),
        ("t",  ["a","e","ai","ei","ao","ou","an","ang","eng","i","ie","iao","ing","u","un","uo"]),
        ("n",  ["a","e","ai","ei","ao","ou","an","en","ang","eng","i","ie","iao","iu","in","ing","u","un","uo","v","ve"]),
        ("l",  ["a","e","ai","ei","ao","ou","an","ang","eng","i","ie","iao","iu","in","ing","u","un","uo","v","ve"]),
        ("g",  ["a","e","ai","ei","ao","ou","an","en","ang","eng","u","ui","un","uo"]),
        ("k",  ["a","e","ai","ei","ao","ou","an","ang","eng","u","ui","un","uo"]),
        ("h",  ["a","e","ai","ei","ao","ou","an","en","ang","eng","u","ui","un","uo"]),
        ("j",  ["i","ia","ie","iao","iu","ian","in","ing","iong","u","ue","uan","un"]),
        ("q",  ["i","ia","ie","iao","iu","ian","in","ing","iong","u","ue","uan","un"]),
        ("x",  ["i","ia","ie","iao","iu","ian","in","ing","u","ue","uan","un"]),
        ("zh", ["a","e","ai","ei","ao","ou","an","en","ang","eng","i","u","ui","un","uo"]),
        ("ch", ["a","e","ai","ao","ou","an","ang","eng","i","u","ui","un","uo"]),
        ("sh", ["a","e","ai","ei","ao","ou","an","ang","eng","i","u","ui","un","uo"]),
        ("r",  ["e","ao","ou","an","ang","en","eng","i","u","ui","un","uo"]),
        ("z",  ["a","e","ai","ao","ou","an","ang","en","eng","i","u","ui","un","uo"]),
        ("c",  ["a","e","ai","ao","ou","an","ang","en","eng","i","u","ui","un","uo"]),
        ("s",  ["a","e","ai","ao","ou","an","ang","en","eng","i","u","ui","un","uo"]),
        ("y",  ["a","e","o","ao","ou","an","ang","in","ing","u","ue","uan","un"]),
        ("w",  ["a","o","ai","ei","an","ang","en","ei","u"]),
    ]

    // Build score lookup from phonemeData
    private var initialScoreMap: [String: Int] {
        Dictionary(phonemeData.initials.map { ($0.phoneme, $0.avgScore) }, uniquingKeysWith: { a, _ in a })
    }
    private var finalScoreMap: [String: Int] {
        Dictionary(phonemeData.finals.map { ($0.phoneme, $0.avgScore) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                legend
                    .padding(.horizontal)
                    .padding(.vertical, 12)

                ForEach(pinyinRows, id: \.0) { (initial, finals) in
                    rowView(initial: initial, finals: finals)
                }
            }
        }
        .navigationTitle("Pinyin Chart")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 16) {
            Text("Tap to hear")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            legendDot(.green,  "≥75%")
            legendDot(.orange, "50–74%")
            legendDot(.red,    "<50%")
            legendDot(Color(.systemGray4), "No data")
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: - Row

    private func rowView(initial: String, finals: [String]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Initial label
            Text(initial.isEmpty ? "∅" : initial)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(.secondary)
                .frame(width: 32, alignment: .center)
                .padding(.top, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(finals, id: \.self) { final_ in
                        let syllable = initial + final_
                        syllableCell(syllable: syllable, initial: initial, final_: final_)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 4)
        return Divider().padding(.leading, 36)
    }

    // MARK: - Cell

    private func syllableCell(syllable: String, initial: String, final_: String) -> some View {
        let isPlaying = store.speech.isSpeaking && lastSpoken == syllable
        let bg = cellColor(initial: initial, final_: final_)

        return Button {
            lastSpoken = syllable
            store.speech.speak(text: syllable, language: "Mandarin")
        } label: {
            Text(syllable)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(isPlaying ? .white : .primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isPlaying ? Color.accentColor : bg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isPlaying ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Color logic

    /// Returns the background color for a cell based on available performance data.
    /// Prefers initial score if available, falls back to final score, then no-data gray.
    private func cellColor(initial: String, final_: String) -> Color {
        let score: Int?
        if !initial.isEmpty, let s = initialScoreMap[initial] {
            score = s
        } else if !final_.isEmpty, let s = finalScoreMap[final_] {
            score = s
        } else {
            score = nil
        }
        guard let s = score else { return Color(.systemGray5) }
        switch s {
        case 0..<50: return .red.opacity(0.25)
        case 50..<75: return .orange.opacity(0.25)
        default: return .green.opacity(0.22)
        }
    }
}

#Preview {
    NavigationView {
        PinyinTableView(phonemeData: (initials: [], finals: []))
    }
    .environmentObject(AppStore())
}
