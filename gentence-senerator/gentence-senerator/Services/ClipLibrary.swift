import Foundation

/// Real recordings for listen mode, with synthesis as the fallback.
///
/// Clips come from corpora that ship human transcripts (VoxPopuli and Common
/// Voice are both CC0 and already sentence-level), so no alignment is needed.
/// Mandarin has no clean spontaneous corpus, so it will usually fall through to
/// synthesis — which the learner is told.
struct ClipLibrary {

    struct Clip: Codable, Hashable, Identifiable {
        let id: String
        let language: Language
        /// The human transcript. Ground truth, not ASR output.
        let text: String
        let english: String?
        /// Relative to the bundle, or absolute for a remote clip.
        let file: String
        let seconds: Double
        let level: Int
        let attribution: String?
        let licence: String

        /// CC0 needs no credit; anything else does.
        var needsCredit: Bool { licence.uppercased() != "CC0" }
    }

    private let clips: [Clip]

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "clips", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Clip].self, from: data)
        else { self.clips = []; return }
        self.clips = decoded
    }

    var isEmpty: Bool { clips.isEmpty }

    /// A clip at or just below the learner's level, not used yet this session.
    func pick(language: Language, level: Int, excluding used: Set<String>) -> Clip? {
        clips.filter {
            $0.language == language && $0.level <= level && !used.contains($0.id)
        }.randomElement()
    }

    func source(for clip: Clip) -> AudioSource {
        let url = clip.file.hasPrefix("http")
            ? URL(string: clip.file)
            : Bundle.main.url(forResource: clip.file, withExtension: nil)
        return AudioSource(kind: .recording, url: url,
                           attribution: clip.attribution, licence: clip.licence,
                           startSeconds: nil, endSeconds: clip.seconds)
    }

    /// Every credit-requiring source in the library, for an acknowledgements
    /// screen. Empty when everything is CC0.
    var credits: [String] {
        Array(Set(clips.filter(\.needsCredit).compactMap {
            guard let attribution = $0.attribution else { return nil }
            return "\(attribution) — \($0.licence)"
        })).sorted()
    }
}
