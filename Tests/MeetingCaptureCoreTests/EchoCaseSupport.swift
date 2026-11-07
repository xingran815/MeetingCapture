import AVFoundation
import XCTest

@testable import MeetingCaptureCore

// Helpers shared by an echo test class and its `…SlowTests` classes (D-77). A slow test is
// moved into its own class so `check.sh` can run it as its own job and CI can skip it by
// class name; the helpers it needs live here, in a base class that has no tests of its own.

class EchoRemoverTestCase: AudioTestCase {

    let rate = Double(EchoLab.rate)

    /// Runs the remover on these two tracks. Returns nil if it found no echo.
    func clean(mic: [Double], system: [Double]) throws -> (result: EchoRemover.Result, audio: [Double])? {
        try EchoLab.writeMono(mic, to: url("mic.wav"))
        try EchoLab.writeMono(system, to: url("system.wav"))
        guard let result = try EchoRemover.clean(mic: url("mic.wav"), system: url("system.wav"), to: url("out.wav"))
        else {
            XCTAssertFalse(exists("out.wav"), "nothing was found, so nothing should be left behind")
            return nil
        }
        return (result, try EchoLab.read(result.cleaned))
    }

    func correlation(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0
        var aa = 0.0
        var bb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            aa += a[i] * a[i]
            bb += b[i] * b[i]
        }
        return dot / max((aa * bb).squareRoot(), 1e-30)
    }

    // MARK: From the M3.2 re-check

    /// 1 s of far side every 10 s from 5 s to 55 s, then continuous speech from 60 s to 100 s.
    func earlyBurstsThenTalk() -> (far: [Double], echo: [Double]) {
        let speech = EchoLab.speech(seconds: 100, seed: 91, rms: 0.1)
        var far = EchoLab.only(speech, seconds: 60...100)
        for t in stride(from: 5.0, to: 56, by: 10.0) {
            far = EchoLab.sum(far, EchoLab.only(speech, seconds: t...(t + 1)))
        }
        return (far, EchoLab.echo(of: far))
    }

    /// From the M3.2 deep review, finding 1. The warp pivots at the file's start, so the
    /// reference has to be shifted by the lag there, not the median. 300 ppm over 220 s puts
    /// the middle 1584 samples from the start, past the 1440 (30 ms lead) the old code
    /// could absorb, so a shift from the median missed a fast mic clock's echo. (Above about
    /// 300 ppm the lag search itself loses the peak in a 20 s window, so this is as large as
    /// a measurable drift gets.) Both signs must clean, and the first seconds are where a
    /// shift from the median fails: the echo is then ahead of the reference.
    /// One sign per call; the +300 and -300 tests are in different slow classes.
    func assertAPartKeepsItsReductionWithAMicClock(ppm: Double) throws {
        do {
            let (result, mic, out) = try autoreleasepool { () -> (EchoRemover.Result, [Double], [Double]) in
                let far = EchoLab.speech(seconds: 220, seed: 51, rms: 0.1)
                // Padded, because a slow clock reads past the end of the source.
                let delayed = EchoLab.shifted(far, by: EchoLab.delay) + [Double](repeating: 0, count: 8_000)
                let mic = EchoLab.sum(
                    Array(EchoLab.warped(delayed, ppm: ppm).prefix(far.count)),
                    EchoLab.noise(far.count, seed: 5, rms: 0.0003))
                let (result, out) = try XCTUnwrap(try clean(mic: mic, system: far), "\(ppm) ppm")
                return (result, mic, out)
            }
            print("EchoRemoverTests: \(ppm) ppm measured as \(result.driftPPM)")
            XCTAssertEqual(result.driftPPM, ppm, accuracy: 25, "\(ppm) ppm")
            for slice in [(2.0, 8.0), (40.0, 70.0), (110.0, 140.0), (170.0, 215.0)] {
                let reduction = EchoLab.reductionDB(input: mic, output: out, from: slice.0, to: slice.1)
                print("EchoRemoverTests: \(ppm) ppm, \(slice): \(reduction) dB")
                XCTAssertGreaterThanOrEqual(reduction, 15, "\(ppm) ppm, \(slice)")
            }
            XCTAssertFalse(result.lagMoved, "a steady drift is not a moved lag")
            try FileManager.default.removeItem(at: url("out.wav"))
        }
    }
}

class EchoPipelineTestCase: AudioTestCase {

    let rate = Double(EchoLab.rate)
    let farWords = Transcriber.Segment(start: 6.0, end: 10.0, text: "words from the other side")
    /// A line with pauses in it, as Whisper makes them: a whole stretch of the far side's talk.
    let farLine = Transcriber.Segment(start: 1.0, end: 5.0, text: "a long line from the other side")
    let ownWords = Transcriber.Segment(start: 15.0, end: 20.0, text: "my own words")

    struct Call {
        let mic: [Double]
        let system: [Double]
        let voice: [Double]
    }

    /// 24 s: the far side talks for the first 12 s and the room echoes it, then the user
    /// speaks from 14 s, with the system silent.
    func call(seconds: Double = 24, farSeed: UInt64 = 11, voiceSeed: UInt64 = 77) -> Call {
        let far = EchoLab.speech(seconds: seconds, seed: farSeed, rms: 0.1)
        let system = EchoLab.only(far, seconds: 0...(seconds / 2))
        let voice = EchoLab.only(
            EchoLab.speech(seconds: seconds, seed: voiceSeed, rms: 0.1), seconds: (seconds / 2 + 2)...seconds)
        let mic = EchoLab.sum(
            EchoLab.sum(EchoLab.echo(of: system), voice), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        return Call(mic: mic, system: system, voice: voice)
    }

    func scripted(
        mic micAnswer: [Transcriber.Segment], onMic: (([Double]) -> Void)? = nil
    ) -> ScriptedTranscriber {
        ScriptedTranscriber { path in
            if path.hasSuffix(".system.wav") { return [Transcriber.Segment(start: 0.5, end: 1, text: "system")] }
            onMic?((try? EchoLab.read(URL(fileURLWithPath: path))) ?? [])
            return micAnswer
        }
    }

    func finish(
        _ parts: [URL], base: String = "m", _ transcriber: SpeechTranscribing, removeEcho: Bool = true,
        encoder: AudioEncoding = AACEncoder()
    ) async throws -> RecordingPipeline.Transcript? {
        var pipeline = RecordingPipeline(transcriber: transcriber, detector: nil)
        pipeline.removeEcho = removeEcho
        return try await RecordingPipeline.finish(
            parts: parts, base: url(base), pipeline: pipeline, encoder: encoder, now: now)
    }

    func pipeline(_ transcriber: SpeechTranscribing, removeEcho: Bool = true) -> RecordingPipeline {
        var pipeline = RecordingPipeline(transcriber: transcriber, detector: nil)
        pipeline.removeEcho = removeEcho
        return pipeline
    }

    // MARK: 8. Failure can't lose audio

    /// A 44.1 kHz stereo file: the mic and system tracks split from it aren't 48 kHz, so
    /// the remover refuses them.
    func wrongRateWAV(_ name: String) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try autoreleasepool {
            let file = try AVAudioFile(
                forWriting: url(name), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = 44_100 * 3
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<2 {
                let out = try XCTUnwrap(buffer.floatChannelData?[channel])
                for i in 0..<frames { out[i] = 0.2 * sin(Float(i) * (channel == 0 ? 0.05 : 0.03)) }
            }
            try file.write(from: buffer)
        }
    }

    func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count)
        let mb = b.reduce(0, +) / Double(b.count)
        var ab = 0.0
        var aa = 0.0
        var bb = 0.0
        for i in a.indices {
            ab += (a[i] - ma) * (b[i] - mb)
            aa += (a[i] - ma) * (a[i] - ma)
            bb += (b[i] - mb) * (b[i] - mb)
        }
        return ab / max((aa * bb).squareRoot(), 1e-30)
    }

    /// Fails only for the cleaned copy, as a full disk might at the wrong moment.
    struct CleanFailingEncoder: AudioEncoding {
        func encode(wav: URL, to m4a: URL) throws {
            if wav.lastPathComponent.contains("_clean") { throw CocoaError(.fileWriteOutOfSpace) }
            try AACEncoder().encode(wav: wav, to: m4a)
        }
    }

    /// 60 s: the far side says 1 s every 10 s, the room echoes it, the user speaks 30 to 45 s.
    func sparseCall() -> Call {
        let far = EchoLab.speech(seconds: 60, seed: 11, rms: 0.1)
        var system = [Double](repeating: 0, count: far.count)
        for t in stride(from: 5.0, to: 60, by: 10.0) {
            system = EchoLab.sum(system, EchoLab.only(far, seconds: t...(t + 1)))
        }
        let voice = EchoLab.only(EchoLab.speech(seconds: 60, seed: 77, rms: 0.1), seconds: 30...45)
        let mic = EchoLab.sum(
            EchoLab.sum(EchoLab.echo(of: system), voice), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        return Call(mic: mic, system: system, voice: voice)
    }
}

class EchoScriptFlagTestCase: AudioTestCase {

    func executable() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let exe = products.appendingPathComponent("MeetingCaptureCLI")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw XCTSkip("MeetingCaptureCLI isn't built beside the tests: \(exe.path)")
        }
        return exe
    }

    func run(
        _ arguments: [String], e2e: String?, tmp: URL? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = try executable()
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = dir.path
        environment["MEETINGCAPTURE_E2E"] = e2e
        if e2e == nil { environment.removeValue(forKey: "MEETINGCAPTURE_E2E") }
        if let tmp { environment["TMPDIR"] = tmp.path }
        process.environment = environment
        process.currentDirectoryURL = dir
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(20)  // a capture that started would still be running
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            XCTFail("the executable didn't exit: \(arguments)")
        }
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    // MARK: From the M3.2 review, finding 7

    /// Both tracks of the recording are copied into a folder in the temporary directory.
    /// `exit` would skip the `defer` that removes it, so every way out must leave none.
    /// The subprocess gets its own TMPDIR, so other tests running at once can't disturb this.
    func assertNoTempLeftBehind(
        _ args: [String], expecting status: Int32, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let tmp = dir.appendingPathComponent("tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let result = try run(args, e2e: "1", tmp: tmp)
        XCTAssertEqual(result.status, status, "\(result.stdout) \(result.stderr)", file: file, line: line)
        let left = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        XCTAssertEqual(left, [], "the temporary folder was left behind: \(args)", file: file, line: line)
    }
}
