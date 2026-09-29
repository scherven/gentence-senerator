import SwiftUI
import NaturalLanguage

/// Typing Mandarin needs a Chinese keyboard. With one installed the field
/// asks for it; without, a transform item is answered as build tiles.
enum ChineseInput {
    static func isChinese(_ item: QuizItem) -> Bool {
        (item.accept.first ?? "").unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    static var installed: Bool {
        UITextInputMode.activeInputModes.contains { $0.primaryLanguage?.hasPrefix("zh") == true }
    }

    /// The transform as a build item over its first accepted answer, cut into
    /// words. Nil when a Chinese keyboard is there, or the cut is too coarse.
    static func fallback(for item: QuizItem) -> QuizItem? {
        guard item.format == .transform, isChinese(item), !installed,
              let answer = item.accept.first else { return nil }
        let tiles = words(answer)
        guard tiles.count >= 2 else { return nil }
        return QuizItem(id: item.id, entry: item.entry, format: .build, gloss: item.gloss,
                        why: item.why, tiles: tiles, accept: item.accept)
    }

    /// Word tokens, punctuation dropped.
    static func words(_ s: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = s
        var out: [String] = []
        tokenizer.enumerateTokens(in: s.startIndex..<s.endIndex) { range, _ in
            let w = String(s[range]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !w.isEmpty { out.append(w) }
            return true
        }
        return out
    }
}

/// A one-line field that asks for a Chinese keyboard when one is installed.
struct ChineseField: UIViewRepresentable {
    @Binding var text: String
    var enabled: Bool
    var colour: UIColor
    let onSubmit: () -> Void

    final class Field: UITextField {
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage?.hasPrefix("zh") == true }
                ?? super.textInputMode
        }
    }

    func makeUIView(context: Context) -> Field {
        let f = Field()
        f.font = .systemFont(ofSize: 22)
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.returnKeyType = .done
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        DispatchQueue.main.async { f.becomeFirstResponder() }
        return f
    }

    func updateUIView(_ f: Field, context: Context) {
        context.coordinator.parent = self
        if f.text != text { f.text = text }
        f.isEnabled = enabled
        f.textColor = colour
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ChineseField
        init(_ parent: ChineseField) { self.parent = parent }

        @objc func changed(_ f: UITextField) { parent.text = f.text ?? "" }

        func textFieldShouldReturn(_ f: UITextField) -> Bool {
            f.resignFirstResponder()
            parent.onSubmit()
            return false
        }
    }
}
