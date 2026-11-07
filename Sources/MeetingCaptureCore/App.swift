import Foundation

/// Command-line arguments, without the program name.
struct CommandLineArguments {
    let raw: [String]

    func flag(_ name: String) -> Bool { raw.contains(name) }

    func option(_ name: String) -> String? {
        guard let i = raw.firstIndex(of: name), raw.index(after: i) < raw.endIndex
        else { return nil }
        return raw[raw.index(after: i)]
    }
}

/// Entry point for the executable, which stays a thin wrapper so everything
/// here can be imported by tests.
public enum MeetingCaptureApp {

    public static func main(arguments: [String]) -> Never {
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        let args = CommandLineArguments(raw: arguments)

        if args.flag("--permission-probe") {
            // Triggers the macOS Microphone TCC prompt by opening an AVAudioEngine
            // input tap for ~1 s, then exits. Used by install.sh.
            do {
                let mic = try MicCapture()
                try mic.start()
                Thread.sleep(forTimeInterval: 1.0)
                mic.stop()
                exit(0)
            } catch {
                fputs("permission-probe: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        // Not in --help: support for checks, not for regular use.
        if let path = args.option("--usage-ledger-stress") {
            UsageLedgerStress.run(path: path, calls: args.option("--calls").flatMap(Int.init) ?? 100)
            exit(0)
        }
        if args.flag("--live-check") {
            Task { exit(await LiveCheck.run(config: Config.load()) ? 0 : 1) }
            keepRunLoopAlive()
        }
        if let fixtures = args.option("--quality-compare-redaction") {
            let out = args.option("--out") ?? "dev/tmp/quality.md"
            let primary = args.option("--llm-cli").flatMap(CLIKind.init(rawValue:))
            Task {
                exit(
                    await QualityCompare.run(
                        fixturesDirectory: fixtures, outputPath: out, config: Config.load(), primary: primary) ? 0 : 1)
            }
            keepRunLoopAlive()
        }

        // Finding from the security re-check: ignoring these flags without the variable
        // went on to a real capture of up to 8 hours, so they stop here instead.
        let scriptFlags = [
            "--two-track-mic", "--two-track-system", "--two-track-out", "--finish-recording", "--clean-echo",
        ]
        if !AudioFixtures.scriptFlagsEnabled(), let used = scriptFlags.first(where: args.flag) {
            fputs("❌  \(used) is only for the test scripts, and needs MEETINGCAPTURE_E2E=1.\n", stderr)
            exit(2)
        }

        // Hidden, for scripts/e2e.sh: builds a two-track file, then runs the real pipeline on it.
        if AudioFixtures.scriptFlagsEnabled(), let mic = args.option("--two-track-mic"),
            let system = args.option("--two-track-system"), let out = args.option("--two-track-out")
        {
            do {
                try AudioFixtures.writeTwoTrack(
                    mic: URL(fileURLWithPath: mic), system: URL(fileURLWithPath: system),
                    systemDelay: 6, to: URL(fileURLWithPath: out))
                exit(0)
            } catch {
                fputs("fixture: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        // Speaker turns alone, so the lab can choose the detection threshold.
        if AudioFixtures.scriptFlagsEnabled(), let path = args.option("--diarize") {
            let threshold = args.option("--threshold").flatMap(Float.init)
            Task {
                do {
                    let detector = SpeakerKitDetector()
                    if let threshold { detector.clusterThreshold = threshold }
                    let turns = try await detector.detectTurns(path: path)
                    let seconds = Dictionary(grouping: turns, by: \.speaker)
                        .mapValues { $0.reduce(0) { $0 + $1.end - $1.start } }
                    print(
                        "speakers \(seconds.count) seconds \(seconds.sorted { $0.key < $1.key }.map { Int($0.value) })")
                    exit(0)
                } catch {
                    fputs("❌  \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            RunLoop.main.run()
        }
        // The cleaned mic alone, so the echo lab can measure the code a user gets.
        if AudioFixtures.scriptFlagsEnabled(), let path = args.option("--clean-echo"),
            let out = args.option("--clean-echo-out")
        {
            do {
                let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                let tracks = try AudioTracks.split(URL(fileURLWithPath: path), into: work)
                guard let mic = tracks.mic, let system = tracks.system else {
                    fputs("❌  \(path) doesn't have both tracks.\n", stderr)
                    exit(1)
                }
                guard
                    let result = try EchoRemover.clean(mic: mic, system: system, to: URL(fileURLWithPath: out))
                else {
                    print("No echo found, so nothing was written.")
                    exit(0)
                }
                print(String(format: "lag %.1f ms, drift %.2f ppm", result.lagSeconds * 1000, result.driftPPM))
                exit(0)
            } catch {
                fputs("❌  \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if AudioFixtures.scriptFlagsEnabled(), let path = args.option("--finish-recording") {
            let model = args.option("--model") ?? Config.load().whisperModel
            let folder = args.option("--model-folder")
            let language = args.option("--language")
            Task {
                do {
                    let transcriber = Transcriber(model: model, language: language, modelFolder: folder)
                    try await transcriber.load()
                    let url = URL(fileURLWithPath: path)
                    let result = try await RecordingPipeline.finish(
                        parts: [url], base: url.deletingPathExtension(),
                        pipeline: RecordingPipeline(transcriber: transcriber, detector: SpeakerKitDetector()))
                    for note in result?.notes ?? [] { print("⚠  \(note)") }
                    exit(0)
                } catch {
                    fputs("❌  \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            keepRunLoopAlive()
        }

        if args.flag("--audio-cleanup") {
            if let dir = try? Config.load().resolvedOutputDirectory() {
                AudioCleanup.run(in: dir)
            }
            exit(0)
        }

        if args.flag("--help") || args.flag("-h") {
            print(
                """
                MeetingCaptureCLI  —  capture, transcribe, summarize meetings, all local

                Usage:
                  swift run MeetingCaptureCLI [options]

                Capture options:
                  --duration <sec>      Maximum capture duration          (default: 28800 = 8h safety cap)
                                         Press Enter during recording to stop earlier
                  --output <path>       Recording name, a new file ending in .wav, kept as .m4a once
                                         proven good                       (default: meeting_<ts>.wav)
                  --all-audio           Capture ALL system audio          (default: meeting app only)
                  --no-mic              Disable mic capture               (default: mic on its own track)
                  --no-aec              Skip removing speaker echo after the call (default: on)

                Transcription options:
                  --transcribe          Transcribe the recording after capture
                  --transcribe-only P   Skip capture; transcribe the .wav or .m4a at path P
                  --model <name>        Whisper model                     (default: openai_whisper-small)
                  --language <code>     Pin language (en, zh, …)           (multilingual models auto-detect if omitted)
                  --model-folder <dir>  Load the Whisper model from this folder, no download

                Summarization options (subscription CLIs by default; API flags pick an API profile):
                  --summarize           Generate an LLM summary after transcription
                  --summarize-only P    Skip everything; summarize existing .txt at path P
                  --summary-style <s>   Force style: meeting | therapy      (default: auto-detected per transcript)
                  --therapy             Alias for --summary-style therapy
                  --llm-cli <name>      CLI to try first: claude | codex  (default: from Settings)
                  --no-redact           Send formatted values as they are (default: replaced with tokens)
                  --llm-profile <name>  Saved API configuration to use
                  --llm-model <name>    Override the chosen config's model
                  --llm-base-url <url>  Override the chosen config's base URL
                  --llm-api-key <key>   Override the chosen config's API key (also: $LLM_API_KEY)

                  Manage saved configurations (add/edit/delete, each with its own provider,
                  model, base URL, and API key) and run a connectivity check in the
                  interactive shell: Settings → LLM configurations.

                Misc:
                  --list                List running applications and exit
                  --audio-cleanup       List old WAV recordings, then convert or delete after asking
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

        // No args → launch interactive shell. Any args (including --help) → stay in flag mode.
        if arguments.isEmpty {
            Task {
                if #available(macOS 14.0, *) {
                    await Shell().run()
                } else {
                    fputs("macOS 14+ required for the interactive shell.\n", stderr)
                }
                exit(0)
            }
            keepRunLoopAlive()
        }

        let persistedConfig = Config.load()

        let duration =
            args.option("--duration").flatMap(Double.init) ?? Double(persistedConfig.defaultDurationMinutes * 60)
        let outputPath = args.option("--output") ?? "meeting_\(makeTimestamp()).wav"
        let allAudio = args.flag("--all-audio")
        let noMic = args.flag("--no-mic")
        let noAec = args.flag("--no-aec")
        let listMode = args.flag("--list")
        let transcribeFlag = args.flag("--transcribe")
        let transcribeOnly = args.option("--transcribe-only")
        let whisperModel = args.option("--model") ?? persistedConfig.whisperModel
        let whisperFolder = args.option("--model-folder")
        let whisperLang = args.option("--language") ?? persistedConfig.whisperLanguage
        let summarizeFlag = args.flag("--summarize")
        let summarizeOnly = args.option("--summarize-only")
        let llmProfileFlag = args.option("--llm-profile")
        let llmProfile =
            llmProfileFlag.flatMap { name in
                persistedConfig.llmProfiles.first { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
            } ?? persistedConfig.activeLLMProfile
        let llmCLI = args.option("--llm-cli").flatMap(CLIKind.init(rawValue:))
        let redaction = persistedConfig.redactionEnabled && !args.flag("--no-redact")
        let apiOverrides = SummaryRoute.APIOverrides(
            profile: llmProfileFlag == nil ? nil : llmProfile,
            model: args.option("--llm-model"),
            baseURL: args.option("--llm-base-url"),
            apiKeyFlag: args.option("--llm-api-key"))
        // Summary style is auto-detected per transcript; these flags force it (scripting
        // escape hatch). `--therapy` is shorthand for `--summary-style therapy`.
        let summaryStyleFlag: SummaryStyle? = {
            if args.flag("--therapy") { return .therapy }
            guard let v = args.option("--summary-style") else { return nil }
            switch v.lowercased() {
            case "therapy": return .therapy
            case "meeting": return .meeting
            default:
                fputs("⚠  Unknown --summary-style \"\(v)\" — auto-detecting instead.\n", stderr)
                return nil
            }
        }()

        if let name = llmProfileFlag,
            !persistedConfig.llmProfiles.contains(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
            )
        {
            fputs(
                "⚠  No saved LLM configuration named \"\(name)\" — using the active one (\(llmProfile.displayName)).\n",
                stderr)
        }


        print(
            """
            ╔════════════════════════════════════════════╗
            ║   MeetingCaptureCLI  ·  v0.6               ║
            ║   capture · transcribe · summarize         ║
            ╚════════════════════════════════════════════╝
            """)


        /// Summarize `transcript`, print it, and write it to a sibling `.md` next
        /// to `sourcePath` (typically the .wav or .txt that produced the transcript).
        func runSummarization(transcript: String, sourcePath: String) async throws {
            let backend = try await SummaryRoute.backend(
                config: persistedConfig, primary: llmCLI, overrides: apiOverrides)
            print("🧩  Summarizing via \(backend.label)…")
            let outcome = try await SummaryPipeline(backend: backend, redaction: redaction)
                .run(transcript: transcript, forcedStyle: summaryStyleFlag)
            print(
                outcome.style == .therapy
                    ? "🧭  Therapy session — wrote Practice Notes."
                    : "🧭  Meeting — wrote a summary.")
            if outcome.redactedValues > 0 {
                print(
                    "🔒  \(outcome.redactedValues) formatted values were kept out of the request. Spoken names aren't caught."
                )
            }

            print("\n──── summary ─────────────────────────────")
            print(outcome.report.trimmingCharacters(in: .whitespacesAndNewlines))
            print("──────────────────────────────────────────")

            let mdURL = URL(fileURLWithPath: sourcePath)
                .deletingPathExtension()
                .appendingPathExtension("md")
            try (outcome.report + "\n").write(to: mdURL, atomically: true, encoding: .utf8)
            print("📝  Summary saved: \(mdURL.path)")
        }

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
                    let text = try await runTranscription(
                        wavPaths: RecordingFiles.allParts(of: path), model: whisperModel, modelFolder: whisperFolder,
                        language: whisperLang, removeEcho: !noAec && persistedConfig.aecEnabled)
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

                let outputURL = URL(fileURLWithPath: outputPath)
                let base = outputURL.deletingPathExtension()
                if let conflict = RecordingFiles.conflict(forNewRecordingAt: base) {
                    fputs("❌  Can't record to \(outputPath): \(conflict)\n", stderr)
                    exit(1)
                }
                cleanOldAudio(persistedConfig)
                try RecordingSidecar.started().save(to: RecordingSidecar.url(forBase: base))
                RecordingKeys.install(on: capture)
                defer { RecordingKeys.remove() }
                let wavFiles = try await capture.run(
                    duration: duration,
                    outputPath: outputPath,
                    captureAllAudio: allAudio,
                    meetingApps: allAudio
                        ? [] : MeetingApp.catalog.filter { persistedConfig.enabledMeetingAppIDs.contains($0.id) },
                    enableMic: !noMic
                )

                guard !wavFiles.isEmpty else { exit(0) }
                // --summarize implies transcription (we need text to summarize)
                var pipeline: RecordingPipeline?
                if transcribeFlag || summarizeFlag {
                    let transcriber = Transcriber(
                        model: whisperModel, language: whisperLang, modelFolder: whisperFolder)
                    try await transcriber.load()
                    pipeline = RecordingPipeline(
                        transcriber: transcriber, detector: SpeakerKitDetector(),
                        removeEcho: !noAec && persistedConfig.aecEnabled)
                }
                let result = try await RecordingPipeline.finish(parts: wavFiles, base: base, pipeline: pipeline)
                cleanOldAudio(persistedConfig)
                if let result {
                    for note in result.notes { print("⚠  \(note)") }
                    print("📄  Transcript saved: \(base.appendingPathExtension("txt").path)")
                    if summarizeFlag {
                        try await runSummarization(
                            transcript: result.formatted, sourcePath: base.appendingPathExtension("txt").path)
                    }
                }
            } catch {
                fputs("❌  \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            exit(0)
        }


        keepRunLoopAlive()
    }

    /// Retention covers the configured output folder only. `--output` can point
    /// anywhere, and a file left in a shared folder shouldn't decide what's deleted
    /// there (D-45).
    private static func cleanOldAudio(_ config: Config) {
        guard let dir = try? config.resolvedOutputDirectory() else { return }
        for url in AudioRetention.clean(in: dir, days: config.audioRetentionDays, now: Date()) {
            print("🧹  Deleted old audio: \(url.lastPathComponent)")
        }
    }

    /// Keeps the main run-loop alive so async Tasks and SCStream callbacks work.
    private static func keepRunLoopAlive() -> Never {
        while true { RunLoop.main.run() }
    }

    private static func makeTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    @available(macOS 14.0, *)
    private static func runTranscription(
        wavPaths: [String], model: String, modelFolder: String?, language: String?, removeEcho: Bool
    ) async throws -> String {
        guard !wavPaths.isEmpty else {
            throw NSError(
                domain: "Transcription", code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "No WAV files to transcribe"
                ])
        }

        let transcriber = Transcriber(model: model, language: language, modelFolder: modelFolder)
        try await transcriber.load()
        let pipeline = RecordingPipeline(
            transcriber: transcriber, detector: SpeakerKitDetector(), removeEcho: removeEcho)
        let result = try await pipeline.transcribe(parts: wavPaths.map { URL(fileURLWithPath: $0) })
        for note in result.notes { print("⚠  \(note)") }
        let text = result.formatted

        print("\n──── transcript ──────────────────────────")
        print(text)
        print("──────────────────────────────────────────")

        // Use the first file's base name (without _partN suffix) for the output
        let firstPath = wavPaths[0]
        let wavURL = URL(fileURLWithPath: firstPath)
        let baseName = RecordingFiles.baseName(of: wavURL.deletingPathExtension().lastPathComponent)
        let dir = wavURL.deletingLastPathComponent()
        let txtURL = dir.appendingPathComponent(baseName).appendingPathExtension("txt")
        try (text + "\n").write(to: txtURL, atomically: true, encoding: .utf8)
        print("📄  Transcript saved: \(txtURL.path)")

        return text
    }

}
