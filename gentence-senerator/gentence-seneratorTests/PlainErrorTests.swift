import Testing
import Foundation
@testable import gentence_senerator

/// No code, worker body or model output reaches the learner.
@MainActor
struct PlainErrorTests {

    @Test func workerStatusesBecomePlainLines() {
        #expect(Plain.message(for: Anthropic.Failure.http(401, "invite")) == Plain.invite)
        #expect(Plain.message(for: Anthropic.Failure.http(429, "slow down")) == Plain.limited)
        #expect(Plain.message(for: Anthropic.Failure.http(529, "overloaded")) == Plain.busy)
        #expect(Plain.message(for: Sender.Failure.rejected(401, "invite")) == Plain.invite)
        #expect(Plain.message(for: Sender.Failure.rejected(403, "model or max_tokens")) == Plain.unknown)
    }

    @Test func networkFailuresSayNoConnection() {
        #expect(Plain.message(for: URLError(.notConnectedToInternet)) == Plain.offline)
        #expect(Plain.message(for: URLError(.networkConnectionLost)) == Plain.offline)
        #expect(Plain.message(for: URLError(.timedOut)) == Plain.timedOut)
        let bridged = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        #expect(Plain.message(for: bridged) == Plain.offline)
    }

    @Test func modelOutputNeverShows() {
        let raw = #"{"score": 80, "findings": [ ... "#
        let line = Plain.message(for: Anthropic.Failure.malformed("no `findings` — \(raw)"))
        #expect(line == Plain.garbled)
        #expect(Plain.message(for: Anthropic.Failure.refused("policy")) == Plain.declined)
    }

    @Test func askNamesTheReasonOnlyWhenThereIsOne() {
        #expect(Store.couldNotAnswer(Plain.offline) == "Couldn't answer that. No connection.")
        #expect(Store.couldNotAnswer(Plain.unknown) == "Couldn't answer that.")
    }
}
