import Foundation
import os

/// `book-<language>.json` and `quiz-<language>.json`, loaded on first use and
/// cached. Fails soft: a missing or broken file is an empty book or no items,
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

    func items(for language: Language) -> [QuizItem] {
        if let i = banks[language] { return i }
        let raw = Self.data("quiz-\(language.rawValue)", in: bundle).map(Self.decodeItems) ?? []
        let i = Self.usable(raw, in: book(for: language))
        banks[language] = i
        return i
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
