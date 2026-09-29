import Foundation

/// What was done each day, per language, for the History calendar. Kept apart
/// from sessions and quiz scores because both of those are trimmed; this is
/// three flags a day and is not.
struct ActivityLog: Codable, Hashable {
    enum Mark: String, Codable, Hashable, CaseIterable {
        case translate, produce, quiz
    }

    /// "yyyy-MM-dd|<language>" → what was done.
    var days: [String: Set<Mark>] = [:]

    static func key(_ day: Date, _ language: Language) -> String {
        "\(Spend.key(day))|\(language.rawValue)"
    }

    func marks(on day: Date, _ language: Language) -> Set<Mark> {
        days[Self.key(day, language)] ?? []
    }

    /// Returns whether anything changed, so callers only save when it did.
    @discardableResult
    mutating func add(_ mark: Mark, on day: Date, _ language: Language) -> Bool {
        days[Self.key(day, language), default: []].insert(mark).inserted
    }

    /// A translate or produce session counts once its set was finished, even
    /// if a raised goal later reopened it.
    static func mark(for session: Session) -> Mark? {
        guard session.isComplete || (session.filed ?? 0) > 0 else { return nil }
        switch session.mode {
        case .translate: return .translate
        case .produce:   return .produce
        default:         return nil
        }
    }

    /// The day a session belongs to is the one in its id, not when it ended.
    static func day(of session: Session) -> String { String(session.id.prefix(10)) }

    @discardableResult
    mutating func add(_ session: Session) -> Bool {
        guard let mark = Self.mark(for: session) else { return false }
        let key = "\(Self.day(of: session))|\(session.language.rawValue)"
        return days[key, default: []].insert(mark).inserted
    }

    enum Shade { case none, some, all }

    static func shade(_ marks: Set<Mark>) -> Shade {
        marks.isEmpty ? .none : marks.count == Mark.allCases.count ? .all : .some
    }
}
