import Foundation

// LLM-backed meeting summarizer.
//
// Talks to either of two wire protocols (see `LLMAPIStyle`), user-selected via a
// catalog of presets (see LLMProvider) — DeepSeek, OpenAI, a local Ollama,
// Anthropic/Claude, or a fully custom base URL + model. This is the API route; the
// default route is the subscription CLIs (see SummaryPipeline). The
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
// Reasoning is provider-specific (see `ReasoningStyle`): the caller passes the
// resolved style + a unified effort level, and `summarize()` serializes whichever
// wire shape that provider uses —
//   .thinking  → `thinking: {type:"enabled", budget_tokens:N}` (off → `{type:"disabled"}`)
//   .openai    → `reasoning_effort: "low"|"medium"|"high"`     (off → omitted)
//   .anthropic → `thinking: {type:"adaptive"}` + `output_config:{effort:…}` (off → omitted)
// `.none` / `.off` send nothing.

final class Summarizer {

    let baseURL: URL
    /// Resolves the API key on demand. Called once per request so we never
    /// cache the secret in an instance property — a fresh keychain read every
    /// time, so rotating / clearing the key takes effect immediately.
    let apiKeyProvider: () -> String?
    let model: String
    let timeout: TimeInterval
    /// Which reasoning wire format to emit, and how deep. Defaults to no reasoning
    /// so existing/other callers are unaffected.
    let reasoningStyle: ReasoningStyle
    let reasoningEffort: ReasoningEffort
    /// Which wire protocol to speak. Defaults to OpenAI-compatible so existing
    /// callers and the flag-mode path are unchanged.
    let apiStyle: LLMAPIStyle

    /// Anthropic's Messages API requires `max_tokens`. A structured summary fits
    /// in `anthropicMaxTokens`; when adaptive thinking is on we raise the cap to
    /// `anthropicMaxTokensReasoning` so reasoning tokens have room. Both are
    /// non-streaming and well under `timeout`.
    private static let anthropicMaxTokens = 8192
    private static let anthropicMaxTokensReasoning = 16_000

    init(
        baseURL: URL,
        apiKeyProvider: @escaping () -> String?,
        model: String,
        apiStyle: LLMAPIStyle = .openAIChat,
        reasoningStyle: ReasoningStyle = .none,
        reasoningEffort: ReasoningEffort = .off,
        timeout: TimeInterval = 180
    ) {
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
        self.model = model
        self.apiStyle = apiStyle
        self.reasoningStyle = reasoningStyle
        self.reasoningEffort = reasoningEffort
        self.timeout = timeout
    }

    /// One request with a system prompt and a user message, returning the model's text.
    func complete(system: String, user: String) async throws -> String {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw SummarizerError.badResponse(
                "No LLM API key available at request time. Set it via Settings → LLM configurations, LLM_API_KEY, or --llm-api-key."
            )
        }

        // Whether the resolved style matches this wire protocol (a mismatched
        // style — e.g. .thinking on the Anthropic protocol — is simply not sent).
        let reasoningOn = reasoningEffort.isOn
        let body: [String: Any]
        switch apiStyle {
        case .anthropicMessages:
            // System prompt is a top-level field (not a message); max_tokens is
            // required; no temperature (sampling params 400 on current Claude).
            let anthropicReasoning = reasoningOn && reasoningStyle == .anthropic
            var b: [String: Any] = [
                "model": model,
                "max_tokens": anthropicReasoning ? Self.anthropicMaxTokensReasoning : Self.anthropicMaxTokens,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
            if anthropicReasoning {
                b["thinking"] = ["type": "adaptive"]
                b["output_config"] = ["effort": reasoningEffort.rawValue]
            }
            body = b
        case .openAIChat:
            var b: [String: Any] = [
                "model": model,
                "temperature": 0.3,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ]
            switch reasoningStyle {
            case .thinking:
                b["thinking"] =
                    reasoningOn
                    ? ["type": "enabled", "budget_tokens": reasoningEffort.budgetTokens]
                    : ["type": "disabled"]
            case .openai:
                if reasoningOn { b["reasoning_effort"] = reasoningEffort.rawValue }
            case .anthropic, .none:
                break  // not an OpenAI-chat reasoning format
            }
            body = b
        }
        let endpoint = baseURL.appendingPathComponent(endpointPath)
        let req = try buildRequest(apiKey: apiKey, body: body, timeout: timeout)

        let t0 = Date()
        print("🧩  Asking \(model) @ \(baseURL.host ?? baseURL.absoluteString)…")
        let (data, response) = try await URLSession.shared.data(for: req)
        let dt = Date().timeIntervalSince(t0)

        guard let http = response as? HTTPURLResponse else {
            throw SummarizerError.badResponse("Not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = Self.scrubbed(data)
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
    /// A provider's error can quote its input, so it's scrubbed before reaching a
    /// screen or log, as CLI errors are.
    private static func scrubbed(_ data: Data) -> String {
        Redactor.redact(String(decoding: data, as: UTF8.self)).text
    }

    private func parseContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = Self.scrubbed(data)
            throw SummarizerError.badResponse("Unexpected response shape:\n\(raw)")
        }
        switch apiStyle {
        case .anthropicMessages:
            // { content: [ { type: "text", text: "…" }, … ] }
            if let blocks = json["content"] as? [[String: Any]] {
                let text =
                    blocks
                    .filter { ($0["type"] as? String) == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined()
                if !text.isEmpty { return text }
            }
        case .openAIChat:
            // { choices: [ { message: { content: "…" } } ] }
            if let choices = json["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let content = message["content"] as? String,
                !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return content
            }
        }
        let raw = Self.scrubbed(data)
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
        do { req = try buildRequest(apiKey: apiKey, body: body, timeout: timeout) } catch {
            completion(.failure(error))
            return
        }

        let t0 = Date()
        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                let host = self.baseURL.host ?? self.baseURL.absoluteString
                completion(
                    .failure(
                        SummarizerError.badResponse(
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
                completion(
                    .failure(
                        SummarizerError.badResponse(
                            "HTTP \(http.statusCode) — invalid or unauthorized API key")))
            case 404:
                completion(
                    .failure(
                        SummarizerError.badResponse(
                            "HTTP 404 — model not found or wrong base URL")))
            default:
                let snippet = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "").prefix(300)
                completion(.failure(SummarizerError.badResponse("HTTP \(http.statusCode): \(snippet)")))
            }
        }
        task.resume()
    }

    /// Active reasoning-capability probe. For this profile's wire protocol, sends
    /// a tiny reasoning-*inducing* request per candidate reasoning format and
    /// inspects the response for actual reasoning output. A plain HTTP 200 is not
    /// enough — many OpenAI-compatible gateways silently ignore unknown fields —
    /// so a positive verdict requires reasoning content in the body.
    ///
    /// `hostDetected` (the URL/preset-based guess) only orders the candidates so a
    /// recognized host confirms first and avoids a spurious 400.
    func probeReasoning(hostDetected: ReasoningStyle, timeout: TimeInterval = 30) async -> ReasoningProbeOutcome {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            return .failed("No LLM API key available.")
        }
        // Reasoning formats that are valid for this wire protocol, host-detected
        // first (then the others), so a known endpoint settles in one request.
        var candidates: [ReasoningStyle]
        switch apiStyle {
        case .anthropicMessages: candidates = [.anthropic]
        case .openAIChat: candidates = [.thinking, .openai]
        }
        if let i = candidates.firstIndex(of: hostDetected), i != 0 {
            candidates.remove(at: i)
            candidates.insert(hostDetected, at: 0)
        }

        var sawInconclusive = false
        var reachedEndpoint = false
        for style in candidates {
            guard let req = try? buildRequest(apiKey: apiKey, body: probeBody(for: style), timeout: timeout),
                let (data, response) = try? await URLSession.shared.data(for: req),
                let http = response as? HTTPURLResponse
            else {
                continue  // network/build error — let another candidate try
            }
            reachedEndpoint = true
            guard (200..<300).contains(http.statusCode) else {
                continue  // this format's parameter was rejected; try the next
            }
            if let detail = reasoningSignal(in: data, style: style) {
                return .supported(style, detail: detail)
            }
            sawInconclusive = true  // accepted, but produced no reasoning output
        }
        guard reachedEndpoint else { return .failed("could not reach the endpoint") }
        return .noneDetected(inconclusive: sawInconclusive)
    }

    /// Callback bridge to `probeReasoning`, for the synchronous Settings menu
    /// (mirrors `ping`: the caller blocks on a semaphore until `completion` fires).
    func probeReasoning(
        hostDetected: ReasoningStyle,
        timeout: TimeInterval = 30,
        completion: @escaping (ReasoningProbeOutcome) -> Void
    ) {
        Task {
            completion(await probeReasoning(hostDetected: hostDetected, timeout: timeout))
        }
    }

    /// A minimal reasoning-inducing request body for one candidate format. The
    /// arithmetic prompt is small but enough to make a reasoning model think;
    /// caps/budgets are kept low to keep the probe cheap.
    private func probeBody(for style: ReasoningStyle) -> [String: Any] {
        let prompt = "What is 23 + 19? Reason briefly, then reply with just the number."
        switch apiStyle {
        case .anthropicMessages:
            var b: [String: Any] = [
                "model": model,
                "max_tokens": 2048,
                "messages": [["role": "user", "content": prompt]],
            ]
            if style == .anthropic {
                b["thinking"] = ["type": "adaptive"]
                b["output_config"] = ["effort": "low"]
            }
            return b
        case .openAIChat:
            var b: [String: Any] = [
                "model": model,
                "temperature": 0,
                "max_tokens": 512,
                "messages": [["role": "user", "content": prompt]],
            ]
            switch style {
            case .thinking:
                b["thinking"] = ["type": "enabled", "budget_tokens": ReasoningEffort.low.budgetTokens]
            case .openai:
                b["reasoning_effort"] = "low"
            case .anthropic, .none:
                break
            }
            return b
        }
    }

    /// Inspect a 2xx probe response for evidence the model actually reasoned under
    /// `style`. Returns a short description of the matched marker, or nil if no
    /// reasoning output is present (the parameter was likely ignored).
    private func reasoningSignal(in data: Data, style: ReasoningStyle) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
            let json = obj as? [String: Any]
        else { return nil }
        switch style {
        case .anthropic:
            // { content: [ { type: "thinking", thinking: "…" }, … ] }
            if let blocks = json["content"] as? [[String: Any]],
                blocks.contains(where: { ($0["type"] as? String)?.contains("thinking") == true })
            {
                return "thinking block present"
            }
        case .thinking:
            // { choices: [ { message: { reasoning_content: "…" } } ] }
            if let choices = json["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any]
            {
                if let rc = message["reasoning_content"] as? String,
                    !rc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return "reasoning_content present"
                }
                if let rc = message["reasoning"] as? String, !rc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return "reasoning field present"
                }
                if let content = message["content"] as? String, content.contains("<think>") {
                    return "<think> block present"
                }
            }
        case .openai:
            // { usage: { completion_tokens_details: { reasoning_tokens: N } } }
            if let usage = json["usage"] as? [String: Any],
                let details = usage["completion_tokens_details"] as? [String: Any],
                let rt = details["reasoning_tokens"] as? Int, rt > 0
            {
                return "\(rt) reasoning tokens"
            }
        case .none:
            break
        }
        return nil
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

    /// Verdict of an active reasoning-capability probe (see `probeReasoning`).
    enum ReasoningProbeOutcome {
        /// The endpoint accepted a reasoning parameter and returned reasoning
        /// output in this wire format. `detail` names the matched marker.
        case supported(ReasoningStyle, detail: String)
        /// No reasoning detected. `inconclusive == true`: the endpoint accepted the
        /// parameter (HTTP 2xx) but produced no reasoning output — likely a
        /// non-reasoning model or a gateway that drops the field. `false`: every
        /// candidate parameter was rejected outright.
        case noneDetected(inconclusive: Bool)
        /// The probe could not run (no key, endpoint unreachable, …).
        case failed(String)
    }
}
