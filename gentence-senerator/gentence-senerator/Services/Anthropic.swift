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
    /// this model can leak `<thinking>` tags into the text, which would land
    /// verbatim in a rule or a question, and would break the partial-JSON
    /// scanners in `Tutor`. `effort` is the lever instead.
    nonisolated private func request(cachedSystem: String, user: String, schema: [String: Any]?,
                        effort: Effort, maxTokens: Int, streaming: Bool) throws -> URLRequest {
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
            "output_config": outputConfig,
            // Routes around a safety refusal instead of failing the turn.
            "fallbacks": "default"
        ]
        if streaming { body["stream"] = true }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120
        return request
    }

    /// A reply as it is written, for the one call the learner waits on. Half
    /// its wall-clock is thinking, before any text exists; the rest arrives at
    /// a steady rate, so showing it as it lands halves the visible wait.
    enum Event {
        case text(String)
        case finished(Usage)
        case refused(String)
    }

    /// Opens the connection and hands back the bytes to read.
    nonisolated private func open(cachedSystem: String, user: String, schema: [String: Any],
                                  effort: Effort, maxTokens: Int)
    async throws -> URLSession.AsyncBytes {
        var request = try self.request(cachedSystem: cachedSystem, user: user,
                                       schema: schema, effort: effort,
                                       maxTokens: maxTokens, streaming: true)
        request.timeoutInterval = 180

        let (bytes, response) = try await self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.malformed("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 400 { break }
            }
            throw Failure.http(http.statusCode, String(body.prefix(400)))
        }
        return bytes
    }

    nonisolated func stream(cachedSystem: String,
                user: String,
                schema: [String: Any],
                effort: Effort = .medium,
                maxTokens: Int = 8000) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    guard !key.isEmpty else { throw Failure.noKey }
                    let bytes = try await self.open(
                        cachedSystem: cachedSystem, user: user, schema: schema,
                        effort: effort, maxTokens: maxTokens)

                    var usage = Usage(inputTokens: 0, outputTokens: 0,
                                      cacheReadTokens: 0, cacheWriteTokens: 0)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any] else { continue }

                        switch object["type"] as? String {
                        case "content_block_delta":
                            if let delta = object["delta"] as? [String: Any],
                               let text = delta["text"] as? String, !text.isEmpty {
                                continuation.yield(.text(text))
                            }
                        case "message_start":
                            if let message = object["message"] as? [String: Any] {
                                usage = Self.usage(from: message["usage"] as? [String: Any] ?? [:])
                            }
                        case "message_delta":
                            if let delta = object["delta"] as? [String: Any],
                               delta["stop_reason"] as? String == "refusal" {
                                let why = (object["stop_details"] as? [String: Any])?["explanation"]
                                    as? String ?? "no explanation given"
                                continuation.yield(.refused(why))
                            }
                            // Output tokens are only final here.
                            if let u = object["usage"] as? [String: Any] {
                                let final = Self.usage(from: u)
                                usage.outputTokens = final.outputTokens
                            }
                        default:
                            break
                        }
                    }
                    continuation.yield(.finished(usage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
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

        let request = try self.request(cachedSystem: cachedSystem, user: user, schema: schema,
                                       effort: effort, maxTokens: maxTokens,
                                       streaming: false)
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw Failure.malformed("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw Failure.http(http.statusCode, String(detail.prefix(400)))
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed("not a JSON object")
        }

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
        if let refusal = reply.refusal { throw Failure.refused(refusal) }

        guard let data = reply.text.data(using: .utf8) else {
            throw Failure.malformed("reply was not UTF-8")
        }
        do {
            return (try JSONDecoder().decode(T.self, from: data), reply.usage)
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

    private static func usage(from raw: [String: Any]) -> Usage {
        Usage(
            inputTokens: raw["input_tokens"] as? Int ?? 0,
            outputTokens: raw["output_tokens"] as? Int ?? 0,
            cacheReadTokens: raw["cache_read_input_tokens"] as? Int ?? 0,
            cacheWriteTokens: raw["cache_creation_input_tokens"] as? Int ?? 0
        )
    }
}
