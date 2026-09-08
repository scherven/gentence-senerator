import Foundation

/// Dialogues for listen mode. Empty until some are built, and the store falls
/// back to single clips when it is — so this shipping empty costs nothing.
struct PassageLibrary {

    private let passages: [Passage]

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "dialogues", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Passage].self, from: data)
        else { self.passages = []; return }
        self.passages = decoded
    }

    var isEmpty: Bool { passages.isEmpty }

    func passage(_ id: String) -> Passage? { passages.first { $0.id == id } }

    /// One at or below the learner's level that they have not finished. There
    /// is no level gate beyond that: a language with no passages at this level
    /// simply returns nil, and listen stays on single clips.
    func pick(language: Language, level: Int, excluding done: Set<String>) -> Passage? {
        passages
            .filter { $0.language == language && $0.level <= level && !done.contains($0.id) }
            .max { $0.level < $1.level }
    }
}
