import Foundation

// The one path from transcript to summary, used by the terminal shell and flag
// mode: redact, pick a style, summarize, restore. Nothing reaches a backend
// without going through here first.

protocol SummaryBackend: AnyObject {
    func detectStyle(transcript: String) async throws -> SummaryStyle
    func summarize(transcript: String, style: SummaryStyle, systemSuffix: String) async throws -> String
    /// Things the report should say, such as a switch to the other CLI.
    var notes: [String] { get }
    var label: String { get }
}

/// Runs on the subscription CLIs, with tools off: cheap tier picks the style,
/// normal tier writes the summary.
final class CLISummaryBackend: SummaryBackend {
    let router: LLMRouter
    var notes: [String] { router.notes }
    let label = "subscription CLI"

    init(router: LLMRouter) { self.router = router }

    func detectStyle(transcript: String) async throws -> SummaryStyle {
        let result = try await router.call(
            .text(
                tier: .cheap, system: Summarizer.classifierPrompt, input: String(transcript.prefix(6000))))
        return result.text.lowercased().contains("therapy") ? .therapy : .meeting
    }

    func summarize(transcript: String, style: SummaryStyle, systemSuffix: String) async throws -> String {
        let result = try await router.call(
            .text(
                tier: .normal, system: Summarizer.systemPrompt(for: style) + systemSuffix, input: transcript))
        return result.text
    }
}

/// Runs on one saved API profile. A profile has one model, so tiers don't apply.
final class APISummaryBackend: SummaryBackend {
    let summarizer: Summarizer
    let notes: [String] = []
    let label: String

    init(summarizer: Summarizer, label: String) {
        self.summarizer = summarizer
        self.label = label
    }

    func detectStyle(transcript: String) async throws -> SummaryStyle {
        try await summarizer.detectStyle(transcript: transcript)
    }

    func summarize(transcript: String, style: SummaryStyle, systemSuffix: String) async throws -> String {
        try await summarizer.summarize(transcript: transcript, style: style, systemSuffix: systemSuffix)
    }
}

struct SummaryOutcome {
    let markdown: String
    let style: SummaryStyle
    let redactedValues: Int
    let flaggedTokens: [String]
    let notes: [String]

    /// The summary as saved, with anything the reader should know at the end.
    var report: String {
        var lines: [String] = []
        if !flaggedTokens.isEmpty {
            lines.append(
                "Couldn't restore these tokens, so they're left as they are: \(flaggedTokens.joined(separator: ", ")).")
        }
        lines += notes
        guard !lines.isEmpty else { return markdown }
        return markdown + "\n\n---\n" + lines.map { "> Note: \($0)" }.joined(separator: "\n")
    }
}

struct SummaryPipeline {
    let backend: SummaryBackend
    let redaction: Bool

    func run(transcript: String, forcedStyle: SummaryStyle? = nil) async throws -> SummaryOutcome {
        // A model handed nothing invents a meeting, and that spends usage too.
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Summarizer.SummarizerError.badResponse("The transcript is empty, so there's nothing to summarize.")
        }
        let redacted =
            redaction
            ? Redactor.redact(transcript)
            : Redactor.Result(text: transcript, tokens: [:])
        let suffix = redacted.tokens.isEmpty ? "" : Redactor.tokenInstruction

        // A failed classifier isn't fatal: fall back to a meeting summary. If usage
        // is full, the summarize call below reports it.
        var style = forcedStyle
        if style == nil { style = (try? await backend.detectStyle(transcript: redacted.text)) ?? .meeting }

        let answer = try await backend.summarize(transcript: redacted.text, style: style!, systemSuffix: suffix)
        let restored =
            redaction
            ? Redactor.restore(answer, tokens: redacted.tokens)
            : Redactor.Restored(text: answer, flagged: [])
        return SummaryOutcome(
            markdown: restored.text, style: style!, redactedValues: redacted.tokens.count,
            flaggedTokens: restored.flagged, notes: backend.notes)
    }
}

/// Chooses the backend. API profiles are used only when asked for or when no CLI
/// is ready; a CLI that's merely full never moves a run onto API billing.
enum SummaryRoute {

    /// Flag-mode overrides, which ask for an API profile by their presence.
    struct APIOverrides {
        var profile: LLMProfile?
        var model: String?
        var baseURL: String?
        var apiKeyFlag: String?
        var isEmpty: Bool { profile == nil && model == nil && baseURL == nil && apiKeyFlag == nil }
    }

    static func makeRouter(config: Config, primary: CLIKind? = nil) -> LLMRouter {
        let runner = CLIRunner(
            models: [.claude: config.claudeModels, .codex: config.codexModels],
            allowAPIBilling: config.allowCLIAPIBilling)
        return LLMRouter(
            runner: runner, ledger: UsageLedger(),
            primary: primary ?? config.primaryCLI, cap: config.dailyCLICallCap)
    }

    static func backend(
        config: Config, primary: CLIKind? = nil, overrides: APIOverrides = APIOverrides()
    ) async throws -> SummaryBackend {
        if config.llmRoute == .apiProfile || !overrides.isEmpty {
            return try apiBackend(config: config, overrides: overrides)
        }
        let router = makeRouter(config: config, primary: primary)
        if await router.hasReadyCLI() { return CLISummaryBackend(router: router) }
        // Row 4 of the provider order: no CLI, so use the chosen profile if it can run.
        if !config.llmProfiles.isEmpty {
            return try apiBackend(config: config, overrides: overrides)
        }
        // Asks the router, for its reasons.
        _ = try await router.call(.text(tier: .cheap, system: "", input: ""))
        throw LLMRouter.RouterError.noCLI([])
    }

    private static func apiBackend(config: Config, overrides: APIOverrides) throws -> SummaryBackend {
        let profile = overrides.profile ?? config.activeLLMProfile
        let baseURLString = overrides.baseURL ?? profile.baseURL
        guard Config.resolveApiKey(profileID: profile.id, flag: overrides.apiKeyFlag) != nil else {
            throw Summarizer.SummarizerError.badResponse(
                "No LLM API key for \"\(profile.displayName)\". Store one via Settings → LLM configurations, export LLM_API_KEY, or log in to the claude or codex CLI."
            )
        }
        guard let baseURL = URL(string: baseURLString) else {
            throw Summarizer.SummarizerError.badResponse("Invalid LLM base URL: \(baseURLString)")
        }
        let flag = overrides.apiKeyFlag
        let id = profile.id
        return APISummaryBackend(
            summarizer: Summarizer(
                baseURL: baseURL,
                apiKeyProvider: { Config.resolveApiKey(profileID: id, flag: flag) },
                model: overrides.model ?? profile.model,
                apiStyle: LLMProvider.apiStyle(baseURL: baseURLString, providerID: profile.providerID),
                reasoningStyle: profile.reasoningStyleOverride
                    ?? LLMProvider.reasoningStyle(baseURL: baseURLString, providerID: profile.providerID),
                reasoningEffort: profile.reasoningEffort),
            label: profile.displayName)
    }
}
