import Foundation

// MARK: - Azure Pronunciation Assessment Service

/// Calls Azure Cognitive Services Pronunciation Assessment REST API.
/// Returns structured per-syllable tone, consonant, and vowel scores for Mandarin.
final class AzureSpeechService {

    // MARK: - Public API

    /// Returns nil if the Azure key is not configured or the call fails.
    func assessPronunciation(audioURL: URL, referenceText: String) async -> PronunciationAssessment? {
        guard !Key.azureKey.isEmpty else {
            print("[Azure] Skipping — azureKey is empty")
            return nil
        }
        do {
            return try await fetchAssessment(audioURL: audioURL, referenceText: referenceText)
        } catch {
            print("[Azure] Assessment failed: \(error)")
            return nil
        }
    }

    // MARK: - REST Call

    private func fetchAssessment(audioURL: URL, referenceText: String) async throws -> PronunciationAssessment {
        // Diagnostic: try plain STT first (no Pronunciation-Assessment header) to verify endpoint/key.
        let endpoint = "https://\(Key.azureRegion).stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1?language=zh-CN&format=detailed"

        guard let url = URL(string: endpoint) else {
            throw AzureError.invalidURL
        }

        let audioData = try Data(contentsOf: audioURL)
        print("[Azure] Sending \(audioData.count) bytes from \(audioURL.lastPathComponent), referenceText: \"\(referenceText)\"")
        logWAVHeader(audioData)

        // --- Plain STT diagnostic (no Pronunciation-Assessment header) ---
        var sttRequest = URLRequest(url: url)
        sttRequest.httpMethod = "POST"
        sttRequest.setValue(Key.azureKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        sttRequest.setValue("audio/wav; codecs=audio/pcm; samplerate=16000", forHTTPHeaderField: "Content-Type")
        sttRequest.httpBody = audioData
        let (sttData, sttResp) = try await URLSession.shared.data(for: sttRequest)
        let sttStatus = (sttResp as? HTTPURLResponse)?.statusCode ?? -1
        let sttBody = String(data: sttData, encoding: .utf8) ?? "<non-UTF8>"
        print("[Azure] Plain STT status: \(sttStatus) body: \(sttBody)")

        // Guard: pronunciation assessment requires a non-empty reference text.
        guard !referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AzureError.parseError("Empty reference text — skipping pronunciation assessment")
        }

        // Minimal config matching Microsoft's REST API documentation.
        // PhonemeAlphabet and EnableMiscue are omitted — they cause 400 on some tiers.
        let assessmentConfig: [String: Any] = [
            "ReferenceText": referenceText,
            "GradingSystem": "HundredMark",
            "Granularity": "Phoneme"
        ]
        let configData = try JSONSerialization.data(withJSONObject: assessmentConfig)
        let configBase64 = configData.base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Key.azureKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("audio/wav; codecs=audio/pcm; samplerate=16000", forHTTPHeaderField: "Content-Type")
        request.setValue(configBase64, forHTTPHeaderField: "Pronunciation-Assessment")
        request.httpBody = audioData

        let (data, response) = try await URLSession.shared.data(for: request)

        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? -1
        print("[Azure] Response status: \(statusCode)")

        guard statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            print("[Azure] Error body: \(body)")
            print("[Azure] Response headers: \(httpResponse?.allHeaderFields ?? [:])")
            print("[Azure] Request URL: \(request.url?.absoluteString ?? "nil")")
            print("[Azure] Request headers: \(request.allHTTPHeaderFields ?? [:])")
            print("[Azure] Audio bytes: \(request.httpBody?.count ?? 0)")
            throw AzureError.httpError(statusCode)
        }

        return try parseResponse(data: data)
    }

    // MARK: - Response Parsing

    private func parseResponse(data: Data) throws -> PronunciationAssessment {
        let rawJSON = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
        print("[Azure] Raw response: \(rawJSON)")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nBest = json["NBest"] as? [[String: Any]],
              let best = nBest.first,
              let words = best["Words"] as? [[String: Any]] else {
            let keys = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys.sorted().joined(separator: ", ") ?? "none"
            print("[Azure] Parse failed — top-level keys: \(keys)")
            throw AzureError.parseError("Missing NBest/Words")
        }

        // Overall accuracy comes from the NBest entry itself when Granularity=Phoneme
        let bestAccuracy = Int((best["AccuracyScore"] as? Double ?? 0).rounded())

        var syllables: [SyllableResult] = []

        for word in words {
            let wordText = word["Word"] as? String ?? ""
            // Scores are directly on the word, NOT nested under "PronunciationAssessment"
            let wordAccuracy = Int((word["AccuracyScore"] as? Double ?? 0).rounded())

            let characters = wordText.map { String($0) }
            if characters.isEmpty { continue }

            // Phonemes are whole pinyin syllables with tone suffix, e.g. "wo 3", "ge 1", "bu 4"
            let phonemes = word["Phonemes"] as? [[String: Any]] ?? []

            // For each character in the word we produce one SyllableResult.
            // Pair characters with phonemes by index; extras fall back to word-level score.
            for (idx, character) in characters.enumerated() {
                var syllableStr = ""
                var initialScore: Int? = nil
                var finalScore: Int? = nil

                if idx < phonemes.count, let phoneme = phonemes[idx] as? [String: Any] {
                    let phonemeScore = Int((phoneme["AccuracyScore"] as? Double ?? Double(wordAccuracy)).rounded())
                    // phoneme["Phoneme"] = "syllable tonenum" e.g. "wo 3"
                    if let raw = phoneme["Phoneme"] as? String {
                        let parts = raw.split(separator: " ")
                        syllableStr = parts.first.map(String.init) ?? ""
                        // Split into initial/final and assign the phoneme score to each.
                        let (hasInit, _) = splitPinyinInitial(syllableStr)
                        if hasInit {
                            initialScore = phonemeScore
                        }
                        finalScore = phonemeScore
                    }
                }

                syllables.append(SyllableResult(
                    character: character,
                    syllable: syllableStr,
                    accuracyScore: wordAccuracy,
                    toneScore: wordAccuracy,   // Azure doesn't return a separate tone score here
                    initialScore: initialScore,
                    finalScore: finalScore,
                    errorType: "None"
                ))
            }
        }

        let overallScore = syllables.isEmpty ? bestAccuracy : syllables.map(\.accuracyScore).reduce(0, +) / syllables.count
        let consonantScores = syllables.compactMap(\.initialScore)
        let consonantScore = consonantScores.isEmpty ? overallScore : consonantScores.reduce(0, +) / consonantScores.count
        let vowelScores = syllables.compactMap(\.finalScore)
        let vowelScore = vowelScores.isEmpty ? overallScore : vowelScores.reduce(0, +) / vowelScores.count

        print("[Azure] Parsed \(syllables.count) syllables, overall=\(overallScore) consonant=\(consonantScore) vowel=\(vowelScore)")

        return PronunciationAssessment(
            overallScore: overallScore,
            toneScore: overallScore,
            accuracyScore: overallScore,
            consonantScore: consonantScore,
            vowelScore: vowelScore,
            syllables: syllables
        )
    }

    // MARK: - Pinyin initial extraction

    /// Returns (hasInitial, initialString) for a bare pinyin syllable (no tone number).
    /// e.g. "ge" → (true, "g"), "wo" → (false, ""), "zhe" → (true, "zh")
    private func splitPinyinInitial(_ syllable: String) -> (Bool, String) {
        // Check 2-char initials first
        for initial in ["zh", "ch", "sh"] {
            if syllable.hasPrefix(initial) { return (true, initial) }
        }
        // 1-char initials (exclude y/w — they are syllable-initial glides, not true initials)
        for initial in ["b","p","m","f","d","t","n","l","g","k","h","j","q","x","r","z","c","s"] {
            if syllable.hasPrefix(initial) { return (true, initial) }
        }
        return (false, "")
    }

    // MARK: - WAV Header Diagnostics

    private func logWAVHeader(_ data: Data) {
        guard data.count >= 44 else {
            print("[Azure] WAV too small to have a valid header (\(data.count) bytes)")
            return
        }
        let riff = String(bytes: data[0..<4], encoding: .ascii) ?? "????"
        let wave = String(bytes: data[8..<12], encoding: .ascii) ?? "????"
        let audioFormat = data[20..<22].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        let channels   = data[22..<24].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        let sampleRate = data[24..<28].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let byteRate   = data[28..<32].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let bitDepth   = data[34..<36].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        print("[Azure] WAV header: \(riff)/\(wave) fmt=\(audioFormat)(1=PCM) ch=\(channels) rate=\(sampleRate)Hz bits=\(bitDepth) byteRate=\(byteRate)")
    }

}

// MARK: - Errors

enum AzureError: Error {
    case invalidURL
    case httpError(Int)
    case parseError(String)
}
