import Foundation

// MARK: - Grammar Point
// A single, discrete Mandarin grammar structure that a generated sentence can target.
// Points are unlocked cumulatively by difficulty (see MandarinGrammarBank.eligiblePoints),
// so at any given difficulty a learner draws from EVERY point unlocked so far — not just
// the newest one. This is what actually produces structural variety: at difficulty 5 there
// are 15 eligible points to rotate through, not one mandatory structure repeated forever.

struct GrammarPoint: Identifiable {
    let id: String
    let name: String
    let hskLevel: Int
    let unlockDifficulty: Int       // 1-10 — vocab band at which this point enters the eligible pool
    let issueCategory: String       // matches the closed-vocabulary categories evaluateAttempt() grades against
    let instruction: String         // what the generated sentence must require, in prompt-ready prose
    let keywords: [String]          // for matching against user-entered grammarFocusAreas tags
    let examples: [String]          // curated Mandarin sentences demonstrating the pattern — the "data bank"
}

// MARK: - Grammar Point Sampling Context

struct GrammarPointSampleContext {
    var usage: [String: Int] = [:]        // times this point has been targeted before
    var weakness: [String: Int] = [:]     // times a sub-85 attempt's grammarIssues matched this point's category
    var focusAreas: [String] = []         // user-pinned focus tags from Settings
}

// MARK: - Mandarin Grammar Bank

enum MandarinGrammarBank {

    static let byID: [String: GrammarPoint] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func eligiblePoints(upTo difficulty: Int) -> [GrammarPoint] {
        all.filter { $0.unlockDifficulty <= difficulty }
    }

    /// Selects `count` grammar points for a generation call. Prefers points matching the user's
    /// pinned focus areas (if any), then ranks the remaining pool by a priority score that favors
    /// least-recently-used and weakest-performing points, with random tie-breaking so equally-due
    /// points don't always surface in the same order.
    static func selectPoints(
        count: Int,
        difficulty: Int,
        context: GrammarPointSampleContext,
        avoiding avoidIDs: [String] = []
    ) -> [GrammarPoint] {
        let eligible = eligiblePoints(upTo: difficulty)
        guard !eligible.isEmpty else { return [] }

        var pool = eligible.filter { !avoidIDs.contains($0.id) }
        if pool.isEmpty { pool = eligible }

        if !context.focusAreas.isEmpty {
            let matched = pool.filter { point in
                context.focusAreas.contains { area in
                    point.keywords.contains { keyword in area.localizedCaseInsensitiveContains(keyword) }
                }
            }
            if !matched.isEmpty { pool = matched }
        }

        pool.shuffle()
        let ranked = pool.sorted { priority(for: $0, context: context) < priority(for: $1, context: context) }
        guard !ranked.isEmpty else { return [] }

        return (0..<count).map { ranked[$0 % ranked.count] }
    }

    private static func priority(for point: GrammarPoint, context: GrammarPointSampleContext) -> Int {
        let used = context.usage[point.id] ?? 0
        let weak = context.weakness[point.id] ?? 0
        return used - weak * 2
    }

    // MARK: - Catalog (40 points, HSK1 → HSK6, unlock difficulty 1 → 10)

    static let all: [GrammarPoint] = [

        // Unlock 1 — cumulative pool size: 3
        GrammarPoint(
            id: "svo_basic", name: "Basic SVO statement", hskLevel: 1, unlockDifficulty: 1,
            issueCategory: "word_order",
            instruction: "A simple subject-verb-object statement using only the most basic everyday verbs (eat 吃, drink 喝, see/read 看, buy 买, like 喜欢). No negation, no questions, no measure words, no particles.",
            keywords: ["svo", "basic", "statement"],
            examples: ["我喝水。", "他看书。", "我们喜欢猫。"]),
        GrammarPoint(
            id: "bu_negation", name: "不 negation", hskLevel: 1, unlockDifficulty: 1,
            issueCategory: "negation",
            instruction: "Negate a present-tense or habitual action with 不.",
            keywords: ["不", "negation", "negative"],
            examples: ["我不喝咖啡。", "她不去学校。", "我们不看电视。"]),
        GrammarPoint(
            id: "ma_question", name: "吗 yes/no question", hskLevel: 1, unlockDifficulty: 1,
            issueCategory: "question_formation",
            instruction: "Form a yes/no question by adding 吗 to the end of a statement.",
            keywords: ["吗", "question", "yes/no"],
            examples: ["你喜欢中国菜吗？", "他是学生吗？", "你有时间吗？"]),

        // Unlock 2 — cumulative pool size: 6
        GrammarPoint(
            id: "ye_dou", name: "也/都 (also / all)", hskLevel: 1, unlockDifficulty: 2,
            issueCategory: "word_order",
            instruction: "Use 也 (also) or 都 (all/both), correctly placed directly before the verb.",
            keywords: ["也", "都", "also", "all", "both"],
            examples: ["我也喜欢咖啡。", "他们都是老师。", "我们都想去。"]),
        GrammarPoint(
            id: "time_word_order", name: "Time expression + word order", hskLevel: 1, unlockDifficulty: 2,
            issueCategory: "word_order",
            instruction: "Include a time word (今天/昨天/明天/现在) placed correctly — after the subject, before the verb.",
            keywords: ["time", "今天", "昨天", "明天"],
            examples: ["我今天很忙。", "她昨天很累。", "他们明天去北京。"]),
        GrammarPoint(
            id: "mei_you_negation", name: "没(有) negation", hskLevel: 1, unlockDifficulty: 2,
            issueCategory: "negation",
            instruction: "Negate a completed action or possession with 没 or 没有 (not 不).",
            keywords: ["没", "没有", "negation", "negative"],
            examples: ["我没吃早饭。", "他没有钱。", "我昨天没去上班。"]),

        // Unlock 3 — cumulative pool size: 9
        GrammarPoint(
            id: "measure_words", name: "Measure words (量词)", hskLevel: 2, unlockDifficulty: 3,
            issueCategory: "measure_words",
            instruction: "Include a quantity + measure word + noun (一本书/两杯水/三个人) that is central to the sentence's meaning.",
            keywords: ["measure word", "量词", "个", "本", "杯"],
            examples: ["他有两个孩子。", "桌子上有三个苹果。", "她要一杯咖啡。"]),
        GrammarPoint(
            id: "adjective_predicate", name: "Adjectival predicate with 很", hskLevel: 1, unlockDifficulty: 3,
            issueCategory: "word_order",
            instruction: "Use an adjective directly as the predicate with 很 (not 是) — e.g. 她很高, not 她是高.",
            keywords: ["adjective", "很", "predicate"],
            examples: ["今天很热。", "这本书很有意思。", "他很累。"]),
        GrammarPoint(
            id: "modal_verbs", name: "Modal verb + verb (想/要/能/会/可以)", hskLevel: 2, unlockDifficulty: 3,
            issueCategory: "verb_complement",
            instruction: "Use a modal verb (想/要/能/会/可以) paired with a second verb as the structural core of the sentence.",
            keywords: ["modal", "想", "要", "能", "会", "可以"],
            examples: ["我想去中国。", "你会说法语吗？", "他不能来。"]),

        // Unlock 4 — cumulative pool size: 13
        GrammarPoint(
            id: "comparison_bi", name: "比 comparison", hskLevel: 2, unlockDifficulty: 4,
            issueCategory: "comparison",
            instruction: "Compare two things using X 比 Y + adjective.",
            keywords: ["比", "比较", "comparison", "compare"],
            examples: ["今天比昨天冷。", "他比我高。", "这个比那个贵。"]),
        GrammarPoint(
            id: "de_possessive_attributive", name: "的 possessive/attributive", hskLevel: 1, unlockDifficulty: 4,
            issueCategory: "word_order",
            instruction: "Use 的 to mark possession or an attributive modifier placed before a noun.",
            keywords: ["的", "possessive", "attributive"],
            examples: ["这是我的书。", "他是我朋友的老师。", "红色的车很漂亮。"]),
        GrammarPoint(
            id: "cong_dao", name: "从...到... (from...to...)", hskLevel: 2, unlockDifficulty: 4,
            issueCategory: "word_order",
            instruction: "Express a range in time or place using 从...到...",
            keywords: ["从", "到", "range"],
            examples: ["我从九点工作到五点。", "从这里到火车站很远。", "他从北京坐火车到上海。"]),
        GrammarPoint(
            id: "time_ago", name: "X 前/以前 (X time ago)", hskLevel: 2, unlockDifficulty: 4,
            issueCategory: "word_order",
            instruction: "The English sentence must use a \"[time period] ago\" phrase (e.g. \"three years ago\", \"two weeks ago\"). This is a classic cross-linguistic trap: Mandarin places the time quantity BEFORE 前/以前 (三年前), not a word-for-word translation of \"ago\" as a preposition.",
            keywords: ["前", "以前", "ago", "idiom", "idiomatic expression"],
            examples: ["我三年前住在北京。", "他两年前是学生。", "她五分钟前在这里。"]),

        // Unlock 5 — cumulative pool size: 16
        GrammarPoint(
            id: "le_completion", name: "了 completion / change of state", hskLevel: 2, unlockDifficulty: 5,
            issueCategory: "aspect_markers",
            instruction: "Use the particle 了 to mark a completed action or a change of state.",
            keywords: ["了", "aspect", "particle", "completion"],
            examples: ["我已经吃了。", "她走了。", "天冷了。"]),
        GrammarPoint(
            id: "guo_experiential", name: "过 experiential aspect", hskLevel: 3, unlockDifficulty: 5,
            issueCategory: "aspect_markers",
            instruction: "Use the particle 过 to express that an action has ever been experienced (\"have ever done\").",
            keywords: ["过", "aspect", "particle", "experiential"],
            examples: ["我去过中国。", "他吃过北京烤鸭吗？", "我没看过这部电影。"]),
        GrammarPoint(
            id: "serial_verb", name: "连动句 serial verb construction", hskLevel: 3, unlockDifficulty: 5,
            issueCategory: "word_order",
            instruction: "Use a serial verb construction — two verb phrases sharing one subject describing a sequence of actions, often go/come + purpose (e.g. 'She goes to the store to buy milk').",
            keywords: ["serial verb", "连动"],
            examples: ["我去图书馆看书。", "她坐下吃饭。", "他们出去玩儿。"]),

        // Unlock 6 — cumulative pool size: 19
        GrammarPoint(
            id: "zhe_durative", name: "着 durative/progressive", hskLevel: 3, unlockDifficulty: 6,
            issueCategory: "aspect_markers",
            instruction: "Use the particle 着 to express an ongoing state or manner-of-action.",
            keywords: ["着", "aspect", "particle", "durative", "progressive"],
            examples: ["她穿着红色的衣服。", "门开着。", "他坐着看书。"]),
        GrammarPoint(
            id: "kuai_le", name: "快...了 / 要...了 (about to)", hskLevel: 3, unlockDifficulty: 6,
            issueCategory: "aspect_markers",
            instruction: "Use 快...了 or 要...了 to express that an action or state is imminent.",
            keywords: ["快", "要...了", "imminent", "about to"],
            examples: ["电影快开始了。", "我要迟到了。", "他快毕业了。"]),
        GrammarPoint(
            id: "yi_bian", name: "一边...一边... (simultaneous actions)", hskLevel: 3, unlockDifficulty: 6,
            issueCategory: "word_order",
            instruction: "Describe two simultaneous actions using 一边 A 一边 B.",
            keywords: ["一边", "simultaneous"],
            examples: ["他一边吃饭一边看手机。", "我们一边走一边聊天。", "她一边工作一边听音乐。"]),
        GrammarPoint(
            id: "pivotal_sentence", name: "兼语句 pivotal sentence", hskLevel: 3, unlockDifficulty: 6,
            issueCategory: "word_order",
            instruction: "Use a pivotal sentence where the object of the first verb (请/让/叫/使) is also the subject of the second verb — e.g. 'Mom lets me go out,' 'The teacher asks the student to answer.'",
            keywords: ["pivotal", "兼语", "请", "让", "叫"],
            examples: ["妈妈让我去买东西。", "老师请学生回答问题。", "他叫我等他。"]),
        GrammarPoint(
            id: "yuanlai", name: "原来 (it turns out that / originally)", hskLevel: 3, unlockDifficulty: 6,
            issueCategory: "topic_comment",
            instruction: "The English sentence must use \"it turns out that...\" or \"I didn't realize...\" to express a surprising realization about something that was already true. Mandarin expresses this with the single adverb 原来 — no structural resemblance to the English phrase.",
            keywords: ["原来", "turns out", "idiom", "idiomatic expression"],
            examples: ["原来你也喜欢音乐。", "原来他是老师。", "我才知道，原来她已经走了。"]),
        GrammarPoint(
            id: "duration_complement", name: "时量补语 duration complement", hskLevel: 3, unlockDifficulty: 6,
            issueCategory: "resultative_complement",
            instruction: "The English sentence must express a DURATION of time spent doing something (e.g. \"I've studied Chinese for three years\", \"we waited for two hours\"). This is a classic cross-linguistic trap: Mandarin places the duration AFTER the verb, repeating the verb before a direct object if there is one (我学中文学了三年) — not a prepositional \"for X time\" tacked on like English.",
            keywords: ["duration", "了", "idiom", "idiomatic expression"],
            examples: ["我学中文学了三年。", "他在中国住了五年。", "我们等了两个小时。"]),

        // Unlock 7 — cumulative pool size: 28
        GrammarPoint(
            id: "resultative_complement", name: "Resultative verb complement", hskLevel: 3, unlockDifficulty: 7,
            issueCategory: "resultative_complement",
            instruction: "Use a verb + result morpheme (写完/听懂/找到/做好/说清楚) where the complement is essential to the sentence's meaning.",
            keywords: ["resultative", "complement", "完", "懂", "到"],
            examples: ["我写完作业了。", "你听懂了吗？", "我找到钥匙了。"]),
        GrammarPoint(
            id: "potential_complement", name: "Potential complement 得/不", hskLevel: 4, unlockDifficulty: 7,
            issueCategory: "potential_complement",
            instruction: "Use a 得/不 potential complement to express possibility or impossibility (听得懂/听不懂, 吃得下/吃不下).",
            keywords: ["potential", "得", "不", "complement"],
            examples: ["这个字我看不懂。", "这么多菜我吃不完。", "他说的话你听得懂吗？"]),
        GrammarPoint(
            id: "shi_de_emphasis", name: "是...的 emphasis", hskLevel: 3, unlockDifficulty: 7,
            issueCategory: "topic_comment",
            instruction: "Use 是...的 to emphasize the time, place, or manner of an already-known completed event.",
            keywords: ["是...的", "是..的", "emphasis"],
            examples: ["我是昨天到的。", "他是坐飞机来的。", "这是在哪儿买的？"]),
        GrammarPoint(
            id: "topic_comment_point", name: "Topic-comment structure", hskLevel: 4, unlockDifficulty: 7,
            issueCategory: "topic_comment",
            instruction: "Front the topic (place it first) and let the rest of the sentence comment on it, rather than using strict SVO order — e.g. 'That book, I've already read.'",
            keywords: ["topic-comment", "topic comment"],
            examples: ["那本书我已经看过了。", "中国菜我特别喜欢。", "这件事你不用担心。"]),
        GrammarPoint(
            id: "zhiyao_jiu", name: "只要...就... (as long as / provided that)", hskLevel: 4, unlockDifficulty: 7,
            issueCategory: "topic_comment",
            instruction: "The English sentence must use \"as long as\" or \"provided that\" to express a sufficient condition. Mandarin: 只要 A 就 B.",
            keywords: ["只要", "就", "as long as", "idiom", "idiomatic expression"],
            examples: ["只要你努力，就能成功。", "只要下雨，我就不出门。", "只要有时间，我们就去看电影。"]),
        GrammarPoint(
            id: "be_used_to", name: "习惯 (be/get used to)", hskLevel: 4, unlockDifficulty: 7,
            issueCategory: "verb_complement",
            instruction: "The English sentence must use \"be used to doing X\" or \"get used to X\" (accustomedness) — NOT the \"I used to...\" past-habit auxiliary. This is a classic cross-linguistic trap: Mandarin expresses accustomedness with the single verb 习惯 (我习惯早起), with no structural resemblance to English \"used to.\"",
            keywords: ["习惯", "used to", "accustomed", "idiom", "idiomatic expression"],
            examples: ["我习惯早起。", "他还不习惯这里的天气。", "你习惯用筷子吃饭吗？"]),

        // Unlock 8 — cumulative pool size: 32
        GrammarPoint(
            id: "ba_construction", name: "把 disposal construction", hskLevel: 4, unlockDifficulty: 8,
            issueCategory: "ba_sentence",
            instruction: "Use a 把-sentence where the object is specifically moved, changed, placed, or disposed of by the action.",
            keywords: ["把", "ba-sentence", "disposal"],
            examples: ["请把门关上。", "我把作业交给老师了。", "她把房间打扫干净了。"]),
        GrammarPoint(
            id: "bei_passive", name: "被 passive voice", hskLevel: 4, unlockDifficulty: 8,
            issueCategory: "ba_sentence",
            instruction: "Use a passive construction with 被 where the subject is acted upon by a stated or implied agent.",
            keywords: ["被", "passive"],
            examples: ["杯子被他打破了。", "我的手机被偷了。", "这本书被翻译成了英文。"]),
        GrammarPoint(
            id: "suiran_danshi", name: "虽然...但是... (although...but)", hskLevel: 3, unlockDifficulty: 8,
            issueCategory: "topic_comment",
            instruction: "Use a concessive clause with 虽然 A 但是 B, where both clauses are meaningfully connected.",
            keywords: ["虽然", "但是", "although", "concessive"],
            examples: ["虽然很累，但是他还是来了。", "虽然下雨，但是我们还是出去了。", "虽然贵，但是很好吃。"]),
        GrammarPoint(
            id: "no_matter", name: "不管/无论...都... (no matter what/how)", hskLevel: 4, unlockDifficulty: 8,
            issueCategory: "topic_comment",
            instruction: "The English sentence must use \"no matter what/how/who...\" Mandarin requires 不管/无论 + a question-word clause + 都 — e.g. 'No matter what he says, I won't believe it.'",
            keywords: ["不管", "无论", "no matter", "idiom", "idiomatic expression"],
            examples: ["不管你说什么，我都不相信。", "无论多忙，他都会锻炼。", "不管天气怎么样，我们都要去。"]),

        // Unlock 9 — cumulative pool size: 37
        GrammarPoint(
            id: "yueyue", name: "越来越 / 越...越... (increasingly / the more...the more)", hskLevel: 4, unlockDifficulty: 9,
            issueCategory: "comparison",
            instruction: "Use 越来越 (increasingly) or 越 A 越 B (the more...the more) to express an escalating trend.",
            keywords: ["越来越", "越", "increasingly"],
            examples: ["天气越来越冷了。", "他越说越生气。", "中文越学越有意思。"]),
        GrammarPoint(
            id: "budan_erqie", name: "不但...而且... (not only...but also)", hskLevel: 4, unlockDifficulty: 9,
            issueCategory: "topic_comment",
            instruction: "Use an additive/escalating clause with 不但 A 而且 B.",
            keywords: ["不但", "而且", "not only"],
            examples: ["她不但聪明，而且很努力。", "这个城市不但漂亮，而且很安全。", "他不但会说中文，而且会说日语。"]),
        GrammarPoint(
            id: "yi_jiu", name: "一...就... (as soon as)", hskLevel: 4, unlockDifficulty: 9,
            issueCategory: "word_order",
            instruction: "Use 一 A 就 B to express that B happens immediately/sequentially after A.",
            keywords: ["一", "就", "as soon as"],
            examples: ["我一到家就睡觉了。", "他一看见我就笑了。", "一下课，学生们就跑出去了。"]),
        GrammarPoint(
            id: "chuleyiwai", name: "除了...以外 (apart from/besides/except)", hskLevel: 4, unlockDifficulty: 9,
            issueCategory: "topic_comment",
            instruction: "The English sentence should naturally use \"apart from X,\" \"besides X,\" or \"except for X.\" Mandarin: 除了...以外(，还/都) — the clause structure doesn't map onto English prepositional \"apart from\" at all.",
            keywords: ["除了", "以外", "besides", "except", "apart from", "idiom", "idiomatic expression"],
            examples: ["除了英语以外，他还会说法语。", "除了周末，我每天都上班。", "除了他以外，大家都来了。"]),
        GrammarPoint(
            id: "yuqi_buru", name: "与其...不如... (rather than A, better to B)", hskLevel: 5, unlockDifficulty: 9,
            issueCategory: "comparison",
            instruction: "The English sentence should use \"rather than X, Y\" or \"instead of X, it's better to Y\" to compare two options and favor one. Mandarin: 与其 A 不如 B — a fixed comparative frame with no word-for-word English equivalent.",
            keywords: ["与其", "不如", "rather than", "instead of", "idiom", "idiomatic expression"],
            examples: ["与其在家看电视，不如出去运动。", "与其等他来，不如自己去。", "与其抱怨，不如想办法解决。"]),

        // Unlock 10 — cumulative pool size: 40
        GrammarPoint(
            id: "lian_dou", name: "连...都/也... (even)", hskLevel: 5, unlockDifficulty: 10,
            issueCategory: "topic_comment",
            instruction: "Use the emphatic \"even\" construction 连...都/也...",
            keywords: ["连", "都", "也", "even"],
            examples: ["他连一个字都不会写。", "这件事连我妈妈都知道了。", "忙得连饭都没时间吃。"]),
        GrammarPoint(
            id: "relative_clause_embed", name: "Embedded relative/attributive clause", hskLevel: 5, unlockDifficulty: 10,
            issueCategory: "word_order",
            instruction: "Build a complex noun phrase with an embedded clause modifying a noun via 的 — e.g. 'The book I bought yesterday is interesting.'",
            keywords: ["relative clause", "embedded", "的"],
            examples: ["我昨天买的那本书很有意思。", "他推荐的那家餐厅很好吃。", "住在我家隔壁的那个人是医生。"]),
        GrammarPoint(
            id: "chengyu_usage", name: "Chengyu (4-character idiom)", hskLevel: 6, unlockDifficulty: 10,
            issueCategory: "topic_comment",
            instruction: "Use a common 4-character chengyu naturally and correctly in context (e.g. 马马虎虎, 一举两得, 半途而废).",
            keywords: ["chengyu", "idiom", "成语"],
            examples: ["他做事总是马马虎虎。", "这样做真是一举两得。", "他学中文从不半途而废。"]),
    ]
}
