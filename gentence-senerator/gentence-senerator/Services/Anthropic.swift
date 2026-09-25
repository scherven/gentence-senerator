import Foundation

/// Transport for the Messages API. There is no official Anthropic SDK for
/// Swift, so this speaks the REST endpoint directly.
actor Anthropic {

    enum Effort: String { case low, medium, high, xhigh, max }

    struct Reply {
        var text: String
        var usage: Usage
        /// Non-nil when safety classifiers declined the request.
        var refusal: String?
    }

    struct Usage: Codable, Hashable {
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
    }

    enum Failure: LocalizedError {
        case noKey
        case http(Int, String)
        case malformed(String)
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "No API key. Add Key.anthropicKey in key.swift."
            case .http(let code, let body):
                return "Request failed (\(code)). \(body)"
            case .malformed(let detail):
                return "Unexpected response: \(detail)"
            case .refused(let why):
                return "The model declined: \(why)"
            }
        }
    }

    private let key: String
    private let session: URLSession
    private let model = "claude-opus-5"

    init(key: String, session: URLSession = .shared) {
        self.key = key
        self.session = session
    }

    /// `thinking` is deliberately never set. On Opus 5 — unlike 4.8 and 4.7 —
    /// omitting it runs adaptive thinking, which is what we want: every reply
    /// here is schema-constrained JSON, and `thinking: {type: "disabled"}` on
    /// this model can leak `<thinking>` tags into the text. `effort` is the
    /// lever instead.
    ///
    /// The body of one Messages request — sent on its own, or as one entry of
    /// a batch.
    ///
    /// Batches refuse `fallbacks`, so a batched request that trips a safety
    /// classifier comes back as a refusal and is left ungraded.
    nonisolated func params(cachedSystem: String, user: String, schema: [String: Any]?,
                            effort: Effort, maxTokens: Int, batched: Bool = false) -> [String: Any] {
        var outputConfig: [String: Any] = ["effort": effort.rawValue]
        if let schema {
            outputConfig["format"] = ["type": "json_schema", "schema": schema]
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": [[
                "type": "text",
                "text": cachedSystem,
                "cache_control": ["type": "ephemeral"]
            ]],
            "messages": [["role": "user", "content": user]],
            "output_config": outputConfig
        ]
        // Routes around a safety refusal instead of failing the turn.
        if !batched { body["fallbacks"] = "default" }
        return body
    }

    nonisolated private func request(_ path: String, method: String = "POST",
                                     body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/\(path)")!)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        // Long enough for a high-effort reply that sends nothing until it is done.
        request.timeoutInterval = 600
        return request
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.malformed("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw Failure.http(http.statusCode, String(detail.prefix(400)))
        }
        return data
    }

    /// One call. `schema` constrains the reply to valid JSON; `cachedSystem` is
    /// the byte-identical prefix that must not vary per request, so per-attempt
    /// facts belong in `user` instead.
    func send(cachedSystem: String,
              user: String,
              schema: [String: Any]? = nil,
              effort: Effort = .medium,
              maxTokens: Int = 8000) async throws -> Reply {

        guard !key.isEmpty else { throw Failure.noKey }

        let body = params(cachedSystem: cachedSystem, user: user, schema: schema,
                          effort: effort, maxTokens: maxTokens)
        let data = try await data(for: try request("messages", body: body))

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed("not a JSON object")
        }
        return try Self.reply(from: object)
    }

    /// A finished message, from `/messages` or from one line of batch results.
    static func reply(from object: [String: Any]) throws -> Reply {
        let usage = Self.usage(from: object["usage"] as? [String: Any] ?? [:])

        // Always check before reading content — a refusal is an HTTP 200.
        if (object["stop_reason"] as? String) == "refusal" {
            let details = object["stop_details"] as? [String: Any]
            let why = details?["explanation"] as? String ?? "no explanation given"
            return Reply(text: "", usage: usage, refusal: why)
        }

        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()

        guard !text.isEmpty else { throw Failure.malformed("no text blocks") }
        return Reply(text: text, usage: usage, refusal: nil)
    }

    /// Same call, decoded into `T`. `schema` should describe `T`.
    func send<T: Decodable>(_ type: T.Type,
                            cachedSystem: String,
                            user: String,
                            schema: [String: Any],
                            effort: Effort = .medium,
                            maxTokens: Int = 8000) async throws -> (T, Usage) {

        let reply = try await send(cachedSystem: cachedSystem, user: user,
                                   schema: schema, effort: effort, maxTokens: maxTokens)
        return (try Self.decode(T.self, from: reply), reply.usage)
    }

    static func decode<T: Decodable>(_ type: T.Type, from reply: Reply) throws -> T {
        if let refusal = reply.refusal { throw Failure.refused(refusal) }
        guard let data = reply.text.data(using: .utf8) else {
            throw Failure.malformed("reply was not UTF-8")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw Failure.malformed("\(Self.explain(error)) — \(reply.text.prefix(400))")
        } catch {
            throw Failure.malformed("\(error.localizedDescription) — \(reply.text.prefix(400))")
        }
    }

    /// `localizedDescription` on a DecodingError says only that something was
    /// wrong. The coding path says which field, which is the whole question.
    private static func explain(_ error: DecodingError) -> String {
        func where_(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "the root" : path
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "no `\(key.stringValue)` in \(where_(context))"
        case .typeMismatch(let type, let context):
            return "`\(where_(context))` was not \(type)"
        case .valueNotFound(let type, let context):
            return "`\(where_(context))` was null, wanted \(type)"
        case .dataCorrupted(let context):
            return "broken JSON at \(where_(context)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    // MARK: Batches
    //
    // Half price, and nobody is waiting. Results can only be downloaded once
    // every request in the batch has ended; the counts are readable before.

    struct Batch {
        var id: String
        var ended: Bool
        var succeeded: Int
        var failed: Int
        var processing: Int
        var resultsURL: URL?
    }

    /// One result line. `reply` is nil when the request errored or expired.
    struct BatchResult {
        var customID: String
        var reply: Reply?
        var error: String?
    }

    func retrieveBatch(_ id: String) async throws -> Batch {
        try Self.batch(from: try await data(for: try request("messages/batches/\(id)", method: "GET")))
    }

    func batchResults(_ batch: Batch) async throws -> [BatchResult] {
        guard let url = batch.resultsURL else { throw Failure.malformed("batch has no results yet") }
        var request = try request("", method: "GET")
        request.url = url
        return Self.results(from: try await data(for: request))
    }

    /// One `BatchResult` per line of a results file. A line that will not
    /// parse is skipped, not fatal: its answer shows as failed and is retried.
    static func results(from data: Data) -> [BatchResult] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> BatchResult? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                        as? [String: Any],
                      let id = object["custom_id"] as? String,
                      let result = object["result"] as? [String: Any] else { return nil }
                if result["type"] as? String == "succeeded",
                   let message = result["message"] as? [String: Any] {
                    do {
                        return BatchResult(customID: id, reply: try Self.reply(from: message), error: nil)
                    } catch {
                        return BatchResult(customID: id, reply: nil, error: error.localizedDescription)
                    }
                }
                let why = ((result["error"] as? [String: Any])?["error"] as? [String: Any])?["message"]
                    as? String ?? (result["type"] as? String ?? "failed")
                return BatchResult(customID: id, reply: nil, error: why)
            }
    }

    private static func batch(from data: Data) throws -> Batch {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else {
            throw Failure.malformed("not a batch")
        }
        let counts = object["request_counts"] as? [String: Any] ?? [:]
        func n(_ key: String) -> Int { counts[key] as? Int ?? 0 }
        return Batch(
            id: id,
            ended: object["processing_status"] as? String == "ended",
            succeeded: n("succeeded"),
            failed: n("errored") + n("expired") + n("canceled"),
            processing: n("processing"),
            resultsURL: (object["results_url"] as? String).flatMap(URL.init(string:))
        )
    }

    private static func usage(from raw: [String: Any]) -> Usage {
        Usage(
            inputTokens: raw["input_tokens"] as? Int ?? 0,
            outputTokens: raw["output_tokens"] as? Int ?? 0,
            cacheReadTokens: raw["cache_read_input_tokens"] as? Int ?? 0,
            cacheWriteTokens: raw["cache_creation_input_tokens"] as? Int ?? 0
        )
    }
}
