import SwiftUI

/// Past days' feedback, and what keeps coming back. Today's stays on the main
/// screen until the day is over.
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
        }
        .tint(Theme.C.accent)
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

    /// One block per day, newest first.
    private var sessions: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            if store.archive.isEmpty {
                ModuleLabel(text: "Sessions")
                Text("Nothing from before today.")
                    .font(Theme.F.note).foregroundStyle(Theme.C.ink3)
            }
            ForEach(store.archive) { day in
                VStack(alignment: .leading, spacing: 6) {
                    ModuleLabel(text: day.day)
                    VStack(spacing: 0) {
                        ForEach(day.sessions) { session in row(session) }
                    }
                }
            }
        }
    }

    /// Read opens on the main screen, the way today's feedback does.
    private func row(_ session: Session) -> some View {
        let graded = session.turns.contains { $0.review != nil }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(session.mode.name.uppercased())
                .font(Theme.F.label).tracking(1)
                .foregroundStyle(graded ? Theme.C.accent : Theme.C.ink3)
                .frame(width: 84, alignment: .leading)
            Text(session.language.name)
                .font(Theme.F.bodyTight)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(graded ? "\(session.completedCount) · avg \(session.averageScore)"
                        : "\(session.completedCount) · ungraded")
                .font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
            if graded {
                TinyButton(title: "Read") {
                    dismiss()
                    store.read(session)
                }
            }
        }
        .padding(Theme.M.padTight)
        .background(Theme.C.surface)
        .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
    }
}
