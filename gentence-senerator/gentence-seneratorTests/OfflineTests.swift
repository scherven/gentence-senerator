import Testing
import Foundation
@testable import gentence_senerator

struct OfflineTests {

    @Test func estimateFallsBackWithoutHistory() {
        let e = CostLog().estimate(days: 7, goal: 3)
        #expect(abs(e.now - 7 * 2 * CostLog.setFallback) < 1e-9)
        #expect(abs(e.later - 7 * 2 * 3 * CostLog.answerFallback) < 1e-9)
    }

    @Test func estimateUsesMeasuredAverages() {
        var log = CostLog()
        log.noteSet(0.04)
        log.noteSet(0.06)
        // A produce exchange of four answers: a tenth each.
        log.noteAnswers(0.4, count: 4)
        #expect(abs(log.perSet - 0.05) < 1e-9)
        #expect(abs(log.perAnswer - 0.1) < 1e-9)
        let e = log.estimate(days: 2, goal: 2)
        #expect(abs(e.now - 0.2) < 1e-9)
        #expect(abs(e.later - 0.8) < 1e-9)
    }

    @Test func logKeepsOnlyTheRecent() {
        var log = CostLog()
        for _ in 0..<40 { log.noteSet(1) }
        log.noteAnswers(1, count: 0)
        #expect(log.sets.count == CostLog.kept)
        #expect(log.answers.isEmpty)
    }

    @Test func pricingMatchesSpend() {
        let usage = Anthropic.Usage(inputTokens: 1000, outputTokens: 2000,
                                    cacheReadTokens: 3000, cacheWriteTokens: 400)
        for batched in [false, true] {
            var spend = Spend()
            spend.add(usage, batched: batched)
            #expect(abs(Spend.dollars(usage, batched: batched, model: nil) - spend.today().dollars) < 1e-12)
            var sonnet = Spend()
            sonnet.addSonnet(usage, batched: batched)
            #expect(abs(Spend.dollars(usage, batched: batched, model: Anthropic.reviewModel)
                        - sonnet.today().dollars) < 1e-12)
        }
    }

    @Test func packDayDecodesWithMissingFields() throws {
        let json = #"{"id":"\#(UUID().uuidString)","language":"german","level":3}"#
        let day = try JSONDecoder().decode(PackDay.self, from: Data(json.utf8))
        #expect(day.translate.isEmpty && day.produce.isEmpty && day.words.isEmpty)
    }
}
