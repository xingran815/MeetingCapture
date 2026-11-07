import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// ─────────────────────────────────────────────────────────────────────────────
// AudioCapture
//
// Lifecycle:
//   listApps()  →  print SCShareableContent.applications and exit
//   run(...)    →  start SCStream, write PCM to WAV, stop after `duration`
// ─────────────────────────────────────────────────────────────────────────────

@available(macOS 13.0, *)
final class AudioCapture: NSObject {

    // Set on run(), read on fileWriteQueue
    private var writer: TrackWriter?
    private var outputURL: URL?
    private var targetDuration: Double = 0

    private var captureStart: Date?
    private let stopper = RecordingStopper()

    /// Audio actually written, which leaves out paused time.
    private var capturedFrames: Int { writer?.framesWritten ?? 0 }

    private var stream: SCStream?
    private var micCapture: MicCapture?
    private let micGate = MicStartGate()

    // Continuation that run() awaits; resumed when capture ends
    private var stopCont: CheckedContinuation<[URL], Error>?

    private let fileWriteQueue = DispatchQueue(
        label: "com.meetingcapture.filewrite",
        qos: .userInitiated
    )

    // ─── Public ──────────────────────────────────────────────────────────────

    func listApps() async throws {
        print("Fetching shareable content…")
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )

        let apps = content.applications.sorted { $0.applicationName < $1.applicationName }
        print("\nApplications (\(apps.count)):\n")
        for app in apps {
            let name = app.applicationName.padding(toLength: 32, withPad: " ", startingAt: 0)
            print("  \(name)  \(app.bundleIdentifier)")
        }

        print("\nDisplays (\(content.displays.count)):")
        for d in content.displays {
            print("  id=\(d.displayID)  \(d.width)×\(d.height)")
        }
    }

    func run(
        duration: Double, outputPath: String, captureAllAudio: Bool, meetingApps: [MeetingApp], enableMic: Bool
    ) async throws -> [URL] {
        targetDuration = duration

        // 1. Enumerate screen content ─────────────────────────────────────────
        print("Enumerating screen content…")
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        print("  got \(content.displays.count) display(s), \(content.applications.count) app(s)")
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }
        print("  using display \(display.displayID) \(display.width)x\(display.height)")

        // 2. Locate a running meeting app ─────────────────────────────────────
        //    Ordered by priority; we take the first enabled app that is running.
        var targetApps: [SCRunningApplication] = []
        var targetLabel = "all system audio"

        if !captureAllAudio && !meetingApps.isEmpty {
            for app in meetingApps {
                let found = content.applications.filter { app.bundleIDs.contains($0.bundleIdentifier) }
                if !found.isEmpty {
                    targetApps = found
                    targetLabel = app.label
                    print("Found \(app.label): \(found.map(\.bundleIdentifier).joined(separator: ", "))")
                    if let warning = Self.targetWarning(for: app) { print(warning) }
                    break
                }
            }
            if targetApps.isEmpty {
                print(
                    """
                    ⚠  None of the enabled meeting apps are running.
                       Falling back to ALL system audio.
                       (Enable/disable apps in Settings → Meeting apps, or use --all-audio)
                    """)
            }
        }

        print("  building filter…")
        // 3. Build content filter ─────────────────────────────────────────────
        let filter: SCContentFilter
        if targetApps.isEmpty {
            // Capture everything on the primary display
            filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
        } else {
            filter = SCContentFilter(
                display: display,
                including: targetApps,
                exceptingWindows: []
            )
        }

        print("  filter built, configuring stream…")
        // 4. Stream configuration ─────────────────────────────────────────────
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true  // don't feed our own output back
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video is required by SCStream even for audio-only capture.
        // Set minimal resolution so it barely costs anything.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps

        // 5. Prepare output URL ───────────────────────────────────────────────
        let url: URL
        if outputPath.hasPrefix("/") {
            url = URL(fileURLWithPath: outputPath)
        } else {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(outputPath)
        }
        outputURL = url

        // 6. Create the mixing writer ─────────────────────────────────────────
        print("  creating WAV at \(url.path)…")
        let writer = try TrackWriter(outputURL: url, targetDurationSeconds: duration)
        self.writer = writer
        print("  WAV file created")

        // 6b. Optionally start mic capture and route into the writer ──────────
        // The mic goes in raw: echo is removed after the call, from a copy (`EchoRemover`),
        // so the recording itself can always be gone back to.
        var micStatus = "disabled"
        var mic: MicCapture?
        if enableMic {
            do {
                let m = try MicCapture()
                m.onSamples = { [weak writer, micGate] ptr, frames in
                    guard micGate.passes else { return }
                    writer?.pushMic(mono: ptr, frameCount: frames)
                }
                try m.start()
                mic = m
                micStatus = "on (\(m.describedInputFormat))"
            } catch {
                print("  ⚠  mic unavailable: \(error.localizedDescription) — continuing system-only")
                micStatus = "unavailable"
            }
        }
        self.micCapture = mic

        // 7. Print summary ─────────────────────────────────────────────────────
        print(
            """
            ┌──────────────────────────────────────────┐
            │  Capture target : \(targetLabel.padding(toLength: 22, withPad: " ", startingAt: 0))│
            │  Mic            : \(micStatus.padding(toLength: 22, withPad: " ", startingAt: 0))│
            │  Duration       : \("\(Int(duration))s".padding(toLength: 22, withPad: " ", startingAt: 0))│
            │  Format         : \(Self.formatDescription.padding(toLength: 22, withPad: " ", startingAt: 0))│
            │  Output         : \(url.lastPathComponent.padding(toLength: 22, withPad: " ", startingAt: 0))│
            └──────────────────────────────────────────┘
            """)

        // 8. Start the stream and await completion ────────────────────────────
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream!.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: fileWriteQueue
        )

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[URL], Error>) in
            stopCont = cont
            Task {
                do {
                    try await self.stream!.startCapture()
                    self.captureStart = Date()
                    print(Self.recordingHint)
                    // A stop that came while starting is honoured now the stream can stop.
                    if self.stopper.arm() {
                        self.stopRecording(reason: .timerExpired)
                        return
                    }
                    // Auto-stop after requested duration
                    self.stopper.startTimer(after: duration) {
                        self.stopRecording(reason: .timerExpired)
                    }
                } catch {
                    _ = self.stopper.arm()
                    if self.stopper.claimStop() {
                        self.micCapture?.stop()
                        self.micCapture = nil
                        _ = self.writer?.finish()
                        self.writer = nil
                        self.stopCont = nil
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    // ─── Public: manual stop ─────────────────────────────────────────────────

    /// Stop an in-progress recording before the duration timer fires. Safe to
    /// call multiple times and from any queue. No-op if no recording is active
    /// or if a stop is already in flight.
    func manualStop() {
        stopRecording(reason: .timerExpired)
    }

    /// Toggle pause state on the active recording. Frames received while
    /// paused are dropped — the wall-clock gap simply does not exist in
    /// the output WAV. Safe to call multiple times and from any queue.
    func pauseToggle() {
        guard let writer = writer else { return }
        let paused = writer.togglePause()
        print(paused ? "\n⏸  Paused — Space+Enter to resume." : "\n▶  Resumed.")
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    private enum StopReason {
        case timerExpired
        case error(Error)
    }

    private func stopRecording(reason: StopReason) {
        guard stopper.claimStop() else { return }
        Task {
            try? await stream?.stopCapture()
            micCapture?.stop()
            micCapture = nil

            let frames = capturedFrames
            let captured = Double(frames) / 48_000.0
            let files = writer?.finish() ?? []
            writer = nil  // closing AVAudioFile flushes + finalises the WAV header

            print("\n──────────────────────────────────────────")
            switch reason {
            case .timerExpired:
                print("✅  Done!")
            case .error(let e):
                print("⚠   Stopped with error: \(e.localizedDescription)")
            }
            print(String(format: "   Captured  : %.2fs  (%d samples)", captured, frames))
            if files.count == 1 {
                let url = files[0]
                print("   Saved to  : \(url.path)")
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                    let size = attrs[.size] as? Int
                {
                    print(String(format: "   File size : %.1f KB", Double(size) / 1024))
                }
            } else if files.count > 1 {
                print("   Saved to  : \(files.count) files (chunked)")
                for (i, url) in files.enumerated() {
                    let label = i == 0 ? "part 1" : "part \(i + 1)"
                    print("      \(label): \(url.lastPathComponent)")
                }
            }

            // Diagnose a suspiciously short capture
            if captured < 0.5 {
                print(
                    """

                    ⚠  VERY SHORT CAPTURE — likely a permission issue.

                       Fix:
                       1. System Settings → Privacy & Security → Screen Recording
                          Add "Terminal" (or the compiled binary's path).
                       2. Quit and relaunch Terminal, then re-run.
                       3. If Zoom is muted, unmute it — silence is still captured
                          but verifies the pipeline.  Use --all-audio as a fallback
                          to capture system sounds (e.g. play a YouTube video).
                    """)
            }

            switch reason {
            case .timerExpired:
                stopCont?.resume(returning: files)
            case .error(let e):
                stopCont?.resume(throwing: e)
            }
            stopCont = nil
        }
    }

    // ─── Text ────────────────────────────────────────────────────────────────

    static let formatDescription = "48 kHz · 2-track · int16"
    static let recordingHint = "🔴 Recording…  (Enter to stop, Space+Enter to pause)\n"

    /// Capture is scoped to the app, so a call in another app would record nothing.
    static func targetWarning(for app: MeetingApp) -> String? {
        guard app.isBrowser else { return nil }
        return """
            ⚠  Capturing only \(app.label). If the call is in another app, this records silence.
               To capture everything: --all-audio, or Settings → Audio source → All system audio.
            """
    }

    // ─── Errors ──────────────────────────────────────────────────────────────

    enum CaptureError: Error, LocalizedError {
        case noDisplay
        var errorDescription: String? {
            "No display found — are you running on a Mac with an attached screen?"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SCStreamDelegate
// ─────────────────────────────────────────────────────────────────────────────

extension AudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("\n⚠  Stream stopped unexpectedly.")
        stopRecording(reason: .error(error))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SCStreamOutput  —  receives CMSampleBuffer, writes to WAV
// ─────────────────────────────────────────────────────────────────────────────

extension AudioCapture: SCStreamOutput {

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        // SCStream sends both video and audio frames on the same output object.
        // We only care about audio.
        guard outputType == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // Guard: don't write past the requested duration
        if let start = captureStart,
            Date().timeIntervalSince(start) > targetDuration + 1.0
        {
            return
        }

        // Convert CMSampleBuffer → AVAudioPCMBuffer → hand to the mixer
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else {
            return
        }
        micGate.open()
        writer?.pushSystem(pcmBuffer)
        printProgress(frameLength: Int(pcmBuffer.frameLength))
    }

    // Print a progress line every 5 seconds
    private func printProgress(frameLength: Int) {
        let frames = capturedFrames
        let elapsed = Double(frames) / 48_000.0
        let prevElapsed = Double(frames - frameLength) / 48_000.0
        let everyN: Double = 5
        guard Int(elapsed / everyN) > Int(prevElapsed / everyN) else { return }

        // "Open-ended" mode for very long durations (>= 4 hours)
        // Show elapsed time only, no progress bar
        if targetDuration >= 4 * 3600 {
            let mins = Int(elapsed) / 60
            let secs = Int(elapsed) % 60
            print(String(format: "  🔴  %02d:%02d elapsed  (Enter to stop)", mins, secs))
        } else {
            // Traditional progress bar for short, known durations
            let progress = min(elapsed / targetDuration, 1.0)
            let filled = Int(progress * 30)
            let bar =
                String(repeating: "█", count: filled)
                + String(repeating: "░", count: 30 - filled)
            print(String(format: "  [%@] %5.1fs / %.0fs", bar, elapsed, targetDuration))
        }
    }
}
