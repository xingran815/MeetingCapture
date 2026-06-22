import Foundation

// LLM-backed meeting summarizer.
//
// Talks to either of two wire protocols (see `LLMAPIStyle`), user-selected via a
// catalog of presets (see LLMProvider) — OpenAI, a local Ollama, Qianfan/Kimi
// (the default), Anthropic/Claude, or a fully custom base URL + model. The
// transcript fits any provider we target in a single request — no chunking.
//
// OpenAI-compatible (`.openAIChat`) — the default for every provider but Anthropic:
//   POST {baseURL}/chat/completions
//   Authorization: Bearer <apiKey>
//   body: { model, temperature, messages: [{role, content}] }
//   200 → { choices: [{ message: { content: "…markdown…" } }] }
//
// Anthropic Messages (`.anthropicMessages`):
//   POST {baseURL}/messages
//   x-api-key: <apiKey> · anthropic-version: 2023-06-01   (NOT Bearer)
//   body: { model, max_tokens (required), system, messages: [{role, content}] }
//         — no `temperature` (rejected on current Claude models)
//   200 → { content: [{ type: "text", text: "…markdown…" }] }
//
// `thinking` is a provider-specific reasoning parameter (Kimi-style). The caller
// only enables it for providers known to accept it; it's only ever sent on the
// OpenAI path. Anthropic's own reasoning param is shaped differently and is not
// sent here (the Anthropic preset gates reasoning off).
enum ThinkingMode: Equatable {
    case enabled(budget: Int)
    case disabled
    case unspecified
}

final class Summarizer {

    let baseURL: URL
    /// Resolves the API key on demand. Called once per request so we never
    /// cache the secret in an instance property — a fresh keychain read every
    /// time, so rotating / clearing the key takes effect immediately.
    let apiKeyProvider: () -> String?
    let model:   String
    let timeout: TimeInterval
    let thinking: ThinkingMode
    /// Which wire protocol to speak. Defaults to OpenAI-compatible so existing
    /// callers and the flag-mode path are unchanged.
    let apiStyle: LLMAPIStyle

    /// Anthropic's Messages API requires `max_tokens`; a structured meeting
    /// summary fits comfortably here. Non-streaming, well under `timeout`.
    private static let anthropicMaxTokens = 8192

    init(baseURL: URL,
         apiKeyProvider: @escaping () -> String?,
         model: String,
         apiStyle: LLMAPIStyle = .openAIChat,
         thinking: ThinkingMode = .unspecified,
         timeout: TimeInterval = 180)
    {
        self.baseURL        = baseURL
        self.apiKeyProvider = apiKeyProvider
        self.model          = model
        self.apiStyle       = apiStyle
        self.thinking       = thinking
        self.timeout        = timeout
    }

    func summarize(transcript: String) async throws -> String {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw SummarizerError.badResponse(
                "No LLM API key available at request time. Set it via Settings → LLM API key, QIANFAN_API_KEY, or --llm-api-key."
            )
        }

        let body: [String: Any]
        switch apiStyle {
        case .anthropicMessages:
            // System prompt is a top-level field (not a message); max_tokens is
            // required; no temperature (sampling params 400 on current Claude).
            body = [
                "model": model,
                "max_tokens": Self.anthropicMaxTokens,
                "system": Self.systemPrompt,
                "messages": [["role": "user", "content": transcript]],
            ]
        case .openAIChat:
            var b: [String: Any] = [
                "model": model,
                "temperature": 0.3,
                "messages": [
                    ["role": "system", "content": Self.systemPrompt],
                    ["role": "user",   "content": transcript]
                ]
            ]
            switch thinking {
            case .enabled(let budget): b["thinking"] = ["type": "enabled", "budget_tokens": budget]
            case .disabled:            b["thinking"] = ["type": "disabled"]
            case .unspecified:         break
            }
            body = b
        }
        let endpoint = baseURL.appendingPathComponent(endpointPath)
        let req = try buildRequest(apiKey: apiKey, body: body, timeout: timeout)

        let t0 = Date()
        print("🧩  Summarizing via \(model) @ \(baseURL.host ?? baseURL.absoluteString)…")
        let (data, response) = try await URLSession.shared.data(for: req)
        let dt = Date().timeIntervalSince(t0)

        guard let http = response as? HTTPURLResponse else {
            throw SummarizerError.badResponse("Not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw SummarizerError.badResponse(
                "HTTP \(http.statusCode) from \(endpoint.absoluteString):\n\(bodyText)"
            )
        }

        let content = try parseContent(from: data)
        print(String(format: "   done in %.1fs (%d chars)", dt, content.count))
        return content
    }

    /// Extract the assistant's text from a 2xx response, per wire protocol.
    /// Throws `badResponse` (echoing the raw body) on an unexpected shape — for
    /// Anthropic this also surfaces a `stop_reason: "refusal"` body with empty
    /// content, which is what we want to show the user.
    private func parseContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw SummarizerError.badResponse("Unexpected response shape:\n\(raw)")
        }
        switch apiStyle {
        case .anthropicMessages:
            // { content: [ { type: "text", text: "…" }, … ] }
            if let blocks = json["content"] as? [[String: Any]] {
                let text = blocks
                    .filter { ($0["type"] as? String) == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined()
                if !text.isEmpty { return text }
            }
        case .openAIChat:
            // { choices: [ { message: { content: "…" } } ] }
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
        }
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        throw SummarizerError.badResponse("Unexpected response shape:\n\(raw)")
    }

    /// Lightweight connectivity check: a minimal one-token completion that
    /// validates endpoint + API key + model name together. Calls `completion`
    /// with a short success descriptor (e.g. "HTTP 200 in 0.8s") or a
    /// categorized SummarizerError.
    ///
    /// Callback-based (not async) on purpose: the only caller is the synchronous
    /// Settings menu handler, which blocks on a semaphore until this returns.
    /// URLSession runs the completion on its own queue, so that bridge can't
    /// starve the Swift-concurrency cooperative pool.
    func ping(timeout: TimeInterval = 20, completion: @escaping (Result<String, Error>) -> Void) {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            completion(.failure(SummarizerError.badResponse("No LLM API key available.")))
            return
        }
        let body: [String: Any]
        switch apiStyle {
        case .anthropicMessages:
            body = [
                "model": model,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]],
            ]
        case .openAIChat:
            body = [
                "model": model,
                "temperature": 0,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]],
            ]
        }
        let req: URLRequest
        do { req = try buildRequest(apiKey: apiKey, body: body, timeout: timeout) }
        catch { completion(.failure(error)); return }

        let t0 = Date()
        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                let host = self.baseURL.host ?? self.baseURL.absoluteString
                completion(.failure(SummarizerError.badResponse(
                    "could not reach \(host) — \(error.localizedDescription)")))
                return
            }
            let dt = Date().timeIntervalSince(t0)
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(SummarizerError.badResponse("not an HTTP response")))
                return
            }
            switch http.statusCode {
            case 200..<300:
                completion(.success(String(format: "HTTP %d in %.1fs", http.statusCode, dt)))
            case 401, 403:
                completion(.failure(SummarizerError.badResponse(
                    "HTTP \(http.statusCode) — invalid or unauthorized API key")))
            case 404:
                completion(.failure(SummarizerError.badResponse(
                    "HTTP 404 — model not found or wrong base URL")))
            default:
                let snippet = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "").prefix(300)
                completion(.failure(SummarizerError.badResponse("HTTP \(http.statusCode): \(snippet)")))
            }
        }
        task.resume()
    }

    /// The provider-specific endpoint path appended to `baseURL`.
    private var endpointPath: String {
        apiStyle == .anthropicMessages ? "messages" : "chat/completions"
    }

    /// Build a POST request to the provider's endpoint with the right auth
    /// headers + JSON body. Shared by summarize() and ping().
    private func buildRequest(apiKey: String, body: [String: Any], timeout: TimeInterval) throws -> URLRequest {
        let endpoint = baseURL.appendingPathComponent(endpointPath)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch apiStyle {
        case .anthropicMessages:
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAIChat:
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    enum SummarizerError: Error, LocalizedError {
        case badResponse(String)
        var errorDescription: String? {
            switch self {
            case .badResponse(let s): return s
            }
        }
    }

    static let systemPrompt: String = """
    You are an expert at summarizing meeting transcripts. The user will give you a transcript of a recorded meeting. Produce a concise, well-structured markdown summary with these sections:

    # Summary
    Two or three sentences describing what the meeting was about.

    ## Key points
    Bullet list of the most important points discussed.

    ## Decisions
    Bullet list of concrete decisions made, or "None" if none.

    ## Action items
    Bullet list in the form `- [ ] <action> (owner: <name or ?>)`. Only include real action items that were explicitly discussed.

    ## Open questions
    Bullet list of unresolved questions or follow-ups, or "None" if none.

    Write the summary in the same language as the transcript. If the transcript is in Chinese, reply in Chinese; if English, reply in English; etc. Do not invent content that isn't in the transcript. If the transcript is too short or unclear to summarize meaningfully, say so explicitly in the Summary section and leave other sections as "None".
    """
}
