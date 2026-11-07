import XCTest

@testable import MeetingCaptureCore

/// `--clean-echo` reads a recording by path and writes a file, so like `--two-track-*` and
/// `--finish-recording` it needs MEETINGCAPTURE_E2E=1 (CLAUDE.md). These run the built
/// executable in a throwaway home folder, with no capture possible: the flag stops first.
final class EchoScriptFlagTests: EchoScriptFlagTestCase {


    func testCleanEchoWithoutTheE2EVariableStopsWithAnError() throws {
        let args = ["--clean-echo", url("in.wav").path, "--clean-echo-out", url("out.wav").path]
        for value in [nil, "0", "", "true"] as [String?] {
            let result = try run(args, e2e: value)
            XCTAssertEqual(result.status, 2, "E2E=\(value ?? "unset"): \(result.stdout) \(result.stderr)")
            XCTAssertTrue(result.stderr.contains("--clean-echo"), result.stderr)
            XCTAssertTrue(result.stderr.contains("MEETINGCAPTURE_E2E=1"), result.stderr)
            XCTAssertFalse(exists("out.wav"))
        }
    }

    func testCleanEchoAloneWithoutTheVariableDoesNotFallThroughToACapture() throws {
        // No `--clean-echo-out`: the flag still stops, rather than being ignored.
        let result = try run(["--clean-echo", url("in.wav").path], e2e: nil)
        XCTAssertEqual(result.status, 2, "\(result.stdout) \(result.stderr)")
    }

    func testWithTheVariableAMissingFileIsAnErrorNotACapture() throws {
        let result = try run(
            ["--clean-echo", url("missing.wav").path, "--clean-echo-out", url("out.wav").path], e2e: "1")
        XCTAssertEqual(result.status, 1, "\(result.stdout) \(result.stderr)")
        XCTAssertFalse(exists("out.wav"))
    }

    func testWithTheVariableARecordingWithOnlyOneTrackIsRefused() throws {
        try wav("mono.wav", seconds: 3, mic: false, system: true)  // the mic channel is silent
        let result = try run(["--clean-echo", url("mono.wav").path, "--clean-echo-out", url("out.wav").path], e2e: "1")
        XCTAssertEqual(result.status, 1, "\(result.stdout) \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("both tracks"), result.stderr)
        XCTAssertFalse(exists("out.wav"))
    }

    // MARK: From the M3.2 review, finding 6

    /// `--diarize`, `--threshold` and `--clean-echo-out` also take a path or run a lab step,
    /// so they stop without the variable too, and no capture starts (it would run for 8 hours).
    func testTheLabOnlyFlagsStopWithoutTheVariable() throws {
        let cases: [[String]] = [
            ["--diarize", url("in.wav").path],
            ["--diarize"],
            ["--threshold", "0.5"],
            ["--clean-echo-out", url("out.wav").path],
        ]
        for args in cases {
            for value in [nil, "0", "", "true"] as [String?] {
                let result = try run(args, e2e: value)
                XCTAssertEqual(result.status, 2, "\(args), E2E=\(value ?? "unset"): \(result.stdout) \(result.stderr)")
                XCTAssertTrue(result.stderr.contains("only for the test scripts"), result.stderr)
                XCTAssertTrue(result.stderr.contains(args[0]), result.stderr)
                XCTAssertFalse(exists("out.wav"))
            }
        }
    }

    /// From the M3.2 deep review, finding 9. With the variable set, `--diarize` with no file
    /// and a lone `--threshold` used to be ignored and fall through to a real capture.
    func testBareDiarizeAndALoneThresholdExitWithTwoInsteadOfCapturing() throws {
        let cases: [[String]] = [
            ["--diarize"],
            ["--threshold", "0.5"],
            ["--threshold"],
        ]
        for args in cases {
            let result = try run(args, e2e: "1")
            XCTAssertEqual(result.status, 2, "\(args): \(result.stdout) \(result.stderr)")
            XCTAssertTrue(result.stderr.contains("--diarize needs a file"), "\(args): \(result.stderr)")
        }
    }

    /// With the variable set, half a pair would otherwise be ignored and fall into a real capture.
    func testHalfAPairOfScriptFlagsExitsWithTwoInsteadOfCapturing() throws {
        let mic = ["--two-track-mic", url("a.wav").path]
        let system = ["--two-track-system", url("b.wav").path]
        let out = ["--two-track-out", url("c.wav").path]
        let cases: [[String]] = [
            ["--clean-echo", url("in.wav").path],
            ["--clean-echo-out", url("out.wav").path],
            mic, system, out, mic + system, mic + out, system + out,
            ["--clean-echo"],  // no value at all
            ["--clean-echo", url("in.wav").path, "--clean-echo-out"],
        ]
        for args in cases {
            let result = try run(args, e2e: "1")
            XCTAssertEqual(result.status, 2, "\(args): \(result.stdout) \(result.stderr)")
            XCTAssertTrue(result.stderr.contains("go together"), "\(args): \(result.stderr)")
            XCTAssertFalse(exists("out.wav"))
            XCTAssertFalse(exists("c.wav"))
        }
    }

    func testCleaningLeavesNoTemporaryFolderWhenNoEchoIsFound() throws {
        let far = EchoLab.speech(seconds: 12, seed: 11, rms: 0.1)
        let voice = EchoLab.speech(seconds: 12, seed: 77, rms: 0.1)  // headphones
        try EchoLab.writeTwoTrack(mic: voice, system: far, to: url("call.wav"))
        try assertNoTempLeftBehind(
            ["--clean-echo", url("call.wav").path, "--clean-echo-out", url("out.wav").path], expecting: 0)
        XCTAssertFalse(exists("out.wav"))
    }

    func testCleaningLeavesNoTemporaryFolderWhenATrackIsMissing() throws {
        try wav("mono.wav", seconds: 3, mic: false, system: true)
        try assertNoTempLeftBehind(
            ["--clean-echo", url("mono.wav").path, "--clean-echo-out", url("out.wav").path], expecting: 1)
    }

    func testCleaningLeavesNoTemporaryFolderOnABadPath() throws {
        try assertNoTempLeftBehind(
            ["--clean-echo", url("missing.wav").path, "--clean-echo-out", url("out.wav").path], expecting: 1)
        try touch("notaudio.wav", contents: Data("not audio".utf8))
        try assertNoTempLeftBehind(
            ["--clean-echo", url("notaudio.wav").path, "--clean-echo-out", url("out.wav").path], expecting: 1)
        // An output path that can't be written.
        let far = EchoLab.speech(seconds: 24, seed: 11, rms: 0.1)
        let mic = EchoLab.sum(EchoLab.echo(of: far), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        try EchoLab.writeTwoTrack(mic: mic, system: far, to: url("call.wav"))
        try assertNoTempLeftBehind(
            ["--clean-echo", url("call.wav").path, "--clean-echo-out", url("no/such/dir/out.wav").path], expecting: 1)
    }
}
