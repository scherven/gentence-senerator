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

    enum State: String, Codable, Hashable {
        /// Not yet a batch: waiting to be handed over, or with iOS until there
        /// is signal.
        case unsent
        case grading
        /// Every review that came back is in the archive.
        case done
    }

    /// The turns one review covers, in order. The review lands on the last.
    struct Exchange: Codable, Hashable {
        /// `x0`, `x1` — what the batch hands back to match results to turns.
        var customID: String
        var turnIDs: [UUID]
    }

    var total: Int { exchanges.count }

    /// Consecutive turns sharing an exchange id become one exchange. Turns
    /// from before exchange ids existed are each their own.
    static func exchanges(of session: Session) -> [Exchange] {
        var groups: [[Turn]] = []
        for turn in session.turns where !turn.attempt.confirmed.isEmpty {
            if let id = turn.exchangeID, let last = groups.last?.last, last.exchangeID == id {
                groups[groups.count - 1].append(turn)
            } else {
                groups.append([turn])
            }
        }
        return groups.enumerated().map { index, turns in
            Exchange(customID: "x\(index)", turnIDs: turns.map(\.id))
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
    }
}
