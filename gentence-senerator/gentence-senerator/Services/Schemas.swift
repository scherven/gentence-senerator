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
            "ask": array(object([
                "question": ["type": "string", "description": "A question the learner plausibly has, in their own words."],
                "answer": string,
                "links": array(atomLink(for: language))
            ], required: ["question", "answer", "links"])),
            "patterns": ["type": "array",
                         "description": "Shown instead of the rule on a third visit. Pattern only, no explanation.",
                         "items": object(["target": string, "gloss": string],
                                         required: ["target", "gloss"])]
        ], required: ["drills", "ask", "patterns"])
    }

    // MARK: Review — two stages
    //
    // The opening is what the learner sees at once: a score and where each
    // problem is. Naming and fixing arrive while they are still trying to
    // repair it themselves.

    static func reviewOpening(for language: Language) -> [String: Any] {
        object([
            "score": ["type": "integer", "description": "0 to 100."],
            "readOfScore": ["type": "string", "description": "One clause on what it means. Not a breakdown."],
            "fixed": ["type": ["string", "null"], "description": "The minimal correction."],
            "findings": array(object([
                "kind": enumOf(LanguagePacks.pack(for: language).kinds.map(\.rawValue), "Category."),
                "verdict": enumOf(["breaks", "weakens", "kept"],
                                  "breaks stops comprehension; weakens marks a learner; kept is right and worth knowing why."),
                "weight": enumOf(["start", "also"], "Exactly one is start."),
                "anchor": ["type": ["string", "null"], "description": "The learner's own words, verbatim."],
                "locate": ["type": "string",
                           "description": "Where, without saying what. The learner should be able to try repairing it from this alone. Never name the fix here."],
                "subject": ["type": "string", "description": "What a lesson about this would be about."]
            ], required: ["kind", "verdict", "weight", "anchor", "locate", "subject"]))
        ], required: ["score", "readOfScore", "fixed", "findings"])
    }

    static func reviewDepth(for language: Language) -> [String: Any] {
        object([
            "natural": ["type": ["string", "null"],
                        "description": "What a speaker would actually say, if different from the minimal fix."],
            "understood": ["type": ["string", "null"], "description": "Produce only: what you took them to mean."],
            "findings": array(object([
                "id": ["type": "string", "description": "Matching an id from the opening."],
                "name": ["type": "string", "description": "What is wrong, still without the corrected text."],
                "fix": ["type": "string", "description": "The corrected text."],
                "note": ["type": "string", "description": "One or two sentences on why."]
            ], required: ["id", "name", "fix", "note"])),
            "respeaks": array(object([
                "instruction": ["type": "string",
                                "description": "Say the same sentence again with one thing changed — a different subject, tense, or added detail. Never a plain repeat."],
                "accept": array(string),
                "correct": string,
                "incorrect": string
            ], required: ["instruction", "accept", "correct", "incorrect"])),
            "ask": array(object([
                "question": string,
                "answer": string,
                "links": array(atomLink(for: language))
            ], required: ["question", "answer", "links"]))
        ], required: ["natural", "understood", "findings", "respeaks", "ask"])
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
