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
    MeetingCaptureCLI  —  capture meeting audio, transcribe locally

    Usage:
      swift run MeetingCaptureCLI [options]

    Capture options:
      --duration <sec>      Capture duration in seconds      (default: 30)
      --output <path>       Output .wav file path            (default: meeting_<ts>.wav)
      --all-audio           Capture ALL system audio         (default: meeting app only)
      --no-mic              Disable mic capture              (default: mic mixed in)

    Transcription options:
      --transcribe          Transcribe the WAV after capture
      --transcribe-only P   Skip capture; transcribe existing WAV at path P
      --model <name>        Whisper model                    (default: openai_whisper-small.en)
                            Common: openai_whisper-tiny.en, openai_whisper-base.en,
                                    openai_whisper-small.en, openai_whisper-medium.en,
                                    openai_whisper-large-v3

    Misc:
      --list                List running applications and exit
      --help                Show this help

    Permissions (once each):
      • Screen Recording (System Settings → Privacy & Security → Screen Recording)
      • Microphone (prompted on first mic use)

    Examples:
      swift run MeetingCaptureCLI --duration 60 --output zoom.wav --transcribe
      swift run MeetingCaptureCLI --transcribe-only /tmp/with_mic.wav
      swift run MeetingCaptureCLI --all-audio --duration 10 --no-mic
    """)
    exit(0)
}

func makeTimestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd_HHmmss"
    return f.string(from: Date())
}

let duration       = option("--duration").flatMap(Double.init) ?? 30.0
let outputPath     = option("--output") ?? "meeting_\(makeTimestamp()).wav"
let allAudio       = flag("--all-audio")
let noMic          = flag("--no-mic")
let listMode       = flag("--list")
let transcribeFlag = flag("--transcribe")
let transcribeOnly = option("--transcribe-only")
let modelName      = option("--model") ?? "openai_whisper-small.en"

// ─── Banner ───────────────────────────────────────────────────────────────────

print("""
╔════════════════════════════════════════════╗
║   MeetingCaptureCLI  ·  v0.2               ║
║   capture + local Whisper transcription    ║
╚════════════════════════════════════════════╝
""")

// ─── Helpers ─────────────────────────────────────────────────────────────────

@available(macOS 14.0, *)
func runTranscription(wavPath: String, model: String) async throws {
    let transcriber = Transcriber(model: model)
    try await transcriber.load()
    let (text, segments) = try await transcriber.transcribe(wavPath: wavPath)

    // Print full transcript
    print("\n──── transcript ──────────────────────────")
    print(text.trimmingCharacters(in: .whitespacesAndNewlines))
    print("──────────────────────────────────────────")

    // Write sibling .txt with timestamped segments
    let wavURL = URL(fileURLWithPath: wavPath)
    let txtURL = wavURL.deletingPathExtension().appendingPathExtension("txt")
    let body = Transcriber.format(segments: segments) + "\n"
    try body.write(to: txtURL, atomically: true, encoding: .utf8)
    print("📄  Transcript saved: \(txtURL.path)")
}

// ─── Run ──────────────────────────────────────────────────────────────────────

Task {
    do {
        // Transcribe-only mode: skip capture entirely
        if let path = transcribeOnly {
            try await runTranscription(wavPath: path, model: modelName)
            exit(0)
        }

        let capture = AudioCapture()
        if listMode {
            try await capture.listApps()
            exit(0)
        }

        try await capture.run(
            duration: duration,
            outputPath: outputPath,
            captureAllAudio: allAudio,
            enableMic: !noMic
        )

        if transcribeFlag {
            // Resolve absolute path for the captured WAV
            let resolved = outputPath.hasPrefix("/")
                ? outputPath
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(outputPath).path
            try await runTranscription(wavPath: resolved, model: modelName)
        }
    } catch {
        fputs("❌  \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    exit(0)
}

// Keep the main run-loop alive so async Tasks and SCStream callbacks work.
RunLoop.main.run()
