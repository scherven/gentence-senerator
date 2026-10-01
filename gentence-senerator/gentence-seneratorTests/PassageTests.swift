import Testing
import Foundation
@testable import gentence_senerator

/// The dialogue flow grades on the device, so this is where its correctness
/// lives — there is no model call to blame and no server to ask.
struct PassageTests {

    // Transferring Money, cut to what the assertions need.
    static let json = """
    [{"id":"cp-1660","lesson":1660,"language":"mandarin","level":4,"title":"Transferring Money",
      "audio":null,"seconds":43.3,"setup":"A bank counter, then a phone call.",
      "speakers":[{"id":"A","name":"Teller"},{"id":"B","name":"Customer"},{"id":"C","name":"Sister"}],
      "lines":[
       {"n":1,"speaker":"A","text":"我要转账。","english":"I'd like to make a transfer.",
        "start":0.5,"end":2.0,
        "words":[{"w":"我","py":"wǒ","g":"I","start":0.6,"end":0.8},
                 {"w":"要","py":"yào","g":"want to","start":0.8,"end":1.0},
                 {"w":"转账","py":"zhuǎnzhàng","g":"transfer money","start":1.0,"end":1.7},
                 {"w":"。"}]},
       {"n":2,"speaker":"C","text":"谢谢哥哥！","english":"Thanks, Gege!",
        "start":2.0,"end":3.5,
        "words":[{"w":"谢谢","py":"xièxie","g":"thanks"},{"w":"哥哥","py":"gēge","g":"big brother",
                  "start":2.8,"end":3.3},{"w":"！"}]}],
      "gist":[{"question":"Who pays the fee?","options":["The customer","The recipient","The bank"],
               "answer":0,"line":1},
              {"question":"When does it arrive?","options":["Tomorrow","In three days","Right away"],
               "answer":2,"line":2}],
      "chunks":["转账"]}]
    """

    static func passage() throws -> Passage {
        try JSONDecoder().decode([Passage].self, from: Data(json.utf8))[0]
    }

    static func run() -> PassageRun {
        PassageRun(passageID: "cp-1660", language: .mandarin, startedOn: "2026-09-30")
    }

    @Test func decodesWhatTheScriptWrites() throws {
        let passage = try PassageTests.passage()
        #expect(passage.lines.count == 2)
        #expect(passage.name(of: "C") == "Sister")
        #expect(passage.voice(of: "C") == 2)
        #expect(passage.lines[0].words.last?.isPunctuation == true)
        #expect(passage.wholeSource == nil)   // no recording bundled
    }

    @Test func timingsFindTheLineAndTheWord() throws {
        let passage = try PassageTests.passage()
        #expect(passage.span == 0.5...3.5)
        #expect(passage.line(at: 1.2)?.n == 1)
        #expect(passage.line(at: 2.0)?.n == 2)   // a boundary belongs to the next line
        #expect(passage.line(at: 9) == nil)
        let word = passage.lines[0].words[2]
        let span = try #require(passage.span(of: word))
        #expect(span.lowerBound < 1.0 && span.upperBound > 1.7)   // padded
        // Whisper missed 谢谢: it can still be glossed, just not played alone.
        #expect(passage.span(of: passage.lines[1].words[0]) == nil)
    }

    // MARK: The order they are shown in

    @Test func choicesAreStableAndKeepTheAnswer() throws {
        let passage = try PassageTests.passage()
        for i in passage.gist.indices {
            let once = passage.choices(for: i)
            #expect((0..<20).allSatisfy { _ in passage.choices(for: i) == once })
            #expect(once.order[once.answer] == passage.gist[i].answer)
            #expect(once.options[once.answer] == passage.gist[i].options[passage.gist[i].answer])
        }
    }

    // MARK: The three passes

    /// Questions answer and a first rating, after hearing it out: the only way
    /// into reading. Skipping the listen still counts as having heard it.
    @Test func readingNeedsTheFirstListenAnsweredAndRated() throws {
        let passage = try PassageTests.passage()
        var run = PassageTests.run()
        run.answers = [0: 0, 1: 2]
        run.followedFirst = .some
        #expect(!run.canRead(passage))    // not heard yet
        run.heardFirst = true
        #expect(run.canRead(passage))
        run.answers = [0: 0]
        #expect(!run.canRead(passage))    // one question left
    }

    @Test func scoresTheFirstListenOnly() throws {
        let passage = try PassageTests.passage()
        var run = PassageTests.run()
        run.answers = [0: 1, 1: 2]
        #expect(run.right(in: passage) == 1)
        #expect(!run.got(0, in: passage))
        #expect(run.got(1, in: passage))
    }

    @Test func aWordIsTappedOnce() {
        var run = PassageTests.run()
        run.tap("转账")
        run.tap("哥哥")
        run.tap("转账")
        #expect(run.tapped == ["转账", "哥哥"])
    }

    /// Only dialogues whose recording ships are offered.
    @Test func theLibraryOffersOnlyWhatCanBePlayed() throws {
        let library = PassageLibrary([try PassageTests.passage()])
        #expect(library.passage("cp-1660") != nil)
        #expect(library.playable(.mandarin).isEmpty)   // no recording bundled
    }

    /// It outlives the day it began — that is the whole reason it is persisted
    /// away from `holds`.
    @Test func survivesARoundTrip() throws {
        var run = PassageTests.run()
        run.stage = .read
        run.heardFirst = true
        run.answers = [0: 1, 1: 2]
        run.followedFirst = .most
        run.tapped = ["转账"]
        let back = try JSONDecoder().decode(PassageRun.self, from: JSONEncoder().encode(run))
        #expect(back == run)
        #expect(back.answers[1] == 2)
        #expect(back.stage == .read)
    }
}
