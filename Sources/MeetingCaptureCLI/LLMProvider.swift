import Foundation

// Catalog of selectable LLM providers for summarization.
//
// All entries speak the OpenAI-compatible `/chat/completions` protocol; a
// provider is just a base URL + a sensible default model + whether it accepts
// the Kimi-style `thinking` reasoning parameter. Picking a preset in Settings
// pre-fills the base URL and model (both still individually editable). The
// "Custom" entry leaves them blank for a fully user-supplied endpoint.
//
// The chosen provider is persisted as Config.llmProviderID. Base URL / model
// remain free-form (Config.llmBaseURL / Config.llmModel) so power users — and
// the --llm-base-url / --llm-model flags — can override any preset.
struct LLMProvider: Identifiable {
    let id: String              // stable key persisted in config
    let label: String           // human-readable name shown in Settings
    let baseURL: String         // OpenAI-compatible base; "" for custom
    let defaultModel: String    // model to pre-fill on selection; "" for custom
    /// Whether the provider accepts the Kimi-style `thinking` body param.
    /// Reasoning mode is only offered / sent for providers where this is true.
    let supportsReasoning: Bool
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
}
