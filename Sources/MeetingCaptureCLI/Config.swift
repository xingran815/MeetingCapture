import Foundation

// Persisted user settings for MeetingCapture.
//
// Stored as JSON at ~/Library/Application Support/MeetingCapture/config.json.
// API keys are intentionally NEVER persisted — they come from env vars / flags.
struct Config: Codable, Equatable {

    // Capture & transcription
    var whisperModel: String            = "openai_whisper-small.en"
    var defaultDurationMinutes: Int     = 30
    var outputDirectory: String         = "~/Documents/MeetingCapture"
    var autoTranscribe: Bool            = true
    var autoSummarize: Bool             = true

    // LLM
    var llmModel: String                = "kimi-k2.5"
    var llmBaseURL: String              = "https://qianfan.baidubce.com/v2/coding"
    var kimiThinkingEnabled: Bool       = true
    var kimiThinkingBudgetTokens: Int   = 32_000

    static let `default` = Config()

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

    /// Returns the API key from flag → env, or nil if none set.
    static func resolveApiKey(flag: String? = nil) -> String? {
        if let k = flag, !k.isEmpty { return k }
        let env = ProcessInfo.processInfo.environment
        if let k = env["QIANFAN_API_KEY"], !k.isEmpty { return k }
        if let k = env["LLM_API_KEY"],     !k.isEmpty { return k }
        return nil
    }

    /// Human-readable source of the API key for the settings screen.
    static var apiKeySourceDescription: String {
        let env = ProcessInfo.processInfo.environment
        if env["QIANFAN_API_KEY"] != nil { return "set via QIANFAN_API_KEY" }
        if env["LLM_API_KEY"]     != nil { return "set via LLM_API_KEY" }
        return "not set"
    }
}
