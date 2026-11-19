import SwiftUI

/// A way onward that opens straight away. Used inside lessons, drill results
/// and answers — anywhere the three-beat reveal would be ceremony.
struct AtomRow: View {
    let link: AtomLink
    /// The leading edge. Seam by default: a link is not a consequence.
    var tint: Color = Theme.C.seam2
    var last = false
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            LedgerRow(account: link.kind.label, colour: Theme.C.ink2, edge: tint, ruled: !last) {
                Text(link.headline)
                    .font(Theme.F.bodyTight)
                    .foregroundStyle(Theme.C.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                Text("›").font(Theme.F.label).foregroundStyle(Theme.C.ink3)
                    .padding(.top, 12).padding(.trailing, 10)
            }
            .background(Theme.C.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
    }
}

/// A finding, all of it at a glance: its number, `wrong → right`, and why in
/// a few words. Tapped, the note and the decisions about it.
struct FindingRow: View {
    let atom: Atom
    /// Shared with the underline in the sentence.
    var number: Int? = nil
    /// Where it is in the sentence, if it could be found.
    var span: Store.Span? = nil
    var last = false
    @Binding var open: Bool
    let knowledge: Progress.Encounter.Knowledge
    let onClassify: (Progress.Encounter.Knowledge) -> Void
    /// When it comes back: `today`, `3 days`, `held`.
    var back: String? = nil
    /// Reported as wrong already.
    var disputed = false
    /// Nil when sent, else the line to show.
    var onDispute: ((String) async -> String?)? = nil
    /// The grammar point the finding is on, and opening its page.
    var point: (name: String, open: () -> Void)? = nil

    @State private var asking = false
    @State private var note = ""
    @State private var sending = false
    @State private var trouble: String?

    private var colour: Color { Theme.colour(for: atom.verdict) }

    /// The words to put beside the arrow. Newer reviews quote them; older
    /// ones have only the located span.
    private var shown: Store.Span? {
        guard let wrong = atom.stages.wrong, !wrong.isEmpty else { return span }
        return Store.Span(range: span?.range ?? 0..<0, wrong: wrong,
                          right: atom.stages.fix.isEmpty ? nil : atom.stages.fix)
    }

    /// Why, unless it is all there is to say and is already the headline.
    private var why: String {
        atom.stages.name.isEmpty ? atom.kind.label : atom.stages.name
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NumberTag(number: number ?? 0, colour: colour)
                .opacity(number == nil ? 0 : 1)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                if shown != nil || !atom.stages.fix.isEmpty {
                    FixLine(span: shown, fix: atom.stages.fix)
                }
                Text(why)
                    .font(Theme.F.note)
                    .foregroundStyle(Theme.C.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if open { opened.padding(.top, 4) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(open ? "–" : "›").font(Theme.F.label).foregroundStyle(Theme.C.ink3)
                .padding(.top, 3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .leading) { Rectangle().fill(colour).frame(width: Theme.M.edge) }
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.C.rule.opacity(0.45)).frame(height: Theme.M.hair) }
        }
        .background(Theme.C.surface)
        .contentShape(Rectangle())
        .onTapGesture { open.toggle() }
        .accessibilityAddTraits(.isButton)
        .alert("What's wrong?", isPresented: $asking) {
            TextField("Optional", text: $note)
            Button("Send") { send() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func send() {
        guard let onDispute else { return }
        sending = true
        trouble = nil
        Task {
            trouble = await onDispute(note)
            sending = false
        }
    }

    @ViewBuilder
    private var opened: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !atom.stages.note.isEmpty {
                Text(atom.stages.note)
                    .font(Theme.F.bodyTight)
                    .foregroundStyle(Theme.C.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                classify
                Spacer(minLength: 0)
                if let back {
                    Text("Back " + back).monoCaps(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                }
            }
            HStack(spacing: 8) {
                if let point { TypedLink(point.name, action: point.open) }
                Spacer(minLength: 0)
                if onDispute != nil {
                    TinyButton(title: disputed ? "Reported" : sending ? "Sending" : "That's wrong",
                               selected: disputed) { if !disputed && !sending { note = ""; asking = true } }
                        .fixedSize()
                }
            }
            if let trouble {
                Text(trouble).font(Theme.F.meta).foregroundStyle(Theme.C.bad)
            }
        }
    }

    @ViewBuilder
    private var classify: some View {
        TinyButton(title: "I knew that",
                   selected: knowledge == .slip) { onClassify(.slip) }
            .fixedSize()
        TinyButton(title: "New to me",
                   selected: knowledge == .gap) { onClassify(.gap) }
            .fixedSize()
    }
}

/// `wrong → right`, the right half in the good colour. Without a located
/// span, only the fix.
struct FixLine: View {
    let span: Store.Span?
    let fix: String

    var body: some View {
        let target = Theme.F.target(size: 15)
        let right = Text(span?.right.map { $0.isEmpty ? "—" : $0 } ?? fix)
            .font(Theme.F.target(size: 15, bold: true))
            .foregroundColor(Theme.C.good)
        Group {
            if let span {
                Text(span.wrong).font(target).foregroundColor(Theme.C.bad).underline(color: Theme.C.bad)
                    + Text("  →  ").font(Theme.F.meta).foregroundColor(Theme.C.ink3)
                    + right
            } else {
                Text("→  ").font(Theme.F.meta).foregroundColor(Theme.C.ink3) + right
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Something that worked: what, and the words.
struct KeptRow: View {
    let atom: Atom
    var last = false

    var body: some View {
        LedgerRow(account: atom.verdict.rawValue, colour: Theme.C.good,
                  edge: Theme.C.good, ruled: !last) {
            VStack(alignment: .leading, spacing: 3) {
                Text(atom.stages.name.isEmpty ? atom.kind.label : atom.stages.name)
                    .font(Theme.F.bodyTight)
                    .foregroundStyle(Theme.C.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !atom.stages.fix.isEmpty {
                    Text(atom.stages.fix)
                        .font(Theme.F.target(size: 13))
                        .foregroundStyle(Theme.C.ink3)
                }
            }
        }
        .background(Theme.C.surface)
    }
}
