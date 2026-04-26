import Foundation

setbuf(stdout, nil)
setbuf(stderr, nil)

// ─── Arg parsing ──────────────────────────────────────────────────────────────

let rawArgs = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool { rawArgs.contains(name) }
func option(_ name: String) -> String? {
    guard let i = rawArgs.firstIndex(of: name), rawArgs.index(after: i) < rawArgs.endIndex
    else { return nil }
    return rawArgs[rawArgs.index(after: i)]
}

if flag("--help") || flag("-h") {
    print("""
    MeetingCaptureCLI  —  capture, transcribe, summarize meetings, all local

    Usage:
      swift run MeetingCaptureCLI [options]

    Capture options:
      --duration <sec>      Maximum capture duration          (default: 28800 = 8h safety cap)
                             Press Enter during recording to stop earlier
      --output <path>       Output .wav file path             (default: meeting_<ts>.wav)
      --all-audio           Capture ALL system audio          (default: meeting app only)
      --no-mic              Disable mic capture               (default: mic mixed in)
      --no-aec              Disable acoustic echo cancellation (default: AEC on)

    Transcription options:
      --transcribe          Transcribe the WAV after capture
      --transcribe-only P   Skip capture; transcribe existing WAV at path P
      --model <name>        Whisper model                     (default: openai_whisper-small.en)

    Summarization options (OpenAI-compatible /chat/completions):
      --summarize           Generate an LLM summary after transcription
      --summarize-only P    Skip everything; summarize existing .txt at path P
      --llm-model <name>    LLM model name                    (default: kimi-k2.5)
      --llm-base-url <url>  OpenAI-compatible base URL        (default: https://qianfan.baidubce.com/v2/coding)
      --llm-api-key <key>   API key (also: $QIANFAN_API_KEY, $LLM_API_KEY)

    Misc:
      --list                List running applications and exit
      --help                Show this help

    Permissions (once each):
      • Screen Recording (System Settings → Privacy & Security → Screen Recording)
      • Microphone (prompted on first mic use)

    Examples:
      MeetingCaptureCLI --duration 60 --transcribe --summarize --output zoom.wav
      MeetingCaptureCLI --transcribe-only /tmp/with_mic.wav --summarize
      MeetingCaptureCLI --summarize-only /tmp/with_mic.txt
    """)
    exit(0)
}

func makeTimestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd_HHmmss"
    return f.string(from: Date())
}

// No args → launch interactive shell. Any args (including --help) → stay in flag mode.
if rawArgs.isEmpty {
    Task {
        if #available(macOS 14.0, *) { await Shell().run() }
        else { fputs("macOS 14+ required for the interactive shell.\n", stderr) }
        exit(0)
    }
    RunLoop.main.run()
}

let persistedConfig = Config.load()

let duration       = option("--duration").flatMap(Double.init) ?? Double(persistedConfig.defaultDurationMinutes * 60)
let outputPath     = option("--output") ?? "meeting_\(makeTimestamp()).wav"
let allAudio       = flag("--all-audio")
let noMic          = flag("--no-mic")
let noAec          = flag("--no-aec")
let listMode       = flag("--list")
let transcribeFlag = flag("--transcribe")
let transcribeOnly = option("--transcribe-only")
let whisperModel   = option("--model") ?? persistedConfig.whisperModel
let summarizeFlag  = flag("--summarize")
let summarizeOnly  = option("--summarize-only")
let llmModel       = option("--llm-model") ?? persistedConfig.llmModel
let llmBaseURL     = option("--llm-base-url") ?? persistedConfig.llmBaseURL
let llmApiKeyFlag  = option("--llm-api-key")

// ─── Banner ───────────────────────────────────────────────────────────────────

print("""
╔════════════════════════════════════════════╗
║   MeetingCaptureCLI  ·  v0.3               ║
║   capture · transcribe · summarize         ║
╚════════════════════════════════════════════╝
""")

// ─── Helpers ─────────────────────────────────────────────────────────────────

@available(macOS 14.0, *)
func runTranscription(wavPaths: [String], model: String) async throws -> String {
    guard !wavPaths.isEmpty else {
        throw NSError(domain: "Transcription", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "No WAV files to transcribe"
        ])
    }

    let transcriber = Transcriber(model: model)
    try await transcriber.load()
    let (text, segments) = try await transcriber.transcribe(wavPaths: wavPaths)

    print("\n──── transcript ──────────────────────────")
    print(text.trimmingCharacters(in: .whitespacesAndNewlines))
    print("──────────────────────────────────────────")

    // Use the first WAV file's base name (without _partN suffix) for the output
    let firstPath = wavPaths[0]
    let wavURL = URL(fileURLWithPath: firstPath)
    let baseName = wavURL.deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: "_part\\d+$", with: "", options: .regularExpression)
    let dir = wavURL.deletingLastPathComponent()
    let txtURL = dir.appendingPathComponent(baseName).appendingPathExtension("txt")
    let body = Transcriber.format(segments: segments) + "\n"
    try body.write(to: txtURL, atomically: true, encoding: .utf8)
    print("📄  Transcript saved: \(txtURL.path)")

    return text
}

/// Run the LLM summarizer on `transcript`, print the markdown, and write it
/// to a sibling `.md` next to `sourcePath` (which is typically the .wav or
/// .txt that produced the transcript).
func runSummarization(transcript: String, sourcePath: String) async throws {
    guard Config.resolveApiKey(flag: llmApiKeyFlag) != nil else {
        throw NSError(domain: "Summarize", code: -1, userInfo: [
            NSLocalizedDescriptionKey:
                "No LLM API key. Store one in the keychain via the interactive shell, export QIANFAN_API_KEY, or pass --llm-api-key <key>."
        ])
    }
    guard let baseURL = URL(string: llmBaseURL) else {
        throw NSError(domain: "Summarize", code: -2, userInfo: [
            NSLocalizedDescriptionKey: "Invalid --llm-base-url: \(llmBaseURL)"
        ])
    }

    let summarizer = Summarizer(
        baseURL: baseURL,
        apiKeyProvider: { Config.resolveApiKey(flag: llmApiKeyFlag) },
        model: llmModel
    )
    let summary = try await summarizer.summarize(transcript: transcript)

    print("\n──── summary ─────────────────────────────")
    print(summary.trimmingCharacters(in: .whitespacesAndNewlines))
    print("──────────────────────────────────────────")

    let mdURL = URL(fileURLWithPath: sourcePath)
        .deletingPathExtension()
        .appendingPathExtension("md")
    try (summary + "\n").write(to: mdURL, atomically: true, encoding: .utf8)
    print("📝  Summary saved: \(mdURL.path)")
}

// ─── Run ──────────────────────────────────────────────────────────────────────

Task {
    do {
        // Summarize-only: no capture, no transcription, just summarize a .txt
        if let path = summarizeOnly {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            try await runSummarization(transcript: text, sourcePath: path)
            exit(0)
        }

        // Transcribe-only: skip capture, transcribe a .wav, optionally summarize
        if let path = transcribeOnly {
            let text = try await runTranscription(wavPaths: [path], model: whisperModel)
            if summarizeFlag {
                try await runSummarization(transcript: text, sourcePath: path)
            }
            exit(0)
        }

        let capture = AudioCapture()
        if listMode {
            try await capture.listApps()
            exit(0)
        }

        let wavFiles = try await capture.run(
            duration: duration,
            outputPath: outputPath,
            captureAllAudio: allAudio,
            enableMic: !noMic,
            aecEnabled: !noAec && persistedConfig.aecEnabled
        )

        if (transcribeFlag || summarizeFlag) && !wavFiles.isEmpty {
            let wavPaths = wavFiles.map { $0.path }

            // --summarize implies transcription (we need text to summarize)
            let text = try await runTranscription(wavPaths: wavPaths, model: whisperModel)
            if summarizeFlag {
                // Use first file's base name for the summary
                let firstPath = wavPaths[0]
                try await runSummarization(transcript: text, sourcePath: firstPath)
            }
        }
    } catch {
        fputs("❌  \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    exit(0)
}

// Keep the main run-loop alive so async Tasks and SCStream callbacks work.
RunLoop.main.run()
