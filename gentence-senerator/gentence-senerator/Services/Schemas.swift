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

    /// One answer to one typed question.
    static func freeAnswer(for language: Language) -> [String: Any] {
        object([
            "id": string,
            "question": string,
            "answer": ["type": "string", "description": "One or two sentences."],
            "atoms": array(atomLink(for: language))
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
    // stage of every finding, and a lesson for each problem, come back
    // together — there is no second pass to hold anything back for.

    static func review(for language: Language) -> [String: Any] {
        let kinds = enumOf(LanguagePacks.pack(for: language).kinds.map(\.rawValue), "Category.")
        let rung = object([
            "support": enumOf(["free", "transform", "frame", "choice"],
                              "free is unaided production; choice is two options."),
            "prompt": string,
            "accept": array(string),
            "options": ["type": ["array", "null"], "items": string],
            "answerIndex": ["type": ["integer", "null"]]
        ], required: ["support", "prompt", "accept", "options", "answerIndex"])
        let pair = object(["target": string, "gloss": string], required: ["target", "gloss"])

        return object([
            "score": ["type": "integer", "description": "0 to 100."],
            "readOfScore": ["type": "string", "description": "One clause on what it means. Not a breakdown."],
            "findings": array(object([
                "kind": kinds,
                "verdict": enumOf(["breaks", "weakens", "kept"],
                                  "breaks stops comprehension; weakens marks a learner; kept is right and worth knowing why."),
                "weight": enumOf(["start", "also"], "Exactly one is start."),
                "locate": ["type": "string",
                           "description": "Where, without saying what. The learner should be able to try repairing it from this alone. Never name the fix here."],
                "name": ["type": "string", "description": "What is wrong, still without the corrected text. For kept: what they did right."],
                "fix": ["type": "string", "description": "The corrected text. For kept: the words that were right."],
                "note": ["type": "string", "description": "One or two sentences on why."],
                "subject": ["type": "string", "description": "What a lesson about this would be about."]
            ], required: ["kind", "verdict", "weight", "locate", "name", "fix", "note", "subject"])),
            "natural": ["type": ["string", "null"],
                        "description": "What a speaker would actually say, if different from the minimal fix."],
            "respeaks": array(object([
                "instruction": ["type": "string",
                                "description": "Say the same sentence again with one thing changed — a different subject, tense, or added detail. Never a plain repeat."],
                "accept": array(string),
                "correct": string,
                "incorrect": string
            ], required: ["instruction", "accept", "correct", "incorrect"])),
            "lessons": ["type": "array",
                        "description": "One per problem finding (breaks or weakens), none for kept.",
                        "items": object([
                "finding": ["type": "integer", "description": "Index of the finding in `findings`, from 0."],
                "title": string,
                "rule": ["type": "string", "description": "The explanation. A short paragraph, not an essay."],
                "contrastTerm": ["type": ["string", "null"], "description": "The confusable neighbour, or null."],
                "contrastNote": nullableString,
                "contrastSubject": ["type": ["string", "null"], "description": "What a lesson about the neighbour would be about."],
                "examples": array(pair),
                "drills": array(object([
                    "rungs": ["type": "array", "items": rung,
                              "description": "At least two, hardest first. Each later rung removes something the learner has to build."],
                    "correct": string,
                    "incorrect": string
                ], required: ["rungs", "correct", "incorrect"])),
                "patterns": ["type": "array",
                             "description": "Shown instead of the rule on a third visit. Pattern only, no explanation.",
                             "items": pair]
            ], required: ["finding", "title", "rule", "contrastTerm", "contrastNote",
                          "contrastSubject", "examples", "drills", "patterns"])],
            "used": ["type": "array", "items": string,
                     "description": "Ids of the grammar points the learner's own sentences used, correctly or not. Only ids from the list given. Empty is a normal answer."]
        ], required: ["findings", "score", "readOfScore", "natural", "respeaks", "lessons", "used"])
    }

    // MARK: The day's prompts

    /// Everything a session will ask, written in one call so the set can be
    /// spread deliberately rather than turn by turn.
    static let daySet: [String: Any] = object([
        "items": array(object([
            "english": ["type": "string",
                        "description": "For translate, what the learner reads. For produce, the gloss of the question."],
            "target": ["type": ["string", "null"],
                       "description": "Produce: the question, one sentence ending in a single question mark. Null for translate."],
            "reference": ["type": ["string", "null"],
                          "description": "Translate: one natural rendering, shown after the learner answers. Null for produce."],
            "revisited": ["type": "array", "items": string,
                          "description": "Which of the listed revisit subjects this sentence actually calls for, copied exactly."]
        ], required: ["target", "english", "reference", "revisited"]))
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
}
