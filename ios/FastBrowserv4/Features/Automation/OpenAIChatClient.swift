import Foundation

/// Failure modes for the OpenAI-compatible HTTP client. Deliberately
/// sanitized — errors carry a status code, never response bodies (which can
/// echo request content on misbehaving providers).
nonisolated enum LLMClientError: Error, Sendable, Equatable {
    case invalidBaseURL
    case unauthorized      // 401/403 — key rejected
    case rateLimited       // 429 — rotate keys
    case serverError(Int)  // 5xx — provider-side, try again later
    case httpStatus(Int)
    case badResponse
    case emptyContent
    case unreachable

    init(statusCode: Int) {
        switch statusCode {
        case 401, 403: self = .unauthorized
        case 429: self = .rateLimited
        case 500...599: self = .serverError(statusCode)
        default: self = .httpStatus(statusCode)
        }
    }

    var isRotatable: Bool {
        switch self {
        case .rateLimited, .serverError, .unreachable: return true
        case .unauthorized, .invalidBaseURL, .httpStatus, .badResponse, .emptyContent: return false
        }
    }

    /// Short, sanitized text for settings UI — never echoes request data.
    var userFacingText: String {
        switch self {
        case .invalidBaseURL: return "The address doesn't look like a valid API endpoint"
        case .unauthorized: return "Key rejected (401/403) — check the key"
        case .rateLimited: return "Rate limited (429) — try again shortly"
        case .serverError(let code): return "Provider error \(code)"
        case .httpStatus(let code): return "Unexpected HTTP \(code)"
        case .badResponse: return "The reply wasn't valid chat-format JSON"
        case .emptyContent: return "The provider replied with an empty message"
        case .unreachable: return "Couldn't reach the server"
        }
    }
}

/// Minimal async client for OpenAI-compatible chat APIs. All methods are
/// nonisolated and Sendable — the networking actors stay off the main actor.
nonisolated struct OpenAIChatClient: Sendable {

    /// One call against one provider identity.
    struct Endpoint: Sendable, Equatable {
        var baseURL: String   // e.g. "https://api.openai.com/v1"
        var apiKey: String
        var model: String
    }

    private enum ClientConfig {
        static var requestTimeout: TimeInterval { 30 }
        static var maxTokens: Int { 300 }
    }

    private func chatCompletionsURL(for baseURL: String) throws -> URL {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/chat/completions") {
            trimmed = String(trimmed.dropLast("/chat/completions".count))
        }
        guard let url = URL(string: trimmed + "/chat/completions"),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil
        else { throw LLMClientError.invalidBaseURL }
        return url
    }

    private struct ChatRequest: Encodable {
        struct ImageURL: Encodable { let url: String }
        struct ContentPart: Encodable {
            let type: String
            let text: String?
            let image_url: ImageURL?
        }
        enum MessageContent: Encodable {
            case text(String)
            case parts([ContentPart])
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let text): try container.encode(text)
                case .parts(let parts): try container.encode(parts)
                }
            }
        }
        struct Message: Encodable {
            let role: String
            let content: MessageContent
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let max_tokens: Int
    }

    /// Asks the model for a single assistant message. `system` carries the
    /// behavioral contract; `user` the payload. Never throws raw provider
    /// bodies — errors are sanitized by `LLMClientError`.
    func chat(system: String, user: String, endpoint: Endpoint) async throws -> String {
        try await chat(system: system, user: user, imageJPEG: nil, endpoint: endpoint)
    }

    /// Same as `chat`, optionally attaching a JPEG as a multimodal part.
    /// The image is expected to be a page screenshot — never a password.
    func chat(system: String, user: String, imageJPEG: Data?, endpoint: Endpoint) async throws -> String {
        let url = try chatCompletionsURL(for: endpoint.baseURL)
        var request = URLRequest(url: url, timeoutInterval: ClientConfig.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")

        let userContent: ChatRequest.MessageContent
        if let imageJPEG {
            let dataURL = "data:image/jpeg;base64," + imageJPEG.base64EncodedString()
            userContent = .parts([
                .init(type: "text", text: user, image_url: nil),
                .init(type: "image_url", text: nil, image_url: .init(url: dataURL))
            ])
        } else {
            userContent = .text(user)
        }

        let body = ChatRequest(
            model: endpoint.model,
            messages: [
                .init(role: "system", content: .text(system)),
                .init(role: "user", content: userContent)
            ],
            temperature: 0.1,
            max_tokens: ClientConfig.maxTokens
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMClientError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw LLMClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMClientError(statusCode: http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw LLMClientError.badResponse }
        return content
    }

    /// Cheap liveness probe for the Test button: 1-token completion.
    func test(endpoint: Endpoint) async throws -> Double {
        let start = Date()
        _ = try await chat(system: "Reply with the single word: ok", user: "healthcheck", endpoint: endpoint)
        return Date().timeIntervalSince(start)
    }

    /// Friendly Test-button result string: latency on success, a sanitized
    /// reason on failure.
    func testConnection(endpoint: Endpoint) async -> String {
        do {
            let seconds = try await test(endpoint: endpoint)
            let ms = Int((seconds * 1000).rounded())
            return "Connected · \(ms) ms"
        } catch let error as LLMClientError {
            return error.userFacingText
        } catch {
            return "Couldn't complete the test request"
        }
    }

    /// GET {base}/models — the model picker data source. Empty list on
    /// failure (settings UI falls back to free text entry).
    func fetchModels(endpoint: Endpoint) async -> [String] {
        var base = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/models") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: ClientConfig.requestTimeout)
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = object["data"] as? [[String: Any]]
            else { return [] }
            return list.compactMap { $0["id"] as? String }.sorted()
        } catch {
            return []
        }
    }
}
