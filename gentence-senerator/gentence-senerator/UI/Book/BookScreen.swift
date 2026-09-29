import SwiftUI

/// The front page. The same structure in every language.
struct BookScreen: View {
    @Bindable var store: Store
    @Environment(\.startQuiz) private var startQuiz

    var body: some View {
        let index = store.bookIndex
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                header
                tally(index)
                drills(index.book.drills)
                chapters(index)
            }
            .padding(.horizontal, Theme.M.gap)
            .padding(.top, Theme.M.gapTight)
            .padding(.bottom, Theme.M.gap)
        }
        .background(Theme.C.ground)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Book").font(Theme.F.title).foregroundStyle(Theme.C.ink)
            Spacer()
            Menu {
                ForEach(Language.allCases) { language in
                    Button(language.name) { store.switchLanguage(language) }
                }
            } label: {
                Text("\(store.settings.language.native) · \(store.pack.level(store.settings.level)) ▾")
                    .font(Theme.F.meta)
                    .foregroundStyle(Theme.C.ink)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.C.surface)
                    .overlay(Rectangle().stroke(Theme.C.seam2, lineWidth: Theme.M.hair))
            }
        }
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
        let parts: [(String, Int, Color)] = [
            ("SOLID", c.solid, LedgerState.solid.fill ?? .clear),
            ("HOLDING", c.holding, LedgerState.holding.fill ?? .clear),
            ("TRIED", c.tried, LedgerState.tried.fill ?? .clear),
            ("SLIPPING", c.slipping, LedgerState.slipping.fill ?? .clear),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(c.met)").font(Theme.F.display)
                Text("/ \(c.total)").font(Theme.F.mono(15))
                    .foregroundStyle(Theme.C.ink2)
            }
            .foregroundStyle(Theme.C.ink)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle().fill(part.2)
                            .frame(width: c.total == 0 ? 0
                                   : geo.size.width * CGFloat(part.1) / CGFloat(c.total))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .background(Theme.C.raised)
            .overlay(Rectangle().stroke(Theme.C.ink, lineWidth: Theme.M.hair))
            StateLegend(states: [.solid, .holding, .tried, .slipping],
                        counts: [.solid: c.solid, .holding: c.holding, .tried: c.tried, .slipping: c.slipping])
        }
    }

    // MARK: Drills

    @ViewBuilder
    private func drills(_ plans: [QuizPlan]) -> some View {
        if !plans.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                      spacing: 6) {
                ForEach(plans) { plan in
                    let done = store.roundsDone(plan)
                    Button { startQuiz(plan) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(plan.name.uppercased())
                                .font(Theme.F.mono(10.5, bold: true))
                                .tracking(0.6)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Text(done == 0 ? "—" : "\(done)")
                                .font(Theme.F.number)
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
        .background(Theme.C.seam)
        .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
    }

    private func tile(_ chapter: Chapter, _ index: Store.BookIndex) -> some View {
        let states = chapter.entries.map { store.bookState(of: $0, in: index) }
            .sorted { rank($0) < rank($1) }
        let met = states.filter { $0.standing != .never || $0.slipping }.count
        let dim = met == 0
        return NavigationLink(value: BookRoute.chapter(chapter.id)) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Shrinks rather than breaking a long compound mid-word.
                    Text(chapter.name).font(Theme.F.serif(15, bold: true))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    Text("\(met)/\(chapter.entries.count)").font(Theme.F.meta)
                        .foregroundStyle(Theme.C.ink2)
                }
                Text(chapter.sub).font(Theme.F.target(size: 13)).foregroundStyle(Theme.C.ink2)
                    .lineLimit(2).multilineTextAlignment(.leading)
                cells(states).padding(.top, 4)
            }
            .foregroundStyle(Theme.C.ink)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 96)
            .background(dim ? Theme.C.sunk : Theme.C.surface)
            .opacity(dim ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    ForEach(rows[r].indices, id: \.self) { i in StateCell(state: rows[r][i]) }
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
