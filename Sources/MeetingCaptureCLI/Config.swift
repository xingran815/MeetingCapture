import Foundation

// Persisted user settings for MeetingCapture.
//
// Stored as JSON at ~/.config/MeetingCapture/config.json. The API key is NOT
// kept in this JSON — it lives in its own 0600 file (see APIKeyStore) so the
// config stays safe to inspect/share. Configs written by older versions at the
// legacy ~/Library/Application Support path are migrated forward on first load.
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

    // LLM
    /// Selected provider preset id (see LLMProvider.catalog). "custom" = free-form.
    var llmProviderID: String           = "qianfan"
    /// User-given label for the custom provider (shown instead of "Custom" when set).
    var llmCustomName: String           = ""
    var llmModel: String                = "kimi-k2.5"
    var llmBaseURL: String              = "https://qianfan.baidubce.com/v2/coding"
    /// Provider-specific reasoning/thinking toggle. Only sent to providers whose
    /// preset has supportsReasoning == true (e.g. Kimi-style `thinking` param).
    var reasoningEnabled: Bool          = false
    var reasoningBudgetTokens: Int      = 32_000

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
        llmProviderID: String = "qianfan",
        llmCustomName: String = "",
        llmModel: String = "kimi-k2.5",
        llmBaseURL: String = "https://qianfan.baidubce.com/v2/coding",
        reasoningEnabled: Bool = false,
        reasoningBudgetTokens: Int = 32_000
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
        self.llmProviderID = llmProviderID
        self.llmCustomName = llmCustomName
        self.llmModel = llmModel
        self.llmBaseURL = llmBaseURL
        self.reasoningEnabled = reasoningEnabled
        self.reasoningBudgetTokens = reasoningBudgetTokens
    }

    // Custom decoder provides defaults for missing keys (backward compat).
    enum CodingKeys: String, CodingKey {
        case whisperModel, whisperLanguage, defaultDurationMinutes, outputDirectory
        case autoTranscribe, autoSummarize, aecEnabled, micEnabled, enabledMeetingAppIDs
        case captureAllAudio
        case llmProviderID, llmCustomName, llmModel, llmBaseURL, reasoningEnabled, reasoningBudgetTokens
    }

    /// Legacy (pre-generalization) keys, decoded as a fallback so older configs
    /// migrate transparently. Kept out of CodingKeys so they're never re-encoded.
    private enum LegacyKeys: String, CodingKey {
        case kimiThinkingEnabled, kimiThinkingBudgetTokens
    }

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
        llmProviderID = try c.decodeIfPresent(String.self, forKey: .llmProviderID) ?? "qianfan"
        llmCustomName = try c.decodeIfPresent(String.self, forKey: .llmCustomName) ?? ""
        llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel) ?? "kimi-k2.5"
        llmBaseURL = try c.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? "https://qianfan.baidubce.com/v2/coding"
        // New keys, falling back to the legacy kimiThinking* keys, then defaults.
        var reasoning = try c.decodeIfPresent(Bool.self, forKey: .reasoningEnabled)
        var reasoningBudget = try c.decodeIfPresent(Int.self, forKey: .reasoningBudgetTokens)
        if let legacy = try? decoder.container(keyedBy: LegacyKeys.self) {
            if reasoning == nil {
                reasoning = try? legacy.decodeIfPresent(Bool.self, forKey: .kimiThinkingEnabled)
            }
            if reasoningBudget == nil {
                reasoningBudget = try? legacy.decodeIfPresent(Int.self, forKey: .kimiThinkingBudgetTokens)
            }
        }
        reasoningEnabled = reasoning ?? false
        reasoningBudgetTokens = reasoningBudget ?? 32_000
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
    static func load() -> Config {
        let url = Self.path
        let fm = FileManager.default

        if !fm.fileExists(atPath: url.path), fm.fileExists(atPath: legacyPath.path) {
            // One-time migration from ~/Library/Application Support → ~/.config.
            if let data = try? Data(contentsOf: legacyPath),
               let migrated = try? JSONDecoder().decode(Config.self, from: data) {
                try? migrated.save()  // best-effort; original is left in place
                return migrated
            }
        }

        guard fm.fileExists(atPath: url.path) else { return Config() }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            fputs("⚠  Config at \(url.path) is unreadable (\(error.localizedDescription)); using defaults.\n", stderr)
            return Config()
        }
    }

    /// Atomic write. Creates parent directory if missing.
    func save() throws {
        let url = Self.path
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - Derived helpers

    /// Display name for the selected LLM provider: the user's custom label when
    /// on a custom provider (falling back to "Custom"), else the preset's label.
    var llmProviderDisplayName: String {
        if llmProviderID == "custom" {
            let n = llmCustomName.trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? "Custom" : n
        }
        return LLMProvider.byID(llmProviderID)?.label ?? llmProviderID
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

    /// Returns the API key from flag → env → file → legacy keychain, or nil.
    /// `LLM_API_KEY` is the primary env var; `QIANFAN_API_KEY` is kept for
    /// backward compatibility. A key found only in the legacy keychain is
    /// migrated into the file store so later launches read it from there.
    static func resolveApiKey(flag: String? = nil) -> String? {
        if let k = flag, !k.isEmpty { return k }
        let env = ProcessInfo.processInfo.environment
        if let k = env["LLM_API_KEY"],     !k.isEmpty { return k }
        if let k = env["QIANFAN_API_KEY"], !k.isEmpty { return k }
        if let k = APIKeyStore.read(),     !k.isEmpty { return k }
        if let k = Keychain.read(),        !k.isEmpty {
            APIKeyStore.write(k)   // best-effort migration out of the keychain
            return k
        }
        return nil
    }

    /// Human-readable source of the API key for the settings screen.
    static var apiKeySourceDescription: String {
        let env = ProcessInfo.processInfo.environment
        if env["LLM_API_KEY"]     != nil { return "set via LLM_API_KEY" }
        if env["QIANFAN_API_KEY"] != nil { return "set via QIANFAN_API_KEY" }
        if APIKeyStore.isStored           { return "stored in ~/.config/MeetingCapture" }
        if Keychain.isStored              { return "stored in keychain (legacy)" }
        return "not set"
    }
}
