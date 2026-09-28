import SwiftUI

/// A chapter: header, its layout, and its speed round pinned above the tabs.
struct ChapterScreen: View {
    @Bindable var store: Store
    let chapterID: String
    @Environment(\.startQuiz) private var startQuiz

    var body: some View {
        let index = store.bookIndex
        Group {
            if let chapter = index.chapter(chapterID) {
                page(chapter, index)
            } else {
                Busy(text: "")
            }
        }
        .background(Theme.C.ground)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func page(_ chapter: Chapter, _ index: Store.BookIndex) -> some View {
        let states = Dictionary(uniqueKeysWithValues: chapter.entries.map {
            ($0.id, store.bookState(of: $0, in: index))
        })
        let met = states.values.filter { $0.standing != .never || $0.slipping }.count
        var levels: [String: String] = [:]
        for entry in chapter.entries {
            if let point = store.point(entry.point) { levels[entry.id] = store.pack.level(point.level) }
        }
        let rows = ChapterRows(chapter: chapter, states: states, levels: levels)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BookPageHeader(back: "Book", title: chapter.name,
                               count: "\(met)/\(chapter.entries.count)")
                ChapterLayoutView(rows: rows)
            }
            .padding(.horizontal, Theme.M.gap)
            .padding(.top, Theme.M.gapTight)
            .padding(.bottom, Theme.M.gap)
        }
        .safeAreaInset(edge: .bottom) {
            // Noted has no quiz items behind it.
            if !chapter.formats.isEmpty {
                let plan = Store.speedRound(for: chapter)
                let done = store.roundsDone(plan)
                SpeedRoundBar(title: "SPEED ROUND · \(plan.count)",
                              trailing: done == 0 ? "" : "×\(done) DONE") { startQuiz(plan) }
                    .padding(.horizontal, Theme.M.gap)
                    .padding(.vertical, Theme.M.gapTight)
            }
        }
    }
}

/// What every layout gets: the chapter and where each entry stands.
struct ChapterRows {
    let chapter: Chapter
    let states: [String: EntryState]
    /// "HSK 3", for entries linked to a point.
    var levels: [String: String] = [:]

    func state(_ entry: Chapter.Entry) -> EntryState {
        states[entry.id] ?? EntryState(standing: .never, slipping: false, lastSeen: nil, recent: [])
    }

    func route(_ entry: Chapter.Entry) -> BookRoute {
        .entry(chapter: chapter.id, entry: entry.id)
    }

    /// Entries grouped by `group`, groups in first-seen order.
    var groups: [(name: String, entries: [Chapter.Entry])] {
        let names = BookColour.order(chapter.entries.map { $0.group ?? "" })
        return names.map { name in (name, chapter.entries.filter { ($0.group ?? "") == name }) }
    }

    var tags: [String] { BookColour.order(chapter.entries.map(\.tag)) }
}

/// The one switch. A new layout is a case here and a view.
struct ChapterLayoutView: View {
    let rows: ChapterRows

    var body: some View {
        switch rows.chapter.layout {
        case .list:     ListLayout(rows: rows)
        case .cards:    CardsLayout(rows: rows)
        case .formulas: FormulasLayout(rows: rows)
        case .pairs:    PairsLayout(rows: rows)
        case .split:    SplitLayout(rows: rows)
        }
    }
}
