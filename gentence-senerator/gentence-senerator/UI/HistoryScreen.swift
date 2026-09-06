import SwiftUI

/// Past attempts, and what keeps coming back. Sessions were being written and
/// never read in the previous build; this is the reader.
struct HistoryScreen: View {
    @Bindable var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.M.gap) {
                    if !weakest.isEmpty { recurring }
                    sessions
                }
                .padding(Theme.M.gap)
            }
            .background(Theme.C.surface)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    TinyButton(title: "Done") { dismiss() }
                }
            }
            .navigationDestination(for: Turn.self) { turn in
                PastReview(store: store, turn: turn)
            }
        }
        .tint(Theme.C.accent)
    }

    /// Points opened more than once, most-visited first.
    private var weakest: [Progress.Encounter] {
        store.progress.encounters.values
            .filter { $0.language == store.settings.language && $0.visits > 1 }
            .sorted { $0.visits > $1.visits }
            .prefix(6)
            .map { $0 }
    }

    private var recurring: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: "Keeps coming back")
            VStack(spacing: 0) {
                ForEach(weakest) { encounter in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(encounter.kind.label.uppercased())
                            .font(Theme.F.label)
                            .foregroundStyle(Theme.C.ink3)
                            .frame(width: 84, alignment: .leading)
                        Text(encounter.subject)
                            .font(Theme.F.bodyTight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("×\(encounter.visits)")
                            .font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                        Text(encounter.dueLabel)
                            .font(Theme.F.label).foregroundStyle(Theme.C.accent)
                    }
                    .padding(Theme.M.padTight)
                    .background(Theme.C.surface)
                    .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
                }
            }
        }
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: "Sessions")
            if store.past.isEmpty {
                Text("Nothing finished yet.")
                    .font(Theme.F.note).foregroundStyle(Theme.C.ink3)
            }
            ForEach(store.past.reversed()) { session in
                VStack(spacing: 0) {
                    HStack {
                        Text("\(session.mode.name) · \(session.language.name)")
                            .font(Theme.F.bodyTight)
                        Spacer()
                        Text("\(session.completedCount) · avg \(session.averageScore)")
                            .font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                    }
                    .padding(Theme.M.padTight)
                    .background(Theme.C.sunk)
                    .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))

                    ForEach(session.turns) { turn in
                        NavigationLink(value: turn) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(turn.attempt.confirmed)
                                    .font(Theme.F.bodyTight)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let score = turn.review?.score {
                                    Text("\(score)")
                                        .font(Theme.F.meta)
                                        .foregroundStyle(Theme.C.ink2)
                                }
                                Text("+").font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                            }
                            .padding(Theme.M.padTight)
                            .background(Theme.C.surface)
                            .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// A past attempt, read with the same screen that showed it live. Findings are
/// still openable — the atoms were persisted with their seeds.
struct PastReview: View {
    @Bindable var store: Store
    let turn: Turn

    var body: some View {
        ReviewScreen(
            turn: turn,
            knowledge: store.knowledge,
            onOpenAtom: { store.open($0) },
            onOpenLink: { store.open($0, context: turn.attempt.confirmed) },
            onClassify: { store.classify($0, as: $1) },
            onAsk: { question in
                Task {
                    await store.ask(question,
                                    about: .init(subject: turn.attempt.confirmed,
                                                 context: turn.attempt.confirmed,
                                                 pointID: turn.prompt.pointID),
                                    context: turn.id.uuidString)
                }
            },
            ask: turn.review?.ask ?? [],
            answers: store.asked[turn.id.uuidString] ?? [],
            isAsking: store.asking.contains(turn.id.uuidString)
        )
        .navigationTitle(turn.mode.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
