import SwiftUI

/// The front page. The same structure in every language.
struct BookScreen: View {
    @Bindable var store: Store
    @Environment(\.startQuiz) private var startQuiz

    var body: some View {
        let index = store.bookIndex
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                tally(index)
                drills(index.book.drills)
                chapters(index)
            }
            .padding(.horizontal, Theme.M.gap)
            .padding(.top, 14)
            .padding(.bottom, Theme.M.gap)
        }
        .background(Theme.C.ground)
        .pageHeader(PageHeader(title: "Book", centred: false) { selector })
        .toolbar(.hidden, for: .navigationBar)
    }

    /// `中文 · HSK 3 ▾`: the language, and the level one step either way.
    private var selector: some View {
        let level = store.settings.level
        return Menu {
            Section {
                ForEach(Language.allCases) { language in
                    Button { store.switchLanguage(language) } label: {
                        if language == store.settings.language {
                            Label(language.name, systemImage: "checkmark")
                        } else {
                            Text(language.name)
                        }
                    }
                }
            }
            Section {
                if level < store.pack.levels {
                    Button("\(store.pack.level(level + 1)) ↑") { store.setLevel(level + 1) }
                }
                if level > 1 {
                    Button("\(store.pack.level(level - 1)) ↓") { store.setLevel(level - 1) }
                }
            }
        } label: {
            Text("\(store.settings.language.native) · \(store.pack.level(level)) ▾")
                .font(Theme.F.mono(12))
                .foregroundStyle(Theme.C.ink)
                .padding(.vertical, 2)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.C.ink).frame(height: Theme.M.hair)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Language and level")
    }

    // MARK: Tally

    private struct Counts {
        var solid = 0, holding = 0, tried = 0, slipping = 0, total = 0
        var met: Int { solid + holding + tried + slipping }
    }

    /// Shipped chapters only. Noted has its own count on its tile.
    private func counts(_ index: Store.BookIndex) -> Counts {
        var c = Counts()
        for entry in index.book.chapters.flatMap(\.entries) {
            c.total += 1
            let s = store.bookState(of: entry, in: index)
            if s.slipping { c.slipping += 1; continue }
            switch s.standing {
            case .solid: c.solid += 1
            case .holding: c.holding += 1
            case .tried: c.tried += 1
            case .never: break
            }
        }
        return c
    }

    private func tally(_ index: Store.BookIndex) -> some View {
        let c = counts(index)
        let parts: [(LedgerState, Int)] = [(.solid, c.solid), (.holding, c.holding),
                                           (.tried, c.tried), (.slipping, c.slipping)]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(c.met)").font(Theme.F.mono(40, bold: true))
                Text("/ \(c.total)").font(Theme.F.mono(15))
                    .foregroundStyle(Theme.C.ink2)
            }
            .foregroundStyle(Theme.C.ink)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle().fill(part.0.fill ?? .clear)
                            .frame(width: c.total == 0 ? 0
                                   : geo.size.width * CGFloat(part.1) / CGFloat(c.total))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .background(Theme.C.raised)
            .overlay(Rectangle().strokeBorder(Theme.C.ink, lineWidth: Theme.M.hair))
            StateLegend(states: parts.map(\.0),
                        counts: Dictionary(uniqueKeysWithValues: parts.map { ($0.0, $0.1) }))
        }
    }

    // MARK: Drills

    @ViewBuilder
    private func drills(_ plans: [QuizPlan]) -> some View {
        if !plans.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                      spacing: 8) {
                ForEach(plans) { plan in
                    Button { startQuiz(plan) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(plan.name.uppercased())
                                .font(Theme.F.mono(10.5, bold: true))
                                .tracking(0.6)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            best(plan)
                        }
                        .foregroundStyle(Theme.C.ink)
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                        .padding(8)
                    }
                    .buttonStyle(KeyStyle())
                }
            }
        }
    }

    /// Best round: `14/20`, or — before the first.
    private func best(_ plan: QuizPlan) -> Text {
        guard let best = store.best(plan) else {
            return Text("—").font(Theme.F.number).foregroundColor(Theme.C.ink3)
        }
        return Text("\(best)").font(Theme.F.number)
            + Text("/\(plan.count)").font(Theme.F.meta).foregroundColor(Theme.C.ink3)
    }

    // MARK: Chapters

    private func chapters(_ index: Store.BookIndex) -> some View {
        let rows = stride(from: 0, to: index.chapters.count, by: 2).map {
            Array(index.chapters[$0..<min($0 + 2, index.chapters.count)])
        }
        return Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            ForEach(rows, id: \.first!.id) { row in
                GridRow {
                    ForEach(row) { chapter in tile(chapter, index) }
                    if row.count == 1 { Theme.C.ground }
                }
            }
        }
        .background(Theme.C.ink)
        .overlay(Rectangle().strokeBorder(Theme.C.ink, lineWidth: Theme.M.hair))
    }

    private func tile(_ chapter: Chapter, _ index: Store.BookIndex) -> some View {
        let states = chapter.entries.map { store.bookState(of: $0, in: index) }
            .sorted { rank($0) < rank($1) }
        let met = states.filter { $0.standing != .never || $0.slipping }.count
        let noted = chapter.formats.isEmpty && chapter.id.hasSuffix(".noted")
        return NavigationLink(value: BookRoute.chapter(chapter.id)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(chapter.name).font(Theme.F.serif(16, bold: true))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text("\(met)/\(chapter.entries.count)").font(Theme.F.meta)
                        .foregroundStyle(Theme.C.ink2)
                }
                Text(chapter.sub).font(Theme.F.target(size: 13)).foregroundStyle(Theme.C.ink2)
                    .lineLimit(2).multilineTextAlignment(.leading)
                cells(states).padding(.top, 4)
            }
            .foregroundStyle(Theme.C.ink)
            .padding(11)
            .padding(.leading, noted ? Theme.M.edge : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 104)
            .background {
                ZStack {
                    Theme.C.surface
                    if met == 0 { Hatch() }
                }
            }
            .overlay(alignment: .leading) {
                if noted { Rectangle().fill(Theme.C.margin).frame(width: Theme.M.edge) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
    }

    /// Solid first, never last, the way the record reads.
    private func rank(_ s: EntryState) -> Int {
        if s.slipping { return 2 }
        switch s.standing {
        case .solid: return 0
        case .holding: return 1
        case .tried: return 3
        case .never: return 4
        }
    }

    private func cells(_ states: [EntryState]) -> some View {
        let rows = stride(from: 0, to: states.count, by: 10).map {
            Array(states[$0..<min($0 + 10, states.count)])
        }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 2) {
                    ForEach(rows[r].indices, id: \.self) { i in StateCell(state: rows[r][i], size: 10) }
                }
            }
        }
    }
}

extension Language {
    /// The pill: what the language calls itself.
    var native: String {
        switch self {
        case .mandarin: return "中文"
        case .german:   return "DEUTSCH"
        case .french:   return "FRANÇAIS"
        }
    }
}
