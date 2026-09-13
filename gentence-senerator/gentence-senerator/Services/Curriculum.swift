import Foundation

/// The authored grammar points, one file per language.
///
/// Five hundred of them is past what belongs in Swift literals, and a
/// curriculum kept in two places is two curricula: the files are the only
/// source. A language whose file is missing loses reach and nothing else —
/// scheduling, review and lessons all still work, so this fails soft the way
/// `Lexicon` and `ClipLibrary` do.
struct Curriculum {

    private let byLanguage: [Language: [GrammarPoint]]

    init(bundle: Bundle = .main) {
        var loaded: [Language: [GrammarPoint]] = [:]
        for language in Language.allCases {
            // Bundle resources are flattened, so the Curriculum folder is not
            // part of the name.
            guard let url = bundle.url(forResource: "grammar-\(language.rawValue)",
                                       withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([GrammarPoint].self, from: data)
            else { continue }
            loaded[language] = decoded
        }
        self.byLanguage = loaded
    }

    var isEmpty: Bool { byLanguage.isEmpty }

    func points(for language: Language) -> [GrammarPoint] { byLanguage[language] ?? [] }
}
