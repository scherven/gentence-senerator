import Foundation

/// ChinesePod dialogues for listen mode, from the gitignored `Dialogues/`
/// folder. Empty in a checkout that hasn't run tools/chinesepod_listen.py, and
/// the store falls back to single clips when it is.
struct PassageLibrary {

    private let passages: [Passage]

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "dialogues", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Passage].self, from: data)
        else { self.passages = []; return }
        self.passages = decoded
    }

    init(_ passages: [Passage]) { self.passages = passages }

    var isEmpty: Bool { passages.isEmpty }

    func passage(_ id: String) -> Passage? { passages.first { $0.id == id } }

    /// The ones that can be listened to: this language, recording bundled.
    func playable(_ language: Language) -> [Passage] {
        passages.filter { $0.language == language && $0.url != nil }
    }
}
