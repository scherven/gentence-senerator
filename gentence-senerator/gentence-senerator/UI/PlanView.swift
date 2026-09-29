import SwiftUI

/// The day before it starts. Four rows saying what has been picked, then the
/// record: every structure the learner could be asked for at this level, one
/// row per band.
///
/// It sits under the mode cards on the start screen rather than behind a tap,
/// because a screen nobody opens cannot be audited — what is coming is in front
/// of them when they choose to begin. `DayScreen` keeps the other end of the
/// day, which is a different question entirely.
///
/// Two colours, and each means one thing. Green is what they have; orange is
/// what today is. What is due is not on the map: being due is a fact about the
/// schedule, not about knowledge, and `Theme.C.warn` already means `weakens`
/// everywhere else in the app. Due appears in the Back row instead.
struct PlanView: View {
    let plan: DayPlan

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(plan.rows) { row in SlotRow(row: row) }
            }
            if !plan.bands.isEmpty { record }
        }
    }

    private var record: some View {
        Panel {
            VStack(alignment: .leading, spacing: Theme.M.pad) {
                ForEach(plan.bands) { band in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(band.name.uppercased())
                                .font(Theme.F.label).tracking(1.1)
                            Spacer()
                            Text("\(band.held) of \(band.cells.count)")
                                .font(Theme.F.label)
                        }
                        .foregroundStyle(Theme.C.ink3)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 14), spacing: 3)],
                                  alignment: .leading, spacing: 3) {
                            ForEach(band.cells) { CellView(cell: $0) }
                        }
                    }
                }
                legend
            }
        }
    }

    private var legend: some View {
        StateLegend(states: [.never, .tried, .holding, .solid])
    }
}

/// One of the four ways the day is chosen: the kind, how many, and the thing.
private struct SlotRow: View {
    let row: DayPlan.Row

    var body: some View {
        if row.slot.label != nil || !row.items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if let label = row.slot.label {
                    HStack(alignment: .firstTextBaseline) {
                        Text(label.uppercased())
                            .font(Theme.F.label).tracking(1.1)
                            .foregroundStyle(Theme.C.ink3)
                        Spacer()
                        Text("\(row.items.count)")
                            .font(Theme.F.label)
                            .foregroundStyle(row.items.isEmpty ? Theme.C.ink3 : Theme.C.accent)
                    }
                }
                if row.items.isEmpty {
                    Text("—").font(Theme.F.body).foregroundStyle(Theme.C.ink3)
                } else {
                    Text(row.items.joined(separator: "  ·  "))
                        .font(isTarget ? Theme.F.targetSmall : Theme.F.body)
                        .foregroundStyle(Theme.C.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.M.padTight)
            .background(Theme.C.surface)
            .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
        }
    }

    /// Two of the rows hold words in the language being learned, and a learner
    /// needs to see the strokes.
    private var isTarget: Bool { row.slot == .words || row.slot == .new }
}

/// One point. Four steps of one hue, so the fill alone carries the state and
/// nothing here depends on colour vision. Today's stretch is marked rather than
/// filled — it is not a state of knowledge, it is what happens next.
private struct CellView: View {
    let cell: DayPlan.Cell

    var body: some View {
        if cell.today {
            Rectangle().strokeBorder(Theme.C.accent, lineWidth: 2).frame(width: 14, height: 14)
        } else {
            StateCell(LedgerState(cell.standing), size: 14)
        }
    }
}
