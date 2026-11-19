import Foundation

/// JSON schemas for every structured reply. `Block` was shaped to match these,
/// so nothing is remapped between the wire and the views.
enum Schemas {

    // MARK: Writing

    /// Structured output writes fields in the order the schema lists them, and
    /// `JSONSerialization` lists a dictionary in hash order — a new one per
    /// request. Reviews came back with `score` before any finding and
    /// `lessons` before the findings they index. So properties go in
    /// `required` order, and every other object's keys sorted.
    static func data(_ object: Any) throws -> Data {
        var out = Data()
        try write(object, order: [], into: &out)
        return out
    }

    private static func write(_ value: Any, order: [String], into out: inout Data) throws {
        switch value {
        case let object as [String: Any]:
            let first = order.filter { object[$0] != nil }
            let keys = first + object.keys.filter { !first.contains($0) }.sorted()
            let required = object["required"] as? [String] ?? []
            out.append(UInt8(ascii: "{"))
            for (index, key) in keys.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                try write(key, order: [], into: &out)
                out.append(UInt8(ascii: ":"))
                try write(object[key]!, order: key == "properties" ? required : [], into: &out)
            }
            out.append(UInt8(ascii: "}"))
        case let array as [Any]:
            out.append(UInt8(ascii: "["))
            for (index, item) in array.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                try write(item, order: [], into: &out)
            }
            out.append(UInt8(ascii: "]"))
        default:
            out.append(try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
        }
    }

    // MARK: Primitives

    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object",
         "additionalProperties": false,
         "properties": properties,
         "required": required]
    }

    private static func array(_ items: [String: Any]) -> [String: Any] {
        ["type": "array", "items": items]
    }

    private static let string: [String: Any] = ["type": "string"]
    private static let nullableString: [String: Any] = ["type": ["string", "null"]]

    private static func enumOf(_ cases: [String], _ description: String) -> [String: Any] {
        ["type": "string", "enum": cases, "description": description]
    }

    // MARK: Atom

    /// Small on purpose: the full atom nested at three depths made the
    /// compiled grammar too large for the model to accept.
    static func atomLink(for language: Language) -> [String: Any] {
        object([
            "kind": enumOf(LanguagePacks.pack(for: language).kinds.map(\.rawValue), "Category."),
            "headline": ["type": "string", "description": "One line. What opening this would teach."],
            "subject": ["type": "string", "description": "What a lesson about this would be about."]
        ], required: ["kind", "headline", "subject"])
    }

    /// One answer to one typed question. Its links also name the curriculum
    /// point they are, so the textbook can file a recommendation under it.
    static func freeAnswer(for language: Language) -> [String: Any] {
        var link = atomLink(for: language)
        var properties = link["properties"] as? [String: Any] ?? [:]
        properties["point"] = ["type": ["string", "null"],
                               "description": "Id of the listed grammar point this is, or null."]
        link["properties"] = properties
        link["required"] = ["kind", "headline", "subject", "point"]
        return object([
            "id": string,
            "question": string,
            "answer": ["type": "string", "description": "One or two sentences."],
            "atoms": array(link)
        ], required: ["id", "question", "answer", "atoms"])
    }

    // MARK: Lesson — two stages
    //
    // One schema carrying blocks, drills, ask items and nested links compiled
    // to a grammar the API rejects as too large. Splitting it also splits the
    // wait: the rule and its examples arrive first and are what the learner
    // reads, while the drills are still being written.

    static func lessonCore(for language: Language) -> [String: Any] {
        object([
            "title": string,
            "rule": ["type": "string", "description": "The explanation. A short paragraph, not an essay."],
            "contrastTerm": ["type": ["string", "null"], "description": "The confusable neighbour, or null."],
            "contrastNote": nullableString,
            "contrastSubject": ["type": ["string", "null"], "description": "What a lesson about the neighbour would be about."],
            "examples": array(object([
                "target": ["type": "string", "description": "In \(language.name)."],
                "gloss": ["type": "string", "description": "In English."],
                "subject": ["type": ["string", "null"], "description": "What opening this example would teach, or null."]
            ], required: ["target", "gloss", "subject"]))
        ], required: ["title", "rule", "contrastTerm", "contrastNote", "contrastSubject", "examples"])
    }

    static func lessonPractice(for language: Language) -> [String: Any] {
        let rung = object([
            "support": enumOf(["free", "transform", "frame", "choice"],
                              "free is unaided production; choice is two options."),
            "prompt": string,
            "accept": array(string),
            "options": ["type": ["array", "null"], "items": string],
            "answerIndex": ["type": ["integer", "null"]]
        ], required: ["support", "prompt", "accept", "options", "answerIndex"])

        return object([
            "drills": array(object([
                "rungs": ["type": "array", "items": rung,
                          "description": "At least two, hardest first. Each later rung removes something the learner has to build."],
                "correct": string,
                "incorrect": string,
                "links": array(atomLink(for: language))
            ], required: ["rungs", "correct", "incorrect", "links"])),
            "patterns": ["type": "array",
                         "description": "Shown instead of the rule on a third visit. Pattern only, no explanation.",
                         "items": object(["target": string, "gloss": string],
                                         required: ["target", "gloss"])]
        ], required: ["drills", "patterns"])
    }

    // MARK: Review
    //
    // One call per answer, graded in a batch while nobody is waiting. Every
    // stage of every finding comes back together — there is no second pass
    // to hold anything back for.

    static func review(for language: Language) -> [String: Any] {
        let kinds = enumOf(LanguagePacks.pack(for: language).kinds.map(\.rawValue), "Category.")

        return object([
            "score": ["type": "integer", "description": "0 to 100: how well it would work said to a native speaker. Understood first, then natural, then form."],
            "readOfScore": ["type": "string", "description": "One clause on what it means. Not a breakdown."],
            "findings": array(object([
                "kind": kinds,
                "verdict": enumOf(["breaks", "weakens", "kept"],
                                  "breaks stops comprehension; weakens marks a learner; kept is right and worth knowing why."),
                "weight": enumOf(["start", "also"], "Exactly one is start."),
                "wrong": ["type": "string",
                          "description": "The learner's words this is about, copied exactly from what they said, as few as show the problem. For kept: the words that were right. Empty only when something is missing and there is nothing to quote."],
                "name": ["type": "string", "description": "Why, in six words or fewer. Read at a glance beside wrong → fix. For kept: what they did right."],
                "fix": ["type": "string", "description": "What replaces `wrong`, and only that: not the whole sentence. For kept: the words that were right."],
                "note": ["type": "string", "description": "One or two sentences on why."],
                "subject": ["type": "string", "description": "What a lesson about this would be about."],
                "point": ["type": ["string", "null"],
                          "description": "Id of the listed grammar point this finding is about, or null."]
            ], required: ["kind", "verdict", "weight", "wrong", "name", "fix", "note", "subject", "point"])),
            "fixed": ["type": ["string", "null"],
                      "description": "The learner's own sentence with every breaks and weakens fix applied and nothing else changed. Null in listen, and when several numbered answers are assessed."],
            "gloss": ["type": ["string", "null"],
                      "description": "What `fixed` means, in plain English, one sentence. Null when `fixed` is."],
            "natural": ["type": ["string", "null"],
                        "description": "What a speaker would actually say, if different from `fixed`."],
            "respeaks": array(object([
                "instruction": ["type": "string",
                                "description": "Say the same sentence again with one thing changed — a different subject, tense, or added detail. Never a plain repeat."],
                "accept": array(string),
                "correct": string,
                "incorrect": string
            ], required: ["instruction", "accept", "correct", "incorrect"])),
            "used": ["type": "array", "items": string,
                     "description": "Ids of the grammar points the learner's own sentences used, correctly or not. Only ids from the list given. Empty is a normal answer."]
        ], required: ["findings", "score", "readOfScore", "fixed", "gloss", "natural", "respeaks", "used"])
    }

    // MARK: The day's prompts

    /// Everything a session will ask, written in one call so the set can be
    /// spread deliberately rather than turn by turn.
    static let daySet: [String: Any] = object([
        "items": array(object([
            "english": ["type": "string",
                        "description": "For translate, what the learner reads. Otherwise the gloss of `target`."],
            "target": ["type": ["string", "null"],
                       "description": "Produce: the question, one sentence ending in a single question mark. Reply: the message. Null for translate."],
            "reference": ["type": ["string", "null"],
                          "description": "Translate: one natural rendering, shown after the learner answers. Null otherwise."],
            "from": ["type": ["string", "null"],
                     "description": "Reply: who sent the message, in the target language. Null otherwise."],
            "revisited": ["type": "array", "items": string,
                          "description": "Which of the listed revisit subjects this sentence actually calls for, copied exactly."]
        ], required: ["target", "english", "reference", "from", "revisited"]))
    ], required: ["items"])

    // MARK: Prompt generation

    static let prompt: [String: Any] = object([
        "english": ["type": "string",
                    "description": "The English side. For translate this is what the learner reads; elsewhere it is the gloss."],
        "target": ["type": ["string", "null"],
                   "description": "The target-language side: the sentence to be played, or the question to be answered — for produce, one sentence ending in a single question mark. Null for translate."]
    ], required: ["english", "target"])

    // MARK: Drill grading

    static let drillResult: [String: Any] = object([
        "correct": ["type": "boolean"],
        "note": ["type": "string", "description": "One or two sentences."]
    ], required: ["correct", "note"])

    // MARK: Talk

    static let conversationScene: [String: Any] = object([
        "place": ["type": "string", "description": "Where, in the target language, two or three words."],
        "you": ["type": "string", "description": "English. Who the learner is and what has happened, one or two short sentences. No target-language words."],
        "want": ["type": "string", "description": "English. What they are after, one short clause, no full stop."],
        "them": ["type": "string", "description": "English. Who the other person is and what they would rather do, short."],
        "role": ["type": "string", "description": "What the learner would call them, in the target language, one to three words."],
        "formal": ["type": "boolean", "description": "Whether a speaker would be formal with them."],
        "opening": ["type": "string", "description": "Their first line, in the target language, one sentence."]
    ], required: ["place", "you", "want", "them", "role", "formal", "opening"])

    static let partnerLine: [String: Any] = object([
        "move": enumOf(["answer", "push back", "ask again", "close"],
                       "ask again: you did not understand them. push back: you resist what they want. close: your line ends the conversation."),
        "say": ["type": "string", "description": "Your line, in the target language only."],
        "goal_met": ["type": "boolean", "description": "True once the learner has got what they wanted."]
    ], required: ["move", "say", "goal_met"])
}
