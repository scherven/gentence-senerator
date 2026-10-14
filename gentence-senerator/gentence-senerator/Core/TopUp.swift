import Foundation

/// More test items for a chapter, written by the model when the learner has
/// nearly run through it. Asked for only when a chapter in use is down to
/// `lowWater` unseen items, written in the background, kept on the phone, so
/// nothing is paid for that isn't about to be asked and no quiz waits on the
/// network.
///
/// Two calls: one writes, one checks. What survives the check, the format
/// rules and the near-duplicate test is kept.
enum TopUp {
    static let lowWater = 10
    static let batch = 20
    /// Two prompts this alike (character bigrams, Dice) count as the same.
    static let sameAt = 0.7
    /// After a failed top-up, a chapter waits this long before another.
    static let retryAfter: TimeInterval = 15 * 60

    /// Formats the model may write. Tone-tap comes from the vocab lists.
    static func formats(_ chapter: Chapter) -> [QuizFormat] {
        chapter.formats.filter { $0 != .toneTap }
    }

    // MARK: Writing

    static let system = """
    You write quiz items for a language-learning app. Each item tests one rule \
    from a textbook chapter, given as entries with ids. Write the items asked \
    for as JSON matching the schema.

    Formats, and the fields each uses (leave the rest empty):
    - pick-one: `prompt` is a sentence with one ＿ gap; one step, 3–4 options.
    - flip: `prompt` with one ＿ gap; one step, exactly 2 options.
    - two-step: `prompt` with ＿ gaps; two steps, each 2–5 options, each step \
    with a short `prompt` naming what it asks ("auxiliary", "ending").
    - spot-it: step 1's options are the sentence's tokens and its answer is the \
    wrong token; step 2 offers fixes and its answer is the right one.
    - build: `tiles` are the sentence's pieces in the right order; `decoys` are \
    2–3 wrong pieces; `accept` lists other correct orders, tiles joined by \
    single spaces.
    - transform: `prompt` is a sentence, `task` the instruction ("→ Perfekt"), \
    `accept` every correct rewrite.
    - sort: 4–12 steps, each step's `prompt` an item, the same 2–4 buckets as \
    options on every step.

    Every item:
    - has exactly one defensible answer. No distractor a native speaker would \
    also accept, including colloquial usage.
    - is a natural sentence at the learner's level, about everyday life, \
    varied in vocabulary and situation.
    - is new: never reuse, translate back or lightly edit a sentence from the \
    "already used" list.
    - has `gloss`: the English of the sentence, and `why`: the rule in three \
    words at most ("warten auf", "机器 → 台").
    """

    static let schema: [String: Any] = {
        let step: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": ["prompt": ["type": "string"],
                           "options": ["type": "array", "items": ["type": "string"]],
                           "answer": ["type": "integer"]],
            "required": ["prompt", "options", "answer"]]
        let strings: [String: Any] = ["type": "array", "items": ["type": "string"]]
        let item: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": ["entry": ["type": "string"], "format": ["type": "string"],
                           "prompt": ["type": "string"], "gloss": ["type": "string"],
                           "task": ["type": "string"], "why": ["type": "string"],
                           "steps": ["type": "array", "items": step],
                           "tiles": strings, "decoys": strings, "accept": strings],
            "required": ["entry", "format", "prompt", "gloss", "task", "why",
                         "steps", "tiles", "decoys", "accept"]]
        return ["type": "object", "additionalProperties": false,
                "properties": ["items": ["type": "array", "items": item]],
                "required": ["items"]]
    }()

    struct Written: Decodable {
        var items: [Draft]

        struct Draft: Decodable {
            var entry: String
            var format: String
            var prompt: String
            var gloss: String
            var task: String
            var why: String
            var steps: [QuizItem.Step]
            var tiles: [String]
            var decoys: [String]
            var accept: [String]
        }
    }

    static func request(chapter: Chapter, level: String, examples: [QuizItem],
                        used: [String], count: Int = batch) -> String {
        let entries = chapter.entries.map { e in
            [e.id, e.head, e.gloss, e.group, e.tag, e.example].compactMap { $0 }.joined(separator: " | ")
        }
        let shown = examples.compactMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        return """
        Learner's level: \(level)
        Chapter: \(chapter.name)
        Entries (id | head | gloss | group | tag | example):
        \(entries.joined(separator: "\n"))

        Formats allowed: \(formats(chapter).map(\.rawValue).joined(separator: ", "))
        Write \(count) items, spread over the entries and formats.

        Examples of the style:
        \(shown.joined(separator: "\n"))

        Already used (do not reuse):
        \(used.joined(separator: "\n"))
        """
    }

    // MARK: Checking

    static let checkSystem = """
    You check quiz items written for a language learner. For each numbered \
    item, decide whether the marked answer is right and is the only answer a \
    native speaker would accept, colloquial usage included, and whether the \
    sentence is natural. List the numbers of every item that fails.
    """

    static let checkSchema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "properties": ["fail": ["type": "array", "items": ["type": "integer"]]],
        "required": ["fail"]]

    struct Checked: Decodable { var fail: [Int] }

    static func checkRequest(_ items: [QuizItem]) -> String {
        items.enumerated().map { i, item in
            let answer = QuizRound.expected(item).joined(separator: " / ")
            let options = item.steps.map { $0.options.joined(separator: ", ") }.joined(separator: " ; ")
            return "\(i). [\(item.format.rawValue)] \(item.prompt ?? item.tiles.joined(separator: " "))"
                + (item.task.map { " (\($0))" } ?? "")
                + (options.isEmpty ? "" : " — options: \(options)")
                + " — answer: \(answer)"
        }.joined(separator: "\n")
    }

    // MARK: Keeping

    /// Drafts that test this chapter in an allowed format, keep the format's
    /// rules and are unlike everything already used and each other.
    static func keep(_ drafts: [Written.Draft], chapter: Chapter, used: [String],
                     idPrefix: String) -> [QuizItem] {
        let entries = Set(chapter.entries.map(\.id))
        let allowed = Set(formats(chapter))
        var seen = used.map { bigrams($0) }
        var out: [QuizItem] = []
        for (i, d) in drafts.enumerated() {
            guard entries.contains(d.entry), let format = QuizFormat(rawValue: d.format),
                  allowed.contains(format) else { continue }
            let blank = { (s: String) -> String? in s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s }
            let item = QuizItem(id: "\(idPrefix).\(i)", entry: d.entry, format: format,
                                prompt: blank(d.prompt), gloss: blank(d.gloss), task: blank(d.task),
                                why: blank(d.why), steps: d.steps.map {
                                    QuizItem.Step(prompt: $0.prompt.flatMap(blank), options: $0.options, answer: $0.answer)
                                },
                                tiles: d.tiles, decoys: d.decoys, accept: d.accept)
            guard item.problems.isEmpty else { continue }
            let grams = bigrams(text(item))
            guard !seen.contains(where: { similarity(grams, $0) >= sameAt }) else { continue }
            seen.append(grams)
            out.append(item)
        }
        return out
    }

    /// What an item reads as, for comparing.
    static func text(_ item: QuizItem) -> String {
        item.prompt ?? QuizRound.join(item.tiles)
    }

    static func bigrams(_ s: String) -> [String: Int] {
        let chars = Array(QuizRound.normalise(s.replacingOccurrences(of: String(QuizItem.gap), with: " ")))
        var out: [String: Int] = [:]
        guard chars.count > 1 else { return chars.isEmpty ? [:] : [String(chars): 1] }
        for i in 0..<(chars.count - 1) { out[String(chars[i...i + 1]), default: 0] += 1 }
        return out
    }

    static func bigrams(_ item: QuizItem) -> [String: Int] { bigrams(text(item)) }

    /// Dice coefficient over bigram counts: 1 is identical.
    static func similarity(_ a: [String: Int], _ b: [String: Int]) -> Double {
        let total = a.values.reduce(0, +) + b.values.reduce(0, +)
        guard total > 0 else { return 0 }
        let shared = a.reduce(0) { $0 + min($1.value, b[$1.key] ?? 0) }
        return 2 * Double(shared) / Double(total)
    }

    static func similarity(_ a: String, _ b: String) -> Double { similarity(bigrams(a), bigrams(b)) }
}
