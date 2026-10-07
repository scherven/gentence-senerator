import SwiftUI

/// The day is capped, so once it is over the main screen has something better
/// to show than three dead buttons: everything the tutor said today, ranked,
/// and the two decisions the learner makes about it — keep it, or see it again.
struct DayScreen: View {
    @Bindable var store: Store
    /// The one finding showing its decisions.
    @State private var expanded: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                WordsRow(store: store)
                SpentToday(store: store)
                WrittenToday(store: store)
                GradingPanel(store: store)
                tally
                section("To fix", store.todayFindings.filter(\.isProblem))
                section("Got right", store.todayFindings.filter { !$0.isProblem })
            }
            .padding(Theme.M.gap)
        }
    }

    /// One tick per graded answer, coloured by band, then the figures.
    private var tally: some View {
        let scores = store.todayScores
        return HStack(alignment: .center, spacing: Theme.M.gapTight) {
            HStack(spacing: 3) {
                ForEach(Array(scores.enumerated()), id: \.offset) { _, score in
                    Rectangle().fill(Theme.band(score)).frame(width: 4, height: 16)
                }
            }
            Text("\(store.todayTally.attempts) · avg \(store.todayTally.average)")
                .font(Theme.F.meta)
                .foregroundStyle(Theme.C.ink2)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Both halves render the same row: what held is worth keeping and worth
    /// seeing again just as much as what broke.
    @ViewBuilder
    private func section(_ title: String, _ rows: [DayFinding]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ModuleLabel(text: title)
                LedgerSheet {
                ForEach(rows) { finding in
                    DayFindingRow(
                        finding: finding,
                        expanded: Binding(get: { expanded == finding.id },
                                          set: { expanded = $0 ? finding.id : nil }),
                        ruled: finding.id != rows.last?.id,
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
}

/// A finding at the end of the day. Tapped, it shows the keep and bring-back
/// decisions and a way into its lesson.
private struct DayFindingRow: View {
    let finding: DayFinding
    @Binding var expanded: Bool
    var ruled = true
    let kept: Bool
    /// When it is next due, if it is coming back at all.
    let due: String?
    let onOpen: () -> Void
    let onKeep: () -> Void
    let onReturn: () -> Void

    var body: some View {
        let colour = Theme.colour(for: finding.atom.verdict)
        // A tap gesture, not a Button: the decisions inside are buttons.
        LedgerRow(account: finding.atom.kind.label, colour: colour, edge: colour,
                      ruled: ruled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(finding.headline)
                        .font(Theme.F.bodyTight)
                        .foregroundStyle(Theme.C.ink)
                        .multilineTextAlignment(.leading)
                    Text(finding.sentence)
                        .font(Theme.F.meta)
                        .foregroundStyle(Theme.C.ink3)
                        .lineLimit(1)
                    if expanded {
                        HStack(spacing: 6) {
                            TinyButton(title: kept ? "Saved" : "Save", selected: kept, action: onKeep)
                            TinyButton(title: due ?? "Bring back", selected: due != nil,
                                       action: onReturn)
                            Spacer(minLength: 0)
                            TypedLink("Open", action: onOpen)
                        }
                        .padding(.top, 6)
                    }
                }
            } trailing: {
                if finding.count > 1 {
                    Text("×\(finding.count)")
                        .font(Theme.F.meta)
                        .foregroundStyle(Theme.C.ink2)
                        .padding(.trailing, 10).padding(.top, 12)
                }
            }
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .accessibilityAddTraits(.isButton)
    }
}
