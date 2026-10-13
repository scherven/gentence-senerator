import Foundation
import os

/// What the learner reads when something fails: a few words, no codes, no
/// machinery. The full error goes to the log.
enum Plain {
    nonisolated private static let log = Logger(subsystem: "gentence-senerator", category: "error")

    /// Logs `error` in full under `context` and returns the line to show.
    static func message(_ error: Error, _ context: String) -> String {
        log.error("\(context, privacy: .public): \(String(describing: error), privacy: .public)")
        return message(for: error)
    }

    /// Logs without returning anything to show: for failures the learner
    /// is told about some other way, or not at all.
    static func note(_ error: Error, _ context: String) {
        log.error("\(context, privacy: .public): \(String(describing: error), privacy: .public)")
    }

    static let offline = "Offline."
    static let timedOut = "Timed out."
    static let invite = "Code expired."
    static let limited = "Too fast. Wait a minute."
    static let capped = "Today's limit reached."
    static let busy = "Busy. Try later."
    static let garbled = "Bad reply."
    static let declined = "Declined."
    static let unknown = "Failed."

    /// The line for `error`, without logging. Pure, for tests.
    static func message(for error: Error) -> String {
        switch error {
        case let error as URLError:
            switch error.code {
            case .timedOut: return timedOut
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .internationalRoamingOff, .callIsActive, .secureConnectionFailed:
                return offline
            default: return unknown
            }
        case let error as Anthropic.Failure:
            switch error {
            case .http(let code, let body): return status(code, body)
            case .malformed: return garbled
            case .refused: return declined
            }
        case let error as Sender.Failure:
            switch error {
            case .rejected(let code, let body): return status(code, body)
            }
        case let error as Voice.Trouble:
            return error.errorDescription ?? unknown
        case is DecodingError:
            return garbled
        default:
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain {
                return message(for: URLError(URLError.Code(rawValue: ns.code)))
            }
            return unknown
        }
    }

    /// The worker says "daily limit" when a code is past its day's spend.
    private static func status(_ code: Int, _ body: String) -> String {
        switch code {
        case 0: return offline
        case 401: return invite
        case 429: return body.contains("daily limit") ? capped : limited
        case 500...599: return busy
        default: return unknown
        }
    }
}
