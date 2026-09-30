import Foundation

/// One finished session, sent to be graded. Kept until every review in it has
/// been read into the archive, so a relaunch, a dead network or a batch that
/// takes an hour costs nothing.
struct GradingJob: Codable, Identifiable, Hashable {
    let id: UUID
    let sessionID: String
    let language: Language
    let mode: Mode
    let createdAt: Date
    /// The level the answers were given at.
    var level: Int? = nil
    var exchanges: [Exchange]
    /// Nil until the batch has been accepted.
    var batchID: String?
    /// Whether the push worker knows about the batch.
    var watched = false
    /// Handed to iOS's background uploader and not yet heard back from.
    var uploading = false
    /// Whether the answers the batch failed on have had their one automatic
    /// second attempt.
    var retried = false
    var graded = 0
    var failed = 0
    var state: State = .unsent
    /// The last thing that went wrong, for the screen. Cleared on success.
    var error: String?
    /// When the batch was accepted, and when it ended. The gap between them
    /// is what the next job's return time is estimated from.
    var sentAt: Date?
    var returnedAt: Date?

    enum State: String, Codable, Hashable {
        /// Not yet a batch: waiting to be handed over, or with iOS until there
        /// is signal.
        case unsent
        case grading
        /// Every review that came back is in the archive.
        case done
    }

    /// The turns one review covers, in order. The review lands on the last.
    /// One turn, except in produce jobs filed before each answer was graded
    /// alone.
    struct Exchange: Codable, Hashable {
        /// `x0`, `x1` — what the batch hands back to match results to turns.
        var customID: String
        var turnIDs: [UUID]
    }

    var total: Int { exchanges.count }

    /// Every answer is its own review, produce included — also answers held
    /// from before that, which share an exchange id.
    static func exchanges(of session: Session) -> [Exchange] {
        session.turns.filter { !$0.attempt.confirmed.isEmpty }
            .enumerated().map { index, turn in
                Exchange(customID: "x\(index)", turnIDs: [turn.id])
            }
    }
}

/// The synthesised decoder demands every key, so a field added here would make
/// every stored job fail to load — and `Vault.load` would drop the lot behind
/// `try?`, answers and all. Everything added after the first version is read
/// as optional. In an extension, so the memberwise initialiser survives.
extension GradingJob {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        language = try c.decode(Language.self, forKey: .language)
        mode = try c.decode(Mode.self, forKey: .mode)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        level = try c.decodeIfPresent(Int.self, forKey: .level)
        exchanges = try c.decode([Exchange].self, forKey: .exchanges)
        batchID = try c.decodeIfPresent(String.self, forKey: .batchID)
        watched = try c.decodeIfPresent(Bool.self, forKey: .watched) ?? false
        uploading = try c.decodeIfPresent(Bool.self, forKey: .uploading) ?? false
        retried = try c.decodeIfPresent(Bool.self, forKey: .retried) ?? false
        graded = try c.decodeIfPresent(Int.self, forKey: .graded) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        state = try c.decodeIfPresent(State.self, forKey: .state) ?? .unsent
        error = try c.decodeIfPresent(String.self, forKey: .error)
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt)
        returnedAt = try c.decodeIfPresent(Date.self, forKey: .returnedAt)
    }
}

/// How long grading takes, from the last few batches. A batch comes back all
/// at once, so a count of graded answers says nothing until it is over; the
/// expected return time is what is worth showing.
enum GradingClock {
    /// Before any batch has come back. Batches have taken 2–10 minutes.
    static let fallback: TimeInterval = 10 * 60
    static let keep = 20

    static func expected(_ past: [TimeInterval]) -> TimeInterval {
        let usable = past.filter { $0 > 0 }.sorted()
        guard !usable.isEmpty else { return fallback }
        return usable[usable.count / 2]
    }

    /// Share of the expected wait gone, never quite full until it is back.
    static func progress(sentAt: Date, expected: TimeInterval, now: Date = .now) -> Double {
        min(0.95, max(0, now.timeIntervalSince(sentAt) / max(expected, 1)))
    }

    static func adding(_ duration: TimeInterval, to past: [TimeInterval]) -> [TimeInterval] {
        Array((past + [duration]).suffix(keep))
    }
}
