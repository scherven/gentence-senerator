import SwiftUI

/// Where listen opens: one suggestion, then every dialogue with how it stands.
/// The suggestion is the top of the shelf's own order — half done, then due
/// again, then the shortest new one.
struct DialoguePicker: View {
    @Bindable var store: Store
    @State private var filter: Filter = .all
    @State private var opened: ShelfEntry?

    enum Filter: String, CaseIterable {
        case all, new, done
    }

    var body: some View {
        let shelf = store.shelf
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                if let next = shelf.first {
                    upNext(next)
                    filters
                    let rest = shelf.dropFirst().filter(keep)
                    if !rest.isEmpty {
                        LedgerSheet {
                            ForEach(rest) { entry in
                                Button { opened = entry } label: {
                                    row(entry, ruled: entry.id != rest.last?.id)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(PressDim())
                            }
                        }
                    }
                }
            }
            .padding(Theme.M.gap)
        }
        .sheet(item: $opened) { entry in
            detail(entry)
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.C.ground)
        }
    }

    private func keep(_ entry: ShelfEntry) -> Bool {
        switch filter {
        case .all:  return true
        case .new:  return entry.status == .new
        case .done: return entry.status.isHeard
        }
    }

    // MARK: Up next

    private func upNext(_ entry: ShelfEntry) -> some View {
        Panel(fill: Theme.C.sunk, edge: Theme.C.accent) {
            Text(kicker(entry).uppercased())
                .font(Theme.F.label).tracking(Theme.M.caps)
                .foregroundStyle(Theme.C.accent)
            Text(entry.passage.title).font(Theme.F.title)
            Text(entry.passage.setup).font(Theme.F.bodyTight).foregroundStyle(Theme.C.ink2)
            Text(meta(entry.passage, speakers: true)).font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
            ActionKey(verb(entry)) { store.choosePassage(entry.id) }
                .padding(.top, 4)
        }
    }

    private func kicker(_ entry: ShelfEntry) -> String {
        switch entry.status {
        case .inProgress(let pass): return "Pass \(pass) of 3"
        case .due(let days), .done(let days):
            let score = entry.last.map { " · \($0.right)/\($0.asked)" } ?? ""
            return "Last heard \(ago(days))\(score)"
        case .new: return "New"
        }
    }

    private func verb(_ entry: ShelfEntry) -> String {
        switch entry.status {
        case .inProgress(let pass): return "Resume · pass \(pass)"
        case .due, .done: return "Again"
        case .new: return "Start"
        }
    }

    private var filters: some View {
        HStack(spacing: 0) {
            ForEach(Filter.allCases, id: \.self) { f in
                Button { filter = f } label: {
                    Text(f.rawValue.uppercased())
                        .font(Theme.F.label).tracking(Theme.M.caps)
                        .foregroundStyle(filter == f ? Theme.C.onAccent : Theme.C.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(filter == f ? Theme.C.accent : Theme.C.surface)
                        .overlay(Rectangle().strokeBorder(Theme.C.seam2, lineWidth: Theme.M.hair))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressDim())
            }
        }
    }

    // MARK: Rows

    private func row(_ entry: ShelfEntry, ruled: Bool) -> some View {
        let (account, colour, edge) = look(entry.status)
        return LedgerRow(account: account, colour: colour, edge: edge,
                         accountWidth: 80, ruled: ruled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.passage.title).font(Theme.F.cardTitle)
                    .foregroundStyle(Theme.C.ink).multilineTextAlignment(.leading)
                Text(entry.passage.lines.first?.text ?? "")
                    .font(Theme.F.target(size: 13)).foregroundStyle(Theme.C.ink2).lineLimit(1)
                Text(meta(entry.passage, speakers: false))
                    .font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
            }
        } trailing: {
            if let last = entry.last {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(last.right)/\(last.asked)").font(Theme.F.mono(13, bold: true))
                        .foregroundStyle(Theme.C.ink)
                    if entry.heard.count > 1 {
                        Text("×\(entry.heard.count)").font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                    }
                }
                .padding(.top, 11)
                .padding(.trailing, 10)
            }
        }
    }

    private func look(_ status: ShelfEntry.Status) -> (String, Color, Color?) {
        switch status {
        case .inProgress(let pass): return ("Pass \(pass)", Theme.C.accent, Theme.C.accent)
        case .due(let days):        return ("\(ago(days))\nDue", Theme.C.warn, Theme.C.warn)
        case .done(let days):       return (ago(days), Theme.C.good, nil)
        case .new:                  return ("New", Theme.C.ink3, nil)
        }
    }

    // MARK: Detail

    private func detail(_ entry: ShelfEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gapTight) {
                Text(entry.passage.title).font(Theme.F.title)
                Text(entry.passage.setup).font(Theme.F.body)
                Text("#\(entry.passage.lesson) · " + meta(entry.passage, speakers: true))
                    .font(Theme.F.meta).foregroundStyle(Theme.C.ink3)

                if !entry.heard.isEmpty {
                    ModuleLabel(text: "Heard").padding(.top, 6)
                    LedgerSheet {
                        ForEach(Array(entry.heard.enumerated()), id: \.offset) { i, h in
                            HStack(spacing: 10) {
                                Text(ago(Shelf.daysBetween(h.on, .now, .current)))
                                    .frame(width: 70, alignment: .leading)
                                Text("\(h.right)/\(h.asked)").bold().frame(width: 36, alignment: .leading)
                                Text("\(h.before?.word ?? "—") → \(h.after?.word ?? "—")")
                                    .foregroundStyle(Theme.C.ink2)
                                Spacer(minLength: 0)
                            }
                            .font(Theme.F.meta)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                if i < entry.heard.count - 1 {
                                    Rectangle().fill(Theme.C.seam).frame(height: Theme.M.hair)
                                }
                            }
                        }
                    }
                }

                ActionKey(verb(entry)) { opened = nil; store.choosePassage(entry.id) }
                    .padding(.top, 8)
                if case .inProgress = entry.status {
                    ActionKey("Start over", variant: .neutral) {
                        opened = nil
                        store.choosePassage(entry.id, fresh: true)
                    }
                }
            }
            .padding(Theme.M.gap)
            .padding(.top, 8)
        }
    }

    // MARK: Shared

    private func meta(_ passage: Passage, speakers: Bool) -> String {
        let seconds = Int((passage.span.map { $0.upperBound - $0.lowerBound } ?? 0).rounded())
        let length = "\(seconds / 60):" + String(format: "%02d", seconds % 60)
        let level = passage.lesson >= 2000 ? "Upper int." : "Intermediate"
        var parts = [length, "\(passage.lines.count) lines", level]
        if speakers { parts.append(passage.speakers.map(\.name).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func ago(_ days: Int) -> String {
        switch days {
        case 0:  return "Today"
        case 1:  return "1d ago"
        default: return "\(days)d ago"
        }
    }
}
