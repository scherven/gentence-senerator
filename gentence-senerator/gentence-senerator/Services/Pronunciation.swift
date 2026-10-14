import Foundation

/// Azure pronunciation assessment, through the worker, which adds the key.
///
/// Feature parity is uneven and the gaps are load-bearing: phoneme *names* come
/// back only for en-US and zh-CN, and prosody only for en-US. German and French
/// return an ordered array of unlabelled scores, so a unit there has an index
/// and no name.
struct Pronunciation {

    /// `reference` is what the learner should have said — the played sentence
    /// in listen mode, their own confirmed words otherwise.
    func assess(wav: URL, reference: String, locale: String) async throws -> PronunciationResult? {
        let config: [String: Any] = [
            "ReferenceText": reference,
            "GradingSystem": "HundredMark",
            "Granularity": "Phoneme",
            "EnableMiscue": true
        ]
        let configData = try JSONSerialization.data(withJSONObject: config)

        var url = URLComponents(url: Worker.url("/azure/pronounce"), resolvingAgainstBaseURL: false)!
        url.queryItems = [
            URLQueryItem(name: "language", value: locale),
            URLQueryItem(name: "format", value: "detailed")
        ]

        var request = URLRequest(url: url.url!)
        request.httpMethod = "POST"
        Worker.authorize(&request)
        request.setValue("audio/wav; codecs=audio/pcm; samplerate=16000",
                         forHTTPHeaderField: "Content-Type")
        request.setValue(configData.base64EncodedString(),
                         forHTTPHeaderField: "Pronunciation-Assessment")
        request.httpBody = try Data(contentsOf: wav)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let best = (object["NBest"] as? [[String: Any]])?.first
        else { return nil }

        let overall = Int(best["PronScore"] as? Double
                          ?? best["AccuracyScore"] as? Double ?? 0)

        var units: [PronunciationResult.Unit] = []
        for (wordIndex, word) in (best["Words"] as? [[String: Any]] ?? []).enumerated() {
            let text = word["Word"] as? String ?? ""
            let phonemes = word["Phonemes"] as? [[String: Any]] ?? []

            if phonemes.isEmpty {
                // No phoneme breakdown for this locale — the word score is all
                // there is.
                units.append(.init(
                    id: "w\(wordIndex)", index: wordIndex, name: text,
                    score: Int(word["AccuracyScore"] as? Double ?? 0),
                    toneScore: nil, gloss: word["ErrorType"] as? String
                ))
                continue
            }

            for (phonemeIndex, phoneme) in phonemes.enumerated() {
                units.append(.init(
                    id: "w\(wordIndex)p\(phonemeIndex)",
                    index: phonemeIndex,
                    // Absent outside en-US and zh-CN.
                    name: phoneme["Phoneme"] as? String,
                    score: Int(phoneme["AccuracyScore"] as? Double ?? 0),
                    toneScore: nil,
                    gloss: text
                ))
            }
        }

        return PronunciationResult(overall: overall, units: units)
    }
}
