import AVFoundation
import XCTest

@testable import MeetingCaptureCore

/// Slow `--clean-echo` runs of the built executable (D-77).
final class EchoScriptFlagSlowTests: EchoScriptFlagTestCase {

    func testWithTheVariableARealCallIsCleanedAndTheOutputIsWritten() throws {
        let far = EchoLab.speech(seconds: 24, seed: 11, rms: 0.1)
        let mic = EchoLab.sum(EchoLab.echo(of: far), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        try EchoLab.writeTwoTrack(mic: mic, system: far, to: url("call.wav"))
        let result = try run(["--clean-echo", url("call.wav").path, "--clean-echo-out", url("out.wav").path], e2e: "1")
        XCTAssertEqual(result.status, 0, "\(result.stdout) \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("lag 150.0 ms"), result.stdout)
        XCTAssertEqual(try EchoLab.read(url("out.wav")).count, mic.count)
    }

    func testCleaningLeavesNoTemporaryFolderOnSuccess() throws {
        let far = EchoLab.speech(seconds: 24, seed: 11, rms: 0.1)
        let mic = EchoLab.sum(EchoLab.echo(of: far), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        try EchoLab.writeTwoTrack(mic: mic, system: far, to: url("call.wav"))
        try assertNoTempLeftBehind(
            ["--clean-echo", url("call.wav").path, "--clean-echo-out", url("out.wav").path], expecting: 0)
        XCTAssertTrue(exists("out.wav"))
    }
}
