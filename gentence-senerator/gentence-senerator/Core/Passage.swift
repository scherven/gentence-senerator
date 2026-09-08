import Foundation

/// A dialogue heard once, then answered on. One passage is the whole listening
/// day, so it is the only thing in the app that outlives the day it started —
/// an unfinished one is picked up tomorrow rather than archived.
///
/// Written by tools/build_dialogue.py. Nothing here is generated at runtime:
/// the questions, the gaps and their options are fixed properties of the
/// passage, so answering costs no model call.
struct Passage: Codable, Hashable, Identifiable {
    let id: String
    let language: Language
    let level: Int
    let title: String
    /// Null until a recording is attached. Lines fall back to synthesis.
    let audio: String?
    let seconds: Double?
    let speakers: [String]
    let lines: [Line]
    let quiz: [Question]

    struct Line: Codable, Hashable, Identifiable {
        /// 1-based, and the handle everything else uses.
        let n: Int
        let speaker: String
        let text: String
        let english: String
        let startSeconds: Double?
        let endSeconds: Double?
        /// Present only on lines a question depends on.
        let gap: Gap?

        var id: Int { n }
    }

    /// One word taken out of a line. The learner picks it back by ear, so the
    /// options are what decides what is being tested — same sound different
    /// tone is a hearing test, same sound same tone is a character test.
    struct Gap: Codable, Hashable {
        let answer: String
        let options: [String]
        /// Shown after they answer.
        let why: String

        var answerIndex: Int { options.firstIndex(of: answer) ?? 0 }
    }

    struct Question: Codable, Hashable, Identifiable {
        let id: String
        let question: String
        let english: String
        let options: [String]
        let answer: Int
        /// The line carrying the answer.
        let line: Int
        /// Per option, the line it is true of. Every wrong option is true of
        /// some other line, so picking one says where the fact was misplaced.
        let optionLines: [Int]
    }

    func line(_ n: Int) -> Line? { lines.first { $0.n == n } }

    /// The clip's length, or an estimate from the text when there is no
    /// recording yet. Only ever shown, never used for playback.
    var length: Double {
        seconds ?? Double(lines.reduce(0) { $0 + $1.text.count }) * 0.28
    }

    var url: URL? {
        guard let audio else { return nil }
        return audio.hasPrefix("http")
            ? URL(string: audio)
            : Bundle.main.url(forResource: audio, withExtension: nil)
    }

    /// Playback for one line, when the recording has been cut to line timings.
    func source(for line: Line) -> AudioSource? {
        guard let url, let start = line.startSeconds, let end = line.endSeconds else { return nil }
        return AudioSource(kind: .recording, url: url, attribution: nil, licence: "CC0",
                           startSeconds: start, endSeconds: end)
    }

    var wholeSource: AudioSource? {
        guard let url else { return nil }
        return AudioSource(kind: .recording, url: url, attribution: nil, licence: "CC0",
                           startSeconds: nil, endSeconds: seconds)
    }
}

// MARK: - Where the learner is in one

/// Survives the day. `retireStaleHolds` archives yesterday's sessions because
/// the day is capped; a passage is the exception the learner was promised, so
/// it is persisted on its own key and carries the day it began.
struct PassageRun: Codable, Hashable {

    /// The quiz runs before the repair: one uninterrupted listen is the only
    /// honest measure of comprehension, and repairing first would test the
    /// repair.
    enum Stage: String, Codable, Hashable {
        case gist, quiz, repairing, reask, done
    }

    let passageID: String
    let language: Language
    /// The day it began, for the history entry. Not a deadline.
    let startedOn: String

    var stage: Stage = .gist
    var played = false
    var replays = 0

    var quizAt = 0
    /// Question id to the option picked, first time round.
    var answers: [String: Int] = [:]

    /// Lines to repair — only those whose question was missed.
    var repair: [Int] = []
    var repairAt = 0
    /// Line number to the option picked.
    var gaps: [Int: Int] = [:]

    var reask: [String] = []
    var reaskAt = 0
    var reanswers: [String: Int] = [:]

    /// One replay. Counted because how many times it took is the measure.
    static let replayLimit = 1
    var canReplay: Bool { played && replays < PassageRun.replayLimit }

    func got(_ question: Passage.Question) -> Bool { answers[question.id] == question.answer }

    func got(_ line: Passage.Line) -> Bool {
        guard let gap = line.gap, let picked = gaps[line.n] else { return false }
        return picked == gap.answerIndex
    }

    /// What the learner is told at the end. `first` is the honest score: the
    /// quiz on one listen, before any repair.
    func read(of passage: Passage) -> (first: Int, asked: Int, gapsRight: Int, gaps: Int) {
        let first = passage.quiz.filter(got).count
        let lines = repair.compactMap(passage.line)
        return (first, passage.quiz.count, lines.filter(got).count, lines.count)
    }

    /// Four outcomes, and the two mixed ones are different learners. Heard
    /// every word and still lost the thread is a discourse problem; got the
    /// gist without the words is context carrying a learner who cannot yet
    /// hear them.
    enum Outcome: String {
        case clean, sound, context, thread

        var read: String {
            switch self {
            case .clean:   return "Done. Raise the level."
            case .sound:   return "The words never arrived."
            case .context: return "You got there from context, not from the words."
            case .thread:  return "You heard every word and lost the thread."
            }
        }
    }

    func outcome(of passage: Passage) -> Outcome {
        let r = read(of: passage)
        let quizPassed = r.asked > 0 && r.first * 5 >= r.asked * 4   // four fifths
        let gapsPassed = r.gaps == 0 || r.gapsRight == r.gaps
        switch (quizPassed, gapsPassed) {
        case (true, true):   return .clean
        case (false, false): return .sound
        case (true, false):  return .context
        case (false, true):  return .thread
        }
    }
}
