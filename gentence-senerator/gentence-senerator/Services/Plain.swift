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

    static let offline = "No connection."
    static let timedOut = "Timed out."
    static let invite = "Invite code no longer works."
    static let limited = "Too many requests. Try again in a minute."
    static let busy = "Server busy. Try again shortly."
    static let garbled = "Couldn't read the reply."
    static let declined = "Couldn't do that one."
    static let unknown = "Something went wrong."

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
            case .http(let code, _): return status(code)
            case .malformed: return garbled
            case .refused: return declined
            }
        case let error as Sender.Failure:
            switch error {
            case .rejected(let code, _): return status(code)
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

    private static func status(_ code: Int) -> String {
        switch code {
        case 0: return offline
        case 401: return invite
        case 429: return limited
        case 500...599: return busy
        default: return unknown
        }
    }
}
