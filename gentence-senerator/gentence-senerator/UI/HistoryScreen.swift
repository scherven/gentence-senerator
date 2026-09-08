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
                    if !kept.isEmpty { saved }
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

    /// Kept by hand off a day's summary, newest first. Not scheduling — this
    /// is the shelf, and nothing on it comes back unless it was also asked for.
    private var kept: [BankEntry] {
        store.bank.filter { $0.language == store.settings.language }.reversed()
    }

    private var saved: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: "Saved")
            ForEach(kept) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(entry.kind.label.uppercased())
                            .font(Theme.F.label)
                            .foregroundStyle(Theme.C.accent)
                            .frame(width: 84, alignment: .leading)
                        Text(entry.subject)
                            .font(Theme.F.bodyTight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        TinyButton(title: "Forget") { store.unkeep(entry.atomID) }
                    }
                    if !entry.fix.isEmpty {
                        Text(entry.fix).font(Theme.F.targetSmall)
                    }
                    Text(entry.note).font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                    Text(entry.sentence)
                        .font(Theme.F.meta).foregroundStyle(Theme.C.ink3).lineLimit(1)
                }
                .padding(Theme.M.padTight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.C.surface)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.C.accent).frame(width: Theme.M.edge)
                }
                .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
            }
        }
    }

    /// Everything scheduled to return, plus anything opened more than once.
    /// Marking a finding "New to me" schedules it without opening a lesson, so
    /// filtering on visits alone hid exactly the thing the learner just asked
    /// to be reminded of.
    private var weakest: [Progress.Encounter] {
        store.progress.encounters.values
            .filter { $0.language == store.settings.language
                      && ($0.dueAt != nil || $0.visits > 1) }
            .sorted { left, right in
                let a = left.dueAt ?? .distantFuture
                let b = right.dueAt ?? .distantFuture
                return a == b ? left.visits > right.visits : a < b
            }
            .prefix(8)
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
                        // Something picked off a day's summary has no visits,
                        // no sightings and no verdict, and "×0" says nothing
                        // about it.
                        Text(encounter.knowledge == .gap ? "NEW"
                             : encounter.knowledge == .slip ? "SLIP"
                             : encounter.visits > 0 ? "×\(encounter.visits)"
                             : encounter.sightings > 0 ? "SEEN ×\(encounter.sightings)"
                             : "PICKED")
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
            exchange: store.exchange(endingAt: turn),
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
            answers: store.asked[turn.id.uuidString] ?? [],
            isAsking: store.asking.contains(turn.id.uuidString),
            deepening: false,
            streaming: false,
            depthError: nil,
            onRetryDepth: {}
        )
        .navigationTitle(turn.mode.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
