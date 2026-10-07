import SwiftUI

/// First launch only: the code that lets this install use the worker. Eight
/// cells; the eighth character sends it.
struct InviteScreen: View {
    /// False while the opening plays: the keyboard waits for it.
    var ready: Bool
    var redeemed: () -> Void

    @State private var code = ""
    @State private var checking = false
    @State private var refused = false
    @State private var focused = false

    var body: some View {
        VStack(spacing: Theme.M.gap) {
            ModuleLabel(text: "Invite code")
            ZStack {
                // The real field, invisible: the cells draw what it holds.
                CodeField(text: $code, focused: $focused)
                    .frame(height: 44)
                    .onChange(of: code) { _, new in edited(new) }
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { cell($0) }
                    Text("–").font(Theme.F.number).foregroundStyle(Theme.C.ink3)
                    ForEach(4..<8, id: \.self) { cell($0) }
                }
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
            }
            Text(refused ? "NOT A CODE" : "CHECKING")
                .font(Theme.F.label)
                .tracking(Theme.M.caps)
                .foregroundStyle(refused ? Theme.C.bad : Theme.C.ink3)
                .opacity(refused || checking ? 1 : 0)
        }
        .frame(maxWidth: 340)
        .padding(.horizontal, Theme.M.gap * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paper()
        .onChange(of: ready, initial: true) { _, ready in if ready { focused = true } }
    }

    private func cell(_ i: Int) -> some View {
        let chars = Array(code)
        let filled = i < chars.count
        let here = focused && !checking && i == chars.count
        return Text(filled ? String(chars[i]) : " ")
            .font(Theme.F.number)
            .foregroundStyle(refused ? Theme.C.bad : Theme.C.ink)
            .frame(width: 32, height: 44)
            .background(Theme.C.sunk)
            .overlay(Rectangle().strokeBorder(here ? Theme.C.accent : Theme.C.seam2,
                                              lineWidth: here ? 2 : Theme.M.hair))
    }

    /// The eighth character sends.
    private func edited(_ new: String) {
        refused = false
        if new.count == 8 { redeem() }
    }

    private func redeem() {
        guard !checking else { return }
        checking = true
        Task {
            let ok = await Worker.redeem(code)
            checking = false
            if ok {
                redeemed()
            } else {
                refused = true
                focused = true
            }
        }
    }
}

/// The hidden field behind the cells. UIKit, because SwiftUI focus set at
/// launch is dropped before the field is in a window; this one takes the
/// keyboard as soon as it is.
private struct CodeField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.keyboardType = .asciiCapable
        field.textColor = .clear
        field.tintColor = .clear
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)),
                        for: .editingChanged)
        field.delegate = context.coordinator
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        if field.text != text { field.text = text }
        if focused, !field.isFirstResponder { field.take(tries: 20) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Field: UITextField {
        /// At launch the window can't take the keyboard yet; keep asking for
        /// a couple of seconds.
        func take(tries: Int) {
            guard !isFirstResponder, tries > 0 else { return }
            if window != nil, becomeFirstResponder() { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.take(tries: tries - 1) }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let parent: CodeField
        init(_ parent: CodeField) { self.parent = parent }

        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }

        /// Cleaned here, keystroke by keystroke: a round trip through SwiftUI
        /// to uppercase loses keys typed fast.
        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            let current = field.text ?? ""
            guard let range = Range(range, in: current) else { return false }
            let next = clean(current.replacingCharacters(in: range, with: string))
            field.text = next
            parent.text = next
            return false
        }
        func textFieldDidBeginEditing(_ field: UITextField) { parent.focused = true }
        func textFieldDidEndEditing(_ field: UITextField) { parent.focused = false }
    }
}

/// Uppercase letters and digits, eight at most. The dash is drawn, not typed.
private func clean(_ s: String) -> String {
    String(s.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
}
