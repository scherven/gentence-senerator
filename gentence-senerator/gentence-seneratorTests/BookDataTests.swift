import Testing
import Foundation
@testable import gentence_senerator

/// The shipped book and quiz files decode whole: nothing the checker accepts
/// is dropped by the app's loader.
@MainActor
struct BookDataTests {

    static let bundle = Bundle(for: Store.self)

    @Test(arguments: [Language.mandarin, .german, .french])
    func shippedBookLoads(_ language: Language) throws {
        let library = BookLibrary(bundle: Self.bundle)
        let book = library.book(for: language)
        #expect(book.chapters.count >= 12)
        #expect(book.drills.count == 4)

        // Every written and generated item survives loading.
        var shipped = 0
        for kind in ["quiz", "gen"] {
            let url = try #require(Self.bundle.url(forResource: "\(kind)-\(language.rawValue)",
                                                   withExtension: "json"))
            let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])
            shipped += raw.count
        }
        #expect(library.items(for: language).count == shipped)
    }
}
