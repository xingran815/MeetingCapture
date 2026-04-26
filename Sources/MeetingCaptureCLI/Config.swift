import Foundation

// Persisted user settings for MeetingCapture.
//
// Stored as JSON at ~/Library/Application Support/MeetingCapture/config.json.
// API keys are intentionally NEVER persisted — they come from env vars / flags.
struct Config: Codable, Equatable {

    // Capture & transcription
    var whisperModel: String            = "openai_whisper-small.en"
    var defaultDurationMinutes: Int     = 480
    var outputDirectory: String         = "~/Documents/MeetingCapture"
    var autoTranscribe: Bool            = true
    var autoSummarize: Bool             = true
    var aecEnabled: Bool                = true

    // LLM
    var llmModel: String                = "kimi-k2.5"
    var llmBaseURL: String              = "https://qianfan.baidubce.com/v2/coding"
    var kimiThinkingEnabled: Bool       = false
    var kimiThinkingBudgetTokens: Int   = 32_000

    static let `default` = Config()

    // Memberwise initializer (for creating defaults).
    init(
        whisperModel: String = "openai_whisper-small.en",
        defaultDurationMinutes: Int = 480,
        outputDirectory: String = "~/Documents/MeetingCapture",
        autoTranscribe: Bool = true,
        autoSummarize: Bool = true,
        aecEnabled: Bool = true,
        llmModel: String = "kimi-k2.5",
        llmBaseURL: String = "https://qianfan.baidubce.com/v2/coding",
        kimiThinkingEnabled: Bool = false,
        kimiThinkingBudgetTokens: Int = 32_000
    ) {
        self.whisperModel = whisperModel
        self.defaultDurationMinutes = defaultDurationMinutes
        self.outputDirectory = outputDirectory
        self.autoTranscribe = autoTranscribe
        self.autoSummarize = autoSummarize
        self.aecEnabled = aecEnabled
        self.llmModel = llmModel
        self.llmBaseURL = llmBaseURL
        self.kimiThinkingEnabled = kimiThinkingEnabled
        self.kimiThinkingBudgetTokens = kimiThinkingBudgetTokens
    }

    // Custom decoder provides defaults for missing keys (backward compat).
    enum CodingKeys: String, CodingKey {
        case whisperModel, defaultDurationMinutes, outputDirectory
        case autoTranscribe, autoSummarize, aecEnabled
        case llmModel, llmBaseURL, kimiThinkingEnabled, kimiThinkingBudgetTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? "openai_whisper-small.en"
        defaultDurationMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultDurationMinutes) ?? 480
        outputDirectory = try c.decodeIfPresent(String.self, forKey: .outputDirectory) ?? "~/Documents/MeetingCapture"
        autoTranscribe = try c.decodeIfPresent(Bool.self, forKey: .autoTranscribe) ?? true
        autoSummarize = try c.decodeIfPresent(Bool.self, forKey: .autoSummarize) ?? true
        aecEnabled = try c.decodeIfPresent(Bool.self, forKey: .aecEnabled) ?? true
        llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel) ?? "kimi-k2.5"
        llmBaseURL = try c.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? "https://qianfan.baidubce.com/v2/coding"
        kimiThinkingEnabled = try c.decodeIfPresent(Bool.self, forKey: .kimiThinkingEnabled) ?? false
        kimiThinkingBudgetTokens = try c.decodeIfPresent(Int.self, forKey: .kimiThinkingBudgetTokens) ?? 32_000
    }

    static var path: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MeetingCapture/config.json")
    }

    /// Load from disk. Missing file → defaults (silent). Corrupt file → defaults (warn,
    /// don't overwrite — the user may want to fix it by hand).
    static func load() -> Config {
        let url = Self.path
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
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

    /// Returns the API key from flag → env → keychain, or nil if none set.
    static func resolveApiKey(flag: String? = nil) -> String? {
        if let k = flag, !k.isEmpty { return k }
        let env = ProcessInfo.processInfo.environment
        if let k = env["QIANFAN_API_KEY"], !k.isEmpty { return k }
        if let k = env["LLM_API_KEY"],     !k.isEmpty { return k }
        if let k = Keychain.read(),        !k.isEmpty { return k }
        return nil
    }

    /// Human-readable source of the API key for the settings screen.
    static var apiKeySourceDescription: String {
        let env = ProcessInfo.processInfo.environment
        if env["QIANFAN_API_KEY"] != nil { return "set via QIANFAN_API_KEY" }
        if env["LLM_API_KEY"]     != nil { return "set via LLM_API_KEY" }
        if Keychain.isStored              { return "stored in keychain" }
        return "not set"
    }
}
