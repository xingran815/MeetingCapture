import Foundation

// The wire protocol a provider speaks. Almost everything is OpenAI-compatible
// `/chat/completions`; Anthropic is the exception — it has its own `/messages`
// shape (x-api-key header, required max_tokens, top-level `system`, and a
// `content[].text` response). `Summarizer` branches on this.
enum LLMAPIStyle: String, Codable {
    case openAIChat          // POST {base}/chat/completions, Bearer auth
    case anthropicMessages   // POST {base}/messages, x-api-key + anthropic-version
}

// How a provider expresses a reasoning/thinking request on the wire. Each shape
// is genuinely different, so `Summarizer` serializes per style:
//   .kimi      → `thinking: {type:"enabled", budget_tokens:N}` on the chat body
//   .openai    → `reasoning_effort: "low"|"medium"|"high"` on the chat body
//   .anthropic → `thinking: {type:"adaptive"}` + `output_config:{effort:…}` on /messages
//   .none      → provider has no reasoning mode; nothing is sent
// Raw values are persisted (per-profile override), so keep them stable.
enum ReasoningStyle: String, Codable {
    case none, kimi, openai, anthropic

    /// Short label for the Settings editor.
    var label: String {
        switch self {
        case .none:      return "none"
        case .kimi:      return "kimi"
        case .openai:    return "openai"
        case .anthropic: return "anthropic"
        }
    }
}

// The single, unified "depth" knob the user sets per profile. Each provider maps
// it to its own parameter (token budget for Kimi, effort level for OpenAI and
// Anthropic). Raw values are persisted; `low`/`medium`/`high` double as the
// OpenAI/Anthropic effort strings.
enum ReasoningEffort: String, Codable, CaseIterable {
    case off, low, medium, high

    var isOn: Bool { self != .off }

    /// Kimi-style `budget_tokens` for each level (unused when `.off`).
    var budgetTokens: Int {
        switch self {
        case .off:    return 0
        case .low:    return 8_000
        case .medium: return 16_000
        case .high:   return 32_000
        }
    }
}

// Catalog of selectable LLM providers for summarization.
//
// Most entries speak the OpenAI-compatible `/chat/completions` protocol; the
// Anthropic entry is the exception (`apiStyle == .anthropicMessages`). A
// provider is a base URL + a sensible default model + which reasoning wire
// format it speaks (if any) + which wire protocol it speaks.
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
    /// Which reasoning wire format this provider speaks (`.none` if it has no
    /// reasoning mode). Host-aware resolution lives in `reasoningStyle(baseURL:providerID:)`.
    let reasoningStyle: ReasoningStyle
    /// Which wire protocol this provider speaks. Defaults to OpenAI-compatible;
    /// only Anthropic opts into `.anthropicMessages`.
    var apiStyle: LLMAPIStyle = .openAIChat
}

extension LLMProvider {
    static let catalog: [LLMProvider] = [
        LLMProvider(id: "qianfan", label: "Qianfan / Kimi",
                    baseURL: "https://qianfan.baidubce.com/v2/coding",
                    defaultModel: "kimi-k2.5", reasoningStyle: .kimi),
        LLMProvider(id: "openai", label: "OpenAI",
                    baseURL: "https://api.openai.com/v1",
                    defaultModel: "gpt-4o-mini", reasoningStyle: .openai),
        LLMProvider(id: "ollama", label: "Ollama (local)",
                    baseURL: "http://localhost:11434/v1",
                    defaultModel: "llama3.1", reasoningStyle: .none),
        LLMProvider(id: "anthropic", label: "Anthropic (Claude)",
                    baseURL: "https://api.anthropic.com/v1",
                    defaultModel: "claude-sonnet-4-6", reasoningStyle: .anthropic,
                    apiStyle: .anthropicMessages),
        LLMProvider(id: "custom", label: "Custom…",
                    baseURL: "", defaultModel: "", reasoningStyle: .none),
    ]

    /// All catalog ids.
    static var allIDs: [String] { catalog.map(\.id) }

    /// Look up a provider by its persisted id.
    static func byID(_ id: String) -> LLMProvider? {
        catalog.first { $0.id == id }
    }

    /// The reasoning wire format declared by the provider `id`. Unknown ids
    /// (e.g. a stale config) have no reasoning mode.
    static func reasoningStyle(_ id: String) -> ReasoningStyle {
        byID(id)?.reasoningStyle ?? .none
    }

    /// Resolve the reasoning format for an effective base URL + provider id. The
    /// endpoint host is what actually determines the format, so a recognized host
    /// wins (even on a `custom` profile or a `--llm-base-url` override) — mirroring
    /// `apiStyle(baseURL:providerID:)`; otherwise the provider's declared style applies.
    static func reasoningStyle(baseURL: String, providerID: String) -> ReasoningStyle {
        if let host = URL(string: baseURL)?.host?.lowercased() {
            if host.contains("anthropic") { return .anthropic }
            if host.contains("qianfan") || host.contains("baidubce") { return .kimi }
            if host.contains("openai") { return .openai }
        }
        return reasoningStyle(providerID)
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
    /// Unified reasoning depth: one knob each provider maps to its own param.
    var reasoningEffort: ReasoningEffort
    /// Optional manual reasoning-format override. `nil` means auto-detect from the
    /// base URL host / preset (see `effectiveReasoningStyle`); set it to force a
    /// format on an unrecognized custom endpoint.
    var reasoningStyleOverride: ReasoningStyle?

    init(
        id: String = UUID().uuidString,
        name: String,
        providerID: String,
        model: String,
        baseURL: String,
        reasoningEffort: ReasoningEffort = .off,
        reasoningStyleOverride: ReasoningStyle? = nil
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.model = model
        self.baseURL = baseURL
        self.reasoningEffort = reasoningEffort
        self.reasoningStyleOverride = reasoningStyleOverride
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, providerID, model, baseURL
        case reasoningEffort, reasoningStyleOverride
    }

    /// Pre-effort per-profile keys, decoded as a fallback so older profiles
    /// migrate transparently. Kept out of CodingKeys so they're never re-encoded.
    private enum LegacyKeys: String, CodingKey {
        case reasoningEnabled, reasoningBudgetTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        providerID = try c.decode(String.self, forKey: .providerID)
        model = try c.decode(String.self, forKey: .model)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        reasoningStyleOverride = try c.decodeIfPresent(ReasoningStyle.self, forKey: .reasoningStyleOverride)
        if let effort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort) {
            reasoningEffort = effort
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self) {
            let enabled = (try? legacy.decode(Bool.self, forKey: .reasoningEnabled)) ?? false
            let budget = (try? legacy.decode(Int.self, forKey: .reasoningBudgetTokens)) ?? 32_000
            reasoningEffort = LLMProfile.effort(fromLegacyEnabled: enabled, budget: budget)
        } else {
            reasoningEffort = .off
        }
    }

    /// Map a pre-effort (enabled, budget_tokens) pair to the nearest effort level.
    static func effort(fromLegacyEnabled enabled: Bool, budget: Int) -> ReasoningEffort {
        guard enabled else { return .off }
        if budget < 12_000 { return .low }
        if budget < 24_000 { return .medium }
        return .high
    }

    /// The reasoning format actually used for this profile: an explicit override
    /// wins, otherwise auto-detect from the base URL host / preset.
    var effectiveReasoningStyle: ReasoningStyle {
        reasoningStyleOverride ?? LLMProvider.reasoningStyle(baseURL: baseURL, providerID: providerID)
    }

    /// Whether this profile has any reasoning mode (after detect + override).
    var supportsReasoning: Bool { effectiveReasoningStyle != .none }

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
