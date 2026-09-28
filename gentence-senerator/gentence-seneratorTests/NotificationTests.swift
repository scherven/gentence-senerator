import Testing
import Foundation
@testable import gentence_senerator

struct NotificationTests {

    static func job(_ batch: String?, state: GradingJob.State = .done,
                    at seconds: TimeInterval = 0) -> GradingJob {
        var job = GradingJob(id: UUID(), sessionID: UUID().uuidString, language: .german,
                             mode: .translate, createdAt: Date(timeIntervalSince1970: seconds),
                             exchanges: [.init(customID: "x0", turnIDs: [UUID()])])
        job.batchID = batch
        job.state = state
        return job
    }

    static let all: (GradingJob) -> Bool = { _ in true }

    @Test func payloadParses() {
        let id = UUID()
        let tap = Store.Tap(["aps": ["alert": "x"], "job": id.uuidString, "batch": "msgbatch_1"])
        #expect(tap == Store.Tap(job: id, batch: "msgbatch_1"))
        #expect(Store.Tap(["batch": "b"]) == Store.Tap(batch: "b"))
        #expect(Store.Tap(["job": "not-a-uuid"]) == Store.Tap())
    }

    @Test func jobIDWins() {
        let a = Self.job("a"), b = Self.job("b")
        #expect(Store.target(of: .init(job: a.id, batch: "b"), in: [a, b], readable: Self.all) == a)
    }

    /// An old worker's push has only the batch.
    @Test func batchAlone() {
        let a = Self.job("a"), b = Self.job("b")
        #expect(Store.target(of: .init(batch: "a"), in: [a, b], readable: Self.all) == a)
    }

    @Test func namedButNotReadyOpensNothing() {
        let grading = Self.job("g", state: .grading), done = Self.job("d")
        #expect(Store.target(of: .init(job: grading.id), in: [done, grading], readable: Self.all) == nil)
        #expect(Store.target(of: .init(job: done.id), in: [done], readable: { _ in false }) == nil)
        #expect(Store.target(of: .init(job: UUID()), in: [done], readable: Self.all) == nil)
    }

    @Test func namelessOpensNewestGraded() {
        let old = Self.job("o", at: 1), new = Self.job("n", at: 2)
        let out = Self.job("x", state: .grading, at: 3)
        #expect(Store.target(of: .init(), in: [old, new, out], readable: Self.all) == new)
        #expect(Store.target(of: .init(), in: [out], readable: Self.all) == nil)
    }
}
