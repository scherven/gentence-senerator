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

    /// One call. `schema` constrains the reply to valid JSON; `cachedSystem` is
    /// the byte-identical prefix that must not vary per request, so per-attempt
    /// facts belong in `user` instead.
    func send(cachedSystem: String,
              user: String,
              schema: [String: Any]? = nil,
              effort: Effort = .medium,
              maxTokens: Int = 8000) async throws -> Reply {

        guard !key.isEmpty else { throw Failure.noKey }

        var outputConfig: [String: Any] = ["effort": effort.rawValue]
        if let schema {
            outputConfig["format"] = ["type": "json_schema", "schema": schema]
        }

        let body: [String: Any] = [
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

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

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
        } catch {
            throw Failure.malformed("\(error.localizedDescription) — \(reply.text.prefix(200))")
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
