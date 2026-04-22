import Foundation

// Interactive shell. Launched when MeetingCaptureCLI is invoked with no args.
//
// Menu-driven, one keystroke per action. Settings are loaded from
// ~/Library/Application Support/MeetingCapture/config.json on launch and
// saved on every change.
//
// Mid-recording stop: we install a FileHandle.readabilityHandler on stdin
// during recording. When the user presses Enter (or any key), the handler
// fires, drains the bytes, and calls capture.manualStop(). Clean removal
// on recording-end means the next readLine() sees a fresh stdin, no race.
@available(macOS 14.0, *)
final class Shell {

    private var config: Config

    init() {
        self.config = Config.load()
    }

    func run() async {
        printBanner()
        loop: while true {
            printMainMenu()
            guard let raw = promptLine() else { break }  // Ctrl-D
            let choice = raw.lowercased().trimmingCharacters(in: .whitespaces)
            switch choice {
            case "1":             await recordFlow()
            case "2":             await transcribeFlow()
            case "3":             await summarizeFlow()
            case "4":             await settingsFlow()
            case "q", "quit", "exit", "":
                if choice.isEmpty { continue }   // just Enter → redraw menu
                break loop
            default:
                print("Unknown option: \(raw)\n")
            }
        }
        print("Bye.")
    }

    // MARK: - Menu rendering

    private func printBanner() {
        print("""
        ╔════════════════════════════════════════════╗
        ║   MeetingCapture  ·  v0.4                  ║
        ╚════════════════════════════════════════════╝
        """)
    }

    private func printMainMenu() {
        let thinking = config.kimiThinkingEnabled ? "on" : "off"
        let autoTS   = config.autoTranscribe ? "on" : "off"
        let autoSum  = config.autoSummarize  ? "on" : "off"

        print("""

          whisper: \(config.whisperModel)   ·  kimi thinking: \(thinking)   ·  auto-ts: \(autoTS), auto-sum: \(autoSum)
          output:  \(config.outputDirectory)          max: \(config.defaultDurationMinutes) min

          1) Record a meeting          ← Enter to stop early
          2) Transcribe a .wav
          3) Summarize a .txt
          4) Settings
          q) Quit
        """)
    }

    private func promptLine(_ prompt: String = "\n> ") -> String? {
        fputs(prompt, stdout)
        return readLine()
    }

    // MARK: - Record

    private func recordFlow() async {
        let base: URL
        do { base = try config.newMeetingBase() }
        catch {
            print("❌  Couldn't prepare output directory: \(error.localizedDescription)")
            return
        }
        let wavURL = base.appendingPathExtension("wav")

        let capture = AudioCapture()
        let totalSec = Double(config.defaultDurationMinutes * 60)

        print("""

        🔴  Recording → \(wavURL.path)
            Press Enter to stop early (or wait \(config.defaultDurationMinutes) min).
        """)

        // Install stdin-readability handler that triggers manualStop on any input.
        let stdin = FileHandle.standardInput
        stdin.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            capture.manualStop()
        }
        defer { stdin.readabilityHandler = nil }

        do {
            try await capture.run(
                duration: totalSec,
                outputPath: wavURL.path,
                captureAllAudio: false,
                enableMic: true
            )
        } catch {
            print("❌  Capture failed: \(error.localizedDescription)")
            return
        }

        print("\n   wav:  \(wavURL.path)")

        // Post-capture pipeline
        var transcript: String? = nil
        if config.autoTranscribe {
            transcript = await runTranscribe(wavPath: wavURL.path)
        }

        if config.autoSummarize {
            if let text = transcript {
                let txtURL = base.appendingPathExtension("txt")
                await runSummarize(transcript: text, sourcePath: txtURL.path)
            } else {
                print("ℹ  Skipping summary: auto-transcribe is off, no transcript available.")
            }
        }
    }

    // MARK: - Transcribe

    private func transcribeFlow() async {
        guard let raw = promptLine("Path to .wav: "), !raw.isEmpty else { return }
        let path = expand(raw)
        guard FileManager.default.fileExists(atPath: path) else {
            print("❌  File not found: \(path)")
            return
        }
        _ = await runTranscribe(wavPath: path)

        // Offer to summarize the fresh transcript
        let txtPath = (path as NSString).deletingPathExtension + ".txt"
        guard FileManager.default.fileExists(atPath: txtPath) else { return }
        guard let yn = promptLine("Summarize the transcript now? [Y/n]: ") else { return }
        if yn.lowercased().hasPrefix("n") { return }
        guard let text = try? String(contentsOfFile: txtPath, encoding: .utf8) else { return }
        await runSummarize(transcript: text, sourcePath: txtPath)
    }

    // MARK: - Summarize

    private func summarizeFlow() async {
        guard let raw = promptLine("Path to .txt: "), !raw.isEmpty else { return }
        let path = expand(raw)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("❌  Couldn't read file: \(path)")
            return
        }
        await runSummarize(transcript: text, sourcePath: path)
    }

    // MARK: - Pipeline primitives

    @discardableResult
    private func runTranscribe(wavPath: String) async -> String? {
        let transcriber = Transcriber(model: config.whisperModel)
        do {
            try await transcriber.load()
            let (text, segments) = try await transcriber.transcribe(wavPath: wavPath)

            print("\n──── transcript ──────────────────────────")
            print(text.trimmingCharacters(in: .whitespacesAndNewlines))
            print("──────────────────────────────────────────")

            let wavURL = URL(fileURLWithPath: wavPath)
            let txtURL = wavURL.deletingPathExtension().appendingPathExtension("txt")
            let body = Transcriber.format(segments: segments) + "\n"
            try body.write(to: txtURL, atomically: true, encoding: .utf8)
            print("   txt:  \(txtURL.path)")
            return text
        } catch {
            print("❌  Transcription failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func runSummarize(transcript: String, sourcePath: String) async {
        guard let apiKey = Config.resolveApiKey() else {
            print("""
            ❌  Summarization skipped: no API key.
               Set QIANFAN_API_KEY or LLM_API_KEY in your shell and retry.
               Transcript is still on disk.
            """)
            return
        }
        guard let baseURL = URL(string: config.llmBaseURL) else {
            print("❌  Invalid LLM base URL: \(config.llmBaseURL)")
            return
        }

        let thinking: ThinkingMode = config.kimiThinkingEnabled
            ? .enabled(budget: config.kimiThinkingBudgetTokens)
            : .disabled

        let summarizer = Summarizer(
            baseURL: baseURL,
            apiKey: apiKey,
            model: config.llmModel,
            thinking: thinking
        )
        do {
            let summary = try await summarizer.summarize(transcript: transcript)

            print("\n──── summary ─────────────────────────────")
            print(summary.trimmingCharacters(in: .whitespacesAndNewlines))
            print("──────────────────────────────────────────")

            let mdURL = URL(fileURLWithPath: sourcePath)
                .deletingPathExtension()
                .appendingPathExtension("md")
            try (summary + "\n").write(to: mdURL, atomically: true, encoding: .utf8)
            print("   md:   \(mdURL.path)")
        } catch {
            print("❌  Summarization failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Settings

    private func settingsFlow() async {
        loop: while true {
            let c = config
            let keyStatus = Config.apiKeySourceDescription
            let thinkingDesc = c.kimiThinkingEnabled
                ? "on, budget \(c.kimiThinkingBudgetTokens) tokens"
                : "off"

            print("""

            Settings

              1) Whisper model           [\(c.whisperModel)]
              2) Max duration (minutes)  [\(c.defaultDurationMinutes)]
              3) Output directory        [\(c.outputDirectory)]
              4) Auto-transcribe         [\(c.autoTranscribe ? "on" : "off")]
              5) Auto-summarize          [\(c.autoSummarize ? "on" : "off")]
              6) LLM model               [\(c.llmModel)]
              7) LLM base URL            [\(c.llmBaseURL)]
              8) Kimi thinking           [\(thinkingDesc)]
              9) LLM API key             [\(keyStatus)]   (read-only)
              r) Reset to defaults
              b) Back
            """)
            guard let raw = promptLine() else { return }
            switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
            case "1":  promptWhisperModel()
            case "2":  promptInt(\.defaultDurationMinutes, label: "duration (minutes)", min: 1, max: 600)
            case "3":  promptString(\.outputDirectory, label: "output directory")
            case "4":  toggle(\.autoTranscribe, label: "Auto-transcribe")
            case "5":  toggle(\.autoSummarize,  label: "Auto-summarize")
            case "6":  promptString(\.llmModel, label: "LLM model")
            case "7":  promptString(\.llmBaseURL, label: "LLM base URL")
            case "8":  promptKimiThinking()
            case "9":
                print("API key is read from the environment. Set QIANFAN_API_KEY (or LLM_API_KEY) and relaunch.")
            case "r":
                config = Config()
                persistConfig()
                print("✓  Reset to defaults.")
            case "b", "":
                break loop
            default:
                print("Unknown option: \(raw)")
            }
        }
    }

    private func promptWhisperModel() {
        print("""
        Common Whisper models:
          openai_whisper-tiny.en      (~75 MB, fastest, rough)
          openai_whisper-base.en      (~140 MB)
          openai_whisper-small.en     (~470 MB, default)
          openai_whisper-medium.en    (~1.5 GB, best for accents)
          openai_whisper-small        (multilingual, for Chinese etc.)
          openai_whisper-medium       (multilingual)
        """)
        guard let v = promptLine("New Whisper model [\(config.whisperModel)]: "), !v.isEmpty else { return }
        config.whisperModel = v
        persistConfig()
    }

    private func promptKimiThinking() {
        let cur = config.kimiThinkingEnabled ? "on" : "off"
        guard let v = promptLine("Thinking on/off [\(cur)]: ") else { return }
        let s = v.lowercased()
        if s == "on" || s == "y" || s == "yes" || s == "true" { config.kimiThinkingEnabled = true }
        else if s == "off" || s == "n" || s == "no" || s == "false" { config.kimiThinkingEnabled = false }
        else if s.isEmpty { /* keep */ }
        else { print("Expected on/off."); return }

        if config.kimiThinkingEnabled {
            let curBudget = config.kimiThinkingBudgetTokens
            if let b = promptLine("Thinking budget tokens [\(curBudget)]: "), !b.isEmpty,
               let n = Int(b), n > 0 {
                config.kimiThinkingBudgetTokens = n
            }
        }
        persistConfig()
    }

    private func promptString(_ kp: WritableKeyPath<Config, String>, label: String) {
        let cur = config[keyPath: kp]
        guard let v = promptLine("\(label) [\(cur)]: "), !v.isEmpty else { return }
        config[keyPath: kp] = v
        persistConfig()
    }

    private func promptInt(_ kp: WritableKeyPath<Config, Int>, label: String, min lo: Int, max hi: Int) {
        let cur = config[keyPath: kp]
        guard let v = promptLine("\(label) [\(cur)]: "), !v.isEmpty else { return }
        guard let n = Int(v), n >= lo, n <= hi else {
            print("Expected an integer between \(lo) and \(hi).")
            return
        }
        config[keyPath: kp] = n
        persistConfig()
    }

    private func toggle(_ kp: WritableKeyPath<Config, Bool>, label: String) {
        config[keyPath: kp].toggle()
        persistConfig()
        print("\(label): \(config[keyPath: kp] ? "on" : "off")")
    }

    private func persistConfig() {
        do { try config.save() }
        catch { print("⚠  Failed to save config: \(error.localizedDescription)") }
    }

    // MARK: - Utilities

    private func expand(_ path: String) -> String {
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst(1)) }
        if path == "~" { return NSHomeDirectory() }
        return path
    }
}
