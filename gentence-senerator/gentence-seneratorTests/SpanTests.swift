import Testing
import Foundation
@testable import gentence_senerator

/// Finding a finding in the sentence, for the underline and the number.
struct SpanTests {

    static func atom(_ verdict: Atom.Verdict = .breaks, locate: String = "Somewhere.",
                     name: String = "", fix: String = "", note: String = "") -> Atom {
        Atom(id: "x", kind: .wordOrder, verdict: verdict,
             stages: .init(locate: locate, name: name, fix: fix, note: note),
             seed: .init(subject: "x", context: "", pointID: nil))
    }

    static func slice(_ s: String, _ r: Range<Int>) -> String {
        String(Array(s)[r])
    }

    @Test func quotedFragmentIsMatchedExactly() throws {
        let said = "Gestern ich habe meinem Bruder das Buch gegeben."
        let a = Self.atom(name: "After „Gestern“ the verb must come next: “ich habe”.",
                          fix: "habe ich")
        let span = try #require(Store.span(of: a, in: said))
        #expect(Self.slice(said, span.range) == "ich habe")
        #expect(span.right == "habe ich")
    }

    @Test func wholeSentenceFixGivesTheChangedWords() throws {
        let said = "Gestern ich habe meinem Bruder das Buch gegeben."
        let a = Self.atom(fix: "Gestern habe ich meinem Bruder das Buch gegeben.")
        let span = try #require(Store.span(of: a, in: said))
        #expect(span.wrong == "ich habe")
        #expect(span.right == "habe ich")
    }

    @Test func fragmentFixFindsItsWindow() throws {
        let said = "Gestern ich habe meinem Bruder das Buch gegeben."
        let reorder = try #require(Store.span(of: Self.atom(fix: "habe ich"), in: said))
        #expect(reorder.wrong == "ich habe")
        let swap = try #require(Store.span(of: Self.atom(.weakens, fix: "das Buch geschenkt"), in: said))
        #expect(swap.wrong == "das Buch gegeben")
        #expect(swap.right == "das Buch geschenkt")
    }

    @Test func mandarinWholeSentence() throws {
        let said = "我们办公室新买了三个电脑。"
        let a = Self.atom(fix: "我们办公室新买了三台电脑。")
        let span = try #require(Store.span(of: a, in: said))
        #expect(span.wrong == "个")
        #expect(span.right == "台")
        #expect(Self.slice(said, span.range) == "个")
    }

    @Test func mandarinQuoted() throws {
        let said = "他是很高。"
        let a = Self.atom(name: "「是很」 does not go before an adjective.", fix: "他很高。")
        let span = try #require(Store.span(of: a, in: said))
        #expect(span.wrong == "是很")
    }

    @Test func mandarinMissingPieceTakesTheCharacterBefore() throws {
        let said = "我昨天去商店。"
        let span = try #require(Store.span(of: Self.atom(fix: "我昨天去了商店。"), in: said))
        #expect(span.wrong == "去")
        #expect(span.right == "去了")
    }

    @Test func missingSpanIsNil() {
        let said = "Ich gehe nach Hause."
        #expect(Store.span(of: Self.atom(locate: "Somewhere in the middle."), in: said) == nil)
        #expect(Store.span(of: Self.atom(fix: "völlig anders formuliert"), in: said) == nil)
        #expect(Store.span(of: Self.atom(name: "“nirgends”"), in: said) == nil)
        #expect(Store.span(of: Self.atom(fix: "x"), in: "") == nil)
    }

    @Test func repeatedSubstringPrefersTheOneTheFixChanged() throws {
        let said = "我的朋友的书的"
        // "的" occurs three times; the fix drops only the last.
        let a = Self.atom(name: "One 「的」 is not needed.", fix: "我的朋友的书")
        let span = try #require(Store.span(of: a, in: said))
        #expect(span.range == 6..<7)
    }

    @Test func repeatedSubstringFallsToTheFirst() throws {
        let said = "der Hund und der Hund"
        let span = try #require(Store.span(of: Self.atom(name: "\"der Hund\""), in: said))
        #expect(span.range == 0..<8)
    }

    @Test func aUniqueQuoteBeatsARepeatedOne() throws {
        let said = "der Hund und der Katze"
        let a = Self.atom(name: "\"der\" before \"der Katze\"")
        let span = try #require(Store.span(of: a, in: said))
        #expect(span.wrong == "der Katze")
    }

    @Test func keptUsesTheWordsThatWereRight() throws {
        let said = "Gestern ich habe meinem Bruder das Buch gegeben."
        let span = try #require(Store.span(of: Self.atom(.kept, fix: "meinem Bruder"), in: said))
        #expect(span.wrong == "meinem Bruder")
        #expect(span.right == nil)
    }

    @Test func apostropheInAWordIsNotAQuote() {
        #expect(Store.quotes(in: "Il n'y a pas d'eau") == [])
        #expect(Store.quotes(in: "the 'y a' part") == ["y a"])
    }
}
