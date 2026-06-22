import Foundation

// The wire protocol a provider speaks. Almost everything is OpenAI-compatible
// `/chat/completions`; Anthropic is the exception — it has its own `/messages`
// shape (x-api-key header, required max_tokens, top-level `system`, and a
// `content[].text` response). `Summarizer` branches on this.
enum LLMAPIStyle: String, Codable {
    case openAIChat          // POST {base}/chat/completions, Bearer auth
    case anthropicMessages   // POST {base}/messages, x-api-key + anthropic-version
}

// Catalog of selectable LLM providers for summarization.
//
// Most entries speak the OpenAI-compatible `/chat/completions` protocol; the
// Anthropic entry is the exception (`apiStyle == .anthropicMessages`). A
// provider is a base URL + a sensible default model + whether it accepts the
// Kimi-style `thinking` reasoning parameter + which wire protocol it speaks.
// Picking a preset in Settings pre-fills the base URL and model (both still
// individually editable). The "Custom" entry leaves them blank for a fully
// user-supplied endpoint.
//
// A provider here is just a template: picking one pre-fills an LLMProfile's
// providerID/baseURL/model (see below). The persisted, switchable state lives
// in Config.llmProfiles / Config.selectedLLMProfileID — each profile's base
// URL / model stay free-form so power users — and the --llm-base-url /
// --llm-model flags — can override any preset.
struct LLMProvider: Identifiable {
    let id: String              // stable key persisted in config
    let label: String           // human-readable name shown in Settings
    let baseURL: String         // base endpoint; "" for custom
    let defaultModel: String    // model to pre-fill on selection; "" for custom
    /// Whether the provider accepts the Kimi-style `thinking` body param.
    /// Reasoning mode is only offered / sent for providers where this is true.
    let supportsReasoning: Bool
    /// Which wire protocol this provider speaks. Defaults to OpenAI-compatible;
    /// only Anthropic opts into `.anthropicMessages`.
    var apiStyle: LLMAPIStyle = .openAIChat
}

extension LLMProvider {
    static let catalog: [LLMProvider] = [
        LLMProvider(id: "qianfan", label: "Qianfan / Kimi",
                    baseURL: "https://qianfan.baidubce.com/v2/coding",
                    defaultModel: "kimi-k2.5", supportsReasoning: true),
        LLMProvider(id: "openai", label: "OpenAI",
                    baseURL: "https://api.openai.com/v1",
                    defaultModel: "gpt-4o-mini", supportsReasoning: false),
        LLMProvider(id: "ollama", label: "Ollama (local)",
                    baseURL: "http://localhost:11434/v1",
                    defaultModel: "llama3.1", supportsReasoning: false),
        LLMProvider(id: "anthropic", label: "Anthropic (Claude)",
                    baseURL: "https://api.anthropic.com/v1",
                    defaultModel: "claude-sonnet-4-6", supportsReasoning: false,
                    apiStyle: .anthropicMessages),
        LLMProvider(id: "custom", label: "Custom…",
                    baseURL: "", defaultModel: "", supportsReasoning: false),
    ]

    /// All catalog ids.
    static var allIDs: [String] { catalog.map(\.id) }

    /// Look up a provider by its persisted id.
    static func byID(_ id: String) -> LLMProvider? {
        catalog.first { $0.id == id }
    }

    /// Whether the provider for `id` accepts a reasoning/thinking parameter.
    /// Unknown ids (e.g. stale config) are treated as non-reasoning.
    static func supportsReasoning(_ id: String) -> Bool {
        byID(id)?.supportsReasoning ?? false
    }

    /// The wire protocol declared by the provider `id`. Unknown ids (e.g. a
    /// stale config) fall back to OpenAI-compatible.
    static func apiStyle(_ id: String) -> LLMAPIStyle {
        byID(id)?.apiStyle ?? .openAIChat
    }

    /// Resolve the wire protocol for an effective base URL + provider id. The
    /// endpoint host is what actually determines the protocol, so an Anthropic
    /// base URL wins (even on a `custom` profile or a `--llm-base-url`
    /// override); otherwise the provider's declared style applies.
    static func apiStyle(baseURL: String, providerID: String) -> LLMAPIStyle {
        if let host = URL(string: baseURL)?.host?.lowercased(),
           host.contains("anthropic") {
            return .anthropicMessages
        }
        return apiStyle(providerID)
    }
}

// A saved, switchable LLM configuration ("profile"). The app stores a list of
// these (Config.llmProfiles) plus which one is active (Config.selectedLLMProfileID),
// so each provider — including any number of fully custom ones — keeps its own
// model/base URL/reasoning settings and, via APIKeyStore, its own API key.
struct LLMProfile: Codable, Equatable, Identifiable {
    var id: String              // stable, assigned once at creation; keys the API-key store
    var name: String            // user label, e.g. "Work Kimi", "Company-internal"
    var providerID: String      // preset id (see LLMProvider.catalog) or "custom"
    var model: String
    var baseURL: String
    var reasoningEnabled: Bool
    var reasoningBudgetTokens: Int

    init(
        id: String = UUID().uuidString,
        name: String,
        providerID: String,
        model: String,
        baseURL: String,
        reasoningEnabled: Bool = false,
        reasoningBudgetTokens: Int = 32_000
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.model = model
        self.baseURL = baseURL
        self.reasoningEnabled = reasoningEnabled
        self.reasoningBudgetTokens = reasoningBudgetTokens
    }

    /// Whether this profile's provider accepts the reasoning/thinking parameter.
    var supportsReasoning: Bool { LLMProvider.supportsReasoning(providerID) }

    /// Which wire protocol `Summarizer` should speak for this profile.
    var apiStyle: LLMAPIStyle {
        LLMProvider.apiStyle(baseURL: baseURL, providerID: providerID)
    }

    /// Display name: the user's label if set, else the preset's label, else the raw id.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return LLMProvider.byID(providerID)?.label ?? providerID
    }

    /// Seeded once, with a fixed (non-random) id so the default config's
    /// `llmProfiles` and `selectedLLMProfileID` always agree on a fresh install.
    static func defaultProfile() -> LLMProfile {
        LLMProfile(
            id: "default-qianfan",
            name: "Qianfan / Kimi",
            providerID: "qianfan",
            model: "kimi-k2.5",
            baseURL: "https://qianfan.baidubce.com/v2/coding"
        )
    }
}
