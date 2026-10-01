import Foundation

/// A ChinesePod dialogue, taken in three passes: once by ear, once reading
/// along, once by ear again. One passage is the whole listening day, so it is
/// the only thing in the app that outlives the day it started — an unfinished
/// one is picked up tomorrow rather than archived.
///
/// Written by tools/chinesepod_listen.py into the gitignored `Dialogues/`
/// folder. Nothing here is generated at runtime, so the whole flow costs no
/// model call and works offline.
struct Passage: Codable, Hashable, Identifiable {
    let id: String
    let lesson: Int
    let language: Language
    let level: Int
    let title: String
    /// Bundle file name. Nil for a dialogue whose recording isn't shipped.
    let audio: String?
    let seconds: Double?
    /// One line of scene-setting, shown before the first listen.
    let setup: String
    let speakers: [Speaker]
    let lines: [Line]
    /// Asked after the first listen, never before it.
    let gist: [Question]
    /// The words worth catching.
    let chunks: [String]

    struct Speaker: Codable, Hashable {
        let id: String
        let name: String
    }

    struct Line: Codable, Hashable, Identifiable {
        /// 1-based, in spoken order.
        let n: Int
        let speaker: String
        let text: String
        let english: String
        let start: Double?
        let end: Double?
        let words: [Word]

        var id: Int { n }
    }

    struct Word: Codable, Hashable {
        let w: String
        /// Nil on punctuation.
        let py: String?
        let g: String?
        let start: Double?
        let end: Double?

        var isPunctuation: Bool { py == nil }
    }

    struct Question: Codable, Hashable {
        let question: String
        let options: [String]
        let answer: Int
        /// The line carrying the answer.
        let line: Int
    }

    func line(_ n: Int) -> Line? { lines.first { $0.n == n } }

    func name(of speaker: String) -> String {
        speakers.first { $0.id == speaker }?.name ?? speaker
    }

    /// Where the speaker sits in `speakers`, for colour.
    func voice(of speaker: String) -> Int {
        speakers.firstIndex { $0.id == speaker } ?? 0
    }

    var url: URL? {
        guard let audio else { return nil }
        let name = (audio as NSString).deletingPathExtension
        let ext = (audio as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    /// Whole dialogue, first speech to last.
    var span: ClosedRange<Double>? {
        guard let first = lines.first?.start, let last = lines.last?.end, last > first
        else { return nil }
        return first...last
    }

    func span(of line: Line) -> ClosedRange<Double>? {
        guard let start = line.start, let end = line.end, end > start else { return nil }
        return start...end
    }

    /// A word on its own, padded a touch so its first consonant isn't clipped.
    func span(of word: Word) -> ClosedRange<Double>? {
        guard let start = word.start, let end = word.end, end > start else { return nil }
        return max(0, start - 0.04)...(end + 0.06)
    }

    /// The line playing at `t`, if any.
    func line(at t: Double) -> Line? {
        lines.first { l in l.start.map { t >= $0 } == true && l.end.map { t < $0 } == true }
    }

    /// The whole thing as one attempt's worth of audio, for the history entry.
    var wholeSource: AudioSource? {
        guard let url, let span else { return nil }
        return AudioSource(kind: .recording, url: url, attribution: "ChinesePod",
                           licence: nil, startSeconds: span.lowerBound,
                           endSeconds: span.upperBound)
    }
}

// MARK: - What is shown

extension Passage {

    /// One question's options in the order they are put on screen.
    ///
    /// Seeded off the passage and the question, so the order survives a view
    /// re-evaluating and a relaunch. Answers are stored as indices into the
    /// passage *as written*; this is the only place display order exists.
    struct Choices: Hashable {
        /// Shown order.
        let options: [String]
        /// Per shown option, its index in the passage as written.
        let order: [Int]
        /// The shown option that is right.
        let answer: Int

        init(options: [String], answer: Int, seed: String) {
            var order = Array(options.indices)
            // Fisher-Yates off a seeded generator rather than `shuffled(using:)`:
            // the stdlib promises nothing about its draw sequence across versions.
            var state = Choices.hash(seed)
            for i in stride(from: order.count - 1, through: 1, by: -1) {
                state = Choices.next(state)
                order.swapAt(i, Int(state % UInt64(i + 1)))
            }
            self.order = order
            self.options = order.map { options[$0] }
            self.answer = order.firstIndex(of: answer) ?? 0
        }

        /// Where a written index is showing.
        func slot(of written: Int) -> Int { order.firstIndex(of: written) ?? 0 }

        /// FNV-1a. `String.hashValue` is seeded per process.
        private static func hash(_ text: String) -> UInt64 {
            var h: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01B3 }
            return h
        }

        /// SplitMix64.
        private static func next(_ state: UInt64) -> UInt64 {
            var z = state &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func choices(for index: Int) -> Choices {
        let q = gist[index]
        return Choices(options: q.options, answer: q.answer, seed: "\(id)|\(index)|\(q.question)")
    }
}

// MARK: - Where the learner is in one

/// Survives the day. A passage is the exception to the daily cap, so it is
/// persisted on its own key and carries the day it began.
struct PassageRun: Codable, Hashable {

    /// Listen, read along, listen again.
    enum Stage: String, Codable, Hashable {
        case first, read, second, done
    }

    /// How much the learner says they followed. Asked after each blind pass;
    /// the difference is what the read-along bought.
    enum Followed: Int, Codable, Hashable, CaseIterable {
        case little, some, most, all

        var word: String {
            switch self {
            case .little: return "Little"
            case .some:   return "Some"
            case .most:   return "Most"
            case .all:    return "All"
            }
        }
    }

    let passageID: String
    let language: Language
    /// The day it began, for the history entry. Not a deadline.
    let startedOn: String

    var stage: Stage = .first
    /// The first listen ran to the end (or was skipped). The questions stay
    /// hidden until then, so they test what was caught, not what was hunted for.
    var heardFirst = false
    /// Full plays of the first blind pass.
    var firstPlays = 0

    /// Question index to the option picked, as written.
    var answers: [Int: Int] = [:]
    var followedFirst: Followed?
    var followedSecond: Followed?

    /// Words tapped while reading along, first tap first.
    var tapped: [String] = []

    func got(_ index: Int, in passage: Passage) -> Bool {
        answers[index] == passage.gist[index].answer
    }

    func right(in passage: Passage) -> Int {
        passage.gist.indices.filter { got($0, in: passage) }.count
    }

    /// Questions answered and the first rating given.
    func canRead(_ passage: Passage) -> Bool {
        heardFirst && answers.count == passage.gist.count && followedFirst != nil
    }

    mutating func tap(_ word: String) {
        if !tapped.contains(word) { tapped.append(word) }
    }
}
