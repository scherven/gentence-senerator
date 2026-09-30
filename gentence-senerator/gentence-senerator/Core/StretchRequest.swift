import Foundation

/// A curriculum point the learner asked for from the book. It is the stretch
/// of the first day drawn after the one it was made on, and is then spent.
struct StretchRequest: Codable, Hashable {
    let pointID: String
    let language: Language
    /// `yyyy-MM-dd`, as `Spend.key` writes it.
    let madeOn: String

    /// The stretch for a draw on `day`: the request's point when it applies,
    /// otherwise `fallback`. `spent` means the request is used up — applied,
    /// or naming a point the pack no longer has.
    static func stretch(on day: String, language: Language, request: StretchRequest?,
                        known: Set<String>,
                        fallback: () -> String?) -> (id: String?, spent: Bool) {
        guard let request, request.language == language, day > request.madeOn else {
            return (fallback(), false)
        }
        guard known.contains(request.pointID) else { return (fallback(), true) }
        return (request.pointID, true)
    }

    /// Tomorrow's draw when it was already made, with the request as its
    /// stretch. Nil when there is nothing drawn for `tomorrow` yet.
    func replacing(_ ahead: DayDraw?, tomorrow: String) -> DayDraw? {
        guard let ahead, ahead.day == tomorrow, ahead.language == language else { return nil }
        return DayDraw(day: ahead.day, language: ahead.language, level: ahead.level,
                       stretchID: pointID, words: ahead.words)
    }
}

extension Vault {
    /// Book requests, keyed by language.
    static let requests = "book.requests.v1"
    /// When a book entry's rule was first saved, by lesson cache key.
    static let bookRules = "book.rules.v1"
}
