import SwiftUI

/// The day is capped, so once it is over the main screen has something better
/// to show than three dead buttons: everything the tutor said today, ranked,
/// and the two decisions the learner makes about it — keep it, or see it again.
struct DayScreen: View {
    @Bindable var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                GradingPanel(store: store)
                tally
                section("To fix", store.todayFindings.filter(\.isProblem))
                section("Got right", store.todayFindings.filter { !$0.isProblem })
            }
            .padding(Theme.M.gap)
        }
    }

    private var tally: some View {
        Panel(fill: Theme.C.sunk) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(store.todayTally.attempts) attempts · average \(store.todayTally.average)")
                    .font(Theme.F.body)
                Text(Mode.allCases
                    .map { "\($0.name) \(store.tally($0).done)" }
                    .joined(separator: " · "))
                    .font(Theme.F.meta)
                    .foregroundStyle(Theme.C.ink2)
            }
        }
    }

    /// Both halves render the same row: what held is worth keeping and worth
    /// seeing again just as much as what broke.
    @ViewBuilder
    private func section(_ title: String, _ rows: [DayFinding]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ModuleLabel(text: title)
                ForEach(rows) { finding in
                    DayFindingRow(
                        finding: finding,
                        kept: store.isKept(finding.id),
                        due: store.progress.dueLabel(finding.id),
                        onOpen: { store.open(finding.atom) },
                        onKeep: {
                            if store.isKept(finding.id) { store.unkeep(finding.id) }
                            else { store.keep(finding) }
                        },
                        onReturn: {
                            store.setReturn(finding.atom,
                                            wanted: !store.progress.returns(finding.id))
                        }
                    )
                }
            }
        }
    }
}

/// A finding at the end of the day. Still openable — the atoms kept their
/// seeds — with the keep and bring-back decisions under it.
private struct DayFindingRow: View {
    let finding: DayFinding
    let kept: Bool
    /// When it is next due, if it is coming back at all.
    let due: String?
    let onOpen: () -> Void
    let onKeep: () -> Void
    let onReturn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 10) {
                    Text(finding.atom.kind.label.uppercased())
                        .font(Theme.F.label)
                        .tracking(1)
                        .foregroundStyle(Theme.colour(for: finding.atom.verdict))
                        .frame(width: 84, alignment: .leading)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(finding.headline)
                            .font(Theme.F.bodyTight)
                            .foregroundStyle(Theme.C.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(finding.sentence)
                            .font(Theme.F.meta)
                            .foregroundStyle(Theme.C.ink3)
                            .lineLimit(1)
                    }

                    if finding.count > 1 {
                        Text("×\(finding.count)")
                            .font(Theme.F.meta)
                            .foregroundStyle(Theme.C.accent)
                            .padding(.top, 2)
                    }

                    Text("+")
                        .font(Theme.F.meta)
                        .foregroundStyle(Theme.C.ink3)
                        .padding(.top, 2)
                }
                .padding(Theme.M.padTight)
                .background(Theme.C.surface)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.colour(for: finding.atom.verdict))
                        .frame(width: Theme.M.edge)
                }
                .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                TinyButton(title: kept ? "Saved" : "Save",
                           selected: kept, action: onKeep)
                TinyButton(title: due ?? "Bring back",
                           selected: due != nil, action: onReturn)
                Spacer()
            }
            .padding(.leading, Theme.M.edge)
        }
    }
}
