import Foundation

/// JSON schemas for every structured reply. `Block` was shaped to match these,
/// so nothing is remapped between the wire and the views.
enum Schemas {

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

    static func atom(for language: Language) -> [String: Any] {
        object([
            "id": ["type": "string",
                   "description": "Stable id, kind-slug/anchor — e.g. word-order/已经. The same point must always produce the same id."],
            "kind": enumOf(LanguagePacks.pack(for: language).kinds.map(\.rawValue),
                           "The learner-facing category."),
            "verdict": enumOf(["breaks", "weakens", "kept"],
                              "breaks stops comprehension; weakens is understood but marks a learner; kept is right and worth knowing why."),
            "anchor": ["type": ["string", "null"],
                       "description": "The learner's own words this is about, verbatim, or null."],
            "weight": enumOf(["start", "also"], "Exactly one atom per review is start."),
            "stages": object([
                "locate": ["type": "string",
                           "description": "Where, without saying what. The learner should be able to try repairing it from this alone."],
                "name": ["type": "string", "description": "What is wrong, still without giving the corrected text."],
                "fix": ["type": "string", "description": "The corrected text itself."],
                "note": ["type": "string", "description": "One or two sentences on why."]
            ], required: ["locate", "name", "fix", "note"]),
            "seed": object([
                "subject": ["type": "string", "description": "What a lesson about this would be about."],
                "context": ["type": "string", "description": "The sentence it came from."],
                "pointID": nullableString
            ], required: ["subject", "context", "pointID"])
        ], required: ["id", "kind", "verdict", "anchor", "weight", "stages", "seed"])
    }

    private static func seed() -> [String: Any] {
        ["type": ["object", "null"],
         "additionalProperties": false,
         "properties": ["subject": string, "context": string, "pointID": nullableString],
         "required": ["subject", "context", "pointID"]]
    }

    // MARK: Lesson

    static func lesson(for language: Language) -> [String: Any] {
        let example = object([
            "id": string,
            "target": ["type": "string", "description": "In \(language.name)."],
            "gloss": ["type": "string", "description": "In English."],
            "seed": seed()
        ], required: ["id", "target", "gloss", "seed"])

        let side = object([
            "id": string,
            "term": string,
            "note": ["type": "string", "description": "One line on when this one is used."],
            "seed": seed()
        ], required: ["id", "term", "note", "seed"])

        let rung = object([
            "id": string,
            "support": enumOf(["free", "transform", "frame", "choice"],
                              "free is unaided production; choice is two options."),
            "prompt": string,
            "accept": array(string),
            "options": ["type": ["array", "null"], "items": string],
            "answerIndex": ["type": ["integer", "null"]]
        ], required: ["id", "support", "prompt", "accept", "options", "answerIndex"])

        let drill = object([
            "id": string,
            "rungs": ["type": "array", "items": rung,
                      "description": "At least two, hardest first. Index 0 is unaided production; each later rung removes something the learner has to build."],
            "correct": string,
            "incorrect": string,
            "atoms": array(atom(for: language))
        ], required: ["id", "rungs", "correct", "incorrect", "atoms"])

        let block = object([
            "id": string,
            "kind": enumOf(["rule", "contrast", "examples", "drills", "atoms"], "Which fields are used."),
            "label": nullableString,
            "text": ["type": ["string", "null"], "description": "rule only."],
            "sides": ["type": ["array", "null"], "items": side, "description": "contrast only. Exactly two."],
            "examples": ["type": ["array", "null"], "items": example, "description": "examples only."],
            "drills": ["type": ["array", "null"], "items": drill, "description": "drills only."],
            "atoms": ["type": ["array", "null"], "items": atom(for: language), "description": "atoms only."]
        ], required: ["id", "kind", "label", "text", "sides", "examples", "drills", "atoms"])

        return object([
            "id": string,
            "title": string,
            "blocks": array(block),
            "ask": array(askItem(for: language)),
            "patterns": ["type": "array", "items": example,
                         "description": "Shown instead of the rule on a third visit. Pattern only, no explanation."]
        ], required: ["id", "title", "blocks", "ask", "patterns"])
    }

    static func askItem(for language: Language) -> [String: Any] {
        object([
            "id": string,
            "question": ["type": "string",
                         "description": "A question the learner plausibly has after reading this, in their own words."],
            "answer": string,
            "atoms": array(atom(for: language))
        ], required: ["id", "question", "answer", "atoms"])
    }

    // MARK: Review

    static func review(for language: Language) -> [String: Any] {
        let respeak = object([
            "id": string,
            "instruction": ["type": "string",
                            "description": "Re-say the same sentence with one thing changed — a different subject, tense, or added detail. Never a plain repeat."],
            "accept": array(string),
            "correct": string,
            "incorrect": string
        ], required: ["id", "instruction", "accept", "correct", "incorrect"])

        return object([
            "score": ["type": "integer", "description": "0 to 100."],
            "readOfScore": ["type": "string", "description": "One clause on what the score means. Not a breakdown."],
            "atoms": ["type": "array", "items": atom(for: language),
                      "description": "Every finding, including what the learner got right. Exactly one has weight start."],
            "fixed": nullableString,
            "natural": ["type": ["string", "null"],
                        "description": "What a speaker would actually say, which is often not the minimal correction."],
            "understood": ["type": ["string", "null"],
                           "description": "Produce mode only: what you understood the learner to mean, in English."],
            "respeaks": array(respeak),
            "ask": array(askItem(for: language))
        ], required: ["score", "readOfScore", "atoms", "fixed", "natural",
                      "understood", "respeaks", "ask"])
    }

    // MARK: Prompt generation

    static let prompt: [String: Any] = object([
        "english": ["type": "string",
                    "description": "The English side. For translate this is what the learner reads; elsewhere it is the gloss."],
        "target": ["type": ["string", "null"],
                   "description": "The target-language side: the sentence to be played, or the question to be answered. Null for translate."],
        "pointID": ["type": ["string", "null"],
                    "description": "The grammar point this was built to exercise, if any."]
    ], required: ["english", "target", "pointID"])

    // MARK: Drill grading

    static let drillResult: [String: Any] = object([
        "correct": ["type": "boolean"],
        "note": ["type": "string", "description": "One or two sentences."],
        "oneGoodAnswer": string
    ], required: ["correct", "note", "oneGoodAnswer"])
}
