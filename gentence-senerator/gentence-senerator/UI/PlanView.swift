import SwiftUI

/// The day before it starts: what is new and what is coming back, then the
/// record, one band per level. Green is what the learner has; the accent
/// outline is today's stretch. Due items are in the Back row, not the map.
struct PlanView: View {
    let plan: DayPlan

    /// The stretch and the words are on the Produce key; these are the rest.
    private var rows: [DayPlan.Row] {
        plan.rows.filter { $0.slot.label != nil && !$0.items.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            if !rows.isEmpty {
                LedgerSheet {
                    ForEach(rows) { row in
                        SlotRow(row: row, ruled: row.id != rows.last?.id)
                    }
                }
            }
            if !plan.bands.isEmpty { record }
        }
    }

    private var record: some View {
        Panel {
            VStack(alignment: .leading, spacing: Theme.M.pad) {
                ForEach(plan.bands) { band in
                    VStack(alignment: .leading, spacing: 5) {
                        ModuleLabel(text: band.name, trailing: "\(band.held)/\(band.cells.count)")
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
    var ruled = true

    var body: some View {
        LedgerRow(account: row.slot.label ?? "", accountWidth: 76, ruled: ruled) {
            Text(row.items.joined(separator: "  ·  "))
                .font(isTarget ? Theme.F.targetSmall : Theme.F.bodyTight)
                .foregroundStyle(Theme.C.ink)
                .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            Text("\(row.items.count)")
                .font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                .padding(.trailing, 10).padding(.top, 12)
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
