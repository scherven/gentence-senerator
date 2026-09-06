import Foundation

struct Settings: Codable, Hashable {
    var language: Language = .mandarin
    var mode: Mode = .translate
    /// 1-6 for CEFR, 1-9 for HSK. `LanguagePack.level` renders it.
    var level: Int = 2
    var dailyGoal: Int = 10
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

        /// Opus 5: $5/MTok in, $25/MTok out, cache reads at a tenth of input.
        var dollars: Double {
            Double(input) / 1_000_000 * 5
            + Double(output) / 1_000_000 * 25
            + Double(cacheRead) / 1_000_000 * 0.5
            + Double(cacheWrite) / 1_000_000 * 6.25
        }
    }

    mutating func add(_ usage: Anthropic.Usage, on day: Date = .now) {
        let key = Spend.key(day)
        var d = days[key] ?? Day()
        d.input += usage.inputTokens
        d.output += usage.outputTokens
        d.cacheRead += usage.cacheReadTokens
        d.cacheWrite += usage.cacheWriteTokens
        days[key] = d
    }

    func today(_ day: Date = .now) -> Day { days[Spend.key(day)] ?? Day() }

    static func key(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

/// Typed JSON in UserDefaults. Small enough to stay there; if sessions ever
/// outgrow it, only this file changes.
enum Vault {
    static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static let settings = "settings.v2"
    static let progress = "progress.v2"
    static let spend = "spend.v2"
    static let sessions = "sessions.v2"
}
