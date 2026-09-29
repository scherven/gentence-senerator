import SwiftUI

// One view per `Chapter.Layout`, registered in `ChapterLayoutView`.

/// One row per entry.
struct ListLayout: View {
    let rows: ChapterRows

    var body: some View {
        let groups = rows.groups
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            ForEach(groups, id: \.name) { group in
                VStack(alignment: .leading, spacing: 6) {
                    if groups.count > 1, !group.name.isEmpty { ModuleLabel(text: group.name) }
                    ForEach(group.entries) { row($0) }
                }
            }
        }
    }

    private func row(_ entry: Chapter.Entry) -> some View {
        let state = rows.state(entry)
        return NavigationLink(value: rows.route(entry)) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.head).font(Theme.F.targetSmall)
                        if let reading = entry.reading {
                            Text(reading).font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                        }
                    }
                    if let gloss = entry.gloss {
                        Text(gloss).font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                    if let meta = meta(entry, state) {
                        Text(meta).font(Theme.F.label).foregroundStyle(Theme.C.ink2)
                    }
                }
                Spacer(minLength: 0)
                if !state.recent.isEmpty { Ticks(recent: state.recent) }
            }
            .foregroundStyle(Theme.C.ink)
            .padding(.horizontal, Theme.M.pad)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if let fill = LedgerState(state).fill { Rectangle().fill(fill).frame(width: 3) }
            }
        }
        .buttonStyle(BookKeyStyle(unseen: state.standing == .never && !state.slipping,
                                  edge: state.slipping ? Theme.C.bad : nil))
    }

    private func meta(_ entry: Chapter.Entry, _ state: EntryState) -> String? {
        let parts = [rows.levels[entry.id], state.standing == .never && !state.slipping ? nil : state.label]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Cards in a 3-column grid, grouped by `group`.
struct CardsLayout: View {
    let rows: ChapterRows
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(rows.groups, id: \.name) { group in
                VStack(alignment: .leading, spacing: 6) {
                    if !group.name.isEmpty { ModuleLabel(text: group.name) }
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(group.entries) { card($0) }
                    }
                }
            }
        }
    }

    private func card(_ entry: Chapter.Entry) -> some View {
        let state = rows.state(entry)
        let unseen = state.standing == .never && !state.slipping
        return NavigationLink(value: rows.route(entry)) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top) {
                    Text(entry.head).font(Theme.F.target(size: 30)).lineLimit(1).minimumScaleFactor(0.5)
                    Spacer(minLength: 2)
                    Text(state.slipping ? "MISSED" : state.right > 0 ? "×\(state.right)" : "")
                        .font(Theme.F.label)
                        .foregroundStyle(state.slipping ? Theme.C.bad : Theme.C.ink2)
                }
                if let reading = entry.reading {
                    Text(reading).font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                }
                if let gloss = entry.gloss {
                    Text(gloss).font(Theme.F.serif(12)).lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                if let level = rows.levels[entry.id] {
                    Text(level).font(Theme.F.label).foregroundStyle(Theme.C.ink3)
                }
                Spacer(minLength: 4)
                Rectangle().fill(LedgerState(state).fill ?? .clear).frame(height: 3)
            }
            .foregroundStyle(Theme.C.ink)
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        }
        .buttonStyle(BookKeyStyle(unseen: unseen,
                                  edge: state.slipping ? Theme.C.bad : nil))
    }
}

/// `head` as a formula: fixed words, and a dashed slot for each `…`.
struct FormulasLayout: View {
    let rows: ChapterRows

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.chapter.entries) { row($0) }
        }
    }

    private func row(_ entry: Chapter.Entry) -> some View {
        let state = rows.state(entry)
        return NavigationLink(value: rows.route(entry)) {
            VStack(alignment: .leading, spacing: 6) {
                FormulaView(parts: Formula.parse(entry.head), size: 20)
                HStack(spacing: 8) {
                    Text(meta(entry, state)).font(Theme.F.label).foregroundStyle(Theme.C.ink2)
                    Spacer(minLength: 0)
                    if !state.recent.isEmpty { Ticks(recent: state.recent) }
                }
            }
            .foregroundStyle(Theme.C.ink)
            .padding(Theme.M.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(BookKeyStyle(unseen: state.standing == .never && !state.slipping,
                                  edge: state.slipping ? Theme.C.bad : nil))
    }

    private func meta(_ entry: Chapter.Entry, _ state: EntryState) -> String {
        var parts = [rows.levels[entry.id], entry.gloss?.uppercased()].compactMap { $0 }
        if state.slipping { parts.append("MISSED") }
        else if state.right > 0 { parts.append("×\(state.right)") }
        else if state.standing == .never { parts.append("NEVER USED") }
        return parts.joined(separator: " · ")
    }
}

/// The formula itself, reused large on the entry page.
struct FormulaView: View {
    let parts: [Formula.Part]
    var size: CGFloat = 20

    var body: some View {
        Flow(spacing: 4, lineSpacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .word(let w):
                    Text(w).font(Theme.F.target(size: size, bold: true))
                case .slot(let label):
                    Text(label).font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                        .frame(minWidth: 34, minHeight: size + 6)
                        .padding(.horizontal, 4)
                        .overlay(Rectangle().strokeBorder(Theme.C.seam2,
                                                          style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                case .filled(let text):
                    Text(text).font(Theme.F.target(size: size * 0.5))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Theme.C.surface)
                        .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
                case .plain(let text):
                    Text(text).font(Theme.F.serif(size * 0.5)).foregroundStyle(Theme.C.ink2)
                }
            }
        }
    }
}

/// Rows keyed by `group`; entries as chips carrying `tag`.
struct PairsLayout: View {
    let rows: ChapterRows

    var body: some View {
        let tags = rows.tags
        VStack(spacing: 0) {
            ForEach(rows.groups, id: \.name) { group in
                HStack(alignment: .top, spacing: 10) {
                    Text(group.name).font(Theme.F.mono(15, bold: true))
                        .frame(width: 52, alignment: .leading)
                        .padding(.top, 5)
                    Flow(spacing: 5, lineSpacing: 5) {
                        ForEach(group.entries) { chip($0, tags) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.C.seam).frame(height: Theme.M.hair) }
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Theme.C.seam).frame(height: Theme.M.hair) }
    }

    private func chip(_ entry: Chapter.Entry, _ tags: [String]) -> some View {
        let state = rows.state(entry)
        let unseen = state.standing == .never && !state.slipping
        let colour = BookColour.tag(entry.tag, among: tags)
        return NavigationLink(value: rows.route(entry)) {
            HStack(spacing: 0) {
                Text(entry.head).font(Theme.F.target(size: 14))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                if let level = rows.levels[entry.id] {
                    Text(level).font(Theme.F.label).foregroundStyle(Theme.C.ink3)
                        .padding(.trailing, 6)
                }
                if let tag = entry.tag {
                    Text(tag).font(Theme.F.label)
                        .padding(.horizontal, 5)
                        .frame(maxHeight: .infinity)
                        .foregroundStyle(unseen ? colour : Theme.C.onAccent)
                        .background(unseen ? Color.clear : colour)
                }
            }
            .fixedSize()
            .foregroundStyle(Theme.C.ink)
        }
        .buttonStyle(BookKeyStyle(unseen: unseen,
                                  edge: state.slipping ? Theme.C.bad : nil))
    }
}

/// Two columns: `tag` picks the side, `group` is the key down the middle.
struct SplitLayout: View {
    let rows: ChapterRows

    var body: some View {
        let tags = Array(rows.tags.prefix(2))
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                head(tags.first, tags, .leading)
                Rectangle().fill(Theme.C.ink).frame(width: 64)
                head(tags.count > 1 ? tags[1] : nil, tags, .trailing)
            }
            .fixedSize(horizontal: false, vertical: true)
            ForEach(rows.groups, id: \.name) { group in
                HStack(spacing: 6) {
                    cell(group.entries.first { $0.tag == tags.first }, .leading)
                    Text(group.name).font(Theme.F.mono(13, bold: true))
                        .lineLimit(2).minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                        .frame(width: 64)
                        .frame(maxHeight: .infinity)
                        .background(Theme.C.raised)
                    cell(tags.count > 1 ? group.entries.first { $0.tag == tags[1] } : nil, .trailing)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func head(_ tag: String?, _ tags: [String], _ edge: HorizontalAlignment) -> some View {
        Text(tag ?? "")
            .font(Theme.F.meta)
            .foregroundStyle(Theme.C.onAccent)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
            .background(BookColour.tag(tag, among: tags))
    }

    @ViewBuilder
    private func cell(_ entry: Chapter.Entry?, _ edge: HorizontalAlignment) -> some View {
        if let entry {
            let state = rows.state(entry)
            let fill = LedgerState(state).fill
            NavigationLink(value: rows.route(entry)) {
                VStack(alignment: edge, spacing: 2) {
                    Text(entry.head).font(Theme.F.target(size: 13))
                    if let level = rows.levels[entry.id] {
                        Text(level).font(Theme.F.label).foregroundStyle(Theme.C.ink3)
                    }
                }
                .multilineTextAlignment(edge == .leading ? .leading : .trailing)
                .foregroundStyle(Theme.C.ink)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: edge == .leading ? .leading : .trailing)
                .overlay(alignment: edge == .leading ? .leading : .trailing) {
                    if let fill { Rectangle().fill(fill).frame(width: 3) }
                }
            }
            .buttonStyle(BookKeyStyle(unseen: fill == nil,
                                      edge: state.slipping ? Theme.C.bad : nil))
        } else {
            Color.clear.frame(maxWidth: .infinity)
        }
    }
}

/// Left-to-right, wrapping.
struct Flow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = arrange(subviews, width: width)
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        let used = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in line.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = line.items.isEmpty ? size.width : line.width + spacing + size.width
            if needed > width, !line.items.isEmpty {
                lines.append(line)
                line = Line()
            }
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.items.append(i)
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}
