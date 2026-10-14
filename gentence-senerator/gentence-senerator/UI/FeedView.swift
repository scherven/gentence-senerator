import SwiftUI

/// Every result in the current language, newest first, by day: sentences,
/// quiz rounds, word decks, dialogues. A sentence opens its review; a point
/// under it opens the point.
struct FeedView: View {
    @Bindable var store: Store
    @Environment(\.openPoint) private var openPoint
    @State private var shown = 60

    var body: some View {
        let items = Array(store.feed.prefix(shown))
        let days = Dictionary(grouping: items) { Spend.key($0.at) }
        let order = days.keys.sorted(by: >)
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            if items.isEmpty {
                Text("Nothing yet.").font(Theme.F.note).foregroundStyle(Theme.C.ink2)
            }
            ForEach(order, id: \.self) { day in
                let rows = days[day] ?? []
                VStack(alignment: .leading, spacing: 6) {
                    ModuleLabel(text: HistoryDay.label(day))
                    LedgerSheet {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
                            row(item, ruled: i < rows.count - 1)
                        }
                    }
                }
            }
            if store.feed.count > shown {
                TypedLink("More") { shown += 60 }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: LearnerRecord.FeedItem, ruled: Bool) -> some View {
        let colour = colour(item)
        let line = LedgerRow(account: account(item.kind), colour: colour, edge: colour,
                             accountWidth: 64, ruled: ruled) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.feedTitle(item))
                    .font(item.kind == .quiz || item.kind == .words
                          ? Theme.F.bodyTight : Theme.F.target(size: 15, for: item.language))
                    .foregroundStyle(Theme.C.ink)
                    .lineLimit(3)
                if !item.detail.isEmpty {
                    let fix = item.kind == .translate || item.kind == .produce
                    Text(fix ? "→ " + item.detail : item.detail)
                        .font(fix ? Theme.F.target(size: 15, for: item.language) : Theme.F.note)
                        .foregroundStyle(fix ? Theme.C.good : Theme.C.ink2)
                        .lineLimit(3)
                }
                ForEach(item.points.compactMap { store.point($0) }.prefix(2), id: \.id) { point in
                    TypedLink(point.name) { openPoint(point.id) }
                }
            }
        } trailing: {
            Text(score(item))
                .font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                .padding(.vertical, 12).padding(.trailing, 10)
        }
        if store.canOpen(item) {
            Button { store.open(item) } label: { line.contentShape(Rectangle()) }
                .buttonStyle(PressDim())
        } else {
            line
        }
    }

    private func account(_ kind: LearnerRecord.FeedItem.Kind) -> String {
        switch kind {
        case .translate: return "Trans"
        case .produce:   return "Prod"
        case .listen:    return "Listen"
        case .quiz:      return "Quiz"
        case .words:     return "Words"
        }
    }

    private func score(_ item: LearnerRecord.FeedItem) -> String {
        if item.kind == .quiz || item.kind == .words { return "\(item.right)/\(item.total)" }
        return item.score.map(String.init) ?? "—"
    }

    private func colour(_ item: LearnerRecord.FeedItem) -> Color {
        if item.kind == .quiz || item.kind == .words {
            return item.total > 0 && item.right == item.total ? Theme.C.good
                : item.right * 2 >= item.total ? Theme.C.warn : Theme.C.bad
        }
        switch item.verdict {
        case .breaks:  return Theme.C.bad
        case .weakens: return Theme.C.warn
        case .clean:   return Theme.C.good
        case nil:      return item.score.map(Theme.band) ?? Theme.C.ink3
        }
    }
}
