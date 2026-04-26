import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

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
    private var writer:        MixingWriter?
    private var outputURL:     URL?
    private var targetDuration: Double = 0

    // Protected by fileWriteQueue
    private var sampleCount:   Int  = 0
    private var captureStart:  Date?

    private var stream:    SCStream?
    private var micCapture: MicCapture?
    private var echo: EchoCanceller?

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

    func run(duration: Double, outputPath: String, captureAllAudio: Bool, enableMic: Bool, aecEnabled: Bool) async throws -> [URL] {
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
        //    Ordered by priority; we take the first match.
        let candidates: [(label: String, bundleIDs: [String])] = [
            ("Zoom",             ["us.zoom.xos",
                                  "us.zoom.xos.ZoomMTRunning",
                                  "us.zoom.xos.ZoomAudio"]),
            ("Microsoft Teams",  ["com.microsoft.teams",
                                  "com.microsoft.teams2"]),
            ("Webex",            ["Cisco-Systems.Spark",
                                  "com.cisco.webexmeetings"]),
            // Google Meet runs inside Chrome/Safari – capturing the browser
            // captures Meet audio as well.
            ("Google Chrome",    ["com.google.Chrome"]),
            ("Safari",           ["com.apple.Safari"]),
        ]

        var targetApps: [SCRunningApplication] = []
        var targetLabel = "all system audio"

        if !captureAllAudio {
            for (label, ids) in candidates {
                let found = content.applications.filter { ids.contains($0.bundleIdentifier) }
                if !found.isEmpty {
                    targetApps = found
                    targetLabel = label
                    print("Found \(label): \(found.map(\.bundleIdentifier).joined(separator: ", "))")
                    break
                }
            }
            if targetApps.isEmpty {
                print("""
                ⚠  No supported meeting app detected.
                   Falling back to ALL system audio.
                   (Tip: open Zoom/Teams/etc. before running, or use --all-audio)
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
        config.capturesAudio             = true
        config.excludesCurrentProcessAudio = true   // don't feed our own output back
        config.sampleRate                = 48_000
        config.channelCount              = 2
        // Video is required by SCStream even for audio-only capture.
        // Set minimal resolution so it barely costs anything.
        config.width                     = 2
        config.height                    = 2
        config.minimumFrameInterval      = CMTime(value: 1, timescale: 1)  // 1 fps

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
        let writer = try MixingWriter(outputURL: url)
        self.writer = writer
        print("  WAV file created")

        // 6b. Optionally start mic capture and route into the writer ──────────
        // When AEC is enabled, mic samples flow through EchoCanceller first;
        // its onCleanMic callback then feeds MixingWriter. When AEC is off,
        // MicCapture feeds MixingWriter directly.
        var micStatus = "disabled"
        var aecStatus = "off"
        var mic: MicCapture?
        var canceller: EchoCanceller?
        if enableMic {
            do {
                let m = try MicCapture()
                if aecEnabled {
                    let c = EchoCanceller()
                    c.onCleanMic = { [weak writer] ptr, frames in
                        writer?.pushMic(mono: ptr, frameCount: frames)
                    }
                    m.onSamples = { [weak c] ptr, frames in
                        c?.pushMic(ptr, frameCount: frames)
                    }
                    canceller = c
                    aecStatus = "on (Speex, 150 ms tail)"
                } else {
                    m.onSamples = { [weak writer] ptr, frames in
                        writer?.pushMic(mono: ptr, frameCount: frames)
                    }
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
        self.echo = canceller

        // 7. Print summary ─────────────────────────────────────────────────────
        print("""
        ┌──────────────────────────────────────────┐
        │  Capture target : \(targetLabel.padding(toLength: 22, withPad: " ", startingAt: 0))│
        │  Mic            : \(micStatus.padding(toLength: 22, withPad: " ", startingAt: 0))│
        │  AEC            : \(aecStatus.padding(toLength: 22, withPad: " ", startingAt: 0))│
        │  Duration       : \("\(Int(duration))s".padding(toLength: 22, withPad: " ", startingAt: 0))│
        │  Format         : 48 kHz · stereo · f32  │
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
                    print("🔴 Recording…  (Ctrl+C to stop early)\n")
                    // Auto-stop after requested duration
                    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                        self.stopRecording(reason: .timerExpired)
                    }
                } catch {
                    cont.resume(throwing: error)
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

    private enum StopReason { case timerExpired, error(Error) }

    private func stopRecording(reason: StopReason) {
        Task {
            try? await stream?.stopCapture()
            micCapture?.stop()
            micCapture = nil
            echo = nil

            let captured = Double(sampleCount) / 48_000.0
            let files = writer?.finish() ?? []
            writer = nil        // closing AVAudioFile flushes + finalises the WAV header

            print("\n──────────────────────────────────────────")
            switch reason {
            case .timerExpired:
                print("✅  Done!")
            case .error(let e):
                print("⚠   Stopped with error: \(e.localizedDescription)")
            }
            print(String(format: "   Captured  : %.2fs  (%d samples)", captured, sampleCount))
            if files.count == 1 {
                let url = files[0]
                print("   Saved to  : \(url.path)")
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int {
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
                print("""

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
           Date().timeIntervalSince(start) > targetDuration + 1.0 { return }

        // Convert CMSampleBuffer → AVAudioPCMBuffer → hand to the mixer
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else {
            return
        }
        writer?.pushSystem(pcmBuffer)
        echo?.pushReference(pcmBuffer)
        sampleCount += Int(pcmBuffer.frameLength)
        printProgress()
    }

    // Print a progress line every 5 seconds
    private func printProgress() {
        let elapsed   = Double(sampleCount) / 48_000.0
        let prevElapsed = Double(sampleCount - 1024) / 48_000.0   // approximate previous
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
            let bar = String(repeating: "█", count: filled)
                + String(repeating: "░", count: 30 - filled)
            print(String(format: "  [%@] %5.1fs / %.0fs", bar, elapsed, targetDuration))
        }
    }
}
