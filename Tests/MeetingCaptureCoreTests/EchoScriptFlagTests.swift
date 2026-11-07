import XCTest

@testable import MeetingCaptureCore

/// `--clean-echo` reads a recording by path and writes a file, so like `--two-track-*` and
/// `--finish-recording` it needs MEETINGCAPTURE_E2E=1 (CLAUDE.md). These run the built
/// executable in a throwaway home folder, with no capture possible: the flag stops first.
final class EchoScriptFlagTests: AudioTestCase {

    private func executable() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let exe = products.appendingPathComponent("MeetingCaptureCLI")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw XCTSkip("MeetingCaptureCLI isn't built beside the tests: \(exe.path)")
        }
        return exe
    }

    private func run(_ arguments: [String], e2e: String?) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = try executable()
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = dir.path
        environment["MEETINGCAPTURE_E2E"] = e2e
        if e2e == nil { environment.removeValue(forKey: "MEETINGCAPTURE_E2E") }
        process.environment = environment
        process.currentDirectoryURL = dir
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(30)
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

    func testWithTheVariableARealCallIsCleanedAndTheOutputIsWritten() throws {
        let far = EchoLab.speech(seconds: 24, seed: 11, rms: 0.1)
        let mic = EchoLab.sum(EchoLab.echo(of: far), EchoLab.noise(far.count, seed: 5, rms: 0.0003))
        try EchoLab.writeTwoTrack(mic: mic, system: far, to: url("call.wav"))
        let result = try run(["--clean-echo", url("call.wav").path, "--clean-echo-out", url("out.wav").path], e2e: "1")
        XCTAssertEqual(result.status, 0, "\(result.stdout) \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("lag 150.0 ms"), result.stdout)
        XCTAssertEqual(try EchoLab.read(url("out.wav")).count, mic.count)
    }
}
