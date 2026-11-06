import Foundation

// What a call to a subscription CLI looks like: which CLI, which tier, the exact
// arguments, and how to read what comes back. Everything here is pure, so it can
// be tested without starting a process. CLIRunner does the running.

enum CLIKind: String, Codable, CaseIterable {
    case claude, codex

    var other: CLIKind { self == .claude ? .codex : .claude }
    var label: String { self == .claude ? "Claude" : "Codex" }
}

enum ModelTier: String, Codable, CaseIterable {
    case cheap, normal, frontier
}

/// Model names for one CLI. They live in config because they change.
struct CLITierModels: Codable, Equatable {
    var cheap: String
    var normal: String
    var frontier: String

    static let claudeDefault = CLITierModels(cheap: "haiku", normal: "sonnet", frontier: "opus")
    static let codexDefault = CLITierModels(cheap: "gpt-6-luna", normal: "gpt-6.1-sol", frontier: "gpt-6-astra")

    func model(for tier: ModelTier) -> String {
        switch tier {
        case .cheap: return cheap
        case .normal: return normal
        case .frontier: return frontier
        }
    }
}

/// One model call. Tools can't be switched on for a call that takes free text:
/// the only way to get a tool is `conceptSearch`, whose prompt is built here from
/// short concept names, so transcript text has no route into a call with tools.
struct CLIRequest {
    let tier: ModelTier
    let system: String
    let input: String
    let schema: String?
    let webSearch: Bool

    private init(tier: ModelTier, system: String, input: String, schema: String?, webSearch: Bool) {
        self.tier = tier
        self.system = system
        self.input = input
        self.schema = schema
        self.webSearch = webSearch
    }

    static func text(tier: ModelTier, system: String, input: String, schema: String? = nil) -> CLIRequest {
        CLIRequest(tier: tier, system: system, input: input, schema: schema, webSearch: false)
    }

    static func conceptSearch(tier: ModelTier, concepts: [String]) throws -> CLIRequest {
        try validate(concepts: concepts)
        let list = concepts.map { "- \($0)" }.joined(separator: "\n")
        return CLIRequest(
            tier: tier,
            system: "You look up general reference sources for concepts. Reply with one reliable source URL per concept. If you aren't sure of a source, say so.",
            input: "Find a reliable general reference for each concept:\n\(list)",
            schema: nil,
            webSearch: true)
    }

    /// Refuses anything that doesn't look like a generic concept name. This is a
    /// backstop and can't tell a concept from a short private phrase, so callers
    /// must still pass only concept names (D-13).
    static func validate(concepts: [String]) throws {
        guard !concepts.isEmpty, concepts.count <= 8 else {
            throw CLIError.badRequest("A concept search takes 1 to 8 concepts.")
        }
        for concept in concepts {
            let words = concept.split(whereSeparator: \.isWhitespace)
            let bad = concept.count > 60 || words.count > 6 || words.isEmpty
                || concept.contains(where: { $0.isNumber || $0.isNewline || "@<>[]{}:/\"".contains($0) })
            if bad {
                throw CLIError.badRequest("A concept search refused text that isn't a short concept name.")
            }
        }
    }
}

enum CLIError: Error, LocalizedError, Equatable {
    case notInstalled(CLIKind)
    case notLoggedIn(CLIKind)
    /// The CLI would bill an API key rather than the subscription.
    case apiBillingRefused(CLIKind, String)
    case usageFull(CLIKind, resetsAt: Date?)
    case failed(CLIKind, String)
    case timedOut(CLIKind)
    case badRequest(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let c): return "\(c.label) CLI isn't installed."
        case .notLoggedIn(let c): return "\(c.label) CLI isn't logged in."
        case .apiBillingRefused(let c, let source):
            return "Refusing to run \(c.label): it would bill an API key (\(source)), not your subscription."
        case .usageFull(let c, _): return "\(c.label) usage is full."
        case .failed(let c, let message): return "\(c.label) failed: \(message)"
        case .timedOut(let c): return "\(c.label) timed out."
        case .badRequest(let message): return message
        }
    }
}

/// The latest usage limits a CLI reported.
struct RateLimitSnapshot: Codable, Equatable {
    var status: String
    var resetsAt: Date?
    /// Window name (`five_hour`, `seven_day`) to fraction used, 0 to 1.
    var windows: [String: Double]
}

struct CLIResult {
    let cli: CLIKind
    let model: String
    let text: String
    let apiKeySource: String?
    /// Counted from tool-use events, because `web_search_requests` reports 0 even when the tool ran.
    let webSearchCount: Int
    let rateLimit: RateLimitSnapshot?
}

// MARK: - Arguments

enum CLIArguments {

    /// Model names come from a config file and land in an argument list.
    static func isSafeModelName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:\-\[\]]*$"#, options: .regularExpression) != nil
    }

    static func claude(_ request: CLIRequest, model: String) -> [String] {
        var args = ["-p", "--safe-mode", "--strict-mcp-config", "--no-session-persistence"]
        if request.webSearch {
            args += ["--tools", "WebSearch", "--allowedTools", "WebSearch"]
        } else {
            args += ["--tools", ""]
        }
        args += ["--model", model, "--output-format", "stream-json", "--verbose"]
        if let schema = request.schema { args += ["--json-schema", schema] }
        args += ["--system-prompt", request.system]
        return args
    }

    /// Features that may stay on, from Job Radar's `CODEX_BENIGN_FEATURES`.
    /// Every other feature the installed Codex lists is switched off.
    static let codexBenignFeatures: Set<String> = [
        "enable_request_compression", "content_item_kinds", "compaction_image_budget",
        "unbounded_connection_retries", "fast_mode", "api_key_model_discovery", "auth_elicitation",
        "guardian_approval", "guardian_reuse_parent_compaction",
    ]

    /// Always off, and the whole list if `codex features list` can't be read.
    /// From Job Radar's `CODEX_FEATURES_FALLBACK_OFF`.
    static let codexFeaturesAlwaysOff: [String] = [
        "shell_tool", "unified_exec", "unified_exec_tty", "write_stdin_approval", "shell_snapshot",
        "multi_agent", "multi_agent_v2", "plugins", "remote_plugin", "plugin_sharing", "apps", "memories",
        "image_generation", "browser_use", "browser_use_external", "browser_use_full_cdp_access",
        "browser_annotation_api", "computer_use", "in_app_browser", "in_app_chat", "in_app_local_automation",
        "view_image", "tool_suggest", "tool_call_mcp_elicitation", "skill_search",
        "skill_mcp_dependency_install", "goals", "sleep_tool", "hooks", "code_mode", "code_mode_host",
        "workspace_dependencies", "worktrees", "mentions_v2", "realtime_conversation", "daemon_auto_start",
        "standalone_web_search", "request_permissions_tool", "network_proxy",
    ]

    static func codexFeaturesOff(listed: [String]) -> [String] {
        var seen = Set<String>()
        return (listed.filter { !codexBenignFeatures.contains($0) } + codexFeaturesAlwaysOff)
            .filter { seen.insert($0).inserted }
    }

    /// `name  stage  enabled` rows from `codex features list`.
    static func parseCodexFeatureList(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard columns.count >= 3, let last = columns.last, last == "true" || last == "false",
                  columns[0].range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil
            else { return nil }
            return columns[0]
        }
    }

    static func codex(
        _ request: CLIRequest, model: String, cwd: String,
        schemaPath: String?, instructionsPath: String, featuresOff: [String]
    ) -> [String] {
        var args = [
            "exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
            "--ignore-user-config", "--ignore-rules", "-C", cwd, "-m", model,
        ]
        if let schemaPath { args += ["--output-schema", schemaPath] }
        if request.tier == .cheap { args += ["-c", "model_reasoning_effort=\"low\""] }
        // Trim Codex's own context. Without this a one-word answer costs about 15k input tokens.
        args += [
            "-c", "model_instructions_file=\(tomlString(instructionsPath))",
            "-c", "skills.include_instructions=false",
            "-c", "agents.enabled=false",
            "-c", "include_permissions_instructions=false",
            "-c", "include_environment_context=false",
        ]
        // Codex 0.163 runs hosted search through this host. With it off, search fails
        // and the model answers from memory with an unverified URL, as seen live. The
        // shell stays off, so a page read during a search can't reach local files.
        let keptOn: Set<String> = request.webSearch ? ["code_mode_host"] : []
        for feature in featuresOff where !keptOn.contains(feature) {
            args += ["-c", "features.\(feature)=false"]
        }
        // Last, so nothing above can switch a tool back on.
        args += [
            "-c", request.webSearch ? "web_search=\"live\"" : "web_search=\"disabled\"",
            "-c", "include_apply_patch_tool=false",
            "-c", "tools.view_image=false",
            "-c", "approval_policy=\"never\"",
            "-",
        ]
        return args
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

// MARK: - Output

/// What a CLI's JSON event stream said.
struct ParsedCLIOutput: Equatable {
    var text: String?
    var hasStructuredOutput = false
    var apiKeySource: String?
    var isError = false
    var errorText: String?
    var httpStatus: Int?
    var rateLimit: RateLimitSnapshot?
    var webSearchCount = 0
}

enum CLIOutcome: Equatable {
    case ok
    case usageFull(resetsAt: Date?)
    case failed(String)
}

enum CLIOutputParser {

    /// From Job Radar's `QUOTA_PATTERN`. Only ever matched against a CLI's error
    /// text, never the model's answer, which may well discuss rate limits.
    static let quotaPattern = "(?i)rate.?limit|usage limit|session limit|hit your (?:\\w+ )?limit|limit reached|limit will reset|too many requests|quota|out of (?:credits|usage)|usage cap|insufficient_quota"

    static func looksLikeQuota(_ text: String) -> Bool {
        text.range(of: quotaPattern, options: .regularExpression) != nil
    }

    private static func events(_ output: String) -> [[String: Any]] {
        output.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object
        }
    }

    static func parseClaude(_ output: String) -> ParsedCLIOutput {
        var parsed = ParsedCLIOutput()
        for event in events(output) {
            switch event["type"] as? String {
            case "system":
                if event["subtype"] as? String == "init" {
                    parsed.apiKeySource = event["apiKeySource"] as? String
                }
            case "rate_limit_event":
                if let info = event["rate_limit_info"] as? [String: Any] {
                    parsed.rateLimit = claudeRateLimit(info)
                }
            case "assistant":
                let message = event["message"] as? [String: Any]
                let blocks = message?["content"] as? [[String: Any]] ?? []
                parsed.webSearchCount += blocks.filter {
                    ($0["type"] as? String) == "tool_use" && ($0["name"] as? String) == "WebSearch"
                }.count
            case "result":
                parsed.isError = event["is_error"] as? Bool ?? false
                parsed.httpStatus = event["api_error_status"] as? Int
                if let structured = event["structured_output"], !(structured is NSNull),
                   JSONSerialization.isValidJSONObject(structured),
                   let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
                    parsed.text = String(decoding: data, as: UTF8.self)
                    parsed.hasStructuredOutput = true
                } else if let result = event["result"] as? String {
                    parsed.text = result
                }
                if parsed.isError {
                    parsed.errorText = (event["result"] as? String) ?? (event["subtype"] as? String)
                }
            default:
                break
            }
        }
        return parsed
    }

    private static func claudeRateLimit(_ info: [String: Any]) -> RateLimitSnapshot {
        var windows: [String: Double] = [:]
        for (name, value) in info["unifiedWindows"] as? [String: Any] ?? [:] {
            if let utilization = (value as? [String: Any])?["utilization"] as? Double {
                windows[name] = utilization
            }
        }
        return RateLimitSnapshot(
            status: info["status"] as? String ?? "unknown",
            resetsAt: (info["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
            windows: windows)
    }

    static func parseCodex(_ output: String) -> ParsedCLIOutput {
        var parsed = ParsedCLIOutput()
        for event in events(output) {
            switch event["type"] as? String {
            case "item.completed", "item.started":
                let item = event["item"] as? [String: Any] ?? [:]
                let completed = event["type"] as? String == "item.completed"
                if completed, item["type"] as? String == "agent_message", let text = item["text"] as? String {
                    parsed.text = text
                }
                if completed, item["type"] as? String == "web_search" { parsed.webSearchCount += 1 }
            case "turn.failed":
                parsed.isError = true
                parsed.errorText = (event["error"] as? [String: Any])?["message"] as? String ?? parsed.errorText
            case "error":
                parsed.isError = true
                parsed.errorText = event["message"] as? String ?? parsed.errorText
            default:
                break
            }
        }
        return parsed
    }

    /// Decides what a finished process means. Fallback hangs off `.usageFull`, so
    /// it must only come from a limit the CLI reported or its error text.
    static func outcome(of parsed: ParsedCLIOutput, exitCode: Int32, stderr: String) -> CLIOutcome {
        let failed = exitCode != 0 || parsed.isError || parsed.text == nil
        guard failed else { return .ok }
        let errorText = [parsed.errorText, stderr].compactMap { $0 }.joined(separator: "\n")
        if parsed.rateLimit?.status == "rejected" || parsed.httpStatus == 429 || looksLikeQuota(errorText) {
            return .usageFull(resetsAt: parsed.rateLimit?.resetsAt)
        }
        let trimmed = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(trimmed.isEmpty ? "exit code \(exitCode), no answer" : trimmed)
    }
}
