import Testing
import Foundation
@testable import gentence_senerator

/// The depth call is scanned as it arrives so a row can stop saying "Working
/// it out…" the moment its own name exists. Its document is a harder shape
/// than the opening's — `natural` before the array, `respeaks` after it, and
/// nested arrays inside those — so this is where that scanning is pinned down.
struct DepthStreamTests {

    static let document = """
    {"natural":"我已经吃过了。",
     "findings":[
      {"id":"0","name":"已经 is in a slot only a particle can hold.",
       "fix":"我已经吃了","note":"已经 goes before the verb, not after it."},
      {"id":"1","name":"The measure word is missing.",
       "fix":"一个朋友","note":"个 is what speech reaches for."}],
     "respeaks":[
      {"instruction":"Say it again about yesterday.",
       "accept":["我昨天吃了","昨天我吃了"],
       "correct":"That is the one.","incorrect":"Not yet."}]}
    """

    /// Two findings, arriving one at a time and each whole. A half-written
    /// object must not be handed out — that is what a torn name on screen
    /// would look like.
    @Test func findingsArriveOneAtATimeAndWhole() throws {
        let bytes = Array(Self.document.utf8)
        let decoder = JSONDecoder()
        var seen: [Int] = []
        var names: [String: String] = [:]

        for end in 1...bytes.count {
            let sofar = String(decoding: bytes[0..<end], as: UTF8.self)
            let elements = PartialJSON.elements(ofArrayAt: "findings", in: sofar)
            seen.append(elements.count)
            for element in elements {
                let filled = try decoder.decode(Tutor.Depth.Filled.self, from: element)
                names[filled.id] = filled.name
            }
        }

        // Never more than the two that are there, and never a torn one: every
        // element that came out decoded, or the loop above would have thrown.
        #expect(seen.max() == 2)
        #expect(names["0"] == "已经 is in a slot only a particle can hold.")
        #expect(names["1"] == "The measure word is missing.")

        // One at a time: the first is readable well before the document ends.
        let firstAt = seen.firstIndex(of: 1) ?? bytes.count
        let secondAt = seen.firstIndex(of: 2) ?? bytes.count
        #expect(firstAt < secondAt)
        #expect(secondAt < bytes.count - 1)
    }

    /// `respeaks` follows the findings and carries arrays of its own. The scan
    /// must close at the findings' `]` and not walk into them.
    @Test func scanStopsAtTheEndOfTheFindings() throws {
        let elements = PartialJSON.elements(ofArrayAt: "findings", in: Self.document)
        #expect(elements.count == 2)
        for element in elements {
            _ = try JSONDecoder().decode(Tutor.Depth.Filled.self, from: element)
        }
    }

    /// The natural version is only handed out once its string has closed.
    @Test func naturalWaitsForItsClosingQuote() {
        let opened = #"{"natural":"我已经吃"#
        #expect(PartialJSON.string(at: "natural", in: opened) == nil)
        #expect(PartialJSON.string(at: "natural", in: Self.document) == "我已经吃过了。")
    }

    /// A whole document still parses strictly — that is what gets kept, the
    /// streamed values being only a preview.
    @Test func theWholeDocumentStillDecodes() throws {
        let depth = try JSONDecoder().decode(Tutor.Depth.self,
                                             from: Data(Self.document.utf8))
        #expect(depth.findings.count == 2)
        #expect(depth.respeaks.count == 1)
        #expect(depth.respeaks[0].accept.count == 2)
        #expect(depth.natural == "我已经吃过了。")
    }
}
