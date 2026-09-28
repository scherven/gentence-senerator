import Foundation

/// A formulas-layout head (等…再…) as fixed words and slots, optionally with
/// the slots filled from the entry's example.
enum Formula {
    enum Part: Hashable {
        case word(String)
        /// Empty, labelled A, B, C.
        case slot(String)
        /// What the example put in the slot.
        case filled(String)
        /// Example text outside any slot: the subject before 一…就….
        case plain(String)
    }

    static func parse(_ head: String) -> [Part] {
        let tokens = head.replacingOccurrences(of: "...", with: "…").components(separatedBy: "…")
        var out: [Part] = []
        var slots = 0
        for (i, token) in tokens.enumerated() {
            let word = token.trimmingCharacters(in: .whitespaces)
            if !word.isEmpty { out.append(.word(word)) }
            if i < tokens.count - 1 {
                out.append(.slot(String(UnicodeScalar(UInt8(65 + slots % 26)))))
                slots += 1
            }
        }
        return out
    }

    /// Nil when the example does not contain the fixed words in order — a
    /// conjugated verb, say — and the slots stay empty.
    static func filled(_ head: String, with example: String) -> [Part]? {
        let parts = parse(head)
        guard parts.contains(where: { if case .slot = $0 { true } else { false } }) else { return nil }
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "，。？！,.?!"))
        var rest = Substring(example)
        var out: [Part] = []
        var open = false
        for part in parts {
            switch part {
            case .word(let w):
                guard let r = rest.range(of: w, options: [.caseInsensitive]) else { return nil }
                let before = rest[..<r.lowerBound].trimmingCharacters(in: trim)
                if open {
                    guard !before.isEmpty else { return nil }
                    out.append(.filled(before))
                    open = false
                } else if !before.isEmpty {
                    out.append(.plain(before))
                }
                out.append(.word(String(rest[r])))
                rest = rest[r.upperBound...]
            case .slot:
                open = true
            case .filled, .plain:
                break
            }
        }
        let tail = rest.trimmingCharacters(in: trim)
        if open {
            guard !tail.isEmpty else { return nil }
            out.append(.filled(tail))
        } else if !tail.isEmpty {
            out.append(.plain(tail))
        }
        return out
    }
}
