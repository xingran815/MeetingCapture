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
    MeetingCaptureCLI  —  ScreenCaptureKit audio capture spike

    Usage:
      swift run MeetingCaptureCLI [options]

    Options:
      --duration <sec>   Capture duration in seconds      (default: 30)
      --output <path>    Output .wav file path            (default: meeting_<ts>.wav)
      --all-audio        Capture ALL system audio         (default: meeting app only)
      --no-mic           Disable mic capture               (default: mic mixed in)
      --list             List running applications and exit
      --help             Show this help

    Requirements:
      • macOS 13+
      • Screen Recording permission must be granted to the terminal /
        the compiled binary (System Settings → Privacy & Security →
        Screen Recording).

    Examples:
      swift run MeetingCaptureCLI --list
      swift run MeetingCaptureCLI --duration 60 --output zoom_test.wav
      swift run MeetingCaptureCLI --all-audio --duration 10
    """)
    exit(0)
}

func makeTimestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd_HHmmss"
    return f.string(from: Date())
}

let duration   = option("--duration").flatMap(Double.init) ?? 30.0
let outputPath = option("--output") ?? "meeting_\(makeTimestamp()).wav"
let allAudio   = flag("--all-audio")
let noMic      = flag("--no-mic")
let listMode   = flag("--list")

// ─── Banner ───────────────────────────────────────────────────────────────────

print("""
╔════════════════════════════════════════════╗
║   MeetingCaptureCLI  ·  v0.1 spike         ║
║   ScreenCaptureKit audio capture test      ║
╚════════════════════════════════════════════╝
""")

// ─── Run ──────────────────────────────────────────────────────────────────────

Task {
    let capture = AudioCapture()
    do {
        if listMode {
            try await capture.listApps()
        } else {
            try await capture.run(
                duration: duration,
                outputPath: outputPath,
                captureAllAudio: allAudio,
                enableMic: !noMic
            )
        }
    } catch {
        fputs("❌  \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    exit(0)
}

// Keep the main run-loop alive so async Tasks and SCStream callbacks work.
RunLoop.main.run()
