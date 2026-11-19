import SwiftUI

/// A sentence the learner got wrong before, asked again from its English.
/// Checked against their own fixed sentence, on the device.
struct RedoView: View {
    @Bindable var store: Store
    @FocusState private var focused: Bool

    var body: some View {
        if let round = store.redo, let item = round.current {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.M.gap) {
                        HStack {
                            Text("Yours, \(item.saidOn.formatted(.dateTime.weekday(.abbreviated)))".uppercased())
                                .font(Theme.F.meta).tracking(Theme.M.caps).foregroundStyle(Theme.C.ink2)
                            Spacer()
                            Text("\(item.atoms.count) to fix".uppercased())
                                .font(Theme.F.meta).tracking(Theme.M.caps).foregroundStyle(Theme.C.bad)
                        }
                        Panel(fill: Theme.C.sunk, edge: Theme.C.accent) {
                            Text(item.english).font(Theme.F.target)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        TextField("Say it…", text: Binding(
                            get: { store.redo?.answer ?? "" },
                            set: { store.redo?.answer = $0 }), axis: .vertical)
                            .font(Theme.F.target)
                            .textFieldStyle(.plain)
                            .targetLanguageInput()
                            .lineLimit(2...5)
                            .focused($focused)
                            .disabled(round.result != nil)
                            .inset()
                        if let result = round.result {
                            outcome(result, item: item, answer: round.answer)
                        }
                    }
                    .padding(Theme.M.gap)
                }
                .scrollDismissesKeyboard(.interactively)
                HStack(spacing: 10) {
                    ActionKey("Skip redo", variant: .neutral) { store.skipRedo() }
                    if round.result == nil {
                        ActionKey("Check") { store.checkRedo() }
                            .disabled(round.answer.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        ActionKey("Next ›") { store.nextRedo() }
                    }
                }
                .padding(.horizontal, Theme.M.gap)
                .padding(.vertical, Theme.M.gapTight)
                .overlay(alignment: .top) { Rectangle().fill(Theme.C.ink).frame(height: Theme.M.hair) }
            }
            .background(Theme.C.ground)
            .onAppear { focused = true }
            .onChange(of: round.index) { focused = true }
        }
    }

    private func outcome(_ result: RedoItem.Result, item: RedoItem, answer: String) -> some View {
        let colour = result.passed ? Theme.C.good : Theme.C.bad
        let apart = Store.divergence(answer, item.fixed, language: item.language)
        return Panel(fill: Theme.C.sunk, edge: colour, padding: Theme.M.padTight) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(result.passed ? "GOT IT" : "NOT YET").monoCaps().foregroundStyle(colour)
                    Spacer()
                    if result.total > 0 {
                        Text("\(result.made)/\(result.total)").monoCaps().foregroundStyle(colour)
                    }
                }
                SpanMark(item.fixed, marks: result.exact ? [] : apart.ref.map { .init($0, colour: Theme.C.good) },
                         font: Theme.F.target(size: 17, for: item.language))
                ForEach(item.alsoRight, id: \.self) { line in
                    Text(line).font(Theme.F.targetSmall(for: item.language))
                        .foregroundStyle(Theme.C.carbon)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Then: \(item.said)")
                    .font(Theme.F.note).foregroundStyle(Theme.C.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
