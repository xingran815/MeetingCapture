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
            let items: [MenuItem] = [
                MenuItem(key: "1", label: "Record a meeting          ← Enter to stop early"),
                MenuItem(key: "2", label: "Transcribe a .wav"),
                MenuItem(key: "3", label: "Summarize a .txt"),
                MenuItem(key: "4", label: "Settings"),
                MenuItem(key: "q", label: "Quit"),
            ]
            let pick = Menu.pick(header: mainHeader(), items: items, allowBack: false)
            switch pick {
            case .back:
                break loop
            case .selected(let i):
                switch i {
                case 0: await recordFlow()
                case 1: await transcribeFlow()
                case 2: await summarizeFlow()
                case 3: await settingsFlow()
                case 4: break loop
                default: break
                }
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

    private func mainHeader() -> String {
        let thinking = config.kimiThinkingEnabled ? "on" : "off"
        let autoTS   = config.autoTranscribe ? "on" : "off"
        let autoSum  = config.autoSummarize  ? "on" : "off"
        return """

          whisper: \(config.whisperModel)   ·  kimi thinking: \(thinking)   ·  auto-ts: \(autoTS), auto-sum: \(autoSum)
          output:  \(config.outputDirectory)          max: \(config.defaultDurationMinutes) min

        """
    }

    private func promptLine(_ prompt: String = "\n> ") -> String? {
        fputs(prompt, stdout)
        return readLine()
    }

    // Like promptLine but treats `b` / `back` (case-insensitive) as cancel,
    // returning nil. Use for any input where the user might want to bail out
    // without changing anything. The prompt is decorated with a `(b = back)` hint.
    private func askLine(_ label: String) -> String? {
        fputs("\(label)  (b = back): ", stdout)
        guard let raw = readLine() else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower == "b" || lower == "back" {
            print("↩  Back, no change.")
            return nil
        }
        return trimmed
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
        guard let raw = askLine("Path to .wav"), !raw.isEmpty else { return }
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
        guard let raw = askLine("Path to .txt"), !raw.isEmpty else { return }
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
        // Fail fast with a helpful message if nothing will resolve a key.
        // The actual key is fetched fresh inside Summarizer.summarize().
        guard Config.resolveApiKey() != nil else {
            print("""
            ❌  Summarization skipped: no API key.
               Store one with Settings → LLM API key, or export QIANFAN_API_KEY.
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
            apiKeyProvider: { Config.resolveApiKey() },
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

            let items: [MenuItem] = [
                MenuItem(key: "1", label: "Whisper model           [\(c.whisperModel)]"),
                MenuItem(key: "2", label: "Max duration (minutes)  [\(c.defaultDurationMinutes)]"),
                MenuItem(key: "3", label: "Output directory        [\(c.outputDirectory)]"),
                MenuItem(key: "4", label: "Auto-transcribe         [\(c.autoTranscribe ? "on" : "off")]"),
                MenuItem(key: "5", label: "Auto-summarize          [\(c.autoSummarize ? "on" : "off")]"),
                MenuItem(key: "6", label: "LLM model               [\(c.llmModel)]"),
                MenuItem(key: "7", label: "LLM base URL            [\(c.llmBaseURL)]"),
                MenuItem(key: "8", label: "Kimi thinking           [\(thinkingDesc)]"),
                MenuItem(key: "9", label: "LLM API key             [\(keyStatus)]"),
                MenuItem(key: "r", label: "Reset to defaults"),
            ]
            let pick = Menu.pick(title: "\nSettings\n", items: items, allowBack: true)
            switch pick {
            case .back:
                break loop
            case .selected(let i):
                switch i {
                case 0:  promptWhisperModel()
                case 1:  promptInt(\.defaultDurationMinutes, label: "duration (minutes)", min: 1, max: 600)
                case 2:  promptString(\.outputDirectory, label: "output directory")
                case 3:  toggle(\.autoTranscribe, label: "Auto-transcribe")
                case 4:  toggle(\.autoSummarize,  label: "Auto-summarize")
                case 5:  promptString(\.llmModel, label: "LLM model")
                case 6:  promptString(\.llmBaseURL, label: "LLM base URL")
                case 7:  promptKimiThinking()
                case 8:
                    promptApiKey()
                case 9:
                    config = Config()
                    persistConfig()
                    print("✓  Reset to defaults.")
                default: break
                }
            }
        }
    }

    private func promptWhisperModel() {
        let models: [(id: String, blurb: String)] = [
            ("openai_whisper-tiny.en",   "~75 MB, fastest, rough"),
            ("openai_whisper-base.en",   "~140 MB"),
            ("openai_whisper-small.en",  "~470 MB, default"),
            ("openai_whisper-medium.en", "~1.5 GB, best for accents"),
            ("openai_whisper-small",     "multilingual, for Chinese etc."),
            ("openai_whisper-medium",    "multilingual"),
        ]
        var items = models.enumerated().map { (i, m) in
            let marker = (m.id == config.whisperModel) ? "●" : " "
            return MenuItem(key: Character("\(i + 1)"), label: "\(marker) \(m.id)   (\(m.blurb))")
        }
        items.append(MenuItem(key: "c", label: "  Custom…  (type any WhisperKit model id)"))

        let initial = models.firstIndex(where: { $0.id == config.whisperModel }) ?? 0
        let pick = Menu.pick(
            title: "\nWhisper model  (current: \(config.whisperModel))\n",
            items: items,
            initialIndex: initial,
            allowBack: true
        )
        switch pick {
        case .back:
            return
        case .selected(let i):
            if i < models.count {
                config.whisperModel = models[i].id
                persistConfig()
                print("✓  Whisper model: \(config.whisperModel)")
            } else {
                guard let v = askLine("Custom Whisper model [\(config.whisperModel)]"),
                      !v.isEmpty else { return }
                config.whisperModel = v
                persistConfig()
            }
        }
    }

    private func promptKimiThinking() {
        let cur = config.kimiThinkingEnabled ? "on" : "off"
        guard let v = askLine("Thinking on/off [\(cur)]") else { return }
        let s = v.lowercased()
        if s == "on" || s == "y" || s == "yes" || s == "true" { config.kimiThinkingEnabled = true }
        else if s == "off" || s == "n" || s == "no" || s == "false" { config.kimiThinkingEnabled = false }
        else if s.isEmpty { /* keep */ }
        else { print("Expected on/off."); return }

        if config.kimiThinkingEnabled {
            let curBudget = config.kimiThinkingBudgetTokens
            if let b = askLine("Thinking budget tokens [\(curBudget)]"), !b.isEmpty,
               let n = Int(b), n > 0 {
                config.kimiThinkingBudgetTokens = n
            }
        }
        persistConfig()
    }

    private func promptApiKey() {
        let env = ProcessInfo.processInfo.environment
        if env["QIANFAN_API_KEY"] != nil || env["LLM_API_KEY"] != nil {
            print("ℹ  An env-var key is set in this shell; it takes precedence over the keychain while present.")
        }

        let stored = Keychain.isStored
        var items: [MenuItem] = [
            MenuItem(key: "s", label: stored ? "Replace stored key" : "Set new key  (stored in macOS Keychain)"),
        ]
        if stored {
            items.append(MenuItem(key: "c", label: "Clear stored key"))
        }
        let pick = Menu.pick(title: "\nLLM API key\n", items: items, allowBack: true)
        switch pick {
        case .back:
            return
        case .selected(let i):
            if items[i].key == "c" {
                if Keychain.delete() { print("✓  Cleared stored key.") }
                else                 { print("⚠  Failed to clear key from keychain.") }
                return
            }
            guard let key = readSecret("Paste API key (input hidden)"),
                  !key.isEmpty else {
                print("↩  No change.")
                return
            }
            if Keychain.write(key) { print("✓  Stored in keychain.") }
            else                   { print("⚠  Failed to store key in keychain.") }
        }
    }

    /// Read one line from stdin with echo suppressed. Returns nil on EOF or
    /// if the user types `b` / `back` to cancel.
    private func readSecret(_ label: String) -> String? {
        fputs("\(label)  (b = back): ", stdout)
        fflush(stdout)

        var original = termios()
        let haveTermios = (isatty(fileno(stdin)) != 0) && (tcgetattr(fileno(stdin), &original) == 0)
        if haveTermios {
            var raw = original
            raw.c_lflag &= ~UInt(ECHO)
            _ = tcsetattr(fileno(stdin), TCSANOW, &raw)
        }
        defer {
            if haveTermios {
                var r = original
                _ = tcsetattr(fileno(stdin), TCSANOW, &r)
            }
            fputs("\n", stdout)
        }

        guard let raw = readLine() else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower == "b" || lower == "back" { return nil }
        return trimmed
    }

    private func promptString(_ kp: WritableKeyPath<Config, String>, label: String) {
        let cur = config[keyPath: kp]
        guard let v = askLine("\(label) [\(cur)]"), !v.isEmpty else { return }
        config[keyPath: kp] = v
        persistConfig()
    }

    private func promptInt(_ kp: WritableKeyPath<Config, Int>, label: String, min lo: Int, max hi: Int) {
        let cur = config[keyPath: kp]
        guard let v = askLine("\(label) [\(cur)]"), !v.isEmpty else { return }
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
