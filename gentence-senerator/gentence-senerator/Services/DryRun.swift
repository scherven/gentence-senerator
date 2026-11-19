import Foundation

/// The simulator spends nothing. Every model call is answered here, on the
/// device, from the request's own schema; batches are graded the same way the
/// moment they would be sent. Text is placeholder, shaped like the real thing
/// so screens can be looked at in each language. Azure is skipped.
///
/// Real calls in the simulator are a switch in Settings, off by default.
enum DryRun {

    static let realKey = "dryrun.real.v1"

    static var on: Bool {
        #if targetEnvironment(simulator)
        return !UserDefaults.standard.bool(forKey: realKey)
        #else
        return false
        #endif
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// One reply, as `/messages` would give it.
    static func reply(body: [String: Any]) -> Anthropic.Reply {
        let schema = ((body["output_config"] as? [String: Any])?["format"] as? [String: Any])?["schema"]
            as? [String: Any] ?? [:]
        let user = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        let system = ((body["system"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let language = Language.allCases.first { system.contains("\($0.name) tutor") }
            ?? Language.allCases.first { system.contains($0.name) } ?? .mandarin
        let value = answer(schema: schema, user: user, language: language)
        let text = (try? Schemas.data(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return Anthropic.Reply(text: text, usage: .init(inputTokens: 0, outputTokens: 0,
                                                       cacheReadTokens: 0, cacheWriteTokens: 0),
                               refusal: nil)
    }

    private static func properties(_ schema: [String: Any]) -> Set<String> {
        Set((schema["properties"] as? [String: Any] ?? [:]).keys)
    }

    private static func answer(schema: [String: Any], user: String, language: Language) -> Any {
        let keys = properties(schema)
        if keys.contains("findings") { return review(user: user, language: language) }
        if keys == ["items"], let items = (schema["properties"] as? [String: Any])?["items"] as? [String: Any],
           properties(items["items"] as? [String: Any] ?? [:]).contains("reference") {
            return daySet(user: user, language: language)
        }
        if keys.contains("opening") { return scene(language) }
        if keys == ["move", "say", "goal_met"] {
            let turns = user.components(separatedBy: "\nLearner:").count - 1
            let close = turns >= 3 || user.contains("This is your last line")
            return ["move": close ? "close" : "answer",
                    "say": bank(language).partner[turns % bank(language).partner.count],
                    "goal_met": close]
        }
        if keys == ["english", "target"] {
            let b = bank(language)
            let mode = field("Mode", in: user) ?? "listen"
            let pick = abs(user.hashValue) % b.translate.count
            return mode == "translate"
                ? ["english": b.translate[pick].english, "target": NSNull()]
                : ["english": b.translate[pick].english, "target": b.translate[pick].target]
        }
        return fake(schema)
    }

    // MARK: Day set

    private static func daySet(user: String, language: Language) -> [String: Any] {
        let count = Int(field("Items", in: user) ?? "") ?? 5
        let mode = field("Mode", in: user) ?? "translate"
        let b = bank(language)
        let items: [[String: Any]] = (0..<count).map { i in
            switch mode {
            case "reply":
                let m = b.messages[i % b.messages.count]
                return ["english": m.english, "target": m.target, "reference": NSNull(),
                        "from": m.from, "revisited": []]
            case "produce", "scene":
                let q = b.questions[i % b.questions.count]
                return ["english": q.english, "target": q.target, "reference": NSNull(),
                        "from": NSNull(), "revisited": []]
            default:
                let t = b.translate[i % b.translate.count]
                return ["english": t.english, "target": NSNull(), "reference": t.target,
                        "from": NSNull(), "revisited": []]
            }
        }
        return ["items": items]
    }

    // MARK: Review

    /// One problem on a word of what was said, one kept. Enough to put every
    /// part of the review screen up.
    private static func review(user: String, language: Language) -> [String: Any] {
        let said = field("The learner said", in: user) ?? field("The learner replied", in: user)
            ?? field("Wrote", in: user)
            ?? field("Said back", in: user) ?? ""
        let listen = user.contains("Mode: listen")
        let b = bank(language)
        let tokens = language.usesSpaces
            ? said.split(separator: " ").map(String.init)
            : said.map(String.init)
        let candidates = tokens.enumerated().filter { $0.element.count >= (language.usesSpaces ? 3 : 1) }
            .filter { !$0.element.allSatisfy(\.isPunctuation) }
        var findings: [[String: Any]] = []
        var fixed: Any = NSNull()
        if let hit = candidates.dropFirst(candidates.count > 1 ? 1 : 0).first {
            let wrong = hit.element.trimmingCharacters(in: .punctuationCharacters)
            var out = tokens
            out[hit.offset] = hit.element.replacingOccurrences(of: wrong, with: b.fixWord)
            fixed = listen ? NSNull() : out.joined(separator: language.usesSpaces ? " " : "")
            findings.append(finding(kind: b.kind, verdict: "weakens", weight: "start",
                                    wrong: wrong, fix: b.fixWord, name: b.why,
                                    note: "Dry run. No model was asked."))
        }
        if let kept = candidates.first, !said.isEmpty {
            findings.append(finding(kind: "word-choice", verdict: "kept", weight: findings.isEmpty ? "start" : "also",
                                    wrong: kept.element, fix: kept.element, name: "This word was right.",
                                    note: "Dry run."))
        }
        return [
            "score": findings.contains { ($0["verdict"] as? String) == "weakens" } ? 82 : 100,
            "readOfScore": "Dry run.",
            "findings": findings,
            "fixed": fixed,
            "gloss": listen ? NSNull() : (field("Asked (English)", in: user) ?? field("It means", in: user) ?? "Dry run."),
            "natural": NSNull(),
            "respeaks": [],
            "used": []
        ]
    }

    private static func finding(kind: String, verdict: String, weight: String, wrong: String,
                                fix: String, name: String, note: String) -> [String: Any] {
        ["kind": kind, "verdict": verdict, "weight": weight, "wrong": wrong, "name": name,
         "fix": fix, "note": note, "subject": "dry run \(wrong)", "point": NSNull()]
    }

    // MARK: Talk

    private static func scene(_ language: Language) -> [String: Any] {
        let b = bank(language)
        return ["place": b.place, "you": "You bought headphones last week and one side is dead.",
                "want": "a refund, not a voucher", "them": "The clerk would rather give store credit.",
                "role": b.role, "formal": true, "opening": b.partner[0]]
    }

    // MARK: Anything else

    /// A value of the schema's shape. Strings say so; arrays hold one.
    private static func fake(_ schema: [String: Any]) -> Any {
        if let options = schema["enum"] as? [Any], let first = options.first { return first }
        if let minimum = schema["minItems"] as? Int, minimum > 1 {
            return Array(repeating: fake(schema["items"] as? [String: Any] ?? ["type": "string"]), count: minimum)
        }
        let type = schema["type"]
        let types = (type as? [String]) ?? [(type as? String) ?? "object"]
        if types.contains("object") {
            var out: [String: Any] = [:]
            for (key, sub) in schema["properties"] as? [String: Any] ?? [:] {
                out[key] = fake(sub as? [String: Any] ?? [:])
            }
            return out
        }
        if types.contains("array") {
            return [fake(schema["items"] as? [String: Any] ?? ["type": "string"])]
        }
        if types.contains("string") { return "Dry run." }
        if types.contains("integer") { return 0 }
        if types.contains("number") { return 0 }
        if types.contains("boolean") { return false }
        return NSNull()
    }

    /// The text after `name: ` on its own line.
    private static func field(_ name: String, in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(name + ":") {
                return String(trimmed.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Sentences to file as yesterday's answers, for `-dryRunSeed`.
    static func samples(_ language: Language) -> [Pair] { bank(language).translate }

    // MARK: Placeholder text

    struct Pair { var english: String; var target: String }
    struct Message { var from: String; var target: String; var english: String }
    struct Bank {
        var translate: [Pair]
        var messages: [Message]
        var questions: [Pair]
        var partner: [String]
        var place: String
        var role: String
        var fixWord: String
        var kind: String
        var why: String
    }

    private static func bank(_ language: Language) -> Bank {
        switch language {
        case .mandarin:
            return Bank(
                translate: [.init(english: "I went to the supermarket, and the bookstore too.", target: "我昨天去了超市，也去了书店。"),
                            .init(english: "I've been waiting for the bus for twenty minutes.", target: "我等公交车等了二十分钟了。"),
                            .init(english: "Could you speak a bit more slowly?", target: "你可以说慢一点吗？")],
                messages: [.init(from: "小王 · 室友", target: "你把垃圾倒了吗？", english: "Did you take the rubbish out?"),
                           .init(from: "李姐 · 同事", target: "明天的会改到十点了，你可以吗？", english: "Tomorrow's meeting moved to ten. Does that work?"),
                           .init(from: "妈妈", target: "周末回家吃饭吗？", english: "Coming home for dinner at the weekend?")],
                questions: [.init(english: "What did you do last weekend?", target: "你上个周末做了什么？"),
                            .init(english: "How do you get from your home to work?", target: "你从家到公司怎么走？")],
                partner: ["您好，有什么可以帮您的？", "退款的话需要小票。", "好的，给您办退款。"],
                place: "电器店", role: "店员", fixWord: "也", kind: "word-choice", why: "也 adds one more")
        case .german:
            return Bank(
                translate: [.init(english: "I've been waiting for the bus for twenty minutes.", target: "Ich warte seit zwanzig Minuten auf den Bus."),
                            .init(english: "Could you speak a bit more slowly?", target: "Könnten Sie etwas langsamer sprechen?"),
                            .init(english: "We went to the cinema yesterday.", target: "Wir sind gestern ins Kino gegangen.")],
                messages: [.init(from: "Jonas · Mitbewohner", target: "Hast du den Müll schon rausgebracht?", english: "Did you take the rubbish out yet?"),
                           .init(from: "Anna · Kollegin", target: "Das Meeting ist jetzt um zehn. Passt dir das?", english: "The meeting is at ten now. Does that work?"),
                           .init(from: "Mama", target: "Kommst du Sonntag zum Essen?", english: "Coming for dinner on Sunday?")],
                questions: [.init(english: "What did you do last weekend?", target: "Was hast du letztes Wochenende gemacht?"),
                            .init(english: "How do you get to work?", target: "Wie kommst du zur Arbeit?")],
                partner: ["Guten Tag, wie kann ich Ihnen helfen?", "Dafür brauche ich den Kassenbon.", "Gut, dann erstatte ich Ihnen das Geld."],
                place: "Elektromarkt", role: "Verkäuferin", fixWord: "auf", kind: "preposition", why: "warten auf, never für")
        case .french:
            return Bank(
                translate: [.init(english: "I've been waiting for the bus for twenty minutes.", target: "J'attends le bus depuis vingt minutes."),
                            .init(english: "Could you speak a bit more slowly?", target: "Vous pourriez parler un peu plus lentement ?"),
                            .init(english: "We went to the cinema yesterday.", target: "On est allés au cinéma hier.")],
                messages: [.init(from: "Léa · coloc", target: "T'as sorti les poubelles ?", english: "Did you take the bins out?"),
                           .init(from: "Marc · collègue", target: "La réunion est à dix heures maintenant, ça te va ?", english: "The meeting is at ten now, OK for you?"),
                           .init(from: "Maman", target: "Tu viens dîner dimanche ?", english: "Coming to dinner on Sunday?")],
                questions: [.init(english: "What did you do last weekend?", target: "Qu'est-ce que tu as fait le week-end dernier ?"),
                            .init(english: "How do you get to work?", target: "Comment tu vas au travail ?")],
                partner: ["Bonjour, je peux vous aider ?", "Il me faudrait le ticket de caisse.", "Très bien, je vous rembourse."],
                place: "magasin d'électronique", role: "vendeuse", fixWord: "depuis", kind: "preposition", why: "depuis for a wait still going")
        case .spanish:
            return Bank(
                translate: [.init(english: "I've been waiting for the bus for twenty minutes.", target: "Llevo veinte minutos esperando el autobús.")],
                messages: [.init(from: "Diego · roomie", target: "¿Ya sacaste la basura?", english: "Did you take the trash out yet?")],
                questions: [.init(english: "What did you do last weekend?", target: "¿Qué hiciste el fin de semana pasado?")],
                partner: ["Buenas tardes, ¿en qué le puedo ayudar?", "Necesito el ticket.", "Muy bien, le devuelvo el dinero."],
                place: "tienda de electrónica", role: "dependienta", fixWord: "el", kind: "word-choice", why: "dry run")
        case .korean:
            return Bank(
                translate: [.init(english: "I've been waiting for the bus for twenty minutes.", target: "버스를 이십 분째 기다리고 있어요.")],
                messages: [.init(from: "민수 · 룸메이트", target: "쓰레기 버렸어?", english: "Did you take the rubbish out?")],
                questions: [.init(english: "What did you do last weekend?", target: "지난 주말에 뭐 했어요?")],
                partner: ["안녕하세요, 뭘 도와드릴까요?", "영수증이 필요합니다.", "네, 환불해 드릴게요."],
                place: "전자제품 매장", role: "직원", fixWord: "도", kind: "particle", why: "dry run")
        }
    }
}
