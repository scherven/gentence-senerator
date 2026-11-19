import Foundation

/// The day's reminders: two per language, spread evenly over waking hours —
/// every translate first, then every reply — and Talk near the end once the
/// rest are done. A slot not done rolls into the next one.
enum Pings {

    struct Item: Hashable, Codable {
        let language: Language
        let mode: Mode
        var label: String { "\(language.code) \(mode == .converse ? "talk" : mode.rawValue)" }
    }

    /// One reminder: the notification and the Live Activity it starts.
    struct Fire: Hashable, Codable {
        let at: Date
        /// The next slot, or the end of waking hours. What the countdown runs to.
        let end: Date
        let items: [Item]
        let title: String
        let body: String?
        /// One per base slot: 0 done, 1 owed, 2 later.
        let ticks: [Int]

        var id: String { "ping.\(Int(at.timeIntervalSince1970))" }
    }

    /// Two side by side; past that, the first and a count.
    static func title(_ owed: [Item]) -> String {
        owed.count > 2 ? "\(owed[0].label) +\(owed.count - 1)" : owed.map(\.label).joined(separator: " · ")
    }

    /// The base slots, in order, for `day`.
    static func slots(languages: [Language], from: Int, to: Int,
                      day: Date, calendar: Calendar = .current) -> [(at: Date, item: Item)] {
        let start = calendar.date(bySettingHour: from, minute: 0, second: 0, of: day) ?? day
        let close = calendar.date(bySettingHour: min(to, 23), minute: to >= 24 ? 59 : 0, second: 0, of: day) ?? day
        let items = languages.map { Item(language: $0, mode: .translate) }
            + languages.map { Item(language: $0, mode: .reply) }
        guard !items.isEmpty, close > start else { return [] }
        let step = close.timeIntervalSince(start) / Double(items.count)
        return items.enumerated().map { i, item in
            // Whole minutes, so the cron's two-minute tick lands on them.
            let raw = start.addingTimeInterval(step * Double(i))
            let minute = (raw.timeIntervalSince1970 / 60).rounded(.down) * 60
            return (Date(timeIntervalSince1970: minute), item)
        }
    }

    /// Every reminder from `now` to the end of the day. The first may be the
    /// slot already running, if it still has something owed: `at` is then in
    /// the past, and only the Live Activity uses it.
    static func plan(languages: [Language], from: Int, to: Int, now: Date,
                     done: (Item) -> Bool, body: (Item) -> String?,
                     talk: Language?, calendar: Calendar = .current) -> [Fire] {
        let base = slots(languages: languages, from: from, to: to, day: now, calendar: calendar)
        guard !base.isEmpty else { return [] }
        let close = calendar.date(bySettingHour: min(to, 23), minute: to >= 24 ? 59 : 0, second: 0, of: now) ?? now
        let finished = base.map { done($0.item) }
        var fires: [Fire] = []
        for (k, slot) in base.enumerated() {
            let end = k + 1 < base.count ? base[k + 1].at : close
            guard end > now else { continue }
            let owed = (0...k).filter { !finished[$0] }.map { base[$0].item }
            guard !owed.isEmpty else { continue }
            let ticks = base.indices.map { j in finished[j] ? 0 : j <= k ? 1 : 2 }
            fires.append(Fire(at: slot.at, end: end, items: owed,
                              title: title(owed),
                              body: body(owed[0]), ticks: ticks))
        }
        // Talk: an hour before the end, only once everything else is in.
        if let talk, finished.allSatisfy({ $0 }) {
            let at = close.addingTimeInterval(-3600)
            if close > now {
                fires.append(Fire(at: max(at, base.last!.at), end: close,
                                  items: [Item(language: talk, mode: .converse)],
                                  title: "talk", body: talk.code,
                                  ticks: base.map { _ in 0 }))
            }
        }
        return fires
    }
}
