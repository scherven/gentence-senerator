import Foundation
import os

/// `book-<language>.json`, `quiz-<language>.json` and the rest of the quiz
/// data, loaded on first use and cached. Fails soft: a missing or broken file is an empty book or no items,
/// logged. One bad item is dropped, not the file.
@MainActor
final class BookLibrary {

    private let bundle: Bundle
    private var books: [Language: Book] = [:]
    private var banks: [Language: [QuizItem]] = [:]
    nonisolated private static let log = Logger(subsystem: "gentence-senerator", category: "book")

    init(bundle: Bundle = .main) { self.bundle = bundle }

    func book(for language: Language) -> Book {
        if let b = books[language] { return b }
        let b = Self.data("book-\(language.rawValue)", in: bundle)
            .map { Self.decodeBook($0, language: language) } ?? Book(language: language, chapters: [], drills: [])
        books[language] = b
        return b
    }

    private var vocab: [Language: [VocabWord]] = [:]

    /// `vocab-<language>.json`; empty when it isn't shipped.
    func words(for language: Language) -> [VocabWord] {
        if let v = vocab[language] { return v }
        let v = Self.data("vocab-\(language.rawValue)", in: bundle)
            .flatMap { try? JSONDecoder().decode([VocabWord].self, from: $0) } ?? []
        vocab[language] = v
        return v
    }

    func items(for language: Language) -> [QuizItem] {
        if let i = banks[language] { return i }
        // Written tests, then the ones made from the vocab lists.
        let raw = ["quiz", "gen"].flatMap { kind in
            Self.data("\(kind)-\(language.rawValue)", in: bundle).map(Self.decodeItems) ?? []
        }
        let i = Self.usable(raw, in: book(for: language))
        banks[language] = i
        return i
    }

    private var rulesBanks: [Language: [QuizItem]] = [:]

    /// `rules-<language>.json`: the rules quizzes, one per entry.
    func rules(for language: Language) -> [QuizItem] {
        if let i = rulesBanks[language] { return i }
        let raw = Self.data("rules-\(language.rawValue)", in: bundle).map(Self.decodeItems) ?? []
        let i = Self.usable(raw, in: book(for: language))
        rulesBanks[language] = i
        return i
    }

    private var conceptRows: [Concept]?
    private var wordIndex: [Language: [String: VocabWord]] = [:]

    /// `concepts.json`: one meaning in all three languages.
    func concepts() -> [Concept] {
        if let c = conceptRows { return c }
        let c = Self.data("concepts", in: bundle)
            .flatMap { try? JSONDecoder().decode([Concept].self, from: $0) } ?? []
        conceptRows = c
        return c
    }

    /// A vocab word by its form, for the cards that show one.
    func word(_ w: String, in language: Language) -> VocabWord? {
        if let index = wordIndex[language] { return index[w] }
        let index = Dictionary(words(for: language).map { ($0.w, $0) }, uniquingKeysWith: { a, _ in a })
        wordIndex[language] = index
        return index[w]
    }

    // MARK: Pure

    /// Bundle resources are flattened: the Curriculum folder is not part of
    /// the name.
    private static func data(_ name: String, in bundle: Bundle) -> Data? {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            log.info("no \(name, privacy: .public).json")
            return nil
        }
        return try? Data(contentsOf: url)
    }

    nonisolated static func decodeBook(_ data: Data, language: Language) -> Book {
        do { return try JSONDecoder().decode(Book.self, from: data) } catch {
            log.error("book-\(language.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            return Book(language: language, chapters: [], drills: [])
        }
    }

    /// Each element on its own, so one malformed item costs only itself.
    nonisolated static func decodeItems(_ data: Data) -> [QuizItem] {
        do {
            return try JSONDecoder().decode([Lossy].self, from: data).compactMap { lossy in
                switch lossy.value {
                case .success(let item): return item
                case .failure(let error):
                    log.error("quiz item: \(String(describing: error), privacy: .public)")
                    return nil
                }
            }
        } catch {
            log.error("quiz file: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Items whose entry is in the book and which keep their format's rules.
    /// Duplicate ids: the first wins.
    nonisolated static func usable(_ items: [QuizItem], in book: Book) -> [QuizItem] {
        let entries = Set(book.chapters.flatMap { $0.entries.map(\.id) })
        var seen: Set<String> = []
        return items.filter { item in
            guard seen.insert(item.id).inserted else {
                log.error("\(item.id, privacy: .public): duplicate id"); return false
            }
            guard entries.contains(item.entry) else {
                log.error("\(item.id, privacy: .public): unknown entry \(item.entry, privacy: .public)"); return false
            }
            let problems = item.problems
            guard problems.isEmpty else {
                log.error("\(item.id, privacy: .public): \(problems.joined(separator: "; "), privacy: .public)")
                return false
            }
            return true
        }
    }

    private struct Lossy: Decodable {
        let value: Result<QuizItem, Error>
        init(from decoder: any Decoder) throws {
            value = Result { try QuizItem(from: decoder) }
        }
    }
}
