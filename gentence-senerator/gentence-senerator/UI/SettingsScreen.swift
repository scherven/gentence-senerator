import SwiftUI

struct SettingsScreen: View {
    @Bindable var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.M.gap) {
                language
                level
                session
            }
            .padding(Theme.M.gap)
        }
        .pageHeader(PageHeader(title: "Settings") {
            Button { dismiss() } label: {
                Text("DONE")
                    .font(Theme.F.meta).tracking(Theme.M.caps)
                    .foregroundStyle(Theme.C.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
        })
        .tint(Theme.C.accent)
        .paper()
    }

    /// Keys for the languages on, the one in use marked; then which are on.
    private var language: some View {
        VStack(spacing: Theme.M.gapTight) {
            ForEach(store.settings.languages) { candidate in
                let on = candidate == store.settings.language
                Button { store.switchLanguage(candidate) } label: {
                    HStack {
                        Text("\(candidate.flag)  \(candidate.name)").font(Theme.F.body)
                        Spacer()
                        if on { Tag("on", .selected) }
                    }
                    .padding(Theme.M.pad)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(KeyStyle(on ? .spent : .neutral))
                .disabled(on)
            }
            VStack(alignment: .leading, spacing: 6) {
                ModuleLabel(text: "Offered")
                VStack(spacing: 0) {
                    ForEach(Language.allCases) { candidate in
                        row {
                            SquareToggle(isOn: Binding(
                                get: { store.settings.languages.contains(candidate) },
                                set: { store.setOffered(candidate, $0) })) {
                                Text(candidate.name).font(Theme.F.body)
                            }
                            .disabled(candidate == store.settings.language)
                        }
                    }
                }
            }
            .padding(.top, Theme.M.gapTight)
        }
    }

    private var level: some View {
        VStack(alignment: .leading, spacing: 6) {
            SquareStepper(value: Binding(get: { store.settings.level },
                                         set: { store.setLevel($0) }),
                          in: 1...store.pack.levels) {
                Text(store.pack.level(store.settings.level)).font(Theme.F.body)
            }
            .padding(Theme.M.pad)
            .background(Theme.C.surface)
            .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))

            // Offered, never taken. The level is the one thing the app would be
            // changing behind the learner's back, so it asks.
            if let offer = store.levelOffer {
                Panel(fill: Theme.C.sunk, edge: Theme.C.accent) {
                    VStack(alignment: .leading, spacing: Theme.M.gapTight) {
                        Text(offer.reason).font(Theme.F.note)
                        TinyButton(title: "Move to \(store.pack.level(offer.level))") {
                            store.setLevel(offer.level)
                        }
                    }
                }
            }
        }
    }

    private var session: some View {
        VStack(spacing: 0) {
            row {
                SquareStepper(value: Binding(get: { store.settings.dailyGoal },
                                             set: { store.setGoal($0) }),
                              in: 1...10) {
                    Text("\(store.settings.dailyGoal) of each mode a day")
                        .font(Theme.F.body)
                }
            }
            row {
                SquareToggle(isOn: $store.settings.prefersTyping) {
                    Text("Type instead of speaking").font(Theme.F.body)
                }
            }
            row {
                SquareToggle(isOn: $store.settings.offerStretch) {
                    Text("Suggest structures I haven't used").font(Theme.F.body)
                }
            }
        }
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .tint(Theme.C.accent)
            .padding(Theme.M.pad)
            .background(Theme.C.surface)
            .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
    }
}
