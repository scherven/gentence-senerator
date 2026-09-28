import SwiftUI

/// A lesson. Identical machinery to a review — blocks, then ask.
///
/// On a third visit the rule is replaced by patterns: explaining twice already
/// failed, so a third explanation is not the move.
struct LessonScreen: View {
    let lesson: Lesson
    let priorVisits: Int
    let onOpenLink: (AtomLink) -> Void
    let onOpenSeed: (Atom.Seed, AtomKind) -> Void
    let onDrillOutcome: (Bool, Rung.Support) -> Void
    let onAsk: (String) -> Void
    let grade: (String, Rung) async -> Tutor.DrillVerdict
    let answers: [AskItem]
    let isAsking: Bool

    @State private var showRuleAnyway = false

    private var showingPatterns: Bool {
        priorVisits >= 2 && !lesson.patterns.isEmpty
    }

    private var blocks: [Block] {
        guard showingPatterns, !showRuleAnyway else { return lesson.blocks }
        return lesson.blocks.filter { $0.kind != .rule }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                header

                if showingPatterns {
                    revisitBanner("Third visit. Patterns only.")
                    BlockView(block: patternBlock,
                              onOpenLink: onOpenLink,
                              onOpenSeed: onOpenSeed,
                              onDrillOutcome: onDrillOutcome,
                              grade: grade)
                    if !showRuleAnyway {
                        TinyButton(title: "Show the rule") { showRuleAnyway = true }
                    }
                } else if priorVisits == 1 {
                    revisitBanner("Second visit. Skip to the drills.")
                }

                ForEach(blocks) { block in
                    BlockView(block: block,
                              onOpenLink: onOpenLink,
                              onOpenSeed: onOpenSeed,
                              onDrillOutcome: onDrillOutcome,
                              grade: grade)
                }

                // Practice arrives in a second call. Without this the lesson
                // reads as though it simply has none.
                if !lesson.hasPractice {
                    HStack(spacing: Theme.M.gapTight) {
                        ProgressView().tint(Theme.C.accent)
                        Text("Writing practice…")
                            .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.M.pad)
                    .background(Theme.C.surface)
                    .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
                }

                AskView(answers: answers, isAsking: isAsking,
                        onOpenLink: onOpenLink, onAsk: onAsk)
            }
            .padding(Theme.M.gap)
        }
        .background(Theme.C.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: "Lesson")
            Text(lesson.title)
                .font(Theme.F.title)
                .foregroundStyle(Theme.C.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var patternBlock: Block {
        Block(id: "\(lesson.id)-patterns", kind: .examples,
              label: "Patterns", examples: lesson.patterns)
    }

    private func revisitBanner(_ text: String) -> some View {
        Text(text)
            .font(Theme.F.bodyTight)
            .foregroundStyle(Theme.C.ink2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.M.padTight)
            .background(Theme.C.surface)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.C.warn).frame(width: Theme.M.edge)
            }
            .overlay(Rectangle().stroke(Theme.C.warn, lineWidth: Theme.M.hair))
    }
}
