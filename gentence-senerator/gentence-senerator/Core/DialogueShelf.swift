import Foundation

/// One finished listen of a dialogue, kept so the picker can say when and how
/// it went.
struct Heard: Codable, Hashable {
    let on: Date
    /// Gist questions right on the first, blind pass.
    let right: Int
    let asked: Int
    let before: PassageRun.Followed?
    let after: PassageRun.Followed?
}

/// Every playable dialogue with where the learner stands on it, in the order
/// the picker shows them: what's half done, what's due again, what's new
/// (shortest first), then the rest.
struct ShelfEntry: Identifiable, Hashable {
    let passage: Passage
    let run: PassageRun?
    /// Newest first.
    let heard: [Heard]
    let status: Status

    var id: String { passage.id }
    var last: Heard? { heard.first }

    enum Status: Hashable {
        case inProgress(pass: Int)
        case due(days: Int)
        case new
        case done(days: Int)

        var isHeard: Bool {
            switch self {
            case .due, .done: return true
            case .inProgress, .new: return false
            }
        }

        fileprivate var rank: Int {
            switch self {
            case .inProgress: return 0
            case .due:        return 1
            case .new:        return 2
            case .done:       return 3
            }
        }
    }
}

enum Shelf {

    /// Days until a dialogue is due again, by how many times it has been
    /// heard: once → 1 day, twice → 3, … A listen that ended at little or
    /// some followed starts it over.
    static let intervals = [1, 3, 7, 14, 30]

    static func dueAfter(_ history: [Heard]) -> Int {
        guard let last = history.first else { return 0 }
        if let after = last.after, after.rawValue <= PassageRun.Followed.some.rawValue {
            return intervals[0]
        }
        return intervals[min(history.count, intervals.count) - 1]
    }

    static func entries(_ passages: [Passage], runs: [String: PassageRun],
                        heard: [String: [Heard]], today: Date,
                        calendar: Calendar = .current) -> [ShelfEntry] {
        let entries = passages.map { p -> ShelfEntry in
            let run = runs[p.id].flatMap { $0.stage == .done ? nil : $0 }
            let history = (heard[p.id] ?? []).sorted { $0.on > $1.on }
            let status: ShelfEntry.Status
            if let run {
                status = .inProgress(pass: pass(of: run))
            } else if let last = history.first {
                let days = daysBetween(last.on, today, calendar)
                status = days >= dueAfter(history) ? .due(days: days) : .done(days: days)
            } else {
                status = .new
            }
            return ShelfEntry(passage: p, run: run, heard: history, status: status)
        }
        return entries.sorted { a, b in
            if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
            switch (a.status, b.status) {
            case let (.due(x), .due(y)), let (.done(x), .done(y)):
                if x != y { return x > y }          // longest ago first
            default: break
            }
            let la = a.passage.span.map { $0.upperBound - $0.lowerBound } ?? 0
            let lb = b.passage.span.map { $0.upperBound - $0.lowerBound } ?? 0
            return la != lb ? la < lb : a.passage.lesson < b.passage.lesson
        }
    }

    /// 1, 2 or 3: the pass the learner is on.
    static func pass(of run: PassageRun) -> Int {
        switch run.stage {
        case .first:  return 1
        case .read:   return 2
        case .second, .done: return 3
        }
    }

    static func daysBetween(_ from: Date, _ to: Date, _ calendar: Calendar) -> Int {
        let a = calendar.startOfDay(for: from), b = calendar.startOfDay(for: to)
        return max(0, calendar.dateComponents([.day], from: a, to: b).day ?? 0)
    }
}
