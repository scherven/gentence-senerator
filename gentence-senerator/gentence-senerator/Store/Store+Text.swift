import Foundation

extension Store {

    /// Where a finding sits in what was said, and its fix as wrong → right.
    struct Span: Equatable {
        /// Character offsets into the sentence.
        var range: Range<Int>
        var wrong: String
        /// Nil when the fix is not a correction of these words (kept, or no fix).
        var right: String?
    }

    /// Finds a finding in the sentence from two sources: quoted fragments of
    /// its stages that occur verbatim, and where the fix places it (the part a
    /// whole-sentence fix changed, or the window a fragment fix rewrites).
    /// Nil when neither lands.
    nonisolated static func span(of atom: Atom, in said: String) -> Span? {
        let chars = Array(said)
        guard !chars.isEmpty else { return nil }
        let fix = atom.stages.fix.trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = atom.verdict.isProblem && !fix.isEmpty
        // Quoted by the review itself, on reviews that quote. The first
        // occurrence: a quote is as short as shows the problem, so a repeat
        // is rare.
        if let wrong = atom.stages.wrong?.trimmingCharacters(in: .whitespacesAndNewlines),
           !wrong.isEmpty, let r = occurrences(of: wrong, in: chars).first {
            return Span(range: r, wrong: String(chars[r]), right: problem ? fix : nil)
        }
        // Where the fix says it is, from the fix alone.
        let fromFix: Span? = !problem ? nil : rewrite(said, to: fix) ?? window(for: fix, in: chars)
            .map { Span(range: $0, wrong: String(chars[$0]), right: fix) }

        var quoted = [atom.stages.locate, atom.stages.name, atom.stages.note]
            .flatMap(quotes(in:))
        if !atom.verdict.isProblem, !fix.isEmpty { quoted.append(fix) }
        let near = { (r: Range<Int>) in fromFix.map { $0.range.overlaps(r) } ?? false }
        let hits = quoted.compactMap { q -> (range: Range<Int>, count: Int)? in
            let found = occurrences(of: q, in: chars)
            guard let first = found.first else { return nil }
            // A repeat is settled by the fix where it can be.
            return (found.first(where: near) ?? first, found.count)
        }
        // A quote the fix agrees with. Where the fix places it elsewhere, the
        // quote was context ("after „Gestern“"): the fix wins. With no fix,
        // a quote that occurs once, then any.
        let agreed = hits.first { near($0.range) }
        if agreed == nil, let fromFix { return fromFix }
        if let r = (agreed ?? hits.first { $0.count == 1 } ?? hits.first)?.range {
            let right: String? = !problem ? nil
                : (fromFix.flatMap { $0.range == r ? $0.right : nil } ?? fix)
            return Span(range: r, wrong: String(chars[r]), right: right)
        }
        return fromFix
    }

    /// Text between paired quotes, trimmed. Two or more characters, or one CJK.
    nonisolated static func quotes(in text: String) -> [String] {
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("“", "”"), ("„", "“"), ("«", "»"), ("‹", "›"),
            ("‘", "’"), ("「", "」"), ("『", "』"), ("*", "*"), ("'", "'")
        ]
        let chars = Array(text)
        var found: [String] = []
        var i = 0
        // One pass, so the closer of „…“ is never read as an opener.
        while i < chars.count {
            let c = chars[i]
            // An apostrophe inside a word is not a quote.
            let inWord = c == "'" && i > 0 && chars[i - 1].isLetter
            let ends = inWord ? [] : pairs.filter { $0.0 == c }.compactMap { pair in
                chars[(i + 1)...].firstIndex(of: pair.1)
            }
            guard let j = ends.min() else { i += 1; continue }
            let inner = String(chars[(i + 1)..<j]).trimmingCharacters(in: .whitespaces)
            if inner.count >= 2 || inner.contains(where: isCJK) { found.append(inner) }
            i = j + 1
        }
        return found
    }

    nonisolated private static func occurrences(of needle: String, in chars: [Character]) -> [Range<Int>] {
        let n = Array(needle)
        guard !n.isEmpty, n.count <= chars.count else { return [] }
        return (0...(chars.count - n.count)).compactMap { i in
            Array(chars[i..<(i + n.count)]) == n ? i..<(i + n.count) : nil
        }
    }

    nonisolated static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }

    nonisolated private static func isWord(_ c: Character) -> Bool {
        !isCJK(c) && (c.isLetter || c.isNumber || c == "-" || c == "'" || c == "’")
    }

    /// A fix that is the whole sentence rewritten: what changed, on word
    /// boundaries. An insertion takes the word before it.
    nonisolated private static func rewrite(_ said: String, to fix: String) -> Span? {
        let a = Array(said), b = Array(fix)
        guard !b.isEmpty, a != b else { return nil }
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        // Too little shared: a fragment, not a rewrite.
        guard p + s >= max(2, a.count / 3) else { return nil }
        var lo = p, hiA = a.count - s, hiB = b.count - s
        // Out to word boundaries; prefix and suffix are shared, so both move.
        while lo > 0, lo < a.count, isWord(a[lo - 1]), isWord(a[lo]) { lo -= 1 }
        while hiA > 0, hiA < a.count, isWord(a[hiA - 1]), isWord(a[hiA]) { hiA += 1; hiB += 1 }
        if lo == hiA {
            // Nothing of the learner's to mark: take the word before, or after.
            if lo > 0 {
                var w = lo - 1
                while w > 0, a[w] == " " { w -= 1 }
                var start = w
                while start > 0, isWord(a[start - 1]) { start -= 1 }
                if isCJK(a[w]) { start = w }
                lo = start
            } else if hiA < a.count {
                var end = hiA + 1
                while end < a.count, isWord(a[end - 1]), isWord(a[end]) { end += 1 }
                hiB += end - hiA
                hiA = end
            }
        }
        guard lo < hiA, hiB <= b.count, lo <= hiB else { return nil }
        let wrong = String(a[lo..<hiA]).trimmingCharacters(in: .whitespaces)
        let right = String(b[lo..<hiB]).trimmingCharacters(in: .whitespaces)
        guard !wrong.isEmpty else { return nil }
        // Trim what trimming took off the range.
        let lead = a[lo..<hiA].prefix { $0 == " " }.count
        let trail = a[lo..<hiA].reversed().prefix { $0 == " " }.count
        return Span(range: (lo + lead)..<(hiA - trail), wrong: wrong, right: right)
    }

    /// Words (or CJK characters) with their offsets.
    nonisolated private static func tokens(_ chars: [Character]) -> [(String, Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var i = 0
        while i < chars.count {
            if isCJK(chars[i]) { out.append((String(chars[i]), i..<(i + 1))); i += 1; continue }
            guard isWord(chars[i]) else { i += 1; continue }
            var j = i
            while j < chars.count, isWord(chars[j]) { j += 1 }
            out.append((String(chars[i..<j]).lowercased(), i..<j))
            i = j
        }
        return out
    }

    /// The run of words a fragment fix most plausibly replaces: the same
    /// length, give or take one, sharing at least half its words. Earliest wins a tie.
    nonisolated static func window(for fix: String, in chars: [Character]) -> Range<Int>? {
        let said = tokens(chars)
        let want = tokens(Array(fix)).map(\.0)
        guard !want.isEmpty, !said.isEmpty else { return nil }
        var best: (score: Double, range: Range<Int>)?
        for len in [want.count, want.count - 1, want.count + 1] where len >= 1 && len <= said.count {
            for start in 0...(said.count - len) {
                var pool = want
                var shared = 0
                for t in said[start..<(start + len)] {
                    if let k = pool.firstIndex(of: t.0) { pool.remove(at: k); shared += 1 }
                }
                let overlap = Double(shared) / Double(max(len, want.count))
                guard shared > 0, overlap >= 0.5 else { continue }
                // Words in the same places break a tie.
                let aligned = zip(said[start..<(start + len)], want).filter { $0.0.0 == $0.1 }.count
                let score = overlap + 0.01 * Double(aligned)
                // A window identical to the fix is not wrong.
                if shared == want.count, len == want.count,
                   said[start..<(start + len)].map(\.0) == want { continue }
                let r = said[start].1.lowerBound..<said[start + len - 1].1.upperBound
                if best == nil || score > best!.score { best = (score, r) }
            }
        }
        return best?.range
    }

    /// Character ranges where two sentences differ, token by token: words for
    /// Latin scripts, characters for Mandarin. Case and punctuation are
    /// ignored. Tokens outside a longest common subsequence are marked;
    /// neighbours merge.
    nonisolated static func divergence(_ said: String, _ ref: String,
                                       language: Language) -> (said: [Range<Int>], ref: [Range<Int>]) {
        let a = tokens(said, language: language)
        let b = tokens(ref, language: language)
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i].key == b[j].key ? lcs[i + 1][j + 1] + 1
                        : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var keepA = Array(repeating: false, count: n)
        var keepB = Array(repeating: false, count: m)
        var i = 0, j = 0
        while i < n && j < m {
            if a[i].key == b[j].key {
                keepA[i] = true; keepB[j] = true; i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (merged(a, keepA), merged(b, keepB))
    }

    private struct Token: Sendable { let range: Range<Int>; let key: String }

    private nonisolated static func tokens(_ text: String, language: Language) -> [Token] {
        let chars = Array(text)
        func key(_ s: String) -> String {
            String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter {
                !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0)
            }))
        }
        var out: [Token] = []
        if language == .mandarin {
            for (i, c) in chars.enumerated() where !c.isWhitespace {
                let k = key(String(c))
                if !k.isEmpty { out.append(Token(range: i..<(i + 1), key: k)) }
            }
            return out
        }
        var start: Int?
        for i in 0...chars.count {
            let space = i == chars.count || chars[i].isWhitespace
            if space, let s = start {
                let k = key(String(chars[s..<i]))
                if !k.isEmpty { out.append(Token(range: s..<i, key: k)) }
                start = nil
            } else if !space, start == nil {
                start = i
            }
        }
        return out
    }

    private nonisolated static func merged(_ tokens: [Token], _ keep: [Bool]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var previous = -2
        for (i, t) in tokens.enumerated() where !keep[i] {
            if previous == i - 1, let last = out.last {
                out[out.count - 1] = last.lowerBound..<t.range.upperBound
            } else {
                out.append(t.range)
            }
            previous = i
        }
        return out
    }
}
