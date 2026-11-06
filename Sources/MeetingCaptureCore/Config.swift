import Foundation

// Persisted user settings for MeetingCapture.
//
// Stored as JSON at ~/.config/MeetingCapture/config.json. The API key is NOT
// kept in this JSON — it lives in its own 0600 file (see APIKeyStore) so the
// config stays safe to inspect/share. Configs written by older versions at the
// legacy ~/Library/Application Support path are migrated forward on first load.
/// Where summaries run. Subscription CLIs by default; an API profile only on request,
/// or when no CLI is ready. See `SummaryRoute`.
enum LLMRoute: String, Codable {
    case subscription, apiProfile
}

struct Config: Codable, Equatable {

    // Capture & transcription
    var whisperModel: String            = "openai_whisper-small.en"
    /// 2-letter language hint (e.g. "en", "zh"). nil = auto-detect (only safe for `.en` models).
    var whisperLanguage: String?        = nil
    var defaultDurationMinutes: Int     = 480
    var outputDirectory: String         = "~/Documents/MeetingCapture"
    var autoTranscribe: Bool            = true
    var autoSummarize: Bool             = true
    var aecEnabled: Bool                = true
    var micEnabled: Bool                = true
    /// Meeting-app ids eligible for SCStream auto-detection (see MeetingApp.catalog).
    /// Empty / none-running → capture falls back to all system audio.
    var enabledMeetingAppIDs: [String]  = MeetingApp.allIDs
    /// When true, capture ALL system audio regardless of which meeting apps are
    /// running — the app auto-detection is bypassed entirely.
    var captureAllAudio: Bool           = false

    // LLM — a tree of named, switchable configurations. Each profile carries its
    // own provider/model/base URL/reasoning settings; its API key lives in
    // APIKeyStore keyed by profile.id. Exactly one profile is "active" at a time
    // (selectedLLMProfileID); Settings → LLM configurations switches between them.
    var llmProfiles: [LLMProfile]       = []
    var selectedLLMProfileID: String    = ""

    // Subscription CLIs (docs/specs/02-llm-providers.md).
    var llmRoute: LLMRoute              = .subscription
    var primaryCLI: CLIKind             = .claude
    var dailyCLICallCap: Int            = UsageLedger.defaultCap
    var claudeModels: CLITierModels     = .claudeDefault
    var codexModels: CLITierModels      = .codexDefault
    /// Lets a CLI run even though it would bill an API key. Off unless set in config.json.
    var allowCLIAPIBilling: Bool        = false
    /// Replace formatted sensitive values with tokens before any LLM call.
    var redactionEnabled: Bool          = true

    static let `default` = Config()

    // Memberwise initializer (for creating defaults).
    init(
        whisperModel: String = "openai_whisper-small.en",
        whisperLanguage: String? = nil,
        defaultDurationMinutes: Int = 480,
        outputDirectory: String = "~/Documents/MeetingCapture",
        autoTranscribe: Bool = true,
        autoSummarize: Bool = true,
        aecEnabled: Bool = true,
        micEnabled: Bool = true,
        enabledMeetingAppIDs: [String] = MeetingApp.allIDs,
        captureAllAudio: Bool = false,
        llmProfiles: [LLMProfile] = [],
        selectedLLMProfileID: String = ""
    ) {
        self.whisperModel = whisperModel
        self.whisperLanguage = whisperLanguage
        self.defaultDurationMinutes = defaultDurationMinutes
        self.outputDirectory = outputDirectory
        self.autoTranscribe = autoTranscribe
        self.autoSummarize = autoSummarize
        self.aecEnabled = aecEnabled
        self.micEnabled = micEnabled
        self.enabledMeetingAppIDs = enabledMeetingAppIDs
        self.captureAllAudio = captureAllAudio
        self.llmProfiles = llmProfiles
        self.selectedLLMProfileID = selectedLLMProfileID
    }

    // Custom decoder provides defaults for missing keys (backward compat).
    enum CodingKeys: String, CodingKey {
        case whisperModel, whisperLanguage, defaultDurationMinutes, outputDirectory
        case autoTranscribe, autoSummarize, aecEnabled, micEnabled, enabledMeetingAppIDs
        case captureAllAudio
        case llmProfiles, selectedLLMProfileID
        case llmRoute, primaryCLI, dailyCLICallCap, claudeModels, codexModels
        case allowCLIAPIBilling, redactionEnabled
    }

    /// Pre-multi-profile keys, decoded as a fallback so older configs migrate
    /// transparently into a single LLMProfile. Kept out of CodingKeys so
    /// they're never re-encoded.
    private enum LegacyKeys: String, CodingKey {
        case llmProviderID, llmCustomName, llmModel, llmBaseURL
        case reasoningEnabled, reasoningBudgetTokens
        case kimiThinkingEnabled, kimiThinkingBudgetTokens
    }

    /// Fixed id assigned to the single profile synthesized from a pre-multi-profile config.
    static let migratedLegacyProfileID = "migrated-legacy"

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? "openai_whisper-small.en"
        whisperLanguage = try c.decodeIfPresent(String.self, forKey: .whisperLanguage)
        defaultDurationMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultDurationMinutes) ?? 480
        outputDirectory = try c.decodeIfPresent(String.self, forKey: .outputDirectory) ?? "~/Documents/MeetingCapture"
        autoTranscribe = try c.decodeIfPresent(Bool.self, forKey: .autoTranscribe) ?? true
        autoSummarize = try c.decodeIfPresent(Bool.self, forKey: .autoSummarize) ?? true
        aecEnabled = try c.decodeIfPresent(Bool.self, forKey: .aecEnabled) ?? true
        micEnabled = try c.decodeIfPresent(Bool.self, forKey: .micEnabled) ?? true
        enabledMeetingAppIDs = try c.decodeIfPresent([String].self, forKey: .enabledMeetingAppIDs) ?? MeetingApp.allIDs
        captureAllAudio = try c.decodeIfPresent(Bool.self, forKey: .captureAllAudio) ?? false

        llmRoute = try c.decodeIfPresent(LLMRoute.self, forKey: .llmRoute) ?? .subscription
        primaryCLI = try c.decodeIfPresent(CLIKind.self, forKey: .primaryCLI) ?? .claude
        dailyCLICallCap = try c.decodeIfPresent(Int.self, forKey: .dailyCLICallCap) ?? UsageLedger.defaultCap
        claudeModels = try c.decodeIfPresent(CLITierModels.self, forKey: .claudeModels) ?? .claudeDefault
        codexModels = try c.decodeIfPresent(CLITierModels.self, forKey: .codexModels) ?? .codexDefault
        allowCLIAPIBilling = try c.decodeIfPresent(Bool.self, forKey: .allowCLIAPIBilling) ?? false
        redactionEnabled = try c.decodeIfPresent(Bool.self, forKey: .redactionEnabled) ?? true

        if let profiles = try c.decodeIfPresent([LLMProfile].self, forKey: .llmProfiles) {
            llmProfiles = profiles
            selectedLLMProfileID = try c.decodeIfPresent(String.self, forKey: .selectedLLMProfileID)
                ?? profiles.first?.id ?? ""
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let providerID = try legacy.decodeIfPresent(String.self, forKey: .llmProviderID) {
            // Pre-multi-profile config: synthesize one profile from the old flat fields.
            let customName = try legacy.decodeIfPresent(String.self, forKey: .llmCustomName) ?? ""
            let model = try legacy.decodeIfPresent(String.self, forKey: .llmModel) ?? ""
            let baseURL = try legacy.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? ""
            var reasoning = try legacy.decodeIfPresent(Bool.self, forKey: .reasoningEnabled)
            var reasoningBudget = try legacy.decodeIfPresent(Int.self, forKey: .reasoningBudgetTokens)
            if reasoning == nil {
                reasoning = try? legacy.decodeIfPresent(Bool.self, forKey: .kimiThinkingEnabled)
            }
            if reasoningBudget == nil {
                reasoningBudget = try? legacy.decodeIfPresent(Int.self, forKey: .kimiThinkingBudgetTokens)
            }
            let name = providerID == "custom"
                ? (customName.trimmingCharacters(in: .whitespaces).isEmpty ? "Custom" : customName)
                : (LLMProvider.byID(providerID)?.label ?? providerID)
            let profile = LLMProfile(
                id: Self.migratedLegacyProfileID,
                name: name,
                providerID: providerID,
                model: model,
                baseURL: baseURL,
                reasoningEffort: LLMProfile.effort(fromLegacyEnabled: reasoning ?? false,
                                                   budget: reasoningBudget ?? 32_000)
            )
            llmProfiles = [profile]
            selectedLLMProfileID = profile.id
        } else {
            llmProfiles = []
            selectedLLMProfileID = ""
        }
    }

    static var path: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/MeetingCapture/config.json")
    }

    /// Pre-generalization location. Read once to migrate forward (see load()).
    static var legacyPath: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MeetingCapture/config.json")
    }

    /// Load from disk. Missing file → defaults (silent), unless a legacy config
    /// exists at the old Application Support path, in which case it's loaded and
    /// migrated to the new path. Corrupt file → defaults (warn, don't overwrite —
    /// the user may want to fix it by hand).
    static func load(at url: URL = Config.path, legacyURL: URL? = Config.legacyPath) -> Config {
        let fm = FileManager.default

        if !fm.fileExists(atPath: url.path), let legacyURL, fm.fileExists(atPath: legacyURL.path) {
            // One-time migration from ~/Library/Application Support → ~/.config.
            if let data = try? Data(contentsOf: legacyURL),
               let migrated = try? JSONDecoder().decode(Config.self, from: data) {
                let config = removingRemovedProviders(from: migrated)
                try? config.save(to: url)  // best-effort; original is left in place
                return config
            }
        }

        guard fm.fileExists(atPath: url.path) else { return Config() }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(Config.self, from: data)
            let config = removingRemovedProviders(from: decoded)
            // A pre-multi-profile file has no "llmProfiles" key; init(from:) just
            // synthesized one in memory. Rewrite the file now so the on-disk
            // schema is upgraded even if the user changes nothing this run.
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if raw?["llmProfiles"] == nil || config != decoded {
                try? config.save(to: url)
            }
            return config
        } catch {
            fputs("⚠  Config at \(url.path) is unreadable (\(error.localizedDescription)); using defaults.\n", stderr)
            return Config()
        }
    }

    /// Drops saved Qianfan and Kimi profiles and their key entries, with one notice.
    /// With nothing left, the CLI order applies, because the list is simply empty.
    static func removingRemovedProviders(from config: Config) -> Config {
        let removed = config.llmProfiles.filter(\.isRemovedProvider)
        guard !removed.isEmpty else { return config }
        var updated = config
        updated.llmProfiles.removeAll(where: \.isRemovedProvider)
        for profile in removed { APIKeyStore.delete(profileID: profile.id) }
        if !updated.llmProfiles.contains(where: { $0.id == updated.selectedLLMProfileID }) {
            updated.selectedLLMProfileID = updated.llmProfiles.first?.id ?? ""
        }
        print("ℹ️  Qianfan and Kimi are no longer supported, so their saved configuration and key were removed.")
        return updated
    }

    /// Atomic write. Creates parent directory if missing.
    func save(to url: URL = Config.path) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - Derived helpers

    /// The currently-active LLM configuration. Falls back to the first profile if
    /// the selected id is stale, and to a keyless stand-in if the list is empty.
    var activeLLMProfile: LLMProfile {
        llmProfiles.first { $0.id == selectedLLMProfileID }
            ?? llmProfiles.first
            ?? .defaultProfile()
    }

    /// Expand `~/` and resolve to an absolute path. Creates the directory if missing.
    func resolvedOutputDirectory() throws -> URL {
        var expanded = outputDirectory
        if expanded.hasPrefix("~/") {
            expanded = NSHomeDirectory() + String(expanded.dropFirst(1))
        } else if expanded == "~" {
            expanded = NSHomeDirectory()
        }
        let url = URL(fileURLWithPath: expanded)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Generates a timestamped meeting file URL in the output dir (no extension).
    /// E.g. `~/Documents/MeetingCapture/meeting_20260422_143512`
    func newMeetingBase(timestamp: Date = Date()) throws -> URL {
        let dir = try resolvedOutputDirectory()
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return dir.appendingPathComponent("meeting_\(f.string(from: timestamp))")
    }

    /// Returns the API key for one LLM profile, from flag → env → that profile's
    /// stored key, or nil. `LLM_API_KEY` is global, not per-profile: an escape
    /// hatch, not how multiple configs normally get their keys.
    static func resolveApiKey(profileID: String, flag: String? = nil) -> String? {
        if let k = flag, !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment["LLM_API_KEY"], !k.isEmpty { return k }
        if let k = APIKeyStore.read(profileID: profileID), !k.isEmpty { return k }
        return nil
    }

    /// Human-readable source of one profile's API key, for the settings screen.
    static func apiKeySource(profileID: String) -> String {
        if ProcessInfo.processInfo.environment["LLM_API_KEY"] != nil { return "set via LLM_API_KEY" }
        if APIKeyStore.isStored(profileID: profileID) { return "stored in ~/.config/MeetingCapture" }
        return "not set"
    }
}
