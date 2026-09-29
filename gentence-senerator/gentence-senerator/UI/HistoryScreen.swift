import SwiftUI

/// Past days' feedback, and what keeps coming back. Today's stays on the main
/// screen until the day is over.
struct HistoryScreen: View {
    @Bindable var store: Store

    var body: some View {
        let days = store.history
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.M.gap) {
                    ActivityCalendar(store: store, targets: Set(days.map(\.day))) { day in
                        withAnimation { proxy.scrollTo(day, anchor: .top) }
                    }
                    if !weakest.isEmpty { recurring }
                    ForEach(days) { block($0) }
                }
                .padding(.horizontal, Theme.M.gap)
                .padding(.vertical, Theme.M.gap)
            }
        }
        .background(Theme.C.ground)
        .toolbar(.hidden, for: .navigationBar)
        .pageHeader(title: "History", centred: false)
    }

    // MARK: Recurring

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
            ModuleLabel(text: "Recurring")
            LedgerSheet {
                ForEach(Array(weakest.enumerated()), id: \.element.id) { i, encounter in
                    Button { store.open(encounter) } label: {
                        LedgerRow(account: encounter.kind.label, colour: Theme.C.accent,
                                  ruled: i < weakest.count - 1) {
                            Text(encounter.subject)
                                .font(Theme.F.target(size: 15, for: encounter.language))
                                .foregroundStyle(Theme.C.ink)
                                .lineLimit(2)
                        } trailing: {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(encounter.dueLabel)
                                    .foregroundStyle(overdue(encounter) ? Theme.C.warn : Theme.C.ink2)
                                Text(standing(encounter)).foregroundStyle(Theme.C.ink3)
                            }
                            .font(Theme.F.meta)
                            .padding(.vertical, 12).padding(.trailing, 10)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressDim())
                }
            }
        }
    }

    /// Something picked off a day's summary has no visits, no sightings and
    /// no verdict, and "×0" says nothing about it.
    private func standing(_ e: Progress.Encounter) -> String {
        e.knowledge == .gap ? "new"
            : e.knowledge == .slip ? "slip"
            : e.visits > 0 ? "×\(e.visits)"
            : e.sightings > 0 ? "seen ×\(e.sightings)"
            : "picked"
    }

    private func overdue(_ e: Progress.Encounter) -> Bool {
        guard let due = e.dueAt else { return false }
        return due < Calendar.current.startOfDay(for: .now)
    }

    // MARK: Archive

    private func block(_ day: HistoryDay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: day.label)
            LedgerSheet {
                ForEach(Array(day.rows.enumerated()), id: \.element.id) { i, row in
                    let ruled = i < day.rows.count - 1
                    switch row {
                    case .session(let s): session(s, ruled: ruled)
                    case .quiz(let name, let score): quiz(name, score, ruled: ruled)
                    }
                }
            }
        }
        .id(day.day)
    }

    /// The whole row opens the review, on Today.
    @ViewBuilder
    private func session(_ s: Session, ruled: Bool) -> some View {
        let row = LedgerRow(account: s.mode.name, colour: s.isGraded ? Theme.C.accent : Theme.C.ink3,
                            ruled: ruled) {
            Text(s.firstAnswer ?? "—")
                .font(Theme.F.target(size: 15, for: s.language))
                .foregroundStyle(Theme.C.ink)
                .lineLimit(1)
        } trailing: {
            Text(s.isGraded ? "\(s.completedCount) · \(s.averageScore)" : "\(s.completedCount) · —")
                .font(Theme.F.meta)
                .foregroundStyle(s.isGraded && s.averageScore < 60 ? Theme.C.bad : Theme.C.ink2)
                .padding(.vertical, 12).padding(.trailing, 10)
        }
        if s.isGraded {
            Button { store.read(s) } label: { row.contentShape(Rectangle()) }
                .buttonStyle(PressDim())
        } else {
            row
        }
    }

    private func quiz(_ name: String, _ score: QuizLog.Score, ruled: Bool) -> some View {
        LedgerRow(account: "Quiz", colour: Theme.C.ink3, ruled: ruled) {
            Text(name)
                .font(Theme.F.bodyTight)
                .foregroundStyle(Theme.C.ink)
                .lineLimit(1)
        } trailing: {
            Text("\(score.right)/\(score.total)")
                .font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                .padding(.vertical, 12).padding(.trailing, 10)
        }
    }
}
