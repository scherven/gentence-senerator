import SwiftUI

struct SettingsScreen: View {
    @Bindable var store: Store
    @Environment(\.dismiss) private var dismiss
    /// Read straight from defaults rather than off `Settings`: `Anthropic` is
    /// built at launch from the key alone and has no route to the store.

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.M.gap) {
                    language
                    level
                    session
                    spend
                }
                .padding(Theme.M.gap)
            }
            .background(Theme.C.surface)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    TinyButton(title: "Done") { dismiss() }
                }
            }
        }
        .tint(Theme.C.accent)
    }

    private var language: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: "Language")
            VStack(spacing: 0) {
                ForEach(Language.allCases) { candidate in
                    Button { store.switchLanguage(candidate) } label: {
                        HStack {
                            Text("\(candidate.flag)  \(candidate.name)")
                                .font(Theme.F.body)
                            Spacer()
                            if candidate == store.settings.language {
                                Text("ON").font(Theme.F.label).foregroundStyle(Theme.C.accent)
                            }
                        }
                        .padding(Theme.M.pad)
                        .background(candidate == store.settings.language ? Theme.C.sunk : Theme.C.surface)
                        .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var level: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: "Level · \(store.pack.level(store.settings.level))")
            Stepper(value: Binding(get: { store.settings.level },
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

            Text("Sentences are built to sit at this level. Below B1 or HSK 4, being understood counts for more than being exactly right.")
                .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
        }
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: "Session")
            VStack(spacing: 0) {
                row {
                    Stepper(value: $store.settings.dailyGoal, in: 1...10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(store.settings.dailyGoal) of each mode a day")
                                .font(Theme.F.body)
                            Text("A cap, not a target. The day ends when all three are spent.")
                                .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                        }
                    }
                }
                row {
                    Stepper(value: $store.settings.turnsBeforeReview, in: 1...8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(store.settings.turnsBeforeReview) turns before review")
                                .font(Theme.F.body)
                            Text("Produce only. Corrections wait this long.")
                                .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                        }
                    }
                }
                row {
                    Toggle(isOn: $store.settings.prefersTyping) {
                        Text("Type instead of speaking").font(Theme.F.body)
                    }
                }
                row {
                    Toggle(isOn: $store.settings.offerStretch) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Push my range").font(Theme.F.body)
                            Text("Offer a structure you have never tried.")
                                .font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                        }
                    }
                }
            }
        }
    }

    private var spend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleLabel(text: "Today")
            HStack {
                Text(String(format: "$%.2f", store.spentToday))
                    .font(Theme.F.number)
                Spacer()
                Text("\(store.progress.xp) XP")
                    .font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
            }
            .padding(Theme.M.pad)
            .background(Theme.C.surface)
            .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
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
