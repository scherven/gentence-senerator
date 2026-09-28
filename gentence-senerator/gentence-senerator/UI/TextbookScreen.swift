import SwiftUI

/// The reference book. Tapping a row opens the same lesson a finding opens.
struct TextbookScreen: View {
    @Bindable var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var scope: Textbook.Scope?
    @State private var search = ""

    var body: some View {
        // Bound to the shared path so lessons, and every link inside them,
        // push here rather than under the sheet.
        NavigationStack(path: $store.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.M.gap) {
                    controls
                    let sections = store.textbook(scope: current, search: search)
                    if sections.isEmpty {
                        Text(search.isEmpty
                             ? "Nothing yet."
                             : "No match.")
                            .font(Theme.F.note).foregroundStyle(Theme.C.ink3)
                    }
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            ModuleLabel(text: "\(section.title) · \(section.entries.count)")
                                .padding(.bottom, 6)
                            ForEach(section.entries) { entry in
                                TextbookRow(entry: entry, store: store)
                            }
                        }
                    }
                }
                .padding(Theme.M.gap)
            }
            .background(Theme.C.surface)
            .navigationTitle("Textbook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    TinyButton(title: "Done") { dismiss() }
                }
            }
            .navigationDestination(for: LessonRequest.self) { request in
                LessonHost(store: store, request: request)
            }
        }
        .tint(Theme.C.accent)
        .onDisappear { store.path.removeAll() }
    }

    /// Yours if there is anything yours, otherwise your level.
    private var current: Textbook.Scope {
        if let scope { return scope }
        let mine = !store.textbook(scope: .mine).isEmpty
        return mine ? .mine : .upTo(store.settings.level)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.M.gapTight) {
            HStack(spacing: 6) {
                TinyButton(title: "Mine", selected: current == .mine) { scope = .mine }
                TinyButton(title: "To \(store.pack.level(store.settings.level))",
                           selected: current == .upTo(store.settings.level)) {
                    scope = .upTo(store.settings.level)
                }
                TinyButton(title: "All", selected: current == .all) { scope = .all }
            }
            TextField("", text: $search, prompt: Text("SEARCH").font(Theme.F.label))
                .font(Theme.F.bodyTight)
                .targetLanguageInput()
                .padding(.horizontal, Theme.M.padTight)
                .padding(.vertical, 6)
                .background(Theme.C.sunk)
                .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
        }
    }
}

/// The header button, carrying its own sheet so the shell needs one line.
struct TextbookButton: View {
    let store: Store
    @State private var showing = false

    var body: some View {
        TinyButton(title: "Textbook") { showing = true }
            .sheet(isPresented: $showing) { TextbookScreen(store: store) }
    }
}

private struct TextbookRow: View {
    let entry: Textbook.Entry
    let store: Store

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { store.open(entry) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.title)
                            .font(Theme.F.bodyTight.weight(.medium))
                            .foregroundStyle(Theme.C.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let level = entry.level {
                            Text(store.pack.level(level))
                                .font(Theme.F.label).foregroundStyle(Theme.C.ink3)
                        }
                    }
                    if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                            .lineLimit(2)
                    }
                    if let example = entry.examples.first {
                        Text(example).font(Theme.F.targetSmall).foregroundStyle(Theme.C.ink)
                    }
                    if let sentence = entry.sentence, !sentence.isEmpty {
                        Text("YOU  \(sentence)")
                            .font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                            .lineLimit(1)
                    }
                    if let question = entry.question, !question.isEmpty {
                        Text("ASKED  \(question)")
                            .font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                            .lineLimit(1)
                    }
                    if !facts.isEmpty {
                        Text(facts.joined(separator: " · "))
                            .font(Theme.F.label).tracking(0.6)
                            .foregroundStyle(entry.isMine ? Theme.C.accent : Theme.C.ink3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            TinyButton(title: entry.pinned ? "Pinned" : "Pin",
                       selected: entry.pinned) { store.togglePin(entry) }
        }
        .padding(Theme.M.padTight)
        .padding(.leading, entry.isMine ? Theme.M.edge : 0)
        .background(Theme.C.surface)
        .overlay(alignment: .leading) {
            if entry.isMine { Rectangle().fill(Theme.C.accent).frame(width: Theme.M.edge) }
        }
        .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
    }

    /// Facts about the learner, never about the system.
    private var facts: [String] {
        var out: [String] = []
        if entry.noted > 0 { out.append("NOTED ×\(entry.noted)") }
        if let returns = entry.returns { out.append("BACK \(returns.uppercased())") }
        if entry.held { out.append("HOLDING") }
        if entry.origins.contains(.suggested) { out.append("SUGGESTED") }
        if entry.pointID != nil {
            if entry.used > 0 {
                out.append("USED ×\(entry.used) · \(entry.clean) CLEAN")
            } else if (entry.level ?? .max) <= store.settings.level {
                out.append("NEVER USED")
            }
        }
        return out
    }
}
