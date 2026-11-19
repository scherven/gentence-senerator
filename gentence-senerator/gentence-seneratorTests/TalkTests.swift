import Testing
import Foundation
@testable import gentence_senerator

/// A conversation, turned into what the grader sees.
struct TalkTests {

    static func conversation(_ language: Language, _ lines: [String]) -> Conversation {
        let scene = Conversation.Scene(place: "P", you: "You lost a receipt", want: "Money back",
                                       them: "Would rather give a voucher", role: "R",
                                       formal: true, opening: lines[0])
        var c = Conversation(language: language, level: 3, scene: scene)
        for (index, text) in lines.dropFirst().enumerated() {
            c.lines.append(.init(id: UUID(), speaker: index.isMultiple(of: 2) ? .learner : .partner,
                                 text: text, move: index.isMultiple(of: 2) ? nil : .answer))
        }
        return c
    }

    static let samples: [(Language, [String])] = [
        (.german, ["Guten Tag! Kann ich Ihnen helfen?", "Er leckt.", "Haben Sie den Bon?", "Nein, verloren."]),
        (.french, ["Bonjour, je peux vous aider ?", "Il fuit.", "Vous avez le ticket ?", "Non, perdu."]),
        (.mandarin, ["您好，需要帮忙吗？", "水壶漏水了。", "有小票吗？", "没有，丢了。"])
    ]

    @Test(arguments: [0, 1, 2])
    func eachLearnerLineIsOneTurn(_ sample: Int) {
        let (language, lines) = Self.samples[sample]
        let c = Self.conversation(language, lines)
        let turns = c.turns()
        #expect(turns.count == 2)
        #expect(turns.allSatisfy { $0.mode == .converse && $0.language == language && $0.attempt.wasTyped })
        #expect(turns[0].prompt.target == lines[0])
        #expect(turns[0].attempt.confirmed == lines[1])
        #expect(turns[1].prompt.target == lines[2])
        #expect(turns[1].attempt.confirmed == lines[3])
        // Earlier lines are context; the line answered and the answer are not.
        let context = turns[1].prompt.context ?? ""
        #expect(context.contains("Money back"))
        #expect(context.contains(lines[1]))
        #expect(!context.contains(lines[3]))
        #expect(turns[0].prompt.context?.contains("Earlier") == false)
    }

    @Test func filedAsOneJobOfOneExchangePerLine() {
        let c = Self.conversation(.german, Self.samples[0].1)
        let session = c.session()
        #expect(session.mode == .converse)
        #expect(session.id.hasPrefix(Spend.key(c.startedAt) + "|german|converse|"))
        #expect(session.isComplete)
        let exchanges = GradingJob.exchanges(of: session)
        #expect(exchanges.map(\.turnIDs.count) == [1, 1])
        #expect(Set(exchanges.flatMap(\.turnIDs)) == Set(c.learnerLines.map(\.id)))
    }

    @Test func capAndCounts() {
        var c = Self.conversation(.french, Self.samples[1].1)
        #expect(c.turnsLeft == Conversation.cap - 2)
        c.lines.append(.init(id: UUID(), speaker: .partner, text: "Non.", move: .pushBack))
        c.lines.append(.init(id: UUID(), speaker: .partner, text: "Pardon ?", move: .askAgain))
        #expect(c.pushedBack == 1 && c.askedAgain == 1)
    }

    @Test func gradingRequestCarriesTheConversation() throws {
        let c = Self.conversation(.mandarin, Self.samples[2].1)
        let turn = c.turns()[1]
        let params = Tutor(api: Anthropic()).reviewParams(turn: turn, history: [], level: 3)
        let user = (params["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        #expect(user.contains("Mode: converse"))
        #expect(user.contains("They were answering: 有小票吗？"))
        #expect(user.contains("The learner said: 没有，丢了。"))
        #expect(user.contains("水壶漏水了。"))
    }

    /// Talk turns stored before `context` existed still load, and the field
    /// round-trips.
    @Test func promptContextDecodes() throws {
        let old = #"{"english":"x","revisited":[]}"#
        let prompt = try JSONDecoder().decode(Turn.Prompt.self, from: Data(old.utf8))
        #expect(prompt.context == nil)
        let turn = Self.conversation(.german, Self.samples[0].1).turns()[1]
        let back = try JSONDecoder().decode(Turn.self, from: JSONEncoder().encode(turn))
        #expect(back.prompt.context == turn.prompt.context)
    }

    @Test func partnerReplyDecodes() throws {
        let json = #"{"move":"push back","say":"Ohne Bon geht das nicht.","goal_met":false}"#
        let line = try JSONDecoder().decode(Tutor.PartnerLine.self, from: Data(json.utf8))
        #expect(line.move == .pushBack)
    }
}
