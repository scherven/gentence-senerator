import SwiftUI

/// The Book front's ENDLESS slip: starts the last mix, or picks one.
struct EndlessBar: View {
    let store: Store
    @Environment(\.startQuiz) private var startQuiz
    @State private var picking = false

    var body: some View {
        let mix = store.endlessMix.flatMap { $0.isEmpty ? nil : $0 }
        HStack(spacing: Theme.M.gapTight) {
            SpeedRoundBar(title: mix.map { "ENDLESS · \(store.endlessLabel($0).uppercased())" } ?? "ENDLESS",
                          trailing: mix == nil ? "PICK ›" : "∞ ›") {
                if let mix { startQuiz(store.endlessPlan(mix)) } else { picking = true }
            }
            .lineLimit(1)
            if mix != nil {
                TinyButton(title: "Change") { picking = true }
            }
        }
        .sheet(isPresented: $picking) {
            EndlessPicker(store: store) { mix in
                picking = false
                store.saveEndlessMix(mix)
                // After the sheet is gone: one cover at a time.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    startQuiz(store.endlessPlan(mix))
                }
            }
        }
    }
}

/// Tick chapters, and for each whether to ask its rules (R), its tests (T)
/// or both; words too, if wanted. Starts with the last mix.
struct EndlessPicker: View {
    let store: Store
    let start: (QuizPlan.Mix) -> Void

    @State private var mix: QuizPlan.Mix

    init(store: Store, start: @escaping (QuizPlan.Mix) -> Void) {
        self.store = store
        self.start = start
        _mix = State(initialValue: store.endlessMix ?? QuizPlan.Mix())
    }

    var body: some View {
        let chapters = store.bookIndex.chapters.filter { !$0.formats.isEmpty }
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ModuleLabel(text: "Endless · \(store.settings.language.short)")
                        .padding(.bottom, 8)
                    wordsRow
                    ForEach(chapters) { chapterRow($0) }
                }
                .padding(Theme.M.gap)
            }
            MainButton(title: "Start", enabled: !mix.isEmpty) { start(mix) }
                .padding(Theme.M.gap)
        }
        .background(Theme.C.ground)
        .presentationDragIndicator(.visible)
    }

    private var wordsRow: some View {
        Button { mix.words.toggle() } label: {
            row(on: mix.words, name: "Words", detail: "flashcards · \(store.wordsDue) due") { EmptyView() }
        }
        .buttonStyle(.plain)
    }

    private func chapterRow(_ chapter: Chapter) -> some View {
        let rules = store.rulesCount(in: chapter)
        let tests = mix.tests.contains(chapter.id), ruled = mix.rules.contains(chapter.id)
        return HStack(spacing: 0) {
            Button { toggle(chapter, hasRules: rules > 0) } label: {
                row(on: tests || ruled, name: chapter.name,
                    detail: rules > 0 ? "\(rules) rules · tests" : "tests") { EmptyView() }
            }
            .buttonStyle(.plain)
            if rules > 0 {
                HStack(spacing: 0) {
                    side("R", on: ruled) { flip(&mix.rules, chapter.id) }
                    side("T", on: tests) { flip(&mix.tests, chapter.id) }
                }
                .overlay(Rectangle().strokeBorder(Theme.C.seam2, lineWidth: Theme.M.hair))
            }
        }
    }

    private func row<Trailing: View>(on: Bool, name: String, detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(on ? Theme.C.accent : Color.clear)
                .frame(width: 16, height: 16)
                .overlay(Rectangle().strokeBorder(on ? Theme.C.accent : Theme.C.ink2, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.F.serif(15, bold: true)).foregroundStyle(Theme.C.ink)
                Text(detail).font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.C.seam).frame(height: Theme.M.hair) }
        .contentShape(Rectangle())
    }

    private func side(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.F.mono(12, bold: true))
                .foregroundStyle(on ? Theme.C.surface : Theme.C.ink2)
                .frame(width: 34, height: 34)
                .background(on ? Theme.C.ink : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .accessibilityLabel(title == "R" ? "Rules" : "Tests")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Ticking a chapter takes everything it has; unticking drops both.
    private func toggle(_ chapter: Chapter, hasRules: Bool) {
        let on = mix.tests.contains(chapter.id) || mix.rules.contains(chapter.id)
        mix.tests.removeAll { $0 == chapter.id }
        mix.rules.removeAll { $0 == chapter.id }
        guard !on else { return }
        mix.tests.append(chapter.id)
        if hasRules { mix.rules.append(chapter.id) }
    }

    private func flip(_ list: inout [String], _ id: String) {
        if list.contains(id) { list.removeAll { $0 == id } } else { list.append(id) }
    }
}
