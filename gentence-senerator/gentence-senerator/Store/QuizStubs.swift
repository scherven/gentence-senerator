import SwiftUI

// TEMPORARY. Stand-ins for the quiz engine's API so the Book UI builds on its
// own. Deleted at merge; nothing may depend on what is inside them.

extension Store {
    var book: Book { QuizStubData.book(for: settings.language) }

    func state(of entry: Chapter.Entry) -> EntryState {
        let h = QuizStubData.hash(entry.id)
        let standing: DayPlan.Standing = [.never, .never, .tried, .holding, .solid, .solid][h % 6]
        let slipping = standing != .never && h % 7 == 0
        let n = standing == .never ? 0 : 1 + h % 8
        return EntryState(standing: standing, slipping: slipping,
                          lastSeen: standing == .never ? nil : .now,
                          recent: (0..<n).map { ($0 + h) % 4 != 0 })
    }

    func roundsDone(_ plan: QuizPlan) -> Int { QuizStubData.hash(plan.id) % 3 == 0 ? 0 : QuizStubData.hash(plan.id) % 20 }

    func recommended() -> (plan: QuizPlan, reason: String)? {
        guard let chapter = book.chapters.first else { return nil }
        return (Store.speedRound(for: chapter), "\(chapter.entries.first?.head ?? "") missed ×2")
    }

    static func speedRound(for chapter: Chapter) -> QuizPlan {
        QuizPlan(id: chapter.id, name: chapter.name, chapters: [chapter.id], formats: chapter.formats)
    }
}

struct QuizScreen: View {
    @Environment(\.dismiss) private var dismiss
    let plan: QuizPlan
    init(store: Store, plan: QuizPlan) { self.plan = plan }
    var body: some View {
        VStack(spacing: Theme.M.gap) {
            Text(plan.name).font(Theme.F.title)
            TinyButton(title: "Close") { dismiss() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.C.surface)
    }
}

struct QuizRound {}

@MainActor
private enum QuizStubData {
    static var cache: [Language: Book] = [:]

    static func hash(_ s: String) -> Int {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Int(h % 10007)
    }

    static func book(for language: Language) -> Book {
        if let b = cache[language] { return b }
        let b = bundled(language) ?? sample(language)
        cache[language] = b
        return b
    }

    static func bundled(_ language: Language) -> Book? {
        guard let url = Bundle.main.url(forResource: "book-\(language.rawValue)", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Book.self, from: data)
    }

    typealias E = Chapter.Entry

    static func sample(_ language: Language) -> Book {
        func ch(_ id: String, _ name: String, _ sub: String, _ layout: Chapter.Layout,
                _ entries: [E]) -> Chapter {
            Chapter(id: id, name: name, sub: sub, layout: layout, entries: entries, formats: [.pickOne])
        }
        switch language {
        case .mandarin:
            let m = { (h: String, r: String, g: String, grp: String) in
                E(id: "zh.measure.\(h)", head: h, reading: r, gloss: g, group: grp,
                  example: "三\(h)", point: "measure-words") }
            let chapters = [
                ch("zh.measure", "Measure words", "张 · 条 · 台", .cards, [
                    m("张", "zhāng", "paper, tables", "FLAT"), m("片", "piàn", "slices, leaves", "FLAT"),
                    m("面", "miàn", "mirrors, flags", "FLAT"), m("条", "tiáo", "roads, fish", "LONG"),
                    m("根", "gēn", "sticks, bananas", "LONG"), m("支", "zhī", "pens, songs", "LONG"),
                    m("辆", "liàng", "cars, bikes", "MACHINES"), m("台", "tái", "computers, TVs", "MACHINES"),
                    m("架", "jià", "planes", "MACHINES"),
                ]),
                ch("zh.structures", "Structures", "等…再… · 一…就…", .formulas, [
                    E(id: "zh.structures.deng-zai", head: "等…再…", gloss: "wait until, then",
                      example: "等你下班再吃饭", point: "deng-zai"),
                    E(id: "zh.structures.yi-jiu", head: "一…就…", gloss: "as soon as",
                      example: "我一到家就睡觉", point: "yi-jiu"),
                    E(id: "zh.structures.lian-dou", head: "连…都…", gloss: "even",
                      example: "他连水都没喝", point: "lian-dou"),
                    E(id: "zh.structures.suiran", head: "虽然…但是…", gloss: "although",
                      example: "虽然很累但是很开心", point: "suiran-danshi"),
                    E(id: "zh.structures.shi-de", head: "是…的", gloss: "past detail",
                      example: "我是昨天来的", point: "shi-de"),
                ]),
                ch("zh.aspect", "Aspect", "了 · 过 · 着", .list, [
                    E(id: "zh.aspect.le", head: "了", reading: "le", gloss: "completed",
                      example: "我吃了饭", point: "le-completion"),
                    E(id: "zh.aspect.guo", head: "过", reading: "guo", gloss: "ever done",
                      example: "我去过北京", point: "guo-experience"),
                    E(id: "zh.aspect.zhe", head: "着", reading: "zhe", gloss: "ongoing state",
                      example: "门开着", point: "zhe-durative"),
                ]),
                ch("zh.tones", "Tone sandhi", "你好 · 不是", .list, [
                    E(id: "zh.tones.nihao", head: "你好", reading: "ní hǎo"),
                    E(id: "zh.tones.bushi", head: "不是", reading: "bú shì"),
                ]),
            ]
            return Book(language: .mandarin, chapters: chapters, drills: [
                QuizPlan(id: "zh.speed", name: "SPEED"),
                QuizPlan(id: "zh.measure", name: "MEASURE", chapters: ["zh.measure"]),
                QuizPlan(id: "zh.build", name: "BUILD", formats: [.build]),
                QuizPlan(id: "zh.tones", name: "TONES", formats: [.toneTap]),
            ])
        case .german:
            let v = { (verb: String, prep: String, c: String) in
                E(id: "de.verbprep.\(verb)-\(prep)", head: verb, gloss: "\(verb) \(prep) + \(c)",
                  group: prep, tag: c, example: nil, point: "verb-preposition") }
            let t = { (s: String, prep: String, c: String) in
                E(id: "de.twoway.\(s)", head: s, group: prep, tag: c, point: "two-way-prep") }
            return Book(language: .german, chapters: [
                ch("de.verbprep", "Verb + Präposition", "warten auf + AKK", .pairs, [
                    v("warten", "auf", "AKK"), v("sich freuen", "auf", "AKK"), v("achten", "auf", "AKK"),
                    v("denken", "an", "AKK"), v("teilnehmen", "an", "DAT"),
                    v("anfangen", "mit", "DAT"), v("telefonieren", "mit", "DAT"),
                    v("sich interessieren", "für", "AKK"),
                ]),
                ch("de.twoway", "Wechselpräpositionen", "im · ins · auf dem", .split, [
                    t("im Büro", "in", "DAT"), t("ins Büro", "in", "AKK"),
                    t("auf dem Tisch", "auf", "DAT"), t("auf den Tisch", "auf", "AKK"),
                    t("an der Wand", "an", "DAT"), t("an die Wand", "an", "AKK"),
                    t("unter dem Bett", "unter", "DAT"), t("unters Bett", "unter", "AKK"),
                ]),
            ], drills: [
                QuizPlan(id: "de.speed", name: "SPEED"),
                QuizPlan(id: "de.case", name: "CASE", chapters: ["de.verbprep", "de.twoway"]),
            ])
        case .french:
            let a = { (verb: String, aux: String, s: String) in
                E(id: "fr.aux.\(verb)-\(aux)", head: s, reading: verb, group: verb, tag: aux,
                  point: "passe-compose-aux") }
            return Book(language: .french, chapters: [
                ch("fr.aux", "Être or avoir", "suis allé · ai sorti", .split, [
                    a("sortir", "ÊTRE", "Je suis sorti."), a("sortir", "AVOIR", "J'ai sorti la poubelle."),
                    a("monter", "ÊTRE", "Elle est montée."), a("monter", "AVOIR", "Elle a monté les valises."),
                    a("passer", "ÊTRE", "Je suis passé."), a("passer", "AVOIR", "J'ai passé un examen."),
                ]),
                ch("fr.recent", "Passé récent", "venir de", .formulas, [
                    E(id: "fr.recent.venir-de", head: "venir de …", gloss: "just did",
                      example: "Je viens de manger", point: "passe-recent"),
                    E(id: "fr.recent.en-train", head: "être en train de …", gloss: "in the middle of",
                      example: "Je suis en train de lire", point: "etre-en-train-de"),
                ]),
            ], drills: [QuizPlan(id: "fr.speed", name: "SPEED")])
        }
    }
}
