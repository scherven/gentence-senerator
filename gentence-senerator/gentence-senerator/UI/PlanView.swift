import SwiftUI

/// The day before it starts: the record, one band per level. Green is what
/// the learner has; the accent outline is today's stretch.
struct PlanView: View {
    let plan: DayPlan

    var body: some View {
        if !plan.bands.isEmpty { record }
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
