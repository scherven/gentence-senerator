import SwiftUI

/// Talk: the scene, then the conversation, then what came of it. Full screen
/// over Today. The review arrives later, with the batch, like produce.
struct TalkScreen: View {
    @Bindable var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var typing = ""
    @FocusState private var focused: Bool

    private var conversation: Conversation? { store.conversation }
    private var language: Language { store.settings.language }

    var body: some View {
        Group {
            if let conversation {
                if conversation.learnerLines.isEmpty && !conversation.ended && !started {
                    brief(conversation)
                } else {
                    thread(conversation)
                }
            } else {
                writing
            }
        }
        .paper()
        .task {
            if conversation == nil { await store.newScene() }
        }
    }

    /// Whether Start was pressed on this scene. Kept off the model: a scene
    /// with no learner line yet is still one to swap.
    @State private var started = false

    // MARK: Scene

    private var writing: some View {
        VStack(spacing: Theme.M.gap) {
            Spacer()
            if case .failed(let why) = store.talk {
                Text(why).font(Theme.F.note).foregroundStyle(Theme.C.ink2)
                    .multilineTextAlignment(.center)
                TinyButton(title: "Try again") { Task { await store.newScene() } }
            } else {
                Ticker(text: "Writing the scene")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.M.gap)
        .pageHeader(.end("Close"), title: "Talk", onLead: { dismiss() })
    }

    private func brief(_ conversation: Conversation) -> some View {
        let scene = conversation.scene
        return VStack(alignment: .leading, spacing: Theme.M.gap) {
            Text(scene.place)
                .font(Theme.F.target(size: 30, bold: true, for: language))
                .padding(.top, Theme.M.gapTight)
            LedgerSheet {
                briefRow("You", scene.you, ruled: true)
                briefRow("Want", scene.want, ruled: true, strong: true)
                briefRow("Them", "\(scene.role). \(scene.them)", ruled: false)
            }
            HStack(spacing: Theme.M.gap) {
                Text("≤\(Conversation.cap) turns")
                Text(scene.formal ? formalWord : "Informal")
                Text("Typed")
            }
            .font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
            Spacer()
            HStack {
                Spacer()
                if store.talk == .setting {
                    Text("Writing…").font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
                } else {
                    TypedLink("Another scene", colour: Theme.C.ink2, chevron: false) {
                        store.closeConversation()
                        Task { await store.newScene() }
                    }
                }
            }
            ActionKey("Start") {
                started = true
                focused = true
            }
        }
        .padding(Theme.M.gap)
        .pageHeader(.end("Close"), title: "Talk", meta: language.short.uppercased(),
                    onLead: { dismiss() })
    }

    /// What formal is called in this language.
    private var formalWord: String {
        switch language {
        case .german:   return "Sie"
        case .french:   return "Vous"
        case .mandarin: return "您"
        case .spanish:  return "Usted"
        case .korean:   return "존댓말"
        }
    }

    private func briefRow(_ account: String, _ text: String, ruled: Bool,
                          strong: Bool = false) -> some View {
        LedgerRow(account: account, colour: Theme.C.ink3, accountWidth: 56, ruled: ruled) {
            Text(text)
                .font(strong ? Theme.F.serif(16, bold: true) : Theme.F.body)
                .foregroundStyle(Theme.C.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Conversation

    private func thread(_ conversation: Conversation) -> some View {
        VStack(spacing: 0) {
            want(conversation)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.M.gapTight + 4) {
                        ForEach(conversation.lines) { line in
                            bubble(line, role: conversation.scene.role,
                                   first: line.id == conversation.lines.first?.id)
                                .id(line.id)
                        }
                        if store.talk == .waiting {
                            Ticker(text: conversation.scene.role).id("waiting")
                        }
                        if case .failed(let why) = store.talk {
                            failed(why)
                        }
                        if conversation.ended { outcome(conversation).id("end") }
                    }
                    .padding(Theme.M.gap)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: conversation.lines.count, initial: true) {
                    withAnimation {
                        if conversation.ended { reader.scrollTo("end") }
                        else if let last = conversation.lines.last?.id { reader.scrollTo(last) }
                    }
                }
                .onChange(of: store.talk) {
                    if store.talk == .waiting { withAnimation { reader.scrollTo("waiting") } }
                }
            }
            if conversation.ended {
                ActionKey("Today") {
                    store.closeConversation()
                    dismiss()
                }
                .padding(Theme.M.gap)
            } else {
                composer(conversation)
            }
        }
        .pageHeader(PageHeader(lead: conversation.ended ? .none : .end(), title: conversation.scene.place,
                               onLead: { store.endConversation() }) {
            Text(conversation.ended
                 ? "\(conversation.learnerLines.count) turns"
                 : "Turn \(min(conversation.learnerLines.count + 1, Conversation.cap))/\(Conversation.cap)")
        })
    }

    private func want(_ conversation: Conversation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.M.gapTight) {
            Text("WANT").font(Theme.F.label).tracking(Theme.M.caps).foregroundStyle(Theme.C.ink3)
            Text(conversation.scene.want).font(Theme.F.bodyTight).foregroundStyle(Theme.C.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.M.gap).padding(.vertical, 8)
        .background(Theme.C.raised)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.C.seam).frame(height: Theme.M.hair) }
    }

    @ViewBuilder
    private func bubble(_ line: Conversation.Line, role: String, first: Bool) -> some View {
        let theirs = line.speaker == .partner
        VStack(alignment: theirs ? .leading : .trailing, spacing: 4) {
            if theirs && first {
                Text(role.uppercased()).font(Theme.F.label).tracking(Theme.M.caps)
                    .foregroundStyle(Theme.C.ink3)
            }
            Text(line.text)
                .font(Theme.F.target(size: 18, for: language))
                .foregroundStyle(Theme.C.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(theirs ? Theme.C.stock : Theme.C.surface)
                .overlay(Rectangle().strokeBorder(theirs ? Theme.C.seam : Theme.C.seam2,
                                                  lineWidth: Theme.M.hair))
                .overlay(alignment: .trailing) {
                    if !theirs { Rectangle().fill(Theme.C.accent).frame(width: Theme.M.edge) }
                }
        }
        .frame(maxWidth: 300, alignment: theirs ? .leading : .trailing)
        .frame(maxWidth: .infinity, alignment: theirs ? .leading : .trailing)
    }

    private func failed(_ why: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(why).font(Theme.F.note).foregroundStyle(Theme.C.bad)
            Spacer(minLength: 4)
            TinyButton(title: "Try again") { Task { await store.reply() } }
        }
    }

    private func composer(_ conversation: Conversation) -> some View {
        let canSend = store.talk != .waiting
            && conversation.lines.last?.speaker == .partner
            && !typing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 0) {
            TextField("", text: $typing, axis: .vertical)
                .font(Theme.F.target(size: 17, for: language))
                .lineLimit(1...5)
                .focused($focused)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .padding(.horizontal, 12).padding(.vertical, 12)
                .frame(minHeight: 50)
                .background(Theme.C.stock)
                .overlay(Rectangle().strokeBorder(Theme.C.seam2, lineWidth: Theme.M.hair))
                .accessibilityLabel("Reply")
            Button {
                let text = typing
                typing = ""
                Task { await store.say(text) }
            } label: {
                Text("SEND").font(Theme.F.mono(13, bold: true)).tracking(1.5)
                    .frame(width: 70, height: 50)
            }
            .buttonStyle(KeyStyle(.primary))
            .disabled(!canSend)
        }
        .padding(.horizontal, Theme.M.gap).padding(.vertical, 10)
        .background(Theme.C.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.C.seam2).frame(height: Theme.M.hair) }
    }

    // MARK: Ended

    private func outcome(_ conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: Theme.M.gap) {
            Slip {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.goalMet ? "GOT IT" : "NOT THIS TIME")
                        .font(Theme.F.mono(22, bold: true)).tracking(1)
                        .foregroundStyle(conversation.goalMet ? Theme.C.accentOnInverse : Theme.C.onInverse)
                    Spacer()
                }
                Text(conversation.scene.want).font(Theme.F.body).foregroundStyle(Theme.C.onInverse)
                VStack(spacing: 6) {
                    count("Your turns", conversation.learnerLines.count)
                    count("Asked again", conversation.askedAgain)
                    count("Pushed back", conversation.pushedBack)
                }
                .padding(.top, 4)
            }
            if !conversation.learnerLines.isEmpty {
                Panel {
                    HStack {
                        Text("\(conversation.learnerLines.count) turns grading")
                            .font(Theme.F.meta).foregroundStyle(Theme.C.ink)
                        Spacer()
                        Text(eta).font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                    }
                }
            }
        }
        .padding(.top, Theme.M.gapTight)
    }

    private func count(_ label: String, _ n: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(n)")
        }
        .font(Theme.F.meta).foregroundStyle(Theme.C.onInverse)
    }

    private var eta: String {
        let minutes = Int((GradingClock.expected(store.gradingTimes) / 60).rounded())
        return "~\(max(minutes, 1)) min"
    }
}
