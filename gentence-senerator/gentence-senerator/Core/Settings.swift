import Foundation
import os

struct Settings: Codable, Hashable {
    var language: Language = .mandarin
    /// The languages offered: the pickers, and the ALL LANGUAGES deck. Always
    /// holds `language`. Spanish and Korean start off: their content has had
    /// no native read.
    var languages: [Language] = [.mandarin, .german, .french]
    var mode: Mode = .translate
    /// 1-6 for CEFR, 1-9 for HSK. `LanguagePack.level` renders it.
    var level: Int = 2
    /// When it last moved. Scores from a level the learner has left say nothing
    /// about the one they are on, so `Store.levelOffer` counts from here.
    var levelChangedAt: Date?
    /// Per mode, per day, and a hard cap: three translate, three listen,
    /// three produce is the whole day.
    var dailyGoal: Int = 3
    var prefersTyping: Bool = false
    var showPhonetics: Bool = true
    /// How long a produce exchange runs before anything is corrected.
    var turnsBeforeReview: Int = 3
    /// Offer a never-attempted structure at the start of a produce session.
    var offerStretch: Bool = true
}

/// Token spend, kept per day so a runaway session is visible.
struct Spend: Codable, Hashable {
    var days: [String: Day] = [:]

    struct Day: Codable, Hashable {
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
        /// The same four, sent through the Batch API at half price.
        var batchInput = 0, batchOutput = 0, batchCacheRead = 0, batchCacheWrite = 0
        /// Sonnet 5.5 calls — quiz top-ups and reviews — already in dollars.
        /// The name predates the reviews; kept so stored days still decode.
        var topUps = 0.0

        /// Opus 5: $5/MTok in, $25/MTok out. Cache reads are a tenth of input,
        /// writes a quarter more, so both fall out of the input price.
        var dollars: Double {
            Self.price(input, output, cacheRead, cacheWrite)
                + Self.price(batchInput, batchOutput, batchCacheRead, batchCacheWrite) / 2
                + topUps
        }

        private static func price(_ i: Int, _ o: Int, _ r: Int, _ w: Int) -> Double {
            (Double(i) * 5 + Double(o) * 25 + Double(r) * 0.5 + Double(w) * 6.25) / 1_000_000
        }
    }

    mutating func add(_ usage: Anthropic.Usage, batched: Bool = false, on day: Date = .now) {
        let key = Spend.key(day)
        var d = days[key] ?? Day()
        if batched {
            d.batchInput += usage.inputTokens
            d.batchOutput += usage.outputTokens
            d.batchCacheRead += usage.cacheReadTokens
            d.batchCacheWrite += usage.cacheWriteTokens
        } else {
            d.input += usage.inputTokens
            d.output += usage.outputTokens
            d.cacheRead += usage.cacheReadTokens
            d.cacheWrite += usage.cacheWriteTokens
        }
        days[key] = d
    }

    /// Sonnet 5.5: $2/MTok in, $10/MTok out; cache reads a tenth of input,
    /// writes a quarter more. Batched, half.
    mutating func addSonnet(_ usage: Anthropic.Usage, batched: Bool = false, on day: Date = .now) {
        let key = Spend.key(day)
        var d = days[key] ?? Day()
        d.topUps += (Double(usage.inputTokens) * 2 + Double(usage.outputTokens) * 10
                     + Double(usage.cacheReadTokens) * 0.2 + Double(usage.cacheWriteTokens) * 2.5)
            / 1_000_000 / (batched ? 2 : 1)
        days[key] = d
    }

    func today(_ day: Date = .now) -> Day { days[Spend.key(day)] ?? Day() }

    static func key(_ date: Date) -> String { dayFormat.string(from: date) }

    /// The day a key names, at local midnight.
    static func date(_ key: String) -> Date? { dayFormat.date(from: key) }

    /// Gregorian and POSIX whatever the device is set to: keys are compared as
    /// strings, so a Buddhist-calendar year would sort every hold as future.
    /// One instance — this runs in loops.
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Tolerant of every key, for the same reason as `Spend.Day`: the synthesised
/// decoder demands each one, and a missing key would reset every setting.
extension Settings {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        language = try c.decodeIfPresent(Language.self, forKey: .language) ?? d.language
        languages = try c.decodeIfPresent([Language].self, forKey: .languages) ?? d.languages
        if !languages.contains(language) { languages.append(language) }
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? d.mode
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? d.level
        levelChangedAt = try c.decodeIfPresent(Date.self, forKey: .levelChangedAt)
        dailyGoal = try c.decodeIfPresent(Int.self, forKey: .dailyGoal) ?? d.dailyGoal
        prefersTyping = try c.decodeIfPresent(Bool.self, forKey: .prefersTyping) ?? d.prefersTyping
        showPhonetics = try c.decodeIfPresent(Bool.self, forKey: .showPhonetics) ?? d.showPhonetics
        turnsBeforeReview = try c.decodeIfPresent(Int.self, forKey: .turnsBeforeReview)
            ?? d.turnsBeforeReview
        offerStretch = try c.decodeIfPresent(Bool.self, forKey: .offerStretch) ?? d.offerStretch
    }
}

/// A default value is not a fallback: the synthesised decoder demands every
/// key, so adding a counter here would make every day's stored total fail to
/// decode and `Vault.load` would swallow it behind `try?`. Tolerant of all
/// four, so the next field added costs nothing. In an extension, so the
/// memberwise initialiser survives.
extension Spend.Day {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        batchInput = try c.decodeIfPresent(Int.self, forKey: .batchInput) ?? 0
        batchOutput = try c.decodeIfPresent(Int.self, forKey: .batchOutput) ?? 0
        batchCacheRead = try c.decodeIfPresent(Int.self, forKey: .batchCacheRead) ?? 0
        batchCacheWrite = try c.decodeIfPresent(Int.self, forKey: .batchCacheWrite) ?? 0
        topUps = try c.decodeIfPresent(Double.self, forKey: .topUps) ?? 0
    }
}

/// Typed JSON in UserDefaults. Small enough to stay there; if sessions ever
/// outgrow it, only this file changes.
///
/// A blob that fails to decode is copied aside before anything can save over
/// it, and lists decode element by element, so one bad session costs that
/// session rather than the archive.
enum Vault {
    private static let log = Logger(subsystem: "gentence-senerator", category: "vault")

    static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log.error("\(key, privacy: .public) failed to decode: \(error, privacy: .public)")
            keepAside(data, key)
            return nil
        }
    }

    /// Drops what fails instead of failing whole.
    static func loadList<E: Decodable>(_ type: E.Type, _ key: String) -> [E]? {
        guard let lossy = load([Lossy<E>].self, key) else { return nil }
        let kept = lossy.compactMap(\.value)
        if kept.count < lossy.count, let data = UserDefaults.standard.data(forKey: key) {
            log.error("\(key, privacy: .public): dropped \(lossy.count - kept.count) of \(lossy.count)")
            keepAside(data, key)
        }
        return kept
    }

    static func loadMap<E: Decodable>(_ type: E.Type, _ key: String) -> [String: E]? {
        guard let lossy = load([String: Lossy<E>].self, key) else { return nil }
        let kept = lossy.compactMapValues(\.value)
        if kept.count < lossy.count, let data = UserDefaults.standard.data(forKey: key) {
            log.error("\(key, privacy: .public): dropped \(lossy.count - kept.count) of \(lossy.count)")
            keepAside(data, key)
        }
        return kept
    }

    /// One copy a day per key: a blob that keeps failing is the same blob.
    private static func keepAside(_ data: Data, _ key: String) {
        let aside = "\(key).corrupt.\(Spend.key(.now))"
        guard UserDefaults.standard.data(forKey: aside) == nil else { return }
        UserDefaults.standard.set(data, forKey: aside)
    }

    static func save<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static let settings = "settings.v3"
    /// Superseded by `settings`. `dailyGoal` used to be a whole sitting, and
    /// defaulted to 10; it is now a per-mode cap, so a stored value from before
    /// the change means something else. Read once, to migrate, then cleared.
    static let oldSettings = "settings.v2"
    static let progress = "progress.v2"
    static let spend = "spend.v2"
    static let sessions = "sessions.v2"
    /// Sessions left unfinished, keyed by language and mode, with the turn
    /// that was on screen for each.
    static let holds = "holds.v1"
    /// Superseded by `holds`. Read once, to migrate, then cleared.
    static let inProgress = "inProgress.v2"
    /// What the learner kept out of a day's summary.
    static let bank = "bank.v1"
    static let suggestions = "textbook.suggestions.v1" // what ask answers pointed at
    /// The dialogue in progress, per language. Kept off `holds` on purpose:
    /// holds are retired at the end of the day and a passage is not.
    static let passages = "passages.v3"
    /// Sessions sent for grading, until their results are read in.
    static let grading = "grading.v1"
    /// Seconds each recent batch took to come back.
    static let gradingTimes = "grading.times.v1"
    /// The day each grading job came back, so its feedback leaves the main
    /// screen the day after.
    static let landed = "landed.v1"
    /// Lessons written with a review, by `LessonRequest.cacheKey`.
    static let lessons = "lessons.v1"
    /// This device's APNs token, as hex.
    static let pushToken = "push.token"
    static let quizLog = "quiz.log.v1" // per-entry results, per-plan rounds
    static let endlessMixes = "quiz.endless.v1" // last endless mix, per language
    static let topUps = "quiz.topups.v1" // items the model wrote, per language
    static let askedItems = "quiz.asked.v1" // item ids answered at least once, per language
    static let conceptEdits = "words.edits.v1" // the learner's own word for a meaning, by concept and language
    static let activity = "activity.v1" // what was done each day, for History
    static let scores = "scores.v1" // every graded answer's score, for History averages
}

/// One element of a stored collection, or nothing if it no longer decodes.
struct Lossy<E: Decodable>: Decodable {
    let value: E?

    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(E.self)
    }
}
