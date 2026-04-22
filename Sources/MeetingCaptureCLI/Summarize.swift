import Foundation

// LLM-backed meeting summarizer.
//
// Talks to any OpenAI-compatible `/chat/completions` endpoint. Default
// configuration targets Baidu Qianfan's coding plan + Kimi-K2.5 (256k
// context, 65k output), which is plenty for any meeting transcript we'll
// hit — no chunking needed.
//
// Endpoint contract expected:
//   POST {baseURL}/chat/completions
//   Authorization: Bearer <apiKey>
//   body: { model, messages: [{role, content}], temperature }
//   200 → { choices: [{ message: { content: "…markdown…" } }] }
enum ThinkingMode: Equatable {
    case enabled(budget: Int)
    case disabled
    case unspecified
}

final class Summarizer {

    let baseURL: URL
    let apiKey:  String
    let model:   String
    let timeout: TimeInterval
    let thinking: ThinkingMode

    init(baseURL: URL,
         apiKey: String,
         model: String,
         thinking: ThinkingMode = .unspecified,
         timeout: TimeInterval = 180)
    {
        self.baseURL  = baseURL
        self.apiKey   = apiKey
        self.model    = model
        self.thinking = thinking
        self.timeout  = timeout
    }

    func summarize(transcript: String) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("chat/completions")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user",   "content": transcript]
            ]
        ]
        switch thinking {
        case .enabled(let budget):
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
        case .disabled:
            body["thinking"] = ["type": "disabled"]
        case .unspecified:
            break
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

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

        guard
            let json    = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first   = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw SummarizerError.badResponse("Unexpected response shape:\n\(raw)")
        }

        print(String(format: "   done in %.1fs (%d chars)", dt, content.count))
        return content
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
